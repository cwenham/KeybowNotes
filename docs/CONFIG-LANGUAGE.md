# The KeybowNotes configuration language

**Version 2**, as understood by KeybowNotes 0.1. This describes what the parser,
the outline converter and the action planner do today; where behaviour is a
default rather than a rule, it says so.

A configuration says what each key on the keypad means: which choices are
offered on each row, what the final choice does, and with what values. It has
two forms:

- an **outline** — a numbered list, the way you'd sketch a tree by hand, with
  keywords in brackets. This is the form meant for writing.
- **JSON** — what the app reads. The outline converts to it; it can also be
  edited directly, and says some things the outline can't yet.

```bash
keybow convert tree.md -o ~/Library/Application\ Support/KeybowNotes/config.json
```

The running app notices the file has changed and reloads it within a couple of
seconds.

---

## 1. Ideas

**Keys.** The Keybow has 16 keys in a 4×4 grid. Rows are numbered 1 to 4 from
the top; within a row, key positions 1 to 4 from the left.

**Trees.** A configuration holds up to four trees. With nothing chosen, *the row
of the first press decides which tree is in play*:

| Tree | Starts on | Runs | Levels |
|---|---|---|---|
| `main` | row 1 | downwards | 4 |
| `row2` | row 2 | downwards | 3 |
| `row3` | row 3 | downwards | 2 |
| `bottom` | row 4 | upwards | 4 |

**Branches and leaves.** Each level of a tree offers up to four **nodes**, one
per key. A node with children is a **branch**; choosing it offers its children
on the next row. A node without children is a **leaf**; choosing it runs an
**action**, after a short delay in which any key cancels.

**Leaves are usually values.** In *Meeting → Tomorrow*, "Meeting" decides the
action (a calendar event) and "Tomorrow" supplies a value (the date). So an
action is normally declared on a branch and **inherited** by every leaf beneath
it; the leaf's label, and anything else along the path, fills in the details.

---

## 2. The outline

```
KeybowNotes template hierarchy          ← not a numbered item: ignored

1. Work
   2. General Tasks
      1. Meeting (Calendar, 5 min alert)
         1. Today
         2. Tomorrow
      3.                                 ← key 3 left empty
      4. Notes
         1. Work log (worklog.md)
2. Personal
   3. Reminder (Reminders)
      1. Grocery basics
         1. Milk

# bottom                                 ← the rest goes in the bottom tree
1. Home
```

### Items

- **`N. Label (annotations)`** — `N` is the key position, 1 to 4. Numbers need
  not be consecutive: a missing or empty number leaves that key unused.
- **Indentation is nesting.** An item belongs to the nearest item above it that
  is indented less. Tabs count as four spaces.
- **Anything that isn't a numbered item is ignored**, so a title or notes between
  items are fine.
- A key number outside 1–4, or used twice at one level, is an error that names
  the line.

### Trees

A heading switches tree for everything below it until the next one:

| Heading | Tree |
|---|---|
| `# main`, `# top`, `# row 1` | main |
| `# row 2` | row2 |
| `# row 3` | row3 |
| `# bottom`, `# row 4`, `# bottom up` | bottom |

The word "tree" is ignored (`# Row 2 tree`), as are case, spaces and hyphens.
A heading that names no tree is treated as a title. Items before any heading go
in the main tree.

### Annotations

Brackets at the end of a label hold **annotations**, separated by commas:
`Meeting (Calendar, 5 min alert)`. An annotation on a branch applies to
everything beneath it, until something deeper says otherwise.

| Annotation | Meaning | JSON it becomes |
|---|---|---|
| `Notes` | a new note | `"type": "notes.create"` |
| `Calendar` | a calendar event | `"type": "calendar.createEvent"` |
| `Reminders` | a reminder | `"type": "reminders.create"` |
| `Messages` | a message, ready to send | `"type": "messages.compose"` |
| `Mail` | an email draft | `"type": "mail.compose"` |
| `append` | add to a running note rather than make a new one | `"type": "notes.append"` |
| `new`, `create` | make a new note | `"type": "notes.create"` |
| `something.md` | a template (see §8) | `"template": "something.md"` |
| `N min alert`, `N hour alert` | an alert before an event | `"alertMinutes": N` |
| an app — `Rider`, `VSCode`… | open the leaf in that app | `"type": "app.open", "app": …, "bundleId": …` |
| anything else, under an app | a channel or target in that app | `"target": …` |

