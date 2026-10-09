# The KeybowNotes configuration language

**Version 3**, as understood by KeybowNotes 0.1. This describes what the parser,
the compiler and the action planner do today; where behaviour is a default
rather than a rule, it says so.

A configuration says what each key on the keypad means: which choices are
offered on each row, what the final choice does, and with what values.

**The outline is the configuration.** It is a numbered list, the way you'd
sketch a tree by hand, with keywords and settings in square brackets — written
by hand or in the tree editor — and it lives at
`~/Library/Application Support/KeybowNotes/tree.md`. The app **compiles** it as
it reads it, at launch and whenever the file changes: saved from the editor, it
reloads at once; saved from any other editor, within a couple of seconds.

A mistake costs only what it touches: the app runs the rest of the tree, and
says how many mistakes there are in the menu, the Settings window and the
overlay. A branch that a mistake leaves with nothing under it is left out
too, rather than become a leaf with an action it was never meant to have.

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

**Pages.** The main, row 2 and row 3 trees can be **pages** instead. Each key
on the tree's row picks a page, and the page stays: the rows below become its
keys, each running its action the moment it's pressed. See [Pages](#pages).

**Leaves are usually values.** In *Meeting → Tomorrow*, "Meeting" decides the
action (a calendar event) and "Tomorrow" supplies a value (the date). So an
action is normally declared on a branch and **inherited** by every leaf beneath
it; the leaf's label, and anything else along the path, fills in the details.

---

## 2. The outline

```
KeybowNotes template hierarchy              ← before the first item: kept as written

1. Work [colour: 0060ff]
   2. General Tasks
      1. Meeting [Calendar, 5 min alert, duration: 1h]
         1. Today
         2. Tomorrow
      4. Notes                              ← key 3 is empty: the numbers say so
         1. Work log [worklog.md]
2. Personal
   3. Reminder [Reminders]
      1. Grocery basics
         1. Milk

# row 2                                     ← a side tree
1. Check-in [append, find.byName: "Check-ins, {{date:MMMM yyyy}}"]
   1. Mood [@rating]

# list rating                               ← nodes to reuse
1. Great
2. Meh

# contacts
- Rudy Rudolph [phone: +15550100, email: rudy@example.com]

# projects
- Project A [path: ~/Code/project-a]

# defaults
- commitDelayMs: 800
```

### Items

- **`N. Label [annotations]`** — `N` is the key position, 1 to 4. A missing
  number leaves that key unused; `3.` with nothing after it says so explicitly
  and is otherwise ignored.
- **Indentation is nesting.** An item belongs to the nearest item above it that
  is indented less. Tabs count as four spaces.
- **Mistakes don't stop the reading.** A key number outside 1–4, a number used
  twice at one level, or an item deeper than its tree allows is reported with
  its line, and skipped along with everything beneath it. The app runs the rest;
  the editor shows them in place, and `keybow convert` refuses to write JSON
  while any remain.

### Sections

A heading starts a section, which lasts until the next one:

