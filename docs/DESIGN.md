# KeybowNotes — design

**Status:** working end to end: packaged as KeybowNotes.app, with EventKit and a settings window. Written after the spikes in
[../spikes/FINDINGS.md](../spikes/FINDINGS.md), which settled the Notes, Calendar
and Messages questions.

A Pimoroni Keybow 2040 (4×4 illuminated mechanical keypad, RP2040) drives a Mac
menu-bar app. Four key presses walk a four-level category tree; a HUD overlay
shows the path so far and the options for the next row; the fourth press runs an
action — usually creating a note, but also reminders, events, messages and more.

---

## 1. Architecture

```
Keybow 2040 ──USB CDC (data port)── Mac app ──┬── AppleScript ── Notes, Mail
   CircuitPython                    Swift     ├── EventKit ───── Calendar, Reminders
   16 keys + RGB LEDs               overlay   ├── URL ───────── Messages, 3rd-party apps
                                              └── shortcuts ─── anything else
```

**The Mac owns all state and logic.** The firmware reports key events and obeys
LED commands; it holds no category tree. This keeps one source of truth in an
editable config file, rather than something reflashed onto the device.

### Parts

| Part | Technology |
|---|---|
| Firmware | CircuitPython on Keybow 2040 (Pimoroni's `pmk` library) |
| Transport | USB CDC serial, on the **data** port, with the console left free for debugging |
| Mac app | Swift / SwiftUI, universal binary, minimum macOS 15 (Sequoia), menu-bar agent (`LSUIElement`) |
| Config | JSON on disk, reloaded when it changes |

Not sandboxed, and not distributed through the App Store: AppleScript automation
makes sandboxing impractical.

---

## 2. Keybow ↔ Mac protocol

Line-based UTF-8 text, one message per line, so it can be debugged with a
terminal. Key numbers are **0–15, left to right, top to bottom**, as the user
sees the device; the firmware translates to the hardware's column-major order.

| Direction | Message | Meaning |
|---|---|---|
| → Mac | `HELLO keybow <protocol-version>` | Sent on boot and on reconnect |
| → Mac | `DOWN <n>` / `UP <n>` | Key pressed / released (both, so long-press works) |
| Mac → | `LEDS <rrggbb>×16` | Set all 16 key colours in one message |
| Mac → | `PING` / → Mac `PONG` | Heartbeat |

**Disconnected behaviour.** If pings stop arriving for a few seconds, the firmware
shows a distinct "no host" pattern (a dim breathing red, say), so a dead app is
obvious rather than silently ignoring presses.

**Connection handling.** The app finds the device by USB vendor/product ID
(`0x16d0` / `0x08c6`), not by a fixed `/dev/cu.*` path, and must survive
unplugging, replugging and sleep/wake. Of the two serial ports CircuitPython
exposes, the console is ignored and the data port used.

**The port stays open.** The firmware writes only while the host asserts DTR, so
the app opens the data port once and holds it for as long as the device is
present. Opening and closing per command loses every reply. `HELLO` arrives on
boot and whenever a host resumes talking after a silence, which is the app's cue
to resend the LED state.

Verified on hardware on 2026-09-23 against CircuitPython 10.3.1; see
`firmware/README.md`.

---

## 3. Interaction model

The overlay appears on the first press and shows the path chosen so far plus the
labels for the next row.

### Four trees

The keypad holds up to four independent trees. **With nothing chosen, the row of
the first press decides which tree is in play:**

| First press on | Runs | Levels | Most leaves |
|---|---|---|---|
| Row 1 | downwards | 4 | 256 — the main tree |
| Row 2 | downwards | 3 | 64 |
| Row 3 | downwards | 2 | 16 |
| Row 4 | upwards | 4 | 256 |

Idle, every tree's first row is lit in its own colours, so all 16 keys may be
entry points. Only the main tree is required; the others are optional.

### Choosing

- **A press on a row already passed, or on the next row, chooses at that depth
  and drops everything beyond it.** "Nearer the tree's start" is what counts, so
  in the upward tree a new press on row 4 starts it over.
- **Presses further along than the next row are ignored**, with the key flashing
  red. Only lit keys are valid; unused positions stay dark.
- **The top row escapes to the main tree** whenever it is not a legal move in the
  tree in play. In a side tree it glows faintly to say so. It is the only way to
  switch trees mid-path; otherwise finish, cancel or wait. (Row 4 cannot do the
  same in reverse, because it is the main tree's final choice.)
- **Branches may end early.** A leaf fires as soon as it is chosen, whatever its
  depth.
- **Cancel:** long-press (≥ 1.5s by default) any key to clear the selection. There
  is no spare key for this — all 16 belong to the trees. A due action wins over
  the long press, so holding the final key runs it rather than cancelling it;
  cancelling within the commit window is done by pressing another key.
- **Commit delay:** after the final press the overlay shows the action for ~1
  second before running it; any key press in that window cancels. This matters
  more with side trees, where every key starts something and the row 3 tree
  reaches an action in two presses. Configurable, including off.
- **Idle timeout:** an incomplete selection clears itself after ~10 seconds.

### Settings

Settings that belong to this Mac rather than the tree live in UserDefaults and
are edited in a settings window: the overlay's screen (the pointer's, the one
with the menu bar, or a named display — falling back to the pointer's when that
one isn't connected), key brightness, dry run, open at login, which config file
to load, and the default calendar and reminders list, chosen from your own and
stored by permanent identifier. Timings can live in either place: the config
file sets them, and a slider in the window overrides the file's value only once
it is moved, with "Use the Config File's Timings" to undo that.

### Overlay

A non-activating HUD panel, so it never steals focus: borderless, ignores the
mouse, joins all Spaces and floats over full-screen apps. Defaults to the screen
with the cursor; a setting allows the main display or a specific one, falling back
to the cursor's screen when that display is absent.

---

## 4. Config file

The full language — outline syntax, keywords, JSON fields, inheritance, every
action's fields, placeholders and dates — is in
[CONFIG-LANGUAGE.md](CONFIG-LANGUAGE.md). This section gives the design.

**The outline is the configuration**: `tree.md`, written by hand or in the tree
editor ([TREE-EDITOR.md](TREE-EDITOR.md)). The app runs JSON compiled from it,
`config.json`, reloaded on change; nothing edits the JSON directly. Both live in
`~/Library/Application Support/KeybowNotes/`. **The real configuration is never
committed**: it holds personal categories, names, phone numbers and paths, and
the repository is public. [`mac/config.example.json`](../mac/config.example.json)
shows the compiled form.

### Writing it as an outline

```
1. Work
   2. General Tasks
      1. Meeting [Calendar, 5 min alert, duration: 1h]
         1. Today
         2. Tomorrow
      4. Notes
         1. Work log [worklog.md]

# contacts
- Rudy Rudolph [phone: +15550100]
```

```bash
keybow convert tree.md -o ~/Library/Application\ Support/KeybowNotes/config.json
```

- **Numbers are key positions**, 1–4 left to right; indentation is nesting.
- **Headings start sections**: side trees (`# row 2`, `# row 3`, `# bottom`),
  reusable lists (`# list when`), `# contacts`, `# projects` and `# defaults`.
- **A final `[…]` holds annotations**, applying to everything beneath until
  overridden. Words name things — an action type, `append`, a template, an alert,
  an app, `@list`. Pairs set things — `duration: 1h` sets an action field,
  anything unrecognised becomes a template value. Parentheses are ordinary text.
  Square brackets were chosen over parentheses (version 2) so that labels can
  contain parentheses.

The compiler reports what it **guessed** (an app it substituted, append-or-create
from a template name), what is **still to fill in** (paths, phone numbers,
channel URLs), and **warnings** (an app not installed), and records, for every
node, what each annotation means and what's wrong with it — which is what the
tree editor highlights. Apps are recorded with their bundle ID, so they are
found wherever they are installed. The output is checked by loading it before
it is written.

### Shape

```jsonc
{
  "version": 2,
  "defaults": {
    "colour": "202020",
    "commitDelayMs": 1000, "idleTimeoutMs": 10000, "longPressCancelMs": 1500,
    "dates": { "todayOffsetMinutes": 30, "defaultTime": "09:00" },
    "action": { "type": "notes.create", "folder": "{{folderPath}}" },  // optional
    "types": { "calendar.createEvent": { "duration": "+1h" } }          // optional
  },
  "contacts": { "Alex Example": { "phone": "+15550100", "email": "alex@example.com" } },
  "projects": { "Website": { "path": "~/Code/website" } },
  "lists":    { "when": [ { "label": "Today", "params": { "when": "today" } }, … ] },
  "trees": {
    "main":   [ … ],   // row 1 down
    "row2":   [ … ],   // row 2 down
    "row3":   [ … ],   // row 3 down
    "bottom": [ … ]    // row 4 up
  }
}
```

Version 1 files, with a single `"tree"`, still load as the main tree.

### Nodes

| Field | Meaning |
|---|---|
| `label` | Shown in the overlay; also a value for templates |
| `key` | Position 0-3; otherwise the next free one |
| `colour` | `rrggbb`, inherited from the parent when omitted |
| `params` | Template values, inherited downwards, deeper nodes overriding |
| `action` | Some or all of an action — inherited by every leaf beneath |
| `children` | Up to four nodes, or `"@name"` for a list under `lists` |

A node with no children is a leaf. **A leaf does not need an action of its own.**

### How a leaf's action is worked out

Most leaves supply a *value* — a date, a person, a grocery item — while the
action is decided higher up. So actions are inherited, in increasing priority:

1. **Per-type defaults**, built in and overridable under `defaults.types`
2. **The default action** (`defaults.action`), only when nothing on the path names
   a type. Built in: a new note in nested folders mirroring the path —
   `Projects/Fiction/Characters/The Detective/` gets a new note per press.
3. **Each node's `action` fields**, shallow to deep.

A node naming a *different* type from the one it inherited starts afresh: fields
meant for another kind of action are dropped instead of leaking in. That is how
"Project Documentation [append]" can hold a "New Project [create]" leaf.

Built-in per-type defaults:

| Type | Defaults |
|---|---|
| `notes.create` (default action) | `folder: {{folderPath}}`, `title: {{leaf}} — {{date:d MMM yyyy}}` |
| `notes.append` | `folder: {{parentPath}}`, find by name `{{leaf}}`, create if missing |
| `calendar.createEvent` | `title: {{parent}}`, `start: {{when}}`, `duration: +30m`, show for editing |
| `reminders.create` | `title: {{leaf}}` |
| `messages.compose` | `to: {{contact.phone}}` |
| `mail.compose` | `to: {{contact.email}}` |
| `app.open` | `open: {{project.path\|}}` — the matching project, if any |

### Contacts and projects

People and projects recur across the tree — the same colleague under Messages and
Mail, the same project under an IDE, Claude and documentation — so they are
defined once. **Any label on the chosen path matching a name** brings that entry
in as `{{contact.*}}` or `{{project.*}}`, the deepest match winning. A node can
name one explicitly with a `contact` or `project` param.

---

## 5. Actions

Every text field in an action is expanded through the template system first.

| `type` | Mechanism | Notes |
|---|---|---|
| `notes.create` | AppleScript | New note, then shown. Creates nested folders as needed. |
| `notes.append` | AppleScript | See constraints. Finds by `byName`, `byId`, `selection`; `createIfMissing` supported. |
| `reminders.create` | EventKit (AppleScript in dev runs) | Title, notes, due date — also set as the alert, which makes the row 3 timers work — and list, else the default list. |
| `calendar.createEvent` | EventKit (AppleScript in dev runs) | Created, then opened for editing via `ical://ekevent/<id>?method=show&options=more`. Calendar by `calendarId` (stable), `calendar` (name), else your default calendar. `alertMinutes` for an alert. |
| `messages.compose` | `sms:` URL | Opens a conversation with the text filled in. **Never sends.** |
| `mail.compose` | AppleScript | Opens a real draft window, ready to edit. |
| `app.open` | `NSWorkspace` | Opens an app (by `bundleId`, else `app` name), optionally with a file, folder or URL. |
| `openURL` | `NSWorkspace` | For apps with URL schemes (Things, OmniFocus, Drafts, Obsidian, Bear…). |
| `shortcut` | `shortcuts run` | Escape hatch for anything supporting Shortcuts. |

Deliberately excluded: an "arbitrary AppleScript" action. It would let a config
file run any code; revisit only if a real need appears.

### Constraints the spikes established

**`notes.append` is lossy.** Appending round-trips the note's whole HTML body
through Notes, which re-normalises it: checklists flatten to bulleted lists,
inline photos become file attachments, headings lose their style. Tables, bullets,
bold and links survive. A note holding one photo exported a 4 MB body.

Accepted deliberately, with two guards, both overridable per node:

```jsonc
"guards": { "maxBodyBytes": 262144, "refuseInlineImages": true }
```

The app **cannot** warn about checklists: in exported HTML a checklist and a
bulleted list are both `<ul><li>`, indistinguishable. Append targets should be
kept to plain text, bullets and tables.

**Calendars are ambiguous by name.** The test machine had two calendars called
"Chris Wenham", and several read-only ones. Config stores the stable identifier,
with the name as a display label; only writable calendars are offered.

**Messages never sends.** `sms:<handle>&body=<text>` fills the compose field and
waits for the user. AppleScript's `send` is not used, because it transmits
immediately with no draft.

### What the first live runs showed (2026-09-26)

All eight actions were run against the real apps. Everything worked, with these
lessons:

- **Every Apple app is driven by `osascript`**, values passed as arguments. EventKit
  would be faster for Calendar and Reminders but needs a proper app bundle with
  usage descriptions; that comes with packaging.
- **Notes drops links set by a script**, keeping only underlined text. Markdown
  links are therefore written as `text (https://…)` so the address survives.
- **Headings are restyled**: `<h1>`/`<h2>` come back as bold 24pt/18pt text. They
  look right; they are not Notes' own heading styles.
- **AppleScript variable names must avoid dictionary terms.** A variable called
  `container` is read as Notes' `container` property and fails with -10006 — the
  same trap as `plaintext` in the spike.
- **Nested folders can be created by script**, one level at a time.
- **First use of each app triggers a macOS permission prompt**, and the script
  waits until it is answered. Scripts time out after 45 seconds with a message
  pointing at the prompt, rather than hanging.
- **Calendar's scripting is slow** — the first event took well over ten seconds
  while Calendar launched. The overlay shows a spinner until it finishes.

### EventKit (2026-09-26)

The packaged app creates events and reminders through EventKit rather than
AppleScript: under 0.1 seconds instead of ten or more, because neither Calendar
nor Reminders has to launch. A development run (`swift run`) has no Info.plist
to hold the usage descriptions EventKit requires — asking without them crashes
the process — so it keeps using AppleScript.

- **Full access, not write-only.** KeybowNotes finds calendars and lists by name
  and opens the new event afterwards, which write-only access can't do. The
  Info.plist deliberately has no write-only description, so the prompt doesn't
  offer that choice.
- **A store keeps the access it was created with.** Access changed in System
  Settings while the app runs is picked up by recreating the store.
- **Opening the new event** uses the link Calendar builds for itself,
  `ical://ekevent/<eventIdentifier>?method=show&options=more` — found in
  Calendar's binary, so undocumented and could change. **Verified:** Calendar
  comes forward on the event's day with its details open, and an edit made
  there (renaming it) stuck. Better than the AppleScript `show`, which only
  selected the event.
- **Prompts come forward.** The app never takes focus, so a permission prompt
  could open unseen behind other windows; it activates itself just before
  asking. The menu's *Allow Calendar and Reminders Access…* asks up front.

### Not yet known

- **Channels inside apps** — Discord, Meshtastic. Discord has per-channel URLs,
  which is promising; Meshtastic is unexplored. Until tested, a channel is carried
  as `target` and the converter lists each one as needing a URL.
- **Claude projects** — whether the desktop app can be opened on a specific one.
- **Fusion** keeps projects in Autodesk's cloud, so there may be no local file to
  open.

---

## 6. Templates and parameters

Templates are **Markdown**, converted to the HTML subset Notes accepts
(paragraphs, headings, bold, italic, bullets, numbered lists, links). No
checklists or tables — Notes cannot create them from a script.

Placeholders are `{{…}}`:

| Form | Meaning |
|---|---|
| `{{name}}` | A parameter or built-in |
| `{{date:d MMM yyyy}}` | Format specifier, using Unicode date patterns |
| `{{project\|none}}` | Fallback when missing or empty; `{{x\|}}` falls back to nothing |

### Sources, in precedence order

1. **Node params** — declared on any node, inherited downwards, deeper wins.
2. **Contacts and projects** — `{{contact.phone}}`, `{{project.path}}` and so on.
3. **Path values** — `{{leaf}}` (the label chosen last), `{{parent}}`,
   `{{level1}}`…`{{level4}}`, `{{path}}` ("Work / Notes / Standup"),
   `{{folderPath}}` ("Work/Notes/Standup"), `{{parentPath}}`, `{{tree}}`.
4. **Built-ins** — `{{date}}`, `{{time}}`, `{{datetime}}`, `{{weekday}}`,
   `{{isoWeek}}`, `{{clipboard}}`, `{{frontApp}}`.

`{{selection}}` is the text selected in the frontmost app. It is read only when
the action uses it, through the accessibility API; apps that don't answer
(Chrome, Electron) are sent ⌘C, with the clipboard restored straight after. In
a link, placed values are percent-encoded — see CONFIG-LANGUAGE.md §6.

### Date expressions

Events and reminders need dates. Agreed defaults, for leaves like Today / Tomorrow
/ Next week / Next month:

| Phrase | Means |
|---|---|
| `today` | 30 minutes from now, rounded up to 5 |
| `tomorrow`, `next week`, `next month` | that day at 09:00 |
| `friday`, `next friday` | the next Friday after today, 09:00 |
| `+3d`, `+2w` | days or weeks ahead, 09:00 |
| `+90m`, `+2h` | exactly that long from now |
| `2026-10-01` | that day, 09:00 |

Any day can take a time: `tomorrow 14:00`, `friday 2:30pm`, `today at 16:15`. A
time alone means today. Offsets and the default time are set under
`defaults.dates`. Events are created with these and **opened for editing**.

### Title

An action may set `title` explicitly. Otherwise the template's first line becomes
the title, matching Notes' own behaviour, and is not repeated in the body.

---

## 7. Permissions

Each is requested on first use of the action that needs it, and the overlay
should explain a refusal rather than failing silently.

| Permission | Needed for |
|---|---|
| Automation → Notes | `notes.create`, `notes.append` |
| Automation → Mail | `mail.compose` |
| Calendars (write) | `calendar.createEvent` |
| Reminders | `reminders.create` |
| Contacts | The tree editor's *Look Up in Contacts*; asked for when first used |
| Accessibility | `{{selection}}`: reading the selected text, and sending ⌘C to apps that won't share it. Asked for when first needed, or from Settings → Selected Text |

`url.open` and `clipboard.copy` need nothing; `phone.call` needs the Mac set up
for iPhone calls, and macOS confirms each call.

The app is not sandboxed, and needs the Apple Events entitlement under the
hardened runtime. Values are passed to fixed, pre-written scripts as arguments —
never spliced into script text, which would break on quotes and allow injection
from template values.

---

## 8. Open questions

1. **Prompted input.** Should a template be able to ask for a value before acting,
   e.g. a text field in the overlay? It would make templates far more useful, but
   turns the overlay from display-only into something focus-stealing. Syntax
   `{{?Label}}` is reserved for it. **Not in the first version.**
2. **Multiple actions per leaf** — e.g. create a note *and* a reminder linking to
   it. Plausible later; one action per leaf for now.
3. ~~Tree editor UI~~ — specified in [TREE-EDITOR.md](TREE-EDITOR.md) and being built.
4. **Per-node Notes account**, once more than one account is in play.

## 9. Build order

1. ✅ Firmware: keys and LEDs over the data port, with the protocol above.
2. ✅ Serial connection and reconnect handling (`KeybowKit`).
3. Overlay: path display, next-row options, cancel and commit behaviour.
4. ✅ Config loading, tree navigation, side trees, outline converter.
5. ✅ Actions: all eight types, run against the real apps.
6. ✅ Template engine and parameters, including `{{clipboard}}` and `{{frontApp}}`.
7. Spikes for the unknowns above: channels in Discord and Meshtastic, Claude projects.
8. ✅ Packaging: signed universal KeybowNotes.app, config reloading, Open at Login.
9. ✅ EventKit for Calendar and Reminders.
10. ✅ Settings window: overlay screen, timings, key brightness, default calendar and list, config file, open at login.
11. ✅ Outline language version 3: square brackets, `key: value` pairs, sections; the outline becomes the source of truth.
12. The tree editor, in the phases set out in [TREE-EDITOR.md](TREE-EDITOR.md).
