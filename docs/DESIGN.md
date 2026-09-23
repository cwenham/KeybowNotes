# KeybowNotes — design

**Status:** draft, pre-implementation. Written after the spikes in
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

**Connection handling.** The app finds the device by USB vendor/product ID, not by
a fixed `/dev/cu.*` path, and must survive unplugging, replugging and sleep/wake.
Of the two serial ports CircuitPython exposes, the console is ignored and the data
port used.

---

## 3. Interaction model

Row 1 (keys 0–3) picks a broad category; rows 2, 3 and 4 narrow it. The overlay
appears on the first press and shows the path chosen so far plus the labels for
the next row.

- **Pressing a key on a higher row resets every row below it.** Selections can be
  changed at any point before the action fires.
- **Out-of-order presses are ignored**, with the key flashing red. Only lit keys
  are valid; unused positions stay dark.
- **Branches may end early.** A node with an action instead of children fires as
  soon as it is selected, so a branch can be two or three levels deep.
- **Cancel:** long-press (≥ 1s) any key to clear the whole selection. There is no
  spare key for this — all 16 belong to the tree.
- **Commit delay:** after the final press the overlay shows the action for ~1
  second before running it; any key press in that window cancels. Guards against
  a mis-press creating unwanted content. Configurable, including off.
- **Idle timeout:** an incomplete selection clears itself after ~10 seconds.

### Overlay

A non-activating HUD panel, so it never steals focus: borderless, ignores the
mouse, joins all Spaces and floats over full-screen apps. Defaults to the screen
with the cursor; a setting allows the main display or a specific one, falling back
to the cursor's screen when that display is absent.

---

## 4. Config file

JSON, reloaded on change. Location: `~/Library/Application Support/KeybowNotes/config.json`.
A commented example ships as `config.example.json`; **the real config is never
committed**, since it holds personal categories, phone numbers and email addresses.

### Node shape

Each level is an array of up to four nodes. Array position is the key position
unless an explicit `key` (0–3) is given, which allows gaps.

```jsonc
{
  "version": 1,
  "defaults": {
    "notes": { "account": "iCloud", "folder": "Notes" },
    "colour": "202020",
    "commitDelayMs": 1000
  },
  "tree": [
    {
      "label": "Work",
      "colour": "0060ff",
      "params": { "area": "work" },
      "children": [
        {
          "label": "Meeting",
          "colour": "00a0ff",
          "params": { "kind": "meeting" },
          "children": [
            {
              "label": "1:1",
              "children": [
                {
                  "label": "New note",
                  "action": {
                    "type": "notes.create",
                    "folder": "Work",
                    "title": "1:1 — {{date:d MMM yyyy}}",
                    "template": "templates/one-to-one.md"
                  }
                },
                {
                  "label": "Add to this week",
                  "action": {
                    "type": "notes.append",
                    "find": { "byName": "1:1 log — week {{isoWeek}}" },
                    "createIfMissing": true,
                    "template": "templates/one-to-one-entry.md"
                  }
                }
              ]
            }
          ]
        }
      ]
    }
  ]
}
```

### Node fields

| Field | Meaning |
|---|---|
| `label` | Shown in the overlay |
| `colour` | `rrggbb` for this key; inherited from the parent when omitted |
| `key` | Optional explicit position 0–3 |
| `params` | Values for templates, inherited downwards, deeper nodes overriding |
| `children` | Up to four child nodes |
| `action` | A leaf's action; mutually exclusive with `children` |

---

## 5. Actions

Every text field in an action is expanded through the template system first.

| `type` | Mechanism | Notes |
|---|---|---|
| `notes.create` | AppleScript | New note, then shown. Unaffected by the append problems below. |
| `notes.append` | AppleScript | See constraints. Finds by `byName`, `byId`, `selection`; `createIfMissing` supported. |
| `reminders.create` | EventKit | Title, notes, due date, alert, priority, flag, list. |
| `calendar.createEvent` | EventKit | Created then shown for editing. Calendar identified **by ID**, not name. |
| `messages.compose` | `sms:` URL | Opens a conversation with the text filled in. **Never sends.** |
| `mail.compose` | AppleScript | Opens a real draft window, ready to edit. |
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
| `{{project\|none}}` | Fallback when missing or empty |

### Sources, in precedence order

1. **Node params** — declared on any node, inherited downwards, deeper wins.
2. **Path values** — `{{level1}}`…`{{level4}}` (the labels chosen) and `{{path}}`
   (joined with " / ").
3. **Built-ins** — `{{date}}`, `{{time}}`, `{{datetime}}`, `{{weekday}}`,
   `{{isoWeek}}`, `{{clipboard}}`, `{{frontApp}}`.

`{{selection}}` (the selected text in the frontmost app) is deferred: it needs
Accessibility permission, so it would be opt-in if added.

### Date expressions

Reminders and events need dates, not just formatted output. Fields such as `due`
and `start` accept: `tomorrow 09:00`, `+1d 09:00`, `next monday 14:00`,
`2026-10-01 09:30`, and `+90m` for durations.

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
| Contacts | Only if recipients are chosen by name rather than handle |

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
3. **Tree editor UI**, deferred until the config format has settled in use.
4. **Per-node Notes account**, once more than one account is in play.

## 9. Build order

1. Firmware: keys and LEDs over the data port, with the protocol above.
2. Mac app skeleton: menu-bar agent, serial connection, reconnect handling.
3. Overlay: path display, next-row options, cancel and commit behaviour.
4. Config loading and tree navigation.
5. Actions, starting with `notes.create`, then `notes.append`.
6. Template engine and parameters.
7. Remaining actions.
8. Settings window: overlay screen, timeouts, config file location.