Details:

- **Case doesn't matter** for the keywords. `min`/`mins`/`minute(s)` and
  `h`/`hr`/`hour(s)` are all accepted in alerts.
- **Template names can imply append or create.** A template whose name begins
  `Append…` makes the node append; one beginning `New…` makes it create. This
  only applies if no other annotation on that node has already chosen, and the
  converter reports it as a guess.
- **Apps are recognised by the names people use** — `VSCode` is Visual Studio
  Code, `Prusa Slicer` is PrusaSlicer, `Fusion` is Autodesk Fusion, `Mastodon`
  is whichever Mastodon client is installed — and looked for in `/Applications`,
  `/System/Applications` and `~/Applications`, including one folder down. The
  app's bundle ID is recorded, so it is found wherever it lives at run time.
- **Under an app, any other word is a target** in it — `Server1 (offtopic)`.
- **Elsewhere, an unknown capitalised word is assumed to be an app**, with a
  warning that it isn't installed, and **an unknown lowercase word is kept** as
  `params.note`, with a warning.

### What the converter infers for leaves

A leaf with no annotations still means something, depending on what it inherits:

| Under | A leaf like | Becomes |
|---|---|---|
| a calendar branch | `Today`, `Next week`, `friday` | a `when` value, if it reads as a date (§7) |
| a Messages branch | `Rudy Rudolph` | a contact, with a phone number to fill in |
| a Mail branch | `Rudy Rudolph` | the same contact, with an email to fill in |
| an app that opens files | `Project A` | a project, with a path to fill in |
| an app that is a service (Discord, Claude…) | `Channel1` | a target needing a URL |
| nothing | `Inventions` | the default action: a new note (§4) |

### The converter's report

Alongside the JSON, the converter lists three things, on stderr:

- **Guessed — check these:** an app it substituted, or append/create read from a
  template's name.
- **Still to fill in:** phone numbers, email addresses, project paths, channel
  URLs.
- **Warnings:** an app that isn't installed, an annotation it didn't understand.

It also gives each top-level branch of a tree its own colour, which the branch's
children inherit. Before writing, it loads its own output to make sure the app
will accept it.

---

## 3. The JSON form

```jsonc
{
  "version": 2,
  "defaults":  { … },                       // §4
  "contacts":  { "Alex Example": { "phone": "+15550100", "email": "alex@example.com" } },
  "projects":  { "Website": { "path": "~/Code/website" } },
  "lists":     { "when": [ { "label": "Today", "params": { "when": "today" } } ] },
  "trees": {
    "main":   [ …nodes… ],
    "row2":   [ … ],
    "row3":   [ … ],
    "bottom": [ … ]
  }
}
```

Every section is optional. A version 1 file, with a single `"tree": [ … ]`,
loads as the main tree.

### Nodes

```jsonc
{
  "label": "Meeting",
  "key": 0,
  "colour": "0060ff",
  "params": { "area": "work" },
  "action": { "type": "calendar.createEvent", "alertMinutes": 5 },
  "children": [ … ]            // or "@when"
}
```

| Field | Meaning |
|---|---|
| `label` | Shown in the overlay; also a value for templates. Required. |
| `key` | Position 0–3. Without it, the next free position. |
| `colour` | `rrggbb` for the key's light (`color` also accepted). Inherited from the parent when absent. |
| `params` | Values for templates, inherited by everything beneath; deeper nodes override. |
| `action` | Some or all of an action, inherited by every leaf beneath (§4). |
| `children` | Up to four nodes, or `"@name"` to use a list from `lists`. |

A node without children is a leaf. **A leaf needs no action of its own.**

### Lists

A list is a set of nodes to reuse. `"children": "@when"` puts the nodes of
`lists.when` under a branch, as if they were written there. The same list can
appear under any number of branches; each appearance takes its action and
`{{parent}}` from where it is used.

### Contacts and projects

People and projects come up in several places — the same colleague under
Messages and Mail, the same project under an IDE and its documentation — so
they are defined once. When a path is chosen, **any label on it that matches a
name** brings that entry in as `{{contact.*}}` or `{{project.*}}`, the deepest
match winning. A node can name one outright with a `contact` or `project` param.

```jsonc
"contacts": { "Alex Example": { "phone": "+15550100", "email": "alex@example.com" } }
```

