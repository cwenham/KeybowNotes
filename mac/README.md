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
| `USBInventory.swift` | Every USB device plugged in, where (location IDs into words), and what an RP2040 is running |
| `USBLog.swift` | macOS's USB log, read (`log show`) and watched (`log stream`): arrivals, departures, failed attempts |
| `Troubleshooting.swift` | What a diagnosis is drawn from: keypads known and sought, drives, ports, console readings, key lights |
| `TreeControl.swift` | The tree as scripts and agents change it: entries named by their labels, added, changed, removed, run, checked |
| `AgentGuide.swift` | What an AI agent is told: the guides, and a catalogue of the action types here |
| `TreeDraft.swift` | Trees designed with Claude: each turn's request, the outline found in the reply, and the draft carried into the file |
| `MCPServer.swift` | `keybow mcp`: the Model Context Protocol, asking the app through its AppleScript |
| `Troubleshooter.swift` | The rules: what's wrong with a missing or silent keypad, and what to do — plus a plain-text report |

## The app

### Building and installing KeybowNotes.app

```bash
scripts/build-app.sh             # → build/KeybowNotes.app
scripts/build-app.sh --install   # and copy it to /Applications, quitting a running copy
```

A universal (Intel and Apple Silicon) release build, with its Info.plist, icon,
example config and templates, and the keypad firmware from `../firmware`, signed with the first "Apple Development"
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
- **Set Up a Keypad…** puts CircuitPython and the firmware on a keypad — new, or
  one to bring up to date — and restarts it. Files it replaces are kept in
  `Keypad Backups` beside the tree; CircuitPython downloads are cached in
  `~/Library/Caches/KeybowNotes/CircuitPython`. See
  [firmware/README.md](../firmware/README.md#install).
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
| `--set-up-keypad` | open *Set Up a Keypad…* on launch |
| `--troubleshoot` | open *Find a Missing Keypad…* on launch |
| `--draft` | open *Design with Claude…* on launch |

A development build sets keypads up from the repository's `firmware` folder;
`KEYBOW_FIRMWARE` names another. For trying the setup window out,
`KEYBOW_SETUP_SELECT` chooses a board by its ID (or `new`), and
`KEYBOW_SETUP_START=1` presses Set Up once it can be — development builds only.
`KEYBOW_HOME_DEMO=1` puts a made-up Home Assistant behind the editor's lists.
`KEYBOW_DRAFT_WANTED` says something in *Design with Claude…* — with
`KEYBOW_DEBUG_CLAUDE_REPLY` as Claude's answer — and `KEYBOW_DRAFT_THEN` says
something more once that's answered; `KEYBOW_DRAFT_USE=1` then adds the draft.
`KEYBOW_TROUBLESHOOT_DEMO=hub` (or `nodata`, `dataport`, `setup`) gives the
troubleshooter made-up keypads in made-up trouble, and `KEYBOW_WINDOW_SNAPSHOTS=<dir>`
has the setup, troubleshooter, settings and editor windows write a PNG of themselves
there every two seconds — for checking layouts without anyone's own devices or
screen recording.

**The tree editor is one component,** `TreeEditorViewController`, around an
`EditorModel`: keypad tabs, outline, inspector and keypad drawing. Put in a
window, it connects the window's undo, catches the keys the outline's text
field would otherwise take (⌃⌘↑/↓, ⌘Return), and takes the menu's Save, Move
and Add Child commands along the responder chain. The tree editor window is
that component on the tree file; *Design with Claude* puts it in a split view
beside the conversation, on a draft — a model made with `draft: true`, which is
never saved. The model's `connectedKeypads` says which keypads are plugged in:
USB, unless something else is given.

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
./.build/debug/keybow keypads   # list the keypads found: model, unique ID, ports
./.build/debug/keybow ping      # connect, ping, print replies
./.build/debug/keybow watch     # print key events until Ctrl-C
./.build/debug/keybow demo      # light each key in turn
./.build/debug/keybow leds ff0000 00ff00 0000ff 000000
./.build/debug/keybow setup     # set a keypad up: CircuitPython, the firmware, a restart
./.build/debug/keybow troubleshoot   # what's wrong with a keypad that isn't working
./.build/debug/keybow mcp            # the MCP server for AI agents, on stdin and stdout
```

The app carries `keybow` in `Contents/Helpers`, for MCP clients to run, and
the guides they read in `Contents/Resources/Guide`. Its AppleScript dictionary
is `Packaging/KeybowNotes.sdef`; its Shortcuts actions are App Intents, whose
metadata `scripts/build-app.sh` makes as Xcode would — see
[docs/AUTOMATION.md](../docs/AUTOMATION.md).

`troubleshoot` looks for the keypads the app has seen and the tree names, and
prints what it finds and what to do, with what it was drawn from: the USB devices,
the USB log (`--since 6h` reads further back), drives and ports. `--watch` watches
for 30 seconds while you unplug a keypad and plug it back in; `--keys red` (or
`dark`, `blue`, `purple`, `lit`) says what its keys are doing; `--console` starts
each keypad's program again and reads what it prints.

`setup` takes the model for a board that can't say — `keybow setup rgbkeypad` for
one waiting in its bootloader — and `--keep-circuitpython` to copy only the
firmware to a board whose CircuitPython is supported.

`leds` takes 1-16 `rrggbb` values; the last one fills the remaining keys.
Device commands talk to the first keypad found. With more than one connected,
`KEYBOW_DEVICE` picks another, by model or by the unique ID `keypads` lists —
and with the app quit, since it holds every keypad's port:

```bash
KEYBOW_DEVICE=rgbkeypad ./.build/debug/keybow ping
```

Config commands:

```bash
./.build/debug/keybow convert tree.md                  # print the JSON it compiles to
./.build/debug/keybow tree tree.md                     # print the trees and each leaf's action
./.build/debug/keybow run tree.md                      # drive the keypad with its trees; prints, runs nothing
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
