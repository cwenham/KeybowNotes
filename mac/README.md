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
| `Config.swift` | JSON config into validated trees: inheritance, lists, contacts, projects; errors name the offending node |
| `DateExpression.swift` | "today", "tomorrow 14:00", "next friday", "+90m" into dates |
| `OutlineConverter.swift` | A numbered outline into a config, reporting guesses and gaps |
| `Navigator.swift` | The selection state machine across four trees; time is injected, so it tests without waiting |
| `Lighting.swift` | Selection state into 16 key colours |
| `SelectionDriver.swift` | Joins device to navigator: keys in, lights out, events and state snapshots published |
| `Template.swift` | `{{placeholders}}`, fallbacks and date built-ins, reporting what is missing |
| `ActionSummary.swift` | "New event · Meeting · Sun 27 Sep, 09:00" — what an action will do |
| `NotesHTML.swift` | Markdown templates into the HTML Notes accepts |
| `ActionPlan.swift` | A selection into exactly what to do, or a clear reason it can't — pure, tested |
| `ActionRunner.swift` | Carries a plan out: AppleScript via `osascript`, `NSWorkspace`, `shortcuts` |
| `EventKitService.swift` | Events and reminders through EventKit, in the packaged app |

## The app

### Building and installing KeybowNotes.app

```bash
scripts/build-app.sh             # → build/KeybowNotes.app
scripts/build-app.sh --install   # and copy it to /Applications, quitting a running copy
```

A universal (Intel and Apple Silicon) release build, with its Info.plist, icon,
example config and templates, signed with the first "Apple Development"
identity in your keychain. macOS remembers permissions by signature, and a real
identity keeps them across rebuilds; an ad-hoc signature would be asked about
again after every build. The first signing asks whether `codesign` may use your
key — that dialog can open behind other windows and isn't in Exposé or the Dock.

Once installed it runs like any menu-bar app:

- **The tree** is `~/Library/Application Support/KeybowNotes/tree.md`, with
  templates in `templates/` beside it. On first run with no tree, the example
  (`tree.demo.md`) is installed there. The app compiles it as it loads it; edits
  are picked up within a couple of seconds, or at once from the editor. A
  mistake is reported in the menu, and costs only the part of the tree it's in.
- **State** — the stopwatch, data sources and where each `{{quote}}` sequence
  has got to — is kept in `state.json` beside the tree, each module in its own
  part. Settings stay in the app's preferences, and secrets in the Keychain.
- **One copy only** — two would compete for the Keybow, so a second refuses to start.
- **Edit Tree…** (⌘E from the menu) opens the tree editor on `tree.md`: an
  outliner with the keypad's rules built in, an inspector that edits a node's
  settings as syntax, and a drawing of the keys. Saving puts it in use at once.
  See [docs/TREE-EDITOR.md](../docs/TREE-EDITOR.md).
- **Settings** (⌘, from the menu): Open at login, dry run, key brightness, which
  screen the overlay uses, timings, the default calendar and reminders list, and
  which tree to load. Settings belong to this Mac and live in
  UserDefaults; the tree stays in its file. A timing slider overrides the
  file's value only once moved, and says which is in force.
- **Logs** go to the unified log. From a terminal (zsh has its own `log`, hence the path):

  ```bash
  /usr/bin/log stream --predicate 'subsystem == "io.github.cwenham.keybownotes"'
  ```

- **Permissions**: Notes and Mail each ask once, as "KeybowNotes". Calendar and
  Reminders go through EventKit and need **full** access — use *Allow Calendar
  and Reminders Access…* in the menu to answer those prompts up front.

### Running from the package, for development

```bash
swift run keybownotes --config tree.demo.md
```

A menu-bar app (no Dock icon) that drives the Keybow and shows a HUD overlay:
which tree you are in, the path so far, the next row's choices laid out where
they sit on the keypad, a mirror of the key lights, the commit countdown, then
the action running and its result. `tree.demo.md` has made-up trees in all
four positions; its templates are in `templates/`. `--config` also takes a
compiled `.json` file.

Run from a terminal, macOS attributes permission prompts to the terminal app
rather than KeybowNotes; each app you drive asks once.

| Option | |
|---|---|
| `--dry-run` | show what each action would do without doing it (also in the menu) |
| `--screen main` | show on the display with the menu bar, rather than the one with the cursor |
| `--simulate "4 8 12"` | press these keys (0-15) in turn, with or without a Keybow |
| `--pace 1.5` | seconds between simulated presses |
| `--debug-snapshots <dir>` | write each overlay state as a PNG and log its window frame |

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

Config commands:

```bash
./.build/debug/keybow convert tree.md                  # print the JSON it compiles to
./.build/debug/keybow tree tree.md                     # print the trees and each leaf's action
./.build/debug/keybow run tree.md                      # drive the Keybow; prints, runs nothing
```

The config language — the outline syntax and its keywords, the JSON form, how a
leaf's action is worked out, and every action's fields — is described in
[docs/CONFIG-LANGUAGE.md](../docs/CONFIG-LANGUAGE.md).

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

**Config format version 2**: actions inherited down the tree, leaves as values,
shared lists, contacts and projects, four trees (main, row 2, row 3, bottom-up),
and an outline converter. Covered by 86 tests; side-tree navigation is not yet
tried on the hardware.

**All eight actions verified against the real apps** — see
[docs/DESIGN.md](../docs/DESIGN.md#what-the-first-live-runs-showed-2026-09-26).

**Packaged as KeybowNotes.app** (see above): signed, universal, installed in
/Applications, with config reloading, a single-instance lock and Open at Login.

**EventKit** creates events and reminders in under 0.1 seconds, and opens a new
event in Calendar ready to edit.

**Settings window** for everything that belongs to this Mac rather than the tree.

### A trap worth remembering

`AsyncStream` has a **single** consumer. Two `for await` loops over the same
stream compete, and each sees only some events — which silently ate key presses
until `SelectionDriver` became the sole consumer and republished what others
need.
