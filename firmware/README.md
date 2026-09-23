# KeybowNotes firmware

CircuitPython for the Pimoroni Keybow 2040. It reports key presses and obeys LED
commands; the Mac app holds the category tree and all the logic.

**Untested on hardware so far** — written from the documented API, and the key
numbering in particular needs checking with the probe tool below.

## Install

1. **CircuitPython.** Hold BOOTSEL while plugging the Keybow in, and drop the
   Keybow 2040 `.uf2` from [circuitpython.org](https://circuitpython.org/board/pimoroni_keybow2040/)
   onto the RPI-RP2 drive. It reboots as `CIRCUITPY`.
2. **The PMK library.** Copy the `pmk` folder from Pimoroni's
   [pmk-circuitpython](https://github.com/pimoroni/pmk-circuitpython) repo into
   `CIRCUITPY/lib/`.
3. **This firmware.** Copy `boot.py`, `code.py` and `keymap.py` to the root of
   `CIRCUITPY`.
4. **Hard reset** — press the reset button or unplug and replug. `boot.py` only
   runs at power-on, and until it does there is no data port.

## Ports

After the reset the Keybow presents two serial ports:

- the **console** (the REPL), for `print()` output and debugging
- the **data** port, which carries the protocol

The Mac app finds them by USB vendor and product ID, not by device path, and
talks on the data port. To watch the console yourself:

```bash
ls /dev/cu.usbmodem*
screen /dev/cu.usbmodemXXXX 115200
```

(Leave `screen` with Ctrl-A then Ctrl-\.)

## Checking the key numbering

The protocol numbers keys as you see them — 0-3 along the top row, 12-15 along
the bottom. The hardware counts up the columns from the bottom-left, and which
corner is "top-left" depends on where the USB socket is.

Copy `tools/keymap_probe.py` over `code.py`, open the console, and press keys.
Each prints the logical number it would report. If the top row does not give
0, 1, 2, 3 left to right, set `ROTATION` in `keymap.py` to where the socket
actually sits (`top`, `bottom`, `left` or `right`) and try again. Then put the
real `code.py` back.

## Protocol

UTF-8 text, one message per line, on the data port.

| Direction | Message | Meaning |
|---|---|---|
| Keybow → Mac | `HELLO keybow 1` | On boot, and whenever the host reappears |
| Keybow → Mac | `DOWN <n>` / `UP <n>` | Key 0-15 pressed / released |
| Mac → Keybow | `LEDS <96 hex chars>` | 16 `rrggbb` colours, in logical key order |
| Mac → Keybow | `PING` → `PONG` | Heartbeat |
| Keybow → Mac | `ERR <reason>` | A line that could not be acted on |

Any line from the host counts as a heartbeat. After `HOST_TIMEOUT_S` (5s) of
silence the keys breathe dim red, so a Mac app that has died or was never
started is visible at a glance. All keys lighting **blue** instead means
`usb_cdc.data` is missing: `boot.py` did not run, so hard-reset the device.

## Trying it by hand

With the app not running, on the data port:

```
PING
LEDS ff0000 00ff00 0000ff 000000 000000 000000 000000 000000 000000 000000 000000 000000 000000 000000 000000 000000
```

Spaces in the `LEDS` payload are ignored, so it can be written either way. That
should answer `PONG` and light the first three keys red, green and blue.