Choosing *Messaging → Alex Example* then gives `{{contact.name}}`,
`{{contact.phone}}` and `{{contact.email}}`. Entries can hold any fields; an
empty one counts as missing.

### Checks

The file is refused, with the node named, when it isn't valid JSON, it declares
a newer `version` than the app understands, a row has more than four nodes, two
nodes claim one key, a key is outside 0–3, a colour isn't `rrggbb`, a tree is
deeper than it can be (a list that includes itself ends up here), a list or tree
name is unknown, or `defaults.action` has no type. A refused file leaves
the previous one in use, and the problem is shown in Settings and the menu.

---

## 4. How a leaf's action is worked out

For the leaf chosen, KeybowNotes gathers the `action` fields of every node on
the path and combines them, in increasing priority:

1. **Per-type defaults** — built in (below), plus any under `defaults.types`.
2. **The default action**, `defaults.action` — only if nothing on the path names
   a type. Built in: a new note in folders mirroring the path.
3. **Each node's own fields**, from the top of the tree down to the leaf.

**A node naming a different type from the one it inherits starts afresh.**
Fields meant for the other kind of action are dropped rather than leaking in.
That is how *Project Documentation (append)* can hold a *New Project (create)*
leaf without it inheriting the append settings.

**Built-in defaults:**

| Type | Default fields |
|---|---|
| `notes.create` — also the default action, so a note is filed alike whether marked `(Notes)` or bare | `folder: {{folderPath}}`, `title: {{leaf}} — {{date:d MMM yyyy}}` |
| `notes.append` | `folder: {{parentPath}}`, `find.byName: {{leaf}}`, `createIfMissing: true` |
| `calendar.createEvent` | `title: {{parent}}`, `start: {{when}}`, `duration: +30m`, `show: true` |
| `reminders.create` | `title: {{leaf}}` |
| `messages.compose` | `to: {{contact.phone}}` |
| `mail.compose` | `to: {{contact.email}}` |
| `app.open` | `open: {{project.path\|}}` |

So, with no settings at all:

- **A bare leaf** such as *Ideas → Inventions* makes a new note in the folder
  `Ideas/Inventions`, titled "Inventions — 27 Sep 2026", every time.
- **Under `append`**, *Characters → Francis De’Angelo* adds a dated entry to a
  note called "Francis De’Angelo" in the folder `Projects/Fiction/Characters`,
  creating the note the first time.
- **Under `Calendar`**, *Meeting → Tomorrow* makes an event called "Meeting",
  tomorrow at 09:00, for half an hour.

### Other defaults

```jsonc
"defaults": {
  "colour": "202020",              // keys with no colour of their own
  "commitDelayMs": 1000,           // after the last key, before the action runs
  "idleTimeoutMs": 10000,          // an unfinished choice clears itself
  "longPressCancelMs": 1500,       // holding a key this long clears the choice
  "dates": { "todayOffsetMinutes": 30, "roundToMinutes": 5, "defaultTime": "09:00" },
  "notes": { "account": "iCloud" },
  "action": { "type": "notes.create", … },
  "types":  { "calendar.createEvent": { "duration": "+1h" } }
}
```

The three timings can also be set in the Settings window, which overrides the
file's values once a slider is moved.

---

## 5. Actions

Every text field is filled in from the template values (§6) before the action
runs. A **required** field that comes out empty, or refers to a value that
doesn't exist, stops the action with a message saying what is missing — "The
config has no value for contact.phone, needed for the message recipient." A
missing value in an optional field is a warning, not a failure.

### `notes.create` — a new note

| Field | |
|---|---|
| `folder` | Folder path, `/` between levels. Folders are created as needed. Empty: the account's default folder. |
| `title` | The note's title, unless the template opens with a `#` heading, which wins. Falls back to the leaf's label. |
| `template` | Markdown for the body (§8). |
| `account` | A Notes account by name; else `defaults.notes.account`; else the default account. |

The new note is opened in Notes.

### `notes.append` — add to a running note

| Field | |
|---|---|
| `find.byName` | The note to add to. **Required.** |
| `folder` | Where to look, and where to create it. |
| `createIfMissing` | Create the note, titled with its name, if it isn't there. Default true. |
| `template` | Markdown for each entry. Else `entry`. |
| `entry` | Markdown for each entry, when there's no template. |
| `guards.maxBodyBytes` | Refuse to add to a note longer than this. Default 262144. |
| `guards.refuseInlineImages` | Refuse notes with inline images. Default true. |
| `account` | As for `notes.create`. |

