# KeybowNotes — Mac side

A Swift package, built and tested from the terminal. The SwiftUI menu-bar app
will be added later as an Xcode project that depends on `KeybowKit`; keeping the
device layer here means it can be exercised without a GUI.

```bash
swift build
swift test
```

## KeybowKit

| File | What it does |
|---|---|
| `Protocol.swift` | `DeviceMessage`, `HostCommand`, `KeyColour`, key numbering |
| `USBSerialPorts.swift` | Finds the Keybow's serial ports through the IO registry, by USB vendor/product ID |
| `SerialPort.swift` | A raw port held open, plus line assembly |
| `KeybowConnection.swift` | Connect, heartbeat, reconnect; an `AsyncStream` of events |
| `Config.swift` | JSON config into a validated tree, with errors that name the offending node |
| `Navigator.swift` | The selection state machine; time is injected, so it tests without waiting |
| `Lighting.swift` | Selection state into 16 key colours |
| `SelectionDriver.swift` | Joins device to navigator: keys in, lights out, events published |

Two details that are easy to get wrong, both learned the hard way:

- **The port must stay open.** The firmware writes only while the host asserts
  DTR. Opening a port per command loses every reply while the device looks
  perfectly healthy.
- **The data port is not found by name.** `/dev/cu.usbmodem*` numbering changes.
  Ports are matched by USB IDs (`0x16d0:0x08c6`) and the data port is the one on
  the higher USB interface number — on this machine, console 1 and data 3. When
  walking the IO registry for those IDs, don't stop at the first entry carrying
  `idVendor`: the ACM driver copies it onto itself, so stopping early skips the
  interface entry that holds `bInterfaceNumber`.

## The `keybow` command

```bash
swift build
./.build/debug/keybow ports     # list the device's serial ports
./.build/debug/keybow ping      # connect, ping, print replies
./.build/debug/keybow watch     # print key events until Ctrl-C
./.build/debug/keybow demo      # light each key in turn
./.build/debug/keybow leds ff0000 00ff00 0000ff 000000
```

`leds` takes 1-16 `rrggbb` values; the last one fills the remaining keys.

## Status

Working against the hardware: discovery, connect, `HELLO`, `PING`/`PONG`,
`LEDS`, and `DOWN`/`UP` with correct row/column reporting.

**Reconnect verified** by unplugging mid-session: the supervisor reported
"device disappeared", reconnected by itself when the Keybow came back, and keys
worked again with no intervention. Overlapping presses interleave correctly
(`DOWN 4, DOWN 0, UP 4, UP 0`), so chords and press-and-hold are both workable.

**Config and tree navigation verified on hardware**: four-level walks, branches
that end early, switching mid-path, invalid presses ignored with a red flash,
parameter inheritance, and the commit window with its cancel.

Not built yet: the overlay, and the actions themselves — `run` prints what it
would do and executes nothing.

### A trap worth remembering

`AsyncStream` has a **single** consumer. Two `for await` loops over the same
stream compete, and each sees only some events — which silently ate key presses
until `SelectionDriver` became the sole consumer and republished what others
need.
