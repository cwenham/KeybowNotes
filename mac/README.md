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

Not built yet: reconnect has only been exercised incidentally (unplug/replug
still needs a proper test), and everything above the transport — config loading,
the tree, the overlay, the actions.
