# KeybowNotes

A 16-key macro pad and a Mac menu-bar app that turn two or three key presses into
a note, a calendar event, a message, a snippet of text typed where you are — or a
question to Claude.

The keypad is a [Pimoroni Keybow 2040](https://shop.pimoroni.com/products/keybow-2040):
a 4 × 4 grid of lit keys. You arrange what you want to do as a tree, four keys to
a row. Pressing a key picks a branch; its choices light up on the next row, and a
heads-up display on the Mac shows where you are. Choosing a leaf runs its action.

![The tree editor: the outline on the left, the selected node's settings on the right, and the keypad as it will light up](docs/images/tree-editor.png)

*Work → Meeting → Tomorrow* makes a calendar event called "Meeting" for tomorrow at
9:00, with an alert, and opens it ready to edit. *Writing → Summarise* asks Claude
to summarise the text you've selected, and types the reply in its place.

## The heads-up display

While you choose, the HUD follows along: the path so far, the choices on offer,
and a copy of what the keys are showing. When you reach a leaf there's a moment to
change your mind — press any key — before the action runs.

| Choosing | About to run |
|---|---|
| ![The HUD offering the four choices under Work › Meeting](docs/images/hud-choosing.png) | ![The HUD counting down before making the Meeting event](docs/images/hud-pending.png) |
| **Waiting for Claude** | **With a stopwatch running** |
| ![The HUD asking Claude, with a timer and a Cancel button](docs/images/hud-asking-claude.png) | ![The HUD's choices, with the stopwatch counting underneath](docs/images/hud-stopwatch.png) |

## Features

**Actions** — each leaf does one thing:

- **Notes**: a new note, filed in folders that mirror the tree, or an entry added
  to a running note. Templates in Markdown become Notes formatting.
- **Calendar and Reminders**: events and reminders from plain dates — *today*,
  *tomorrow 14:00*, *friday*, *+25m* — with alerts; a reminder due in 25 minutes
  makes a handy timer.
- **Messages and Mail**: a message or email ready to send — never sent for you.
- **Calls**: a phone call through your iPhone, or FaceTime audio.
- **Apps, files and links**: open an app, a file in an app, a web page, or any
  app's own link — a Discord channel, a Things project.
- **Maps, Music, Clock**: search Maps, play a playlist or an album, start a timer.
- **Shortcuts**: run any shortcut, with text as its input.
- **Text**: copy a snippet to the clipboard, or type it at the cursor in whatever
  app you're using — by pasting, or directly, without touching the clipboard.
- **Stopwatch**: start, stop, lap and reset from the keys; it shows in the HUD and
  the menu bar, and its key breathes while it runs.

**Values** — anything an action writes can include `{{placeholders}}`: the labels
along the path, a contact's number, the date in any format, the **text selected in
the app you're using**, or the clipboard. `{{selection}}` makes a key that looks up,
quotes, files or rewrites whatever you've highlighted.

**Ask Claude** — a template can hold `{{#ai}}…{{/ai}}` blocks. The text inside is
filled in and sent to Claude, and the reply takes the block's place:

```
Summarise [Insert, text: "{{#ai}}Summarise in one line: {{selection}}{{/ai}}"]
```

Blocks nest, and those side by side are asked at once. While you wait, the HUD
shows a timer and a Cancel button. Blocks aren't allowed where a reply could decide
where an action goes — links, phone numbers, apps — so text you select can't steer
it there. Claude Opus 5.5 at low effort by default; your API key stays in the
Keychain.

**Four trees** — the row you press first chooses the tree: row 1 runs down through
all four rows, rows 2 and 3 are shorter trees of their own, and row 4 runs upwards.
Four menus on one keypad, with the top row always a way back to the main one.

**The tree editor** — the tree is a plain outline file, `tree.md`, and the editor
is an outliner for it: Return, Tab and Shift-Tab to add and arrange nodes, a
settings pane with a tooltip on every field, and the keypad drawn as it will light
up. Colours, templates, contacts and values are all set there, and anything a node
has that does nothing is flagged, with a button to remove it.

![The tree editor with a calendar event selected: its title, start, duration and alert, each showing where it comes from](docs/images/tree-editor-event.png)

**Modules** — the stopwatch and the Claude blocks are modules: separate code that
plugs in through one interface, adding actions, template blocks, values, settings
and menu commands. See [docs/MODULES.md](docs/MODULES.md).

## How it fits together

- **[firmware/](firmware/)** — CircuitPython for the Keybow 2040. The keypad only
  reports key presses and shows the colours it's told to, over a USB serial port
  of its own.
- **[mac/](mac/)** — a Swift package: the menu-bar app, the tree editor, the core
  library, a `keybow` command-line tool, and the modules. Everything that decides
  what a key means lives here, on the Mac.
- **[docs/](docs/)** — the design, the configuration language, the editor, and
  the module interface.

## Requirements

- A **Pimoroni Keybow 2040**, running CircuitPython 10 with Pimoroni's `pmk`
  library.
- A Mac with **macOS 15 Sequoia** or later — Apple silicon or Intel.
- **Xcode 16** or later to build it (Swift 6).
- Optional: an **Anthropic API key** for `{{#ai}}` blocks, and an **iPhone** on
  the same Apple Account for calls.

## Getting started

1. **Set up the keypad** — install CircuitPython, the `pmk` library and the three
   firmware files: [firmware/README.md](firmware/README.md).
2. **Build and install the app** — from the `mac` folder:

   ```bash
   scripts/build-app.sh --install
   ```

   This builds a universal app, signs it with your Apple Development identity if
   you have one (so macOS remembers the permissions you grant), and copies it to
   `/Applications`. More in [mac/README.md](mac/README.md).
3. **Open KeybowNotes** and plug in the Keybow. A keyboard icon appears in the
   menu bar, and the first launch installs an example tree in
   `~/Library/Application Support/KeybowNotes`.
4. **Make the tree your own** — choose *Edit Tree…* from the menu bar (⌘E). The
   language is described in [docs/CONFIG-LANGUAGE.md](docs/CONFIG-LANGUAGE.md),
   and every field in the editor explains itself.
5. **Try things safely** — *Dry Run* in the menu shows what a key would do without
   doing it.

## Permissions

macOS asks the first time each is needed:

| For | Permission |
|---|---|
| Notes, Mail, Music | Automation — control of that app |
| Calendar events and reminders | Calendars, Reminders |
| `{{selection}}`, and typing text into other apps | Accessibility |
| Looking people up in the editor | Contacts |

The app isn't sandboxed and isn't on the App Store: driving Notes, Mail and Music
through AppleScript rules that out.

## Documentation

- [docs/DESIGN.md](docs/DESIGN.md) — how it works, and why
- [docs/CONFIG-LANGUAGE.md](docs/CONFIG-LANGUAGE.md) — the tree, actions, values,
  templates and `{{#ai}}` blocks
- [docs/TREE-EDITOR.md](docs/TREE-EDITOR.md) — the editor, its keys and its panes
- [docs/MODULES.md](docs/MODULES.md) — the module interface, the stopwatch and
  Claude
- [firmware/README.md](firmware/README.md) — the keypad's side and its protocol
- [mac/README.md](mac/README.md) — building, running and testing the Mac side
