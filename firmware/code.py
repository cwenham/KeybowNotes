# KeybowNotes firmware.
#
# The Mac owns the category tree, the colours and all the logic. This reports
# key presses and obeys LED commands, nothing more.
#
# Protocol (UTF-8 text, one message per line, on the USB CDC *data* port):
#
#   -> HELLO keybow 1              sent on boot and whenever the host reappears
#   -> DOWN <n> / UP <n>           key 0-15, numbered as you see them
#   <- LEDS <96 hex chars>         16 colours, rrggbb each, logical order
#   <- PING            -> PONG     heartbeat
#   -> ERR <reason>                a line we could not act on
#
# If the host goes quiet the keys breathe red, so a Mac app that has died or
# was never started is obvious rather than silently swallowing presses.

import time

import usb_cdc
from pmk import PMK
from pmk.platform.keybow2040 import Keybow2040 as Hardware

from keymap import LOGICAL_TO_PHYSICAL, PHYSICAL_TO_LOGICAL

PROTOCOL_VERSION = 1

# How long without a line from the host before we assume it has gone.
HOST_TIMEOUT_S = 5.0

# "No host" breathing pattern.
IDLE_COLOUR = (60, 0, 0)
IDLE_PERIOD_S = 3.0
IDLE_MIN = 0.08
IDLE_MAX = 1.0

KEY_COUNT = 16

keybow = PMK(Hardware())
keys = keybow.keys
serial = usb_cdc.data

# Kept as bytes, not bytearray: CircuitPython's bytearray has no slice deletion.
_rx = b""
_pressed = [False] * KEY_COUNT
_host_last_seen = 0.0
_host_present = False


def send(line):
    """Write one protocol line, ignoring a host that is not listening."""
    if serial is None or not serial.connected:
        return
    try:
        serial.write(line.encode("utf-8") + b"\n")
    except OSError:
        # Host vanished mid-write; the heartbeat will notice shortly.
        pass


def set_all(colour):
    r, g, b = colour
    for key in keys:
        key.set_led(r, g, b)


def apply_leds(payload):
    """LEDS <96 hex chars>: 16 rrggbb colours in logical key order."""
    payload = payload.replace(" ", "")
    if len(payload) != KEY_COUNT * 6:
        send("ERR LEDS expects %d hex characters, got %d" % (KEY_COUNT * 6, len(payload)))
        return
    for logical in range(KEY_COUNT):
        chunk = payload[logical * 6:(logical + 1) * 6]
        try:
            value = int(chunk, 16)
        except ValueError:
            send("ERR LEDS bad colour %r for key %d" % (chunk, logical))
            return
        key = keys[LOGICAL_TO_PHYSICAL[logical]]
        key.set_led((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)


def handle(line):
    global _host_last_seen, _host_present

    line = line.strip()
    if not line:
        return

    # Anything at all means the host is alive.
    _host_last_seen = time.monotonic()
    if not _host_present:
        _host_present = True
        send("HELLO keybow %d" % PROTOCOL_VERSION)

    if line == "PING":
        send("PONG")
    elif line.startswith("LEDS "):
        apply_leds(line[5:])
    else:
        send("ERR unknown command %r" % line[:32])


def read_serial():
    """Drain whatever has arrived and act on each complete line."""
    global _rx

    if serial is None or not serial.connected:
        return
    waiting = serial.in_waiting
    if not waiting:
        return
    _rx += serial.read(waiting)
    while b"\n" in _rx:
        raw, _, _rx = _rx.partition(b"\n")
        try:
            handle(raw.decode("utf-8"))
        except UnicodeError:
            send("ERR line was not valid UTF-8")


def read_keys():
    for physical, key in enumerate(keys):
        logical = PHYSICAL_TO_LOGICAL[physical]
        if key.pressed and not _pressed[logical]:
            _pressed[logical] = True
            send("DOWN %d" % logical)
        elif not key.pressed and _pressed[logical]:
            _pressed[logical] = False
            send("UP %d" % logical)


def breathe(now):
    """Dim pulse across all keys while no host is talking to us."""
    # Triangle wave: 0 -> 1 -> 0 over IDLE_PERIOD_S.
    phase = (now % IDLE_PERIOD_S) / IDLE_PERIOD_S
    level = phase * 2 if phase < 0.5 else (1.0 - phase) * 2
    scale = IDLE_MIN + (IDLE_MAX - IDLE_MIN) * level
    set_all(tuple(int(channel * scale) for channel in IDLE_COLOUR))


if serial is None:
    # boot.py did not run, or the data port is disabled. Say so on the console
    # and light everything blue, since the protocol cannot work at all.
    print("usb_cdc.data is not available — check boot.py and hard-reset the Keybow")
    set_all((0, 0, 60))
    while True:
        keybow.update()
        time.sleep(0.1)

send("HELLO keybow %d" % PROTOCOL_VERSION)
set_all((0, 0, 0))

while True:
    keybow.update()
    read_serial()
    read_keys()

    now = time.monotonic()
    if _host_present and now - _host_last_seen > HOST_TIMEOUT_S:
        _host_present = False
    if not _host_present:
        breathe(now)

    time.sleep(0.005)