| Heading | Holds |
|---|---|
| none — items before any heading | the main tree |
| `# main`, `# top`, `# row 1` | the main tree |
| `# row 2` | the row 2 tree |
| `# row 3` | the row 3 tree |
| `# bottom`, `# row 4`, `# bottom up` | the bottom tree |
| `# main [pages]`, `# row 2 [pages]`, `# row 3 [pages]` | a tree as pages — see [Pages](#pages) |
| `# keypad <name> [model, id: …]` | another keypad's trees — see [Keypads](#keypads) |
| `# list <name>` | nodes reused with `[@name]` |
| `# contacts` | people: `- Name [field: value, …]` |
| `# projects` | projects: `- Name [path: …, …]` |
| `# defaults` | settings: `- key: value` |

The word "tree", case, spaces and hyphens don't matter in tree headings. A
heading before the first item that names no section is part of the preamble —
a title. Other lines between items are ignored, and aren't kept when the
outline is written back out.

### Keypads

With more than one keypad, each can have trees of its own. A `# keypad`
heading starts a keypad's section: the items right under it are its main tree,
and the tree headings after it — `# row 2`, `# row 3`, `# bottom` — are its
side trees, until the next `# keypad` heading. Trees before any `# keypad`
heading are the **Default** trees.

```
1. Work [colour: 0060ff]                    ← the Default trees
   1. Standup

# row 2
1. Capture [Copy]

# keypad Desk [RGB Keypad]                  ← trees for any RGB Keypad
1. Music [colour: ff8c00]
   1. Play
# row 3
1. Timers [Stopwatch]

# keypad Spare [Keybow 2040, id: E66000000000AAAA]   ← for one board only

# contacts                                  ← shared by every keypad
- Alex Example [phone: +15550100]
```

The brackets say which keypads a section is for:

- **A model** — `Keybow 2040` or `RGB Keypad` (also `keybow`, `rgb`,
  `Pico`) — for every keypad of that model.
- **`id: …`** — for one board, by the unique ID it reports. It's for having two
  of one model: the section naming a board's ID wins over one naming only its
  model. `keybow keypads` lists the IDs of those connected, and the tree
  editor's ID menu offers them.

A keypad uses the first section with its ID, else the first with its model and
no ID, else the Default trees — or, when the Default trees are empty, the first
section's. A word that isn't a model is reported, and the section matches
by ID alone.

Lists, contacts, projects and defaults are shared, wherever their headings
fall. A file without `# keypad` headings reads as before: every keypad shares
its trees.

### Pages

`[pages]` on a tree's heading makes the tree a set of pages, for keys that each
do one thing at once — macros, snippets, window positions — rather than a walk
through choices:

```
# row 2 [pages]
1. Editing [colour: 20c060, Insert]          ← a page, on row 2, key 1
   1. Greeting [text: Hello there]           ← row 3, key 1
   2. Sign-off [text: Best wishes]           ← row 3, key 2
   5. Today [text: {{date:d MMMM}}]          ← row 4, key 1
   8. Undo [Copy, colour: e04040]            ← row 4, key 4, in its own colour
2. Windows [colour: f0a020, Window]
   1. Left
   2. Right
   5. Full
```

- **The items on the tree's row are pages.** The items under a page are its
  keys, on every row below, numbered left to right and then down: 1–4 on the
  next row, 5–8 on the one after, 9–12 on the last. Row 1's pages have 12 keys,
  row 2's have 8, row 3's have 4. The bottom tree has no rows below it, and
  can't be pages.
- **A page's keys are actions.** Each runs the moment it's pressed, with no time
  to cancel, and has no keys under it. It inherits from its page as any leaf
  inherits from its branch: `[Insert]` on the page makes every key on it
  insert text.
- **Pressing a page's key turns to it, and it stays** — through waiting, through
  running its keys, through edits to the tree — until another page is chosen.
  Its keys light in the page's colour, unless they have their own; the page's
  key is lit fully, and the other pages dimly.
- **Back to the trees**: the page's own key again, or any key on a row above
  the pages. That press also counts as the first in its tree, so pressing
  *Work* on row 1 opens *Work*. Row 1's pages have no row above, so their own
  key is the way back.
- While a tree is in play, its next row is its own: with row 2 as pages, the
  main tree still goes on from row 1 to row 2 as usual. Pages are picked from a
  keypad at rest.

A page takes its keys from the items under it, not from a list. An empty page
is noted, and does nothing.

### Brackets

A **final** group in square brackets holds the item's annotations, separated by
commas. Parentheses are just text: `Project (old) [Notes]` is labelled
"Project (old)". To put a square bracket in a label, write `\[` or `\]`.

An annotation is either a **word** or a **pair**.

#### Words

| Word | Meaning | Compiles to |
|---|---|---|
| `Notes` | a new note | `"type": "notes.create"` |
| `Calendar` | a calendar event | `"type": "calendar.createEvent"` |
| `Reminders` | a reminder | `"type": "reminders.create"` |
| `Messages` | a message, ready to send | `"type": "messages.compose"` |
| `Mail` | an email draft | `"type": "mail.compose"` |
| `Call` | a phone call through your iPhone | `"type": "phone.call"` |
| `FaceTime` | a FaceTime audio call | `"type": "phone.call", "via": "facetime"` |
| `Link`, `Browser` | open a link: web links in the default browser | `"type": "url.open"` |
| `Copy`, `Clipboard` | put text on the clipboard | `"type": "clipboard.copy"` |
| `Insert`, `Paste` | type text at the cursor in the app in front | `"type": "text.insert"` |
| `Direct Insert`, `Type` | the same, without using the clipboard | `"type": "text.insertDirect"` |
| `Timer` | start a timer in Clock | `"type": "clock.timer"` |
| `Maps` | search in Maps | `"type": "maps.search"` |
| `Music` | play a song, an album, an artist, a genre or a playlist in Music | `"type": "music.play"` |
| `Stopwatch` | KeybowNotes' own stopwatch (a module) | `"type": "stopwatch"` |
| `Display`, `Show` | show text on screen (a module) | `"type": "display"` |
| `Ask`, `Prompt` | ask for something to be typed, and hand it on (a module) | `"type": "ask"` |
| `Window`, `Arrange` | move and size the window you're working in (a module) | `"type": "window"` |
| `append` | add to a running note rather than make a new one | `"type": "notes.append"` |
| `new`, `create` | make a new note | `"type": "notes.create"` |
| `something.md` | a template (§8) | `"template": "something.md"` |
| `N min alert`, `N hour alert` | an alert before an event | `"alertMinutes": N` |
| `@name` | take this branch's children from `# list name` | `"children": "@name"` |
| an app — `Rider`, `VSCode`… | open the leaf in that app | `"type": "app.open", "app": …, "bundleId": …` |
| a link — `https://example.com/page` | the link to open; with no type in force, opens it | `"url": …`, and `"type": "url.open"` if nothing names a type |
| any other word, under an app | a channel or place in that app | `"target": …` |

- **Case doesn't matter** for the keywords. `min`/`mins`/`minute(s)` and
  `h`/`hr`/`hour(s)` are all accepted in alerts.
- **Template names can imply append or create.** A template whose name begins
  `Append…` makes the node append; one beginning `New…` makes it create — unless
  another annotation on the node has already chosen. Reported as a guess.
- **Apps are recognised by the names people use** — `VSCode` is Visual Studio
  Code, `Prusa Slicer` is PrusaSlicer, `Fusion` is Autodesk Fusion, `Mastodon`
  is whichever Mastodon client is installed — and looked for in `/Applications`,
  `/System/Applications` and `~/Applications`, including one folder down. The
  bundle ID is recorded, so the app is found wherever it lives at run time.
- **Elsewhere, an unknown capitalised word is assumed to be an app**, with a
  warning that it isn't installed, and **an unknown lowercase word is kept** as a
  `note` value, with a warning.
- A branch can't both take `@list` children and have its own.
- **A link as a word needs `://`** — `https://…`, `things:///add…`. Anything
  else with a colon reads as a pair, so write `url: mailto:someone@example.com`.
  A link containing a comma or square bracket must be a quoted `url: "…"` too.
  Under an app, a link opens in that app: `Safari [Safari]` with a child
  `Docs [https://developer.apple.com]`.

#### Pairs

`key: value` sets something. The key decides where it goes:

- **`colour`** (or `color`): the key's light, `rrggbb`.
- **`type`**: the action type by its full name, for types without a keyword:
  `type: shortcut`.
- **An action field** (§5) sets that field: `folder`, `title`, `template`,
  `account`, `entry`, `createIfMissing`, `find.byName`, `guards.maxBodyBytes`,
  `guards.refuseInlineImages`, `start`, `duration`, `alertMinutes`, `calendar`,
  `calendarId`, `notes`, `show`, `due`, `list`, `to`, `body`, `subject`, `app`,
  `bundleId`, `open`, `url`, `target`, `name`, `input`, `via`, `text`, `shortcut`,
  `query`, `playlist`, `album`, `artist`, `shuffle`, `instant`. A dotted key sets a field
  inside another: `find.byName: Journal`.
- **Anything else** is a value for templates (§6), inherited by everything
  beneath: `area: work`, `when: tomorrow`, `contact: Rudy Rudolph`.

`alertMinutes` and `guards.maxBodyBytes` are numbers; `createIfMissing`, `show`,
`shuffle`, `instant` and `guards.refuseInlineImages` are `true` or `false`; everything else is text,
placeholders included: `title: Standup — {{date:d MMM}}`. The value runs to the
next comma; **put it in double quotes** if it contains a comma, a square
bracket or a quote (written `\"`), or starts or ends with a space. Inside
quotes, `\n` is a new line: `body: "Running late.\nSorry!"`. `key:` with nothing
after it is an empty value.

#### Contacts, projects and defaults

Contacts and projects are bulleted names with pairs: any fields, used as
`{{contact.phone}}` or `{{project.path}}` (§3). Defaults are bulleted pairs,
with dots for grouped settings:

```
# defaults
- colour: 202020
- commitDelayMs: 800
- dates.defaultTime: 08:30
- notes.account: iCloud
- action.type: notes.append
- types.calendar.createEvent.duration: 1h
```

### What the compiler infers for leaves

A leaf with no annotations still means something, depending on what it inherits:

| Under | A leaf like | Becomes |
|---|---|---|
| a calendar branch | `Today`, `Next week`, `friday` | a `when` value, if it reads as a date (§7) |
| a Messages branch | `Rudy Rudolph` | a contact needing a phone number |
| a Mail branch | `Rudy Rudolph` | the same contact, needing an email address |
| a Call branch | `Rudy Rudolph` | the same contact, needing a phone number |
| an app that opens files | `Project A` | a project needing a path |
| an app that is a service (Discord, Claude…) | `Channel1` | a target needing a URL — add `open: …` |
| nothing, with a link on the leaf | `Docs [https://…]` or `Search [url: …]` | opens the link (`url.open`) |
| nothing | `Inventions` | the default action: a new note (§4) |

In a `# list`, a leaf that reads as a date gets a `when` value whatever uses the
list. An explicit `when:`, `start:`, `to:`, `contact:` or `open:` is left alone.

A person or project the tree refers to but `# contacts` or `# projects`
doesn't define still gets an entry in the compiled JSON, with empty fields, and
is reported.

### The compiler's report

`keybow convert` lists, on stderr:

- **Guessed — check these:** an app it substituted, or append/create read from a
  template's name.
- **Still to fill in:** phone numbers, email addresses, project paths, channel
  URLs, events with no date.
- **Warnings:** an app that isn't installed, a word it didn't understand.

Each top-level node without a `colour` gets one from a small palette, which its
children inherit. Before writing, the compiled JSON is loaded exactly as the
app would load it.

### Writing it back out

The tree editor, and `keybow upgrade-outline`, write the outline in one
consistent form: three spaces per level, numbers as key positions, empty keys
omitted, and sections in the order main tree, side trees, each keypad's section
— its heading, its main tree, its side trees — then lists, contacts, projects,
defaults. A tree that's pages is written under its heading — `# main [pages]`
included — even when it's empty. The preamble is kept as written.

### Upgrading an older outline

Version 2 put annotations in parentheses. `keybow upgrade-outline tree.md`
rewrites a trailing `(…)` on each item as `[…]`, adds `# contacts` and
`# projects` entries — with empty fields — for everyone and everything the tree
refers to, and keeps the original as `tree.md.bak`.

---

## 3. The compiled form

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
  },
  "pages": [ "row2" ],                      // §2, Pages
  "keypads": [                              // §2, Keypads
    { "name": "Desk", "model": "rgbkeypad", "trees": { "main": [ … ] }, "pages": [ "main" ] },
    { "name": "Spare", "model": "keybow2040", "id": "E66000000000AAAA", "trees": { … } }
  ]
}
```

This is what the outline compiles to, in memory, as the app loads it. No file
of it is kept; it's described here because it is what every rule below is
expressed in, and because it's readable when something needs checking —
`keybow convert tree.md` prints it. The app and the `keybow` command also load
a `.json` file of it as it is, which tests and tools use. Every section is
optional. A version 1 file, with a single `"tree": [ … ]`, loads as the main
tree.

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
| `key` | Position 0–3 — or under a page, 0–11, across then down. Without it, the next free position. |
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
That is how *Project Documentation [append]* can hold a *New Project [create]*
leaf without it inheriting the append settings.

**Built-in defaults:**

| Type | Default fields |
|---|---|
| `notes.create` — also the default action, so a note is filed alike whether marked `[Notes]` or bare | `folder: {{folderPath}}`, `title: {{leaf}} — {{date:d MMM yyyy}}` |
| `notes.append` | `folder: {{parentPath}}`, `find.byName: {{leaf}}`, `createIfMissing: true` |
| `calendar.createEvent` | `title: {{parent}}`, `start: {{when}}`, `duration: +30m`, `show: true` |
| `reminders.create` | `title: {{leaf}}` |
| `messages.compose` | `to: {{contact.phone}}` |
| `phone.call` | `to: {{contact.phone}}` |
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

### Running at once: `instant`

A chosen leaf normally waits the time to cancel (`commitDelayMs`, a second by
default) before its action runs, so a wrong press can be taken back.
`instant: true` on a node skips that wait for the leaves under it: the action
runs the moment the key is pressed, and can't be cancelled. `instant: false`
restores the wait where something would otherwise skip it. A module may ask
for its actions to run at once — the stopwatch does, for all but Reset.

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
| `template` | A file whose text is used instead of `body`, placeholders filled in. |

Messages opens with the conversation and the text in place. **Nothing is sent**
until you press Return.

### `phone.call` — a phone call, confirmed first

| Field | |
|---|---|
| `to` | The number. **Required.** Spaces and brackets are dropped; digits, `+`, `*`, `#` are kept. |
| `via` | Empty for a call through your iPhone; `facetime` for FaceTime audio. |