With no template or entry text, each entry is the time in bold — plus the path,
when the note isn't named after the leaf, so that a note shared by many choices
(monthly check-ins, say) records which was made.

Appending rewrites the whole note, and Notes changes some things as it does:
checklists become plain bullet lists, inline images become attachments, and
headings lose their style. Tables, lists, bold and links survive. The guards
exist because of this; keep appended notes to text, lists and tables. A
checklist can't be detected beforehand, so there is no guard for it.

### `calendar.createEvent` — an event

| Field | |
|---|---|
| `title` | **Required.** |
| `start` | A date expression (§7). **Required.** |
| `duration` | `+30m`, `1h`, `90 min`… Default 30 minutes. |
| `alertMinutes` | An alert this many minutes before. |
| `calendarId` | A calendar by its permanent identifier. |
| `calendar` | A calendar by name. If two share it, the first is used and the result says so. |
| `notes` | The event's notes. |
| `show` | Open the new event in Calendar, ready to edit. Default true. |

With neither `calendarId` nor `calendar`: the default calendar chosen in
Settings, else Calendar's own default.

### `reminders.create` — a reminder

| Field | |
|---|---|
| `title` | **Required.** |
| `due` | A date expression (§7). Sets an alert at the same time, which is what makes a timer go off. |
| `list` | A list by name or identifier. |
| `notes` | The reminder's notes. |

With no `list`: the default list chosen in Settings, else Reminders' own default.
A list that doesn't exist falls back to the default, and the result says so.

### `messages.compose` — a message, not sent

| Field | |
|---|---|
| `to` | A phone number or Apple ID. **Required.** |
| `body` | The text, placed in the message field. |

Messages opens with the conversation and the text in place. **Nothing is sent**
until you press Return.

### `mail.compose` — an email draft

| Field | |
|---|---|
| `to` | An address. If missing, the draft opens without one, with a warning. |
| `subject`, `body` | |

### `app.open` — open an app, a file or a link

| Field | |
|---|---|
| `bundleId` | The app, found wherever it is installed. |
| `app` | The app by name, if there's no bundle ID. One of the two is **required**. |
| `open` | A path (`~` allowed) or a URL (anything with `://`) to open in it. Empty: just launch the app. |
| `url` | Used if `open` is empty. |
| `target` | A channel or place in the app, awaiting a URL. With none, the app just opens, with a warning. |

A path that doesn't exist fails with a message saying so.

### `shortcut` — run a Shortcuts shortcut

| Field | |
|---|---|
| `name` | The shortcut. **Required.** |
| `input` | Text passed to it as input. |

A shortcut that doesn't exist fails with Shortcuts' own message.

---

## 6. Values: `{{placeholders}}`

Any text in an action, and every template, can use placeholders:

| Form | |
|---|---|
| `{{leaf}}` | a value |
| `{{contact.phone\|none}}` | with a fallback, used when the value is missing or empty |
| `{{project.path\|}}` | an empty fallback: missing is fine |
| `{{date:yyyy-MM-dd}}` | a date built-in with a format |

A missing value with no fallback becomes empty, and is reported (§5).

### Where values come from

Highest priority first:

1. **`params` on the nodes** along the path — deeper nodes override shallower.
2. **Contacts and projects** matched on the path — `{{contact.name}}`,
   `{{contact.phone}}`, `{{project.path}}`, and whatever other fields they hold.
3. **The path itself:**

   | Name | For *Projects → Fiction → Characters → Francis De’Angelo* |
   |---|---|
   | `leaf` | Francis De’Angelo |
   | `parent` | Characters. A leaf at the top of a tree is its own parent. |
   | `level1` … `level4` | Projects, Fiction, Characters, Francis De’Angelo |
   | `path` | Projects / Fiction / Characters / Francis De’Angelo |
   | `folderPath` | Projects/Fiction/Characters/Francis De’Angelo |
   | `parentPath` | Projects/Fiction/Characters |
   | `tree` | main |

   In `folderPath` and `parentPath`, a `/` inside a label becomes `-`, since `/`
   separates folders.

4. **What you were doing:** `{{clipboard}}` (its text, trimmed) and `{{frontApp}}`
   (the app in front when the key was pressed — KeybowNotes never takes focus).
