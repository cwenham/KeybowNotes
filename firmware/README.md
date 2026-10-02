# KeybowNotes firmware

CircuitPython for Pimoroni's 4×4 keypads: the **Keybow 2040**, and the **RGB
Keypad Base** on a Raspberry Pi Pico. It reports key presses and obeys LED
commands; the Mac app holds the category tree and all the logic. One firmware
runs on both — it tells which board it's on from CircuitPython's `board_id` —
and the app drives any number of them at once.

**Verified on hardware** (2026-09-23): CircuitPython 10.3.1 on a Keybow 2040,
with `pmk` unchanged. `HELLO`, `PING`/`PONG`, `LEDS`, the error replies and
`DOWN`/`UP` for all keys all behave as specified, and `ROTATION = "top"` gives
the numbering the protocol expects (top row 0-3, left column 0, 4, 8, 12).
Also run on a Pico with the RGB Keypad Base: on CircuitPython 8.2.10
(2026-10-01), and on 10.3.1, which the app's setup installed (2026-10-02).

## Install

**The easy way:** in the app, choose *Set Up a Keypad…* from the menu bar — or
run `keybow setup` from the `mac` folder. Either one:

1. finds the newest CircuitPython release the firmware supports — the range is in
   `manifest.json` — that's built for the board, and downloads it from
   circuitpython.org into `~/Library/Caches/KeybowNotes/CircuitPython`, checking
   it's a whole RP2040 UF2 image;
2. restarts the board in its bootloader: a board running this firmware is sent
   `STOP` on its data port, and its console then runs the restart; failing that,
   the "1200-baud touch" on the console; failing that, it asks for the BOOT button;
3. copies CircuitPython to the RPI-RP2 drive, and waits for CIRCUITPY;
4. copies the files `manifest.json` names for that board, writing only those that
   differ, and setting `code.txt` aside, since it would run instead. Whatever it
   replaces goes first to
   `~/Library/Application Support/KeybowNotes/Keypad Backups`;
5. ejects the drive and restarts the board the same way, so `boot.py` runs, and
   waits for it to say hello.

A board already on a CircuitPython the firmware supports can keep it, and the
firmware is all that's copied. The app carries this folder in its Resources as
`Firmware`; a development build uses the repository's.

**By hand:**

1. **CircuitPython.** Hold BOOTSEL while plugging the board in, and drop its
   `.uf2` from circuitpython.org onto the RPI-RP2 drive — the
   [Keybow 2040's](https://circuitpython.org/board/pimoroni_keybow2040/), or for
   the RGB Keypad the [Pico's](https://circuitpython.org/board/raspberry_pi_pico/).
   It reboots as `CIRCUITPY`.
2. **Libraries.** Copy `lib/pmk` to `CIRCUITPY/lib/`, with the board's LED
   driver: `lib/adafruit_is31fl3731` for the Keybow 2040, `lib/adafruit_dotstar.py`
   for the RGB Keypad. They're here as source, so they run on any version the
   firmware supports; [lib/README.md](lib/README.md) says where each is from.
3. **This firmware.** Copy `boot.py`, `code.py` and `keymap.py` to the root of
   `CIRCUITPY`. A board that has run something else may hold a `code.txt`,
   `main.py` or `main.txt`; CircuitPython runs the first of `code.txt`,
   `code.py`, `main.txt`, `main.py`, so set the others aside.
4. **Hard reset** — press the reset button or unplug and replug. `boot.py` only
   runs at power-on, and until it does there is no data port. From the console,
   `import microcontroller; microcontroller.reset()` does the same.

## Ports

After the reset the keypad presents two serial ports:

- the **console** (the REPL), for `print()` output and debugging
- the **data** port, which carries the protocol

The Mac app finds them by USB vendor and product ID, not by device path, and
talks on the data port. It tells keypads apart by their USB serial number,
which CircuitPython sets to the board's unique ID; a board with only one port —
`boot.py` not yet run — isn't taken for a keypad. `keybow keypads` lists those
it finds. The RGB Keypad is known by the Pico's IDs, so any Pico running
CircuitPython with a data port counts as one. To watch the console yourself:

```bash
ls /dev/cu.usbmodem*
screen /dev/cu.usbmodemXXXX 115200
```

(Leave `screen` with Ctrl-A then Ctrl-\.)

## Checking the key numbering

The protocol numbers keys as you see them — 0-3 along the top row, 12-15 along
the bottom. The hardware counts up the columns from the bottom-left, and which
corner is "top-left" depends on where the USB socket is. `keymap.py` keeps a
rotation per board, in `ROTATIONS`; pmk numbers the RGB Keypad as it does the
Keybow, so both start at `top`.

Copy `tools/keymap_probe.py` over `code.py`, open the console, and press keys.
Each prints the logical number it would report. If the top row does not give
0, 1, 2, 3 left to right, set the board's entry in `ROTATIONS` in `keymap.py`
to where the socket actually sits (`top`, `bottom`, `left` or `right`) and try
again. Then put the real `code.py` back.

## Protocol

UTF-8 text, one message per line, on the data port.

| Direction | Message | Meaning |
|---|---|---|
| Keybow → Mac | `HELLO keybow 2 <model> <id>` | On boot, and whenever the host reappears: the model — `keybow2040` or `rgbkeypad` — and the board's unique ID |
| Keybow → Mac | `DOWN <n>` / `UP <n>` | Key 0-15 pressed / released |
| Mac → Keybow | `LEDS <96 hex chars>` | 16 `rrggbb` colours, in logical key order |
| Mac → Keybow | `PING` → `PONG` | Heartbeat |
| Mac → Keybow | `STOP` → `BYE` | End the program, freeing the console's prompt: it ignores Ctrl-C. Setup uses it to restart the board |
| Keybow → Mac | `ERR <reason>` | A line that could not be acted on |

Any line from the host counts as a heartbeat. After `HOST_TIMEOUT_S` (5s) of
silence the keys breathe dim red, so a Mac app that has died or was never
started is visible at a glance. All keys lighting **blue** instead means
`usb_cdc.data` is missing: `boot.py` did not run, so hard-reset the device.

## The host must hold the port open

The firmware only writes when CircuitPython reports the host as connected, which
means **DTR asserted**. A tool that opens the port, writes a line and closes it
again drops DTR between calls, and replies are silently discarded — the symptom
is commands that appear to be ignored while the device is working perfectly.

The Mac app therefore opens the data port once and keeps it open for as long as
the device is present. `HELLO` is sent on boot and again whenever a host starts
talking after a silence, so the app can resynchronise without a reset.

## Trying it by hand

With the app not running, on the data port:

```
PING
LEDS ff0000 00ff00 0000ff 000000 000000 000000 000000 000000 000000 000000 000000 000000 000000 000000 000000 000000
```

Spaces in the `LEDS` payload are ignored, so it can be written either way. That
should answer `PONG` and light the first three keys red, green and blue.

Version 1 sent only `HELLO keybow 1`. The app still takes it — it knows the
model and ID from USB — so a keypad on older firmware keeps working.