The Mac opens a `tel:` link, and macOS shows its call prompt: **you confirm the
call** — nothing dials by itself. Calls go through your iPhone when it and the
Mac share an Apple ID and *Calls from iPhone* is on (FaceTime → Settings on the
Mac; *Calls on Other Devices* on the iPhone).

### `mail.compose` — an email draft

| Field | |
|---|---|
| `to` | An address. If missing, the draft opens without one, with a warning. |
| `subject`, `body` | |
| `template` | A file whose text is used instead of `body`. |

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

### `url.open` — open a link

| Field | |
|---|---|
| `url` | **Required.** A web link opens in the default browser; any other link (`mailto:`, `things:`, `obsidian:`…) in the app that handles it; a path (`~` allowed) in its default app. |

Values placed into a link are encoded (§6, *Inside links*). A value that is the
whole link — `url: "{{selection}}"` — is used as it stands, and a bare address
like `apple.com/mac` gets `https://`. Text that isn't a link, or a path with
nothing there, fails with a message saying so.

```
1. Web [Browser]
   1. Search [url: "https://duckduckgo.com/?q={{selection}}"]
   2. Open selected [url: "{{selection}}"]
   3. Apple docs [https://developer.apple.com/documentation]
```

To open a link in a particular browser, use its app instead:
`Safari [Safari, url: …]`.

### `clock.timer` — a timer in Clock

| Field | |
|---|---|
| `duration` | How long: `5 min`, `1h 30m`, `90 seconds`, `+25m` — or, as for a reminder's `due`, a time to run until: `16:30`, `today at 16:15`, `tomorrow 9:00`. A time of day that has passed means tomorrow's. With no `duration`, a `due` is used, then the leaf's label, so *5 Minutes* needs nothing more. |
| `shortcut` | The helper shortcut; `KeybowNotes Timer` if empty. |

Clock can't be scripted, but Shortcuts' **Start Timer** action reaches it, so
timers go through a shortcut you make once: in Shortcuts, a new shortcut called
**KeybowNotes Timer** with one action, *Start Timer*, whose duration is
*Shortcut Input* in *seconds*. KeybowNotes runs it with the length in seconds.
Until it exists, the action stops with a message saying how to make it, and the
tree editor shows the same steps. Clock's timers stop at 24 hours; longer is
refused.

```
1. Timer [Timer]
   1. 5 Minutes
   2. 25 Minutes
   3. Tea [duration: 4 min]
   4. Until the call [duration: 15:55]
```

A reminder branch used as a timer — `[Reminders]` leaves with `due: +5m` —
becomes a Clock timer by changing `Reminders` to `Timer`.

Clock's **stopwatch** can't be started this way: neither Clock nor Shortcuts
offers any automation for it. KeybowNotes has a stopwatch of its own instead.

### `maps.search` — search in Maps

| Field | |
|---|---|
| `query` | What to search for; the leaf's label if empty. `{{selection}}` searches for the selected text. |

Opens Maps with the search, through a `maps:` link.

```
1. Places [Maps]
   1. Coffee
   2. Petrol station
   3. Look up [query: "{{selection}}"]
```

### `music.play` — play a song, an album, an artist, a genre or a playlist

| Field | |
|---|---|
| `song` | One song in your library, by its title. Wins over everything else. |
| `album` | An album in your library, played in disc and track order. Wins over `playlist`, `artist` and `genre`. |
| `playlist` | A playlist by name. Wins over `artist` and `genre`. |
| `artist` | By itself, the artist's songs; with `genre`, those in the genre. With `song` or `album`, picks whose when two share a name. Matches the artist or album artist. |
| `genre` | The genre's songs — or, with `artist`, that artist's in it. |
| `shuffle` | `true` or `false`. Empty leaves Music's setting alone for a playlist, and shuffles an artist's or a genre's songs, which have no order of their own. Songs and albums play in order. |

With none of `song`, `album`, `playlist`, `artist` or `genre`, the leaf's label
names a playlist. Names are matched without regard to case.

Music plays a playlist, so a song, an album, an artist's or a genre's songs are
copied into a playlist of KeybowNotes' own, **KeybowNotes**, remade each time —
deleting a playlist never deletes its songs. Only music in your library can be
played. The first time, macOS asks whether KeybowNotes may control Music.

```
1. Music [Music]
   1. Focus
   2. Party [shuffle: true]
   3. Kind of Blue [album: Kind of Blue, artist: Miles Davis]
   4. So What [song: So What]
2. Jazz [Music, genre: Jazz, artist: "{{leaf}}"]
   1. Miles Davis
   2. John Coltrane
   3. All of it [artist: ""]
```

A genre with an artist on each key below it: `artist: "{{leaf}}"` on the genre
gives every key its own artist, by its label; `artist: ""` on a key clears it,
for the whole genre.

In the tree editor, *Song*, *Album*, *Playlist*, *Artist* and *Genre* list
what's in your library — an artist's albums, a genre's artists — most played
first. Reading the library asks, the first time, for Media & Apple Music access.

### `stopwatch` — KeybowNotes' own stopwatch

| Field | |
|---|---|
| `do` | `toggle`, `start`, `stop`, `lap` or `reset`. Without it, the leaf's label decides — *Start*, *Stop*, *Pause*, *Lap*, *Split*, *Reset* — and anything else toggles. |

```
# row 3
1. Stopwatch [Stopwatch]
   1. Start
   2. Stop
   3. Lap
   4. Reset
```

Start, stop and lap happen **the moment the key is pressed**, with no time to
cancel, and are timed from the press itself. Reset keeps the time to cancel,
so a stray press can't wipe a time; `instant:` changes either.

A lone `Stopwatch [Stopwatch]` key starts and stops it. Whatever keys you set
up, the menu bar's menu has Stop, Lap and Reset under *Stopwatch*, usable while
it runs, so a stopwatch started from a key that only starts it can always be
stopped. The same menu lists the laps so far under *Laps* — each lap's length,
then the time since the start: "Lap 2 — 1:00 (2:05)" — and *Copy Lap Times*
puts them on the clipboard as tab-separated columns, which paste into a
spreadsheet or a note.

While it has a time it shows at the foot of the overlay and in the menu bar;
while it runs, the key that leads to it breathes. It keeps running through a
restart. Its time is a value for any action:

| Value | Example | |
|---|---|---|
| `{{stopwatch}}` | 3:12 | the time so far |
| `{{stopwatch.seconds}}` | 192 | the same, in seconds |
| `{{stopwatch.laps}}` | 1:05, 1:00 | how long each lap took |
| `{{stopwatch.splits}}` | 1:05, 2:05 | the time since the start at each lap |

So a note can log it: `Log [append, entry: "**{{datetime}}** — {{stopwatch}}, laps {{stopwatch.laps}}"]`.

The stopwatch is a **module** — see MODULES.md — so its keyword, field and
values come from the module, not the core.

### `text.insert` — text at the cursor

| Field | |
|---|---|
| `text` | The text, placeholders and `\n` new lines included; kept exactly, spaces and all. |
| `template` | A file whose text is inserted instead. |
| `format` | `auto` (the default): pasted formatted when the text is Markdown, where the app takes formatting. `rich`: formatted always. `plain`: the text alone. See [Formatted text](#formatted-text). |

With neither, the leaf's label is inserted. Like typing it, it goes wherever
the cursor is in the app in front, and replaces any selected text — so
`text: "“{{selection}}”"` wraps the selection in quotes.

It works by pasting: the text goes on the clipboard, KeybowNotes presses ⌘V,
and a moment later your clipboard is put back as it was, marked so clipboard
managers don't record it twice. That works in nearly every app, including
Chrome, Electron apps and Terminal. Pressing ⌘V needs **Accessibility
access**, the same as `{{selection}}`; the first use asks for it.

```
1. Type [Insert]
   1. Kind regards
   2. Today [text: "{{date:d MMMM yyyy}}"]
   3. Signature [signature.md]
   4. Quote it [text: "“{{selection}}”"]
```

### `text.insertDirect` — text at the cursor, without the clipboard

| Field | |
|---|---|
| `text`, `template` | As for `text.insert`; with neither, the leaf's label. |
| `via` | `accessibility`, `typing`, or empty for accessibility where the app takes it, else typing. |

For when a clipboard manager is installed and `text.insert`'s paste would
clutter its history. It never touches the clipboard:

- **Accessibility**: the app is asked to replace its selection with the text.
  Exact and instant, in standard Mac text views — Notes, TextEdit, Mail, Pages.
  Some apps — Chrome, Electron apps — say yes and do nothing, so KeybowNotes
  checks the text really went in, by the field's length, before believing it.
- **Typing**: a key press for each character, carrying the character itself,
  so it doesn't depend on the keyboard layout. Works nearly everywhere, a
  little slower for long text. A new line is typed as Return — which, in a chat
  app, sends the message.

`via: accessibility` fails with a message rather than typing, for apps where
typing would go wrong. Both ways need **Accessibility access**.

```
1. Type [Direct Insert]
   1. Kind regards
   2. Today [text: "{{date:d MMMM yyyy}}"]
   3. In the terminal [text: "git status", via: typing]
```

### `clipboard.copy` — put text on the clipboard

| Field | |
|---|---|
| `text` | The text, placeholders and `\n` new lines included; kept exactly, spaces and all. |
| `template` | A file whose text is copied instead. |
| `format` | `auto` (the default), `rich` or `plain`, as below. |

With neither, the leaf's label is copied, so a list of snippets needs only
labels. A value that `text` needs but can't find stops the action rather than
copying something incomplete.

```
1. Snippets [Copy]
   1. Kind regards
   2. Address [text: "1 High Street\nSmalltown"]
   3. Signature [signature.md]
2. Numbers [Copy, text: "{{contact.phone}}"]
   1. Rudy Rudolph
```

#### Formatted text

Copy and Insert put Markdown on the clipboard formatted as well as plain:
headings (`#` to `###`), lists, `**bold**`, `*italic*` or `_italic_`, and
`[links](https://…)`. Mail, Notes, Pages and other rich editors paste it
formatted; a plain field, a terminal or a Markdown editor gets the Markdown as
written. Most useful for a Claude reply, which comes back in Markdown:

```
1. Draft [Copy, text: "{{#ai}}Write release notes for: {{selection}}{{/ai}}"]
```

With `format: auto`, the default, text with none of that formatting goes on
plain, so a phone number or a sentence pastes in the style of where it lands.
`format: rich` formats even plain text, in the system font; `format: plain`
never does.

### `display` — show text on screen

A module. Shows a template or text in a panel above everything, sized to fit
it — for a quote, today's notes, a forecast, anything worth a glance without
opening an app.

| Field | |
|---|---|
| `template` | A file to show, filled in when the key is pressed. |
| `text` | What to show, when there's no template. With neither, the leaf's label. |
| `button` | `ok`, `cancel` or `okCancel`: buttons that close it. Without one, it fades by itself. |
| `fade` | How long it stays when it has no buttons: `15 sec`, `2 min`, or a number of seconds. Without it, long enough to read — about three words a second, from six seconds to a minute. |
| `ok`, `cancel` | An action to run when that button is chosen (below). |

```
1. Glance [Display]
   1. Quote [text: "{{quote file=quotes.md}}", fade: 20 sec]
   2. Today [today.md]
   3. Status [status.html, button: ok]
2. Idea [Display, text: "{{#ai}}One idea for {{selection}}{{/ai}}", button: okCancel, ok: Copy]
```

- **Markdown**, unless it's an **HTML document** — text that begins
  `<!DOCTYPE html>`, `<html>`, an XML declaration (`<?xml … encoding=…?>`) or a
  `<meta>` tag — which is shown as a web page, in its own styles, over the
  panel's dark background. What's shown is trimmed of blank lines and spaces
  first. Values placed into an HTML document are escaped, so a quote with a `<`
  or `&` in it stays text; Markdown takes them as written.
- **Scripts don't run.** The text can hold values from outside — the selection,
  an API's response, Claude's reply — so a page's JavaScript is off.
- **Links open in your default browser**, when you click them. Nothing else
  makes the panel go anywhere.
- **Esc closes it**, from whatever app you're in, and so does its ✕ button.
  While a display is up, Esc is its own — the app in front doesn't also get it —
  and it's handed back as soon as the display goes. With a Cancel button, Esc
  is Cancel. It never takes the focus from what you're doing; click it first to
  use Return for OK.
- **One at a time:** a new display replaces the last.
- **Its size** follows the text: as wide as the longest line, up to 620 points
  (or half the screen), and as tall as it needs, up to 70% of the screen — and
  it scrolls beyond that. It appears on the overlay's screen, above the middle.

**On OK and Cancel**, the display can run an action of its own, as though its
key had been pressed. Name its type with the button's name — by keyword, like
`[Copy]`, or in full — and give its fields after a dot:

```
Idea [Display, text: "…", button: okCancel,
      ok: Copy,
      cancel: Notes, cancel.folder: Rejected, cancel.title: "Not this: {{displayed}}"]
```

`{{displayed}}` is the text that was shown, as it reads — an HTML document
without its tags. An action that takes text — Copy, Insert, Direct Insert — and
is given none uses it, so `ok: Copy` copies what was shown. The action runs for
the same key, so `{{leaf}}` and the rest are what they were. Closing it any
other way — ✕, Esc without a Cancel button, fading, being replaced — runs
nothing. In the tree editor, *When OK is chosen* and *When Cancel is chosen*
appear once the buttons are set, each with its own Type menu and fields.

### `window` — move and size the window you're working in

A module. Moves the focused window of the app in front — KeybowNotes never
takes the front, so it's the window you were working in — to part of its
screen, or to another screen.

| Field | |
|---|---|
| `place` | `full`, a half — `left`, `right` (the full height), `top`, `bottom` (the full width) — or a quarter: `topLeft`, `topRight`, `bottomLeft`, `bottomRight`. Without it, the leaf's label, when it names one. |
| `screen` | `next` or `previous` (round the ends), `main` (the one with the menu bar), a number counting from the left, or part of a display's name. Without it, the window's own screen. |

```
1. Windows [Window]
   1. Left
   2. Right
   3. Top left
   4. Full
2. Elsewhere [Window, screen: next]
   1. Left
   2. Full
   3. Next screen
```

- **The screen's area** is all of it less the menu bar, and less the Dock when
  it's always shown. Halves meet exactly; an odd point goes to the right or
  upper one. Quarters are half of each.
- **`full` fills that area.** It isn't macOS's full-screen mode, and a window in
  that mode is left alone, with a note to leave it first.
- **Labels name places** as you'd say them: *Top left*, *Upper right*, *Left
  half*, *Bottom right corner*, *Full screen*, *Maximise*. A label like *Next
  screen* or *Previous display*, with no place, names the screen.
- **To another screen without a place,** the window keeps its share of the
  screen: half the width, a quarter of the way in, stays so.
- A window that's one size only is moved, not resized, and the overlay says so.
  Some apps round a size — a terminal to whole lines — so they may fall a few
  points short.
- On a screen with a menu bar of its own, macOS keeps windows below it.
- It needs **Accessibility** access, like Insert and `{{selection}}`.

### `expose` — Mission Control, an app's windows, or the desktop

A module. Shows every window — Mission Control, Exposé as was — the windows of
the app in front, or the desktop. Pressing it again puts things back, as the
keyboard shortcuts do. It runs on the press, with no time to cancel.

| Field | |
|---|---|
| `show` | `all` (Mission Control), `app` (the app in front's windows) or `desktop`. Without it, the leaf's label when it says *app* or *desktop*; else `all`. |

```
1. Windows [Exposé]
   1. All windows
   2. App windows
   3. Desktop
2. Spaces [Mission Control]
```

Keywords: `Exposé`, `Expose`, `Mission Control`. It asks the Dock, as macOS's
own Mission Control launcher does, so it needs no permissions, and Mission
Control's settings — grouping by app, separate spaces per display — apply.

### `ask` — ask for something, and hand it on

A module, built on `display`. Shows a question with a field to type in, and on
OK runs an action of the node's own with what was typed, as `{{answer}}`.

| Field | |
|---|---|
| `template`, `text` | The question, as a display's: Markdown or an HTML document. With neither, the leaf's label. |
| `initial` | What's in the field to begin with, selected so typing replaces it: `{{selection|}}`. |
| `hint` | Grey words in the empty field. |
| `multiline` | `true` for a taller field that takes new lines. |
| `ok` | The action given the answer. |
| `cancel` | An action for Cancel or Esc; usually none. |

```
1. Search [Ask, text: "Search Wikipedia for", ok: Display, ok.text: "{{api.wikipedia term={{answer}}}}"]
2. Jot [Ask, text: "A note for the inbox", multiline: true, ok: append, ok.find.byName: Inbox, ok.entry: "{{answer}}"]
3. Rename [Ask, text: "New name", initial: "{{selection}}", ok: Insert]
```

- **It takes the keyboard** as it opens, without taking the app you're in from
  the front — so an Insert on OK types into that app, and once it's answered,
  your typing goes back there.
- **Return is OK** — ⌘Return with `multiline`, where Return starts a new line —
  and Esc is Cancel. OK waits for something to be typed; the answer is trimmed.
- **`{{answer}}`** is what was typed, for any field of the OK action, and what
  Copy, Insert and Direct Insert use when they're given no text. It's kept out
  of the log, like the selection.
- `ok` and `cancel` are written, and chosen in the editor, as a display's are.
- **The OK action is worked out when it runs,** after OK: its `{{#ai}}` blocks
  are asked, and its data sources fetched, with the answer in hand. So
  `ok.text: "{{#ai}}{{answer}}{{/ai}}"` asks Claude what you typed, and
  `{{api.wikipedia term={{answer}}}}` looks it up — nothing is asked or fetched
  for it when the key is pressed.

### `home` — Home Assistant

A module. Calls a Home Assistant service on an entity: switches a lamp, sets a
thermostat, runs a scene. Its address and a long-lived access token go in
Settings → Home Assistant.

| Field | |
|---|---|
| `entity` | The entity ID — `light.desk_lamp` — or several, separated by commas. *Copy the Entity List*, in the menu bar's Home Assistant menu, lists them. |
| `service` | What to do: `turn_on`, `turn_off`, `toggle`, or a whole name — `climate.set_preset_mode`. Usually left out (below). |
| `brightness` | A light's brightness, 0–100. |
| `color` | A light's colour: a name Home Assistant knows — `orange`, `warm white` — or `#rrggbb`. |
| `kelvin` | A white light's warmth: 2700 warm, 6500 daylight. |
| `temperature` | What a thermostat is set to. |
| `mode` | A thermostat's mode: `heat`, `cool`, `auto`, `off`. |
| `value` | For a number, text or select entity: the value, or the option. |
| `data` | Anything else the service takes: `transition: 2, effect: colorloop`, or JSON. |

```
1. Desk lamp [Home, entity: light.desk_lamp]
2. Reading [Home, entity: light.desk_lamp, brightness: 40, kelvin: 2700]
3. Warmer [Home, entity: climate.hallway, temperature: 21.5]
4. Evening [Home, entity: scene.evening]
5. All off [Home, entity: "light.lounge, light.kitchen", service: turn_off]
```

- **Left out, the service is worked out:** a toggle; for a light given a
  brightness, colour or warmth, `turn_on`; for a thermostat given a
  temperature, `set_temperature`, or a mode alone, `set_hvac_mode`; for a
  scene or script, `turn_on`; a button is pressed, an automation triggered, a
  media player played or paused; a number or select set to its `value`.
- **A thermostat given a mode and a temperature** — `service: turn_on,
  mode: heat, temperature: 21` — has its mode set first, then its
  temperature: many heaters ignore a mode sent with the temperature, and a
  temperature while they're off. Given only a temperature, `turn_on` turns it
  on first.
- **Locks and alarms never toggle:** say `service: lock` or `unlock`, `arm_away`
  or `disarm`. The time to cancel is there for second thoughts.
- **The overlay says what happened,** from what Home Assistant reports back:
  *Desk lamp: on, 40%*, *Hallway: heat, 21°*, *Ran Evening*.
- **What goes wrong is said:** a refused token, an entity it doesn't have, a
  service it didn't accept — in its own words — or nothing answering.
- **In the tree editor,** *Entity* lists what Home Assistant has, and
  *Service*, *Mode* and *Value* list what that entity takes; *Colour* has a
  colour picker. Only the fields the entity uses are shown.

### `calendar.join` — join the meeting

A module. Opens the video call of the meeting under way — Zoom, Google Meet,
Teams, Webex, FaceTime, Whereby, Jitsi, Chime, GoTo or BlueJeans — from the
link in its URL, location or notes; failing those, whatever link its URL holds.

| Field | |
|---|---|
| `which` | `now` (the default): the meeting under way, else the next today. `next`: the next to start, whatever's under way. |

```
1. Join [Join]
2. Next call [Join, which: next]
```

Which meeting is meant, and which calendars count, are as for `{{event}}` (§6).
A meeting without a link says so: *“Lunch” has no link to join*.

### `calendar.addNote` — add to the meeting's notes

A module. Adds a paragraph to the notes of the meeting under way, in Calendar,
so what was decided stays with the meeting.

| Field | |
|---|---|
| `template`, `text` | What to add, filled in; with neither, the leaf's label. |
| `which` | `now` or `next`, as for `calendar.join`. |

```
1. Decision [Add to Event, text: "{{time}} — decided: {{selection}}"]
```

A repeating meeting gets it on today's occurrence only. A meeting on a
calendar that can't be changed — a subscription, a holiday calendar — says so.

### `reminders.complete` — tick off a reminder

A module. Marks a reminder done.

| Field | |
|---|---|
| `title` | Words from its title: an exact title wins, then the one due soonest. Left out, the reminder due next — overdue first — which is `{{reminder}}`. |
| `list` | The list to look in. Left out, the lists chosen in Settings, else all. |

```
1. Done [Done]
2. Bank [Done, title: Call the bank, list: Errands]
```

A reminder without a date is never "due next": name it with `title` to tick it
off. Keywords: `Done`, `Complete Reminder`, `Tick Off`.

---

## 6. Values: `{{placeholders}}`

Any text in an action, and every template, can use placeholders:

| Form | |
|---|---|
| `{{leaf}}` | a value |
| `{{contact.phone\|none}}` | with a fallback, used when the value is missing or empty |
| `{{project.path\|}}` | an empty fallback: missing is fine |
| `{{date:yyyy-MM-dd}}` | a date built-in with a format |
| `{{selection}}` | the text selected in the app in front when the key was pressed |
| `{{api.weather}}` | a value fetched from an API, found by a rule Claude wrote once (below) |
| `{{location.latitude}}` | where this Mac is (below) |
| `{{home.sensor.outdoor_temperature}}` | an entity's state in Home Assistant (below) |
| `{{event.title}}` | the meeting under way, and the day's agenda (below) |
| `{{quote file="quotes.md"}}` | a paragraph or list item from a file, at random or in turn (below) |

A fallback in quotes is taken without them: `{{selection|"5 minute timer"}}`
gives *5 minute timer*.

A missing value with no fallback becomes empty, and is reported (§5). With
nothing selected, `{{selection}}` in a required field stops the action —
"Nothing is selected in Safari, and the link needs it." — and in an optional
one leaves a gap and a warning. `{{selection|}}` makes an empty selection fine.

### Inside links

In a field that starts with a scheme — `https:`, `mailto:`, `things:` — the
**values placed into it are percent-encoded**, so a selected "swift & rust"
becomes one search term, `swift%20%26%20rust`, not two broken ones. `/` and `:`
are left alone, so `https://github.com/{{repo}}` with `repo: owner/name` still
works. This applies to `url` and to `open` (§5).

A field that is **only a placeholder** — `url: "{{selection}}"`,
`open: "{{project.url}}"` — is taken as the whole link and isn't encoded, and
neither is a path: `open: "~/Downloads/{{selection}}"` gets the text as it is.

### Blocks: `{{#ai}}…{{/ai}}`

A **block** wraps text and hands it to something that replies; the reply takes
the block's place. `{{#ai}}` asks Claude:

```
{{#ai}}Summarise in one line: {{selection}}{{/ai}}
{{#ai model="sonnet-5" effort="medium"}}Draft a polite reply to: {{clipboard}}{{/ai}}
```

- **Inside first.** A block's own placeholders are filled in, and any blocks
  inside it worked out, before it's sent — so blocks nest:
  `{{#ai}}Translate into French: {{#ai}}Summarise: {{selection}}{{/ai}}{{/ai}}`.
  Blocks side by side are asked at the same time; the same block twice is asked
  once. Nesting can go as deep as you like — nothing about it is recursive — but
  one key press may ask for at most 24 replies, since each can cost money.
- **Images and PDFs go as themselves.** When `{{clipboard}}` holds an image or a
  PDF (see [What you were doing](#where-values-come-from)), a block sends it to
  Claude where it's written among the text:
  `{{#ai}}What does this error mean? {{clipboard}}{{/ai}}`. Images are scaled
  to 1568 points on their long side first, the size Claude works best at; a PDF
  goes as it is, up to Claude's limit of 100 pages. Anywhere outside a block,
  an image stands as a description — "[image 1568×980]" — never as itself.
- **The reply is plain text.** It's never read as a template: `{{…}}` in a reply
  stays as written.
- **Attributes** go in the opening tag, `key="value"` (or `key=value` without
  spaces). `{{#ai}}` takes `model` — `opus-5.5`, `opus-5`, `sonnet-5`,
  `haiku-4.5`, `fable-5.1`, a family (`opus`) for its newest, or a full
  `claude-…` ID — and `effort` — `low`, `medium`, `high`, `xhigh`, `max`.
  Without them, the choices in Settings → Claude: Claude Opus 5.5 at low effort.
- **Where blocks go.** In an action's fields and in templates — notes, messages,
  email, the clipboard, inserted text, titles. **Not** where a reply could decide
  where the action goes or who it reaches: `url`, `open`, `to`, `app`,
  `bundleId`, `target`, `via`, a shortcut's `name` and `input`, and a timer's
  `shortcut`. Selected text can carry instructions aimed at the model, so its
  reply mustn't choose a link, a number or an app. Such an action is refused
  before anything is asked. A value from a data source may go in those fields
  (below); a block reading one may not. Blocks in values (`topic: "{{#ai}}…"`) don't run;
  they're kept as written, and the editor says so.
- **Waiting.** While replies are worked out the overlay shows how long it's
  been, with a **Cancel** button that stops every request and the action with
  them; *Cancel Waiting for Replies* in the menu bar's menu does the same. The
  time to cancel still comes first, so a wrong key costs nothing.
- **If you switch apps while waiting,** an Insert or Direct Insert doesn't type
  into the new one; the text goes on the clipboard instead.
- **Previews** in the editor and the overlay show a stand-in, `‹Claude's
  reply›`, and never ask anything.
- **What a block may send** is chosen in Settings → Privacy: the selected text
  (`{{selection}}`), the clipboard (`{{clipboard}}`), images and PDFs on it,
  where you are (`{{location}}` and its parts), and your meetings and reminders
  (`{{event}}`, `{{agenda}}`, `{{reminder}}` and their parts) — all of them,
  until unticked. A key whose block uses one that's unticked is refused before
  anything is read, fetched or asked, and says which. Whether the clipboard
  holds an image is known only once it's read, so an image or PDF unticked
  stops the action then, before anything is sent. What the block's own words
  say always goes, and anything else it fills in — `{{leaf}}`, a data source's
  value — including another block's reply inside it.
- **Refused or failed** replies stop the action with the reason: no API key, a
  model that doesn't exist, Claude declining the request, no connection.

Claude needs an **API key**, kept in the Keychain from Settings → Claude. Make
it in a Claude Console workspace with a spend limit. Requests go to Anthropic
with `{{selection}}` or `{{clipboard}}` in them — text, an image or a PDF — when
the prompt uses them; neither the prompts nor the replies are written to the
log, and images and PDFs are held in memory only while the action runs. With Opus 5.5,
Opus 5 and Fable 5.1, a request Claude's safety classifiers decline is retried
on the model Anthropic recommends for it (`fallbacks: "default"`).

### Values from APIs: `{{api.weather}}`

A **data source** is an API KeybowNotes fetches when a key needs it, and the one
value you want from its response. Sources are set up in their own window — *Edit
Data Sources…* in the menu bar's menu:

- **A name**, which is how templates use it: `{{api.weather}}`. Letters, digits,
  `-` and `_`, starting with a letter.
- **A URL**, over https. It can hold placeholders, filled from the key being
  pressed and encoded as in any link (§6, *Inside links*):
  `https://api.example.com/v1/current?city={{city}}`. Give them sample values in
  the window, for fetching a sample there. `{{location.latitude}}` and
  `{{location.longitude}}` make a source follow the Mac about:
  `https://api.open-meteo.com/v1/forecast?latitude={{location.latitude}}&longitude={{location.longitude}}&current=temperature_2m`.
  They need no sample values — the window finds the Mac, as a key would —
  though you can give some to try another place.
- **An API key**, if it needs one — sent as a Bearer token, in a header of its
  own (`X-API-Key` unless you name another) or as a query parameter (`key`
  unless you name another). It's kept in the Keychain, sent only to that
  source's server, and never to Claude. It isn't a placeholder — there's no
  `{{key}}` — so leave it out of the URL: for `?apiKey=…`, choose *In the URL's
  query* and name the parameter `apiKey`.
- **How long to keep a response:** from every time to a day. Each URL is kept
  apart, so `{{city}}` London and York are two responses.
- **The value you want,** in your own words: *the current temperature, in
  Celsius*.

**Find It with Claude** fetches a sample and sends it, with your description,
to Claude — the model and effort in Settings → Claude. Claude writes a **rule**:
a JSONPath for JSON (`$.current.temp_c`), an XPath for XML or HTML
(`//item[1]/title`), or a regular expression whose first group is the value.
KeybowNotes tries the rule on the sample itself, and if it finds nothing, or
something other than what Claude expected, tells Claude and asks again, up to
three times. You see what the rule finds, and keep it with **Use This Rule**.
You can also write a rule yourself.

That's the only time Claude is asked. **Every key press after that** fetches the
source (or uses the kept response) and applies the rule on the Mac: no Claude,
no cost, no waiting on a model. The overlay shows *Fetching weather…* with the
same timer and **Cancel** as a block.

**When a rule stops finding its value** — the API changed, or sent an error
page — the action stops, saying which source, and the source is marked: in the
window, and as *⚠︎ weather needs fixing* in the menu bar's menu. **Find It
Again** asks Claude for a new rule from the description you kept; **Test Now**
tries the current one.

For a source whose URL takes values — a search — finding nothing can be the
right answer: a word with no Wikipedia page. So for one of those, finding
nothing stops the action with *“wikipedia” found nothing*, and the values it
was given, but doesn't mark the source. A response the rule can't read at all
still does, and so does finding nothing with the sample values, in **Test Now**.

**Giving the URL its values where it's used.** A URL's placeholders are filled
from the key being pressed — its own values, `{{selection}}`, and the rest. To
decide at the key which value goes in, give it as an **attribute**, named after
the URL's placeholder:

```
Look up [Display]
   1. Selection [text: "{{api.wikipedia term={{selection}}}}"]
   2. Clipboard [text: "{{api.wikipedia term={{clipboard}}}}"]
   3. Ada [text: "{{api.wikipedia term='Ada Lovelace'}}"]
```

- The value can be words, in quotes if they have spaces, or placeholders —
  quoted or not, and as deep as needed: `term={{quote file=topics.txt}}`.
- It's used for that one placeholder, over any value the key has of that name.
  A name the URL doesn't use is a mistake: *“wikipedia”'s URL has no {{search}}
  — It uses {{term}}.* A placeholder with no value — nothing selected — stops
  the action and says so.
- `.raw` takes them too: `{{api.wikipedia.raw term={{selection}}}}`.
- The same source can be used more than once in one action with different
  values; each distinct URL is fetched once, and kept as long as the source says.

- **`{{api.weather.raw}}`** is the whole response, for an `{{#ai}}` block to
  read: `{{#ai}}In one line, what's the news here? {{api.news.raw}}{{/ai}}`. It
  needs no rule.
- **Fetched values can steer an action.** A rule is fixed, and applied by the
  Mac, so its value may go in a `url`, a `to` or a shortcut's `input`:
  `url: "https://example.com/track/{{api.parcel}}"`. What can't is an `{{#ai}}`
  block, even one reading a fetched value — blocks stay out of those fields.
- Sources used by one key are fetched at the same time, and each once, however
  many of its values the key uses.
- The window never shows a key once saved; removing a source removes its key.
  Responses are never written to the log, and neither are values.
- **When an API refuses** — a wrong key, a plan that doesn't cover the data, a
  bad URL — the overlay and the window show its status and what the API said
  about it, with a hint; the log gets only the status.
- **Previews** show a stand-in, `‹weather›`, and fetch nothing.

### Where you are: `{{location}}`

| Name | Example | |
|---|---|---|
| `location` | 51.50722,-0.1275 | latitude and longitude, for a map link or an API |
| `location.latitude` | 51.50722 | degrees north; south is negative |
| `location.longitude` | -0.1275 | degrees east; west is negative |
| `location.altitude` | | metres above sea level — usually empty (below) |
| `location.accuracy` | 35 | how far off the place may be, in metres |

```
Here [Copy, text: "I'm at https://maps.apple.com/?ll={{location}}"]
Journal [append, entry: "**{{datetime}}** at {{location}} — {{selection}}"]
```

- **Found when a key uses it,** through Location Services, and kept for five
  minutes, so keys pressed together don't each wait. The overlay shows
  *Fetching your location…* with a timer and Cancel; a Mac on Wi-Fi usually
  answers within a few seconds, and gives up after twenty.
- **Macs find their place from nearby Wi-Fi networks,** not GPS: expect tens of
  metres, and no altitude — `{{location.altitude}}` is empty unless the Mac
  knows it, so write `{{location.altitude|unknown}}` to say so.
- **Precision,** in Settings → Location, rounds the place: as exactly as the Mac
  knows (5 decimal places), about 100 m, about 1 km, or about 10 km. Rounding is
  kinder to your privacy when the place goes to someone else's API; a weather
  forecast needs no more than about 1 km. `{{location.accuracy}}` grows to match.
- **The tree's own values win.** A node with `location.latitude: 40.7128` and
  `location.longitude: -74.006` — or `location: "40.7128,-74.006"`, quoted for
  its comma — uses that place for every `{{location…}}` value beneath it, and
  the Mac isn't asked: handy for keys that are always about the office.
- **The first time,** macOS asks whether KeybowNotes may use your location. The
  prompt can open behind other windows. Refused, a key that needs the place
  stops and says where to allow it: System Settings → Privacy & Security →
  Location Services.
- The place is never written to the log. **Previews** show `‹your latitude›`.

### Your home: `{{home.…}}`

Any entity in Home Assistant, by its ID after `home.`, with a part after that
if you like:

| Name | Example | |
|---|---|---|
| `home.sensor.outdoor_temperature` | 14.2 | its state |
| `home.sensor.outdoor_temperature.text` | 14.2 °C | its state with its unit |
| `home.sensor.outdoor_temperature.unit` | °C | |
| `home.sensor.outdoor_temperature.name` | Outdoor temperature | its friendly name |
| `home.sensor.outdoor_temperature.changed` | 09:15 | when its state last changed |
| `home.climate.hallway.current_temperature` | 19.5 | any attribute, by its name |

```
Weather [Display, text: "It's {{home.sensor.outdoor_temperature.text|unknown}} outside"]
Heating [Display, text: "Hallway: {{home.climate.hallway.current_temperature}}°, set to {{home.climate.hallway.temperature}}°"]
```

- **Read when a key uses them,** fresh each time: one request an entity, or
  one for all of them when an action uses more than four. An attribute it
  doesn't have is empty; an entity it doesn't have stops the action and says so.
- **The address,** in Settings → Home Assistant, is `http://homeassistant.local:8123`
  unless you say otherwise. Plain http is only used on your local network — a
  `.local` name, one without dots, or a private address, Tailscale's included —
  and https everywhere else, Nabu Casa's remote address among them.
- **The token** is a long-lived access token: in Home Assistant, open your
  profile, then Security, and create one at the bottom of the page. It's kept
  in the Keychain, and sent only to that address.
- **The first time,** macOS asks whether KeybowNotes may find devices on your
  local network. The prompt can open behind other windows; refused, Home
  Assistant can't be reached until it's allowed in Privacy & Security → Local
  Network. *Check the Connection*, in the menu bar's Home Assistant menu, says
  whether it answers, and to the token.

### Your calendar: `{{event}}`, `{{agenda}}`, `{{reminder}}`

| Name | Example | |
|---|---|---|
| `event` | Design review | the meeting under way, else the next today: its title |
| `event.start`, `event.end` | 14:00, 14:45 | |
| `event.time` | 14:00–14:45 | |
| `event.date` | 7 Oct 2026 | |
| `event.location` | Room 4 | |
| `event.link` | https://zoom.us/j/… | its video call, as `calendar.join` finds it |
| `event.attendees` | Alex Example, Sam Sample | everyone invited but you, rooms left out |
| `event.organizer` | Alex Example | empty when it's you |
| `event.notes`, `event.calendar` | | |
| `event.next` | Planning | the next meeting to start, today or tomorrow — and `event.next.start` and the rest |
| `agenda` | | the rest of today: events, and reminders due or overdue, as a Markdown list |
| `agenda.today`, `agenda.tomorrow` | | all of today; tomorrow |
| `reminder` | Call the bank | the reminder due next, overdue first — and `reminder.due`, `.list`, `.notes` |

```
Meeting notes [Notes, folder: Meetings, title: "{{event|Meeting}} — {{date}}"]
Today [Display, text: "{{agenda|Nothing more today.}}", button: ok]
Next [Display, text: "Next: **{{event.next|nothing}}** at {{event.next.start|}}"]
```

- **A meeting** is an event that isn't all day, declined or called off. The one
  under way wins — the latest to start, when two overlap — except in its last
  five minutes, when a meeting starting within ten is meant instead: a key
  pressed on the way into the next one is about the next one. With nothing
  under way, it's the next to start today; after the last, `{{event}}` is empty.
- **The agenda** lists all-day events first, then the rest by time, marking
  the one under way *(now)*; declined events are left out. Under **Reminders**
  come those due that day — and before, for today — with their times.
- **Nothing there is empty,** so `{{event|No meeting}}` and
  `{{agenda|Nothing more today.}}` say so in your words.
- **Which calendars and lists,** in Settings → Meetings and Agenda: every one,
  or only those you tick. Birthdays and holidays are calendars too.
- **Read when a key uses them,** through EventKit, which needs full access to
  Calendars (and Reminders, for `{{reminder}}`; the agenda leaves reminders out
  without it). Only KeybowNotes.app can ask for that: a development build says
  so instead. Nothing read is written to the log. **Previews** show
  `‹the meeting›`.
- **Claude** is sent them, in a `{{#ai}}` block, only while Settings → Privacy
  ticks *My meetings and reminders*; unticked, the key is refused before
  anything is read.

### Quotes from a file: `{{quote file="…"}}`

`{{quote}}` picks a **portion** of a text file each time a key uses it — a
quote of the day, a fortune, a writing prompt, the next article on a reading
list, where to go for lunch:

```
Today [Copy, text: "{{quote file='quotes.md' heading='Stoics'}}"]
Read next [Link, url: "{{quote file=reading.md order=sequential}}"]
Lunch [Maps, query: "{{quote file=lunch.txt}}"]
```

What a portion is depends on the file:

| File | Portions |
|---|---|
| Plain text — `.txt`, or anything not below | each paragraph, between blank lines. A file with no blank lines gives one per line, and a `fortune` file — entries between lines holding only `%` — one per entry |
| Markdown — `.md`, `.markdown` | each item of a bulleted (`-`, `*`, `+`) or numbered (`1.`, `1)`) list, with whatever is indented under it: a sub-bullet with the author stays with its quote. Code blocks are skipped |
| HTML — `.html`, `.htm` | each item of a `<ul>` or `<ol>`, with any list inside it as lines of `- …` |

It takes three attributes:

| Attribute | |
|---|---|
| `file` | the file: in the templates folder beside `tree.md`, or a full or `~/` path. Required |
| `heading` | Markdown and HTML only: just the items under this heading, down to the next heading of the same level or higher — so a heading takes in its subheadings. Matched ignoring case, spacing, `*`/`_` emphasis and a closing colon. Without it, every item in the file |
| `order` | `random`, the default — never the same item twice running — or `sequential`: each in turn, from the top again once the list is done |

- **Attributes** are written like a block's: `key="value"`, `key='value'`, or
  `key=value` without spaces. Inside an outline's quoted value, use single
  quotes or none, so as not to need `\"`.
- **Placeholders in attributes** are filled in from the key being pressed, so
  one branch can serve several lists: `Quote [Copy, text: "{{quote
  file=quotes.md heading={{leaf}}}}"]` with leaves *Stoics* and *Poets*.
  Quotes around a placeholder are optional.
- **In sequence,** the place in each list — each file and heading — is kept in
  `state.json` (§9), so it carries on after a restart. A list that has grown
  or shrunk carries on from the same place, or starts again if it's past the end.
- **Once per press:** the same quote twice in one action is one pick.
- **A fallback** comes after the attributes, as usual:
  `{{quote file=fortunes.txt|No fortune today}}`.
- **It may steer an action** — go in a `url`, a `to`, a Maps `query` — because
  it comes from a file you wrote, not from a model.
- **Mistakes stop the action and say what's wrong**: a file that isn't there, a
  heading that isn't (with the ones that are), a heading asked of plain text.
- **Previews** show `‹a quote from quotes.md, Stoics›` and pick nothing, so a
  preview never moves a sequence on.

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

4. **What you were doing:** `{{selection}}` (the selected text, trimmed),
   `{{clipboard}}` (its text, trimmed) and `{{frontApp}}` (the app in front when
   the key was pressed — KeybowNotes never takes focus).

   `{{clipboard}}` can be an image or a PDF too, when that's what was copied:
   a screenshot copied with ⌃⇧⌘4, an image copied in Preview or a browser, or
   image and PDF files copied in the Finder — up to five, a line each. Text
   wins when there's text: a file copied in the Finder that isn't an image or a
   PDF is its name, as before. A Claude block sends an image or PDF as itself;
   everywhere else it's a description, "[image 1568×980]" or "[PDF, 12 pages]".

   The selection is read only when the action uses it, through the
   accessibility API, which needs **Accessibility access** (Privacy & Security).
   Apps that don't answer — Chrome, Electron apps like VS Code and Slack — are
   sent ⌘C instead, and the clipboard is put back straight after; that can be
   turned off in Settings. Neither the selection nor the clipboard is written to
   the system log.
5. **Fetched:** `{{api.weather}}` and `{{api.weather.raw}}` from data sources,
   `{{location}}` and its parts from Location Services, `{{home.…}}` from Home
   Assistant, `{{event}}`, `{{agenda}}` and `{{reminder}}` from your calendar,
   and `{{quote …}}` from a file (above) — only when the action uses them. A value one of them needs is fetched first: a source's URL
   gets the Mac's place.
6. **Built-ins:**

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
- **Privacy** — what a `{{#ai}}` block may send Claude (§6, *Blocks*); a key whose block
  would send something kept from it doesn't run.

What the app remembers between runs — the stopwatch, data sources, each
`{{quote}}` sequence's place — is neither: it's kept in `state.json` beside
`tree.md`, each module in its own part. It's JSON, and readable, but written by
the app; edit it only while KeybowNotes isn't running.

---

## 10. Reserved words

**Outline words:** `Notes`, `Calendar`, `Reminders`, `Messages`, `Mail`, `Call`,
`FaceTime`, `Link`, `Browser`, `Copy`, `Clipboard`, `Insert`, `Paste`, `Direct Insert`, `Type`,
`Timer`, `Maps`, `Music`,
`Stopwatch`, `Display`, `Show`, `Ask`, `Prompt`, `Window`, `Arrange`, `Exposé`, `Expose`, `Mission Control`
(and any other module's keywords),
`append`, `new`, `create`, `… alert`, `….md`, `@…`, and the app names the
compiler knows.

**Outline pairs with a meaning of their own:** `colour`/`color`, `type`, and the
action fields listed in §2.

**Section headings:** `main`, `row 2`, `row 3`, `bottom` (and their variants),
`keypad …`, `list …`, `contacts`, `projects`, `defaults`; `[pages]` on a tree's.

**Keypad models:** `Keybow 2040`, `RGB Keypad` (and their variants), with `id`.

**Action types:** `notes.create`, `notes.append`, `calendar.createEvent`,
`reminders.create`, `messages.compose`, `mail.compose`, `phone.call`, `app.open`,
`url.open`, `clipboard.copy`, `text.insert`, `text.insertDirect`, `clock.timer`, `maps.search`, `music.play`, `shortcut`,
and from modules, `stopwatch`, `display`, `ask`, `window` and `expose`.

**Computed values:** `leaf`, `parent`, `level1`–`level4`, `path`, `folderPath`,
`parentPath`, `tree`, `contact.*`, `project.*`, `selection`, `clipboard`, `frontApp`,
`stopwatch`, `stopwatch.*`, `api.*`, `location`, `location.*`, `quote`, `displayed`, `answer`, `date`,
`time`, `datetime`, `weekday`, `isoWeek`, and `when` by convention.

**Tree names:** `main`, `row2`, `row3`, `bottom`.

---

## 11. Not yet in the language

- **Asking for a value inline**, in any action's text, rather than with an
  `ask` action before it. Reserved syntax: `{{?Label}}`.
- **More than one action** per leaf — a note *and* a reminder pointing to it.
- **Channel URLs** for apps like Discord and Meshtastic, which the compiler can
  only list as needing one.
- **Comments** between items, which the outline's writer doesn't keep yet.
