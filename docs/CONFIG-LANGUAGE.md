# The KeybowNotes configuration language

**Version 3**, as understood by KeybowNotes 0.1. This describes what the parser,
the compiler and the action planner do today; where behaviour is a default
rather than a rule, it says so.

A configuration says what each key on the keypad means: which choices are
offered on each row, what the final choice does, and with what values.

**The outline is the configuration.** It is a numbered list, the way you'd
sketch a tree by hand, with keywords and settings in square brackets — written
by hand or in the tree editor. The app runs a JSON file **compiled** from it;
the JSON is never edited, and says nothing the outline can't.

```bash
keybow convert tree.md -o ~/Library/Application\ Support/KeybowNotes/config.json
```

The running app notices the JSON has changed and reloads it within a couple of
seconds. The tree editor compiles on every save.

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
  its line, and skipped along with everything beneath it. `keybow convert`
  refuses to write a config while any remain; the editor shows them in place.

### Sections

A heading starts a section, which lasts until the next one:

| Heading | Holds |
|---|---|
| none — items before any heading | the main tree |
| `# main`, `# top`, `# row 1` | the main tree |
| `# row 2` | the row 2 tree |
| `# row 3` | the row 3 tree |
| `# bottom`, `# row 4`, `# bottom up` | the bottom tree |
| `# list <name>` | nodes reused with `[@name]` |
| `# contacts` | people: `- Name [field: value, …]` |
| `# projects` | projects: `- Name [path: …, …]` |
| `# defaults` | settings: `- key: value` |

The word "tree", case, spaces and hyphens don't matter in tree headings. A
heading before the first item that names no section is part of the preamble —
a title. Other lines between items are ignored, and aren't kept when the
outline is written back out.

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
| `Music` | play a playlist or album in Music | `"type": "music.play"` |
| `Stopwatch` | KeybowNotes' own stopwatch (a module) | `"type": "stopwatch"` |
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
omitted, and sections in the order main tree, side trees, lists, contacts,
projects, defaults. The preamble is kept as written.

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
  }
}
```

This is what the outline compiles to, and what the app loads. It's described
here because it is what every rule below is expressed in, and because the
compiler's output is readable when something needs checking. Every section is
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

### `music.play` — play a playlist or album

| Field | |
|---|---|
| `playlist` | A playlist by name; the leaf's label if neither this nor `album` is set. |
| `album` | An album in your library, played in disc and track order. Wins over `playlist`. |
| `artist` | Narrows an album down when two share a name. Matches the artist or album artist. |
| `shuffle` | `true` or `false` for a playlist; empty leaves Music's setting alone. Albums play in order. |

Music only plays a playlist in order, so an album is copied into a playlist of
KeybowNotes' own, **KeybowNotes Album**, remade each time — deleting a playlist
never deletes its songs. Only music in your library can be played. The first
time, macOS asks whether KeybowNotes may control Music.

```
1. Music [Music]
   1. Focus
   2. Party [shuffle: true]
   3. Kind of Blue [album: Kind of Blue, artist: Miles Davis]
```

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
  before anything is asked. Blocks in values (`topic: "{{#ai}}…"`) don't run;
  they're kept as written, and the editor says so.
- **Waiting.** While replies are worked out the overlay shows how long it's
  been, with a **Cancel** button that stops every request and the action with
  them; *Cancel Waiting for Replies* in the menu bar's menu does the same. The
  time to cancel still comes first, so a wrong key costs nothing.
- **If you switch apps while waiting,** an Insert or Direct Insert doesn't type
  into the new one; the text goes on the clipboard instead.
- **Previews** in the editor and the overlay show a stand-in, `‹Claude's
  reply›`, and never ask anything.
- **Refused or failed** replies stop the action with the reason: no API key, a
  model that doesn't exist, Claude declining the request, no connection.

Claude needs an **API key**, kept in the Keychain from Settings → Claude. Make
it in a Claude Console workspace with a spend limit. Requests go to Anthropic
with `{{selection}}` or `{{clipboard}}` text in them when the prompt uses them;
neither the prompts nor the replies are written to the log. With Opus 5.5,
Opus 5 and Fable 5.1, a request Claude's safety classifiers decline is retried
on the model Anthropic recommends for it (`fallbacks: "default"`).

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

   The selection is read only when the action uses it, through the
   accessibility API, which needs **Accessibility access** (Privacy & Security).
   Apps that don't answer — Chrome, Electron apps like VS Code and Slack — are
   sent ⌘C instead, and the clipboard is put back straight after; that can be
   turned off in Settings. Neither the selection nor the clipboard is written to
   the system log.
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

**Outline words:** `Notes`, `Calendar`, `Reminders`, `Messages`, `Mail`, `Call`,
`FaceTime`, `Link`, `Browser`, `Copy`, `Clipboard`, `Insert`, `Paste`, `Direct Insert`, `Type`,
`Timer`, `Maps`, `Music`,
`Stopwatch` (and any other module's keywords),
`append`, `new`, `create`, `… alert`, `….md`, `@…`, and the app names the
compiler knows.

**Outline pairs with a meaning of their own:** `colour`/`color`, `type`, and the
action fields listed in §2.

**Section headings:** `main`, `row 2`, `row 3`, `bottom` (and their variants),
`list …`, `contacts`, `projects`, `defaults`.

**Action types:** `notes.create`, `notes.append`, `calendar.createEvent`,
`reminders.create`, `messages.compose`, `mail.compose`, `phone.call`, `app.open`,
`url.open`, `clipboard.copy`, `text.insert`, `text.insertDirect`, `clock.timer`, `maps.search`, `music.play`, `shortcut`,
and from modules, `stopwatch`.

**Computed values:** `leaf`, `parent`, `level1`–`level4`, `path`, `folderPath`,
`parentPath`, `tree`, `contact.*`, `project.*`, `selection`, `clipboard`, `frontApp`,
`stopwatch`, `stopwatch.*`, `date`,
`time`, `datetime`, `weekday`, `isoWeek`, and `when` by convention.

**Tree names:** `main`, `row2`, `row3`, `bottom`.

---

## 11. Not yet in the language

- **Asking for a value** before acting — a text field in the overlay. Reserved
  syntax: `{{?Label}}`.
- **More than one action** per leaf — a note *and* a reminder pointing to it.
- **Channel URLs** for apps like Discord and Meshtastic, which the compiler can
  only list as needing one.
- **Comments** between items, which the outline's writer doesn't keep yet.