5. **Built-ins:**

   | Name | Default format | Example |
   |---|---|---|
   | `date` | `d MMM yyyy` | 27 Sep 2026 |
   | `time` | `HH:mm` | 14:07 |
   | `datetime` | `d MMM yyyy, HH:mm` | 27 Sep 2026, 14:07 |
   | `weekday` | `EEEE` | Sunday |
   | `isoWeek` | — | 39 |

   `date`, `time`, `datetime` and `weekday` take any
   [Unicode date format](https://www.unicode.org/reports/tr35/tr35-dates.html#Date_Field_Symbol_Table)
   after a colon: `{{date:MMMM yyyy}}` is "September 2026".

A value set lower down this list is only used when nothing higher sets the same
name, so a node's `params` can replace any of them.

---

## 7. Dates

`start` and `due` take a short phrase, usually from a leaf's `when` value:

| Phrase | Means |
|---|---|
| `today` | 30 minutes from now, rounded up to 5 |
| `tomorrow` | tomorrow at 09:00 |
| `next week` | a week today, 09:00 |
| `next month` | a month today, 09:00 |
| `friday`, `next friday`, `fri` | the next Friday after today, 09:00 — never today |
| `+3d`, `+2w` | days or weeks from today, 09:00 |
| `+90m`, `+2h` | exactly that long from now |
| `2026-10-01` | that day, 09:00 |
| `now` | now |

Any day can take a time: `tomorrow 14:00`, `friday 2:30pm`, `today at 16:15`. A
time on its own means today. A bare number is not a time (`9` is ambiguous;
`9am` and `09:00` are fine).

The half hour, the rounding and the 09:00 are set under `defaults.dates`.

Durations, for `duration`: `+30m`, `30 min`, `1h`, `2 hours`, `+1d`.

---

## 8. Templates

A template is a Markdown file. A relative name is looked up in the `templates`
folder beside the config file; an absolute or `~/` path is used as it is.
Placeholders are filled in first, then the Markdown becomes the HTML that Notes
accepts:

| Markdown | In the note |
|---|---|
| `# Heading`, `## …`, `### …` | headings (restyled by Notes as bold text of three sizes) |
| `- item` or `* item` | a bulleted list |
| `-` on its own | an empty bullet, to fill in |
| `1. item` | a numbered list |
| `**bold**` | bold |
| `*italic*` or `_italic_` | italic (not inside words, so `file_name` is left alone) |
| `[text](https://…)` | "text (https://…)" — Notes drops links set by a script, so the address is kept as text |
| a blank line | a blank line |

For `notes.create`, a template whose first line is a `#` heading names the
note: that line becomes the title, ahead of any `title` in the action, and the
rest becomes the body. Checklists
and tables can't be created from a script, so there's no syntax for them.

---

## 9. Settings that take part

A few things belong to the Mac rather than the tree, and live in the Settings
window instead of the file. Two of them feed into the language:

- **Timings** — a slider, once moved, overrides the file's `commitDelayMs`,
  `idleTimeoutMs` or `longPressCancelMs`.
- **Default calendar and reminders list** — used when an action names neither.

---

## 10. Reserved words

**Outline annotations:** `Notes`, `Calendar`, `Reminders`, `Messages`, `Mail`,
`append`, `new`, `create`, `… alert`, `….md`, and the app names the converter
knows.

**Action types:** `notes.create`, `notes.append`, `calendar.createEvent`,
`reminders.create`, `messages.compose`, `mail.compose`, `app.open`, `shortcut`.

**Computed values:** `leaf`, `parent`, `level1`–`level4`, `path`, `folderPath`,
`parentPath`, `tree`, `contact.*`, `project.*`, `clipboard`, `frontApp`, `date`,
`time`, `datetime`, `weekday`, `isoWeek`, and `when` by convention.

**Tree names:** `main`, `row2`, `row3`, `bottom`.

---

## 11. Not yet in the language

- **Asking for a value** before acting — a text field in the overlay. Reserved
  syntax: `{{?Label}}`.
- **More than one action** per leaf — a note *and* a reminder pointing to it.
- **Channel URLs** for apps like Discord and Meshtastic, which the converter can
  only list as needing one.
- **Outline syntax for everything JSON can say** — `params`, `find`, `guards`,
  lists, contacts and projects still need the JSON.
- **An editor** for the tree, beyond the outline.
