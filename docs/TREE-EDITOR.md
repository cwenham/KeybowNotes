# The tree editor

**Status:** phases 1–6 built; mirroring on the Keybow is next (see the end). The outline
language it edits is described in [CONFIG-LANGUAGE.md](CONFIG-LANGUAGE.md).

A guided outliner for the KeybowNotes outline, in the style of OmniOutliner:
typing edits a node, Tab and Shift-Tab change its level, Return starts the next
one. "Guided" because it understands what it's editing — which keys are free,
how deep each tree may go, what each bracketed word means — and shows it as you
type. A pane beside the outline shows the selected node's settings, and changes
made there are written back into the outline as syntax. A diagram of the keypad
shows where the node sits and what the keys will look like.

**The outline stays the single source of truth.** The editor reads `tree.md`,
changes it, and writes it back, and the app compiles the same file as it loads
it. Nothing the editor knows is kept anywhere but the outline.

---

## Layout

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Default   Desk   +     Name [Desk     ]  RGB Keypad ⌄  Any one ⌄  Remove… │
│  Main ↓   Row 2 ↓   Row 3 ↓   Bottom ↑                   ● Edited   Save │
├──────────────────────────────────────┬───────────────────────────────────┤
│ 1 ▾ Work                             │ Work › General Tasks › Meeting    │
│   1 ▸ Immediate task                 │ Main tree · row 3 · key 1         │
│   2 ▾ General Tasks                  │                                   │
│     1 ▾ Meeting [Calendar, 5 min …]  │ Pressing a key under this:        │
│       1   Today                      │   New event · Meeting ·           │
│       2   Tomorrow                   │   Sun 27 Sep, 09:00 · alert 5 min │
│     2 ▸ Deployment [Calendar, …]     │                                   │
│     3   ·· key 3 — empty ··          │ Label   [Meeting            ]     │
│     4 ▸ Reminder [Reminders]         │ Action  Calendar event  set here  │
│   4 ▸ Notes                          │ Alert   [5] min         set here  │
│ 2 ▸ Personal                         │ Duration [30 min]  from default   │
│                                      │ Values  area: work   from Work    │
│                                      ├───────────────────────────────────┤
│                                      │   ▣ ▢ ▢ ▢                         │
│                                      │   ▢ ▣ ▢ ▢     keypad, focused     │
│                                      │   ▣ ▣ ▢ ▣     on this level       │
│                                      │   ▢ ▢ ▢ ▢                         │
└──────────────────────────────────────┴───────────────────────────────────┘
```

- **Keypad tabs**, on the top row, switch between keypads' trees: **Default**
  — the trees before any `# keypad` section, for every keypad without trees of
  its own — then one tab per section. Resting on a tab says which keypads use
  it, of those connected. See [Keypads](#keypads).
- **Tree tabs** switch between the four trees, or ⌘1 to ⌘4. Beside them,
  **Pages** makes the main, row 2 or row 3 tree a set of pages: its row's keys
  pick a page, and the items under each page are its keys on the rows below,
  numbered 1 to 12 across then down, each running its action when pressed. The
  tab then reads "Row 2 pages", the keypad drawing shows a page's keys where
  they sit, and the inspector says where each key is. It's refused where the
  tree doesn't fit — a tree with keys under its second level, or using a list,
  can't become pages, and pages with keys past the first row below can't become
  a tree — with the reason. See [CONFIG-LANGUAGE.md](CONFIG-LANGUAGE.md#pages). Each has a diagram of the
  keypad in the tree's colour — Main blue, Row 2 teal, Row 3 orange, Bottom
  pink — with its starting row at full strength and the rows it goes on to
  fading in order, so it shows which way the tree runs. The overlay's tree badge
  uses the same diagram and colour. A dot marks a tree with problems.
- **Outline** on the left; **inspector** at top right; **keypad** at bottom right.
- The window opens from the menu bar: **Edit Tree…** (⌘E).

The same editor is the right half of *Design with Claude…*, on a working copy
with Claude's draft in it: everything works as here, but there's no Save — the
draft goes into the tree with *Add to My Tree* — and each new draft from Claude
is one step for ⌘Z. See [AUTOMATION.md](AUTOMATION.md#design-with-claude).

### Keypads

With more than one keypad, each can have trees of its own: a `# keypad`
section of the outline ([CONFIG-LANGUAGE.md](CONFIG-LANGUAGE.md#keypads)).

- **A green dot** on a tab: a keypad that's plugged in uses those trees. On
  trees none of them uses — Default, when each has a section of its own — a
  note under the tabs says so, with a link to each keypad's own tab, since
  edits there won't reach a keypad. The editor opens on trees that are in use.
- **+** adds one. It's named and set for the first connected keypad still using
  the Default trees, if there is one; else it's "Keypad 2" for no model yet.
- Choosing a keypad's tab shows its settings beside the tabs:
  - **Name** — what it's called, in the tab and the section's heading.
  - **Model** — Keybow 2040, RGB Keypad, or any model: its trees are for every
    keypad of that model.
  - **ID** — *Any one*, or one connected board's unique ID: for two keypads of
    the same model, each with trees of its own.
  - **Copy Default's Trees** — while it has no trees, starts it from a copy of
    the Default ones.
  - **Remove…** — takes the section away, asking first when it has trees; its
    keypads go back to the Default trees. Undo brings it back.
- Everything else — the outline, the inspector, the keypad drawing, the four
  tree tabs — works on the chosen keypad's trees. Lists, contacts, projects and
  defaults are shared, so they're the same on every tab.

---

## The outline pane

Each row is one node:

- its **key number** (1–4) in a small badge — its position on the keypad row;
- a disclosure triangle for branches;
- the **label**, then the **brackets** with each annotation coloured by what it
  means (below);
- a **problem marker** when the node has one, with the message as a tooltip and
  in the inspector.

A key's **steps** — what it does, in turn, when it has more than one action —
appear under it as rows with a bullet instead of a number, and the steps under
an If are under that. An If, Else if or Else is in bold, its {{values}}
coloured. See [CONFIG-LANGUAGE.md](CONFIG-LANGUAGE.md#steps).

**Empty keys** between occupied ones appear as faint placeholder rows — "key 3 —
empty" — so that a node's position is never ambiguous and never shifts
silently. Typing into a placeholder creates a node on that key. Empty keys after
the last occupied one aren't shown; Return reaches them. An empty key chosen on
the keypad — below a node with no children, say — gets a placeholder row for as
long as it's selected, so typing always has somewhere to go.

### Keys

| Key | Not editing | Editing a row |
|---|---|---|
| typing | starts editing the selected row, replacing its text with what's typed | edits |
| Return | edits the selected row | ends the edit; starts a **new node on the next free key** of the same row and edits it — or, when every key on the row is taken, the node's **first child** |
| ⌘Return | starts a **child** of the selected node, on its first free key | ends the edit, then the same |
| ⇧Return | adds a **step**: at the end of a key's steps, after a step, or under an If (below) | ends the edit, then the same |
| Return on an empty new node | — | removes it again |
| Tab | **indent**: the node becomes a child of the node above it | ends the edit, indents, carries on editing |
| Shift-Tab | **outdent**: the node moves up a level, after its parent | ends the edit, outdents, carries on editing |
| ⌃⌘↑ / ⌃⌘↓, or ⇧⌘↑ / ⇧⌘↓ | **move** the node to the key before / after, swapping with what's there or moving into an empty key | the same, ending the edit |
| ↑ / ↓ | select the previous / next row | end the edit and select |
| ← / → | collapse / expand | move the cursor |
| Delete | delete the node and everything under it — or every node selected | edits |
| ⇧-click, ⌘-click, ⇧↑ / ⇧↓, ⌘A | select several nodes | — |
| ⌘X / ⌘C / ⌘V | **cut / copy** the selected nodes, each with everything under it; **paste** after the selected node, onto a selected empty key, or onto the tree's top row | the same, for the text |
| Esc | — | abandon the edit |
| ⌘Z / ⇧⌘Z | undo / redo | the same, for the text |
| ⌘S | save | end the edit and save |

A new node isn't made until something is typed: Esc, or Return on the empty
row, leaves nothing behind.

### Steps

⇧Return, or **Add Step** in the inspector or the right-click menu, gives the
selected key a step, ready to type: `[Reminders]`, `Log it [append]`, or
`If {{answer}} is yes`. A key that had no steps keeps what it did as its first,
named for what it does — "New event" — since a key with steps runs only them; the
new one goes after it. Esc or Return on the new step, left empty, takes both
away again.

On a step:

- **Return** ends the edit and starts the next step after it — under it, for an
  If, Else if or Else, so an If isn't parted from its Else.
- **Tab** puts it under the step above, which must be an If, Else if or Else;
  **Shift-Tab** takes it out, to after the If and any Else that goes with it.
- **Add Else** and **Add Else If** — in the inspector for an If or an Else
  if, and its right-click menu — put one in its place: an Else after the If
  and its Else ifs, with a step under it ready to type the action into; an
  Else if before the Else, ready to type its test. Add Else is off once the If
  has one. Left empty, what they made goes again.
- **⌃⌘↑ / ⌃⌘↓** move it earlier or later among its neighbours; order is what
  steps run in.
- **Delete**, **⌘X**, **⌘C** work as on keys, a step with the steps under it.
  Steps go on the clipboard as bulleted lines, and **⌘V** with a step selected
  pastes after it; on a key, **Paste as Steps** in the right-click menu adds
  them to its steps.

A key with steps can't have keys under it, and a branch can't have steps:
⌘Return, indenting under it and pasting under it are refused, with the reason. So Return on a full row can offer a child without
risk, which is how a branch's fourth node gets children — the Return, Tab way
needs a free key beside it first. *Add Child* is in the Edit menu too.

⌃⌘↑/↓ follows OmniOutliner. Shift with the arrows would be the obvious choice,
but it already extends a text selection while editing. ⇧⌘↑/↓ works too: ⌃ and
⇧ are easily mistaken for each other, and in a one-line field ⇧⌘↑/↓ only
duplicates ⇧⌘←/→.

### Cut, copy and paste

Nodes go on the clipboard as **outline text** — the lines of `tree.md`, each
node with everything under it — so they paste into another tree, a keypad's
own trees, a list, or a text editor; and outline text copied from a text editor
pastes in as nodes. Right-click a node for the same, plus:

- **Paste After** — on the free keys after the node on its row, then before it.
- **Paste Under** — on the node's own free keys.
- **Paste Here**, on an empty key — that key first, then the next free ones.
- **Delete**.

Right-clicking a node in the selection acts on all of it; any other node, on
that node alone. With several selected, the inspector says how many, and
what's possible.

Pasted nodes are new copies, selected once they're in. A paste that doesn't
fit is refused whole, with the reason: too few free keys, too deep for the
tree — a page's keys can't have keys of their own — or a page's keys past the
fourth going where there's only a row. Undo takes a whole paste or cut back.

### The rules it keeps

Refusals are shown briefly in place — "Row full: four keys are taken" — rather
than as alerts.

- **Four keys per row.** A new node goes on the first free key after the
  current one, then any free key before it; with none free, it's refused.
- **Depth.** Each tab has a limit — 4, 3, 2 and 4 levels. Indenting past it is
  refused, as is indenting a branch whose children would end up too deep.
- **Indent** makes the node a child of the nearest node above it on the same
  row, on its first free key. Refused if that node's row is full or it takes its
  children from a `@list`.
- **Outdent** puts the node on its parent's row, on the first free key after the
  parent. Refused if that row is full.
- **Move** swaps with the neighbouring key, occupied or empty; it stops at key 1
  and key 4.

Everything is undoable, including edits made in the inspector.

### Highlighting

The text in brackets is coloured by the role the compiler gives it, which
depends on what the node inherits — `offtopic` is a channel under Discord and an
unknown word elsewhere. While typing, the same classification runs on the text
in the field.

| Role | Examples | Shown as |
|---|---|---|
| action type | `Calendar`, `Notes`, `append`, `new` | bold, accent colour |
| app | `Rider`, `VSCode` | purple; struck through if not installed |
| template | `worklog.md` | teal; red if the file isn't in the templates folder |
| alert | `5 min alert` | orange |
| list reference | `@when` | green; red if there's no such list |
| action field | `duration: 1h` | key dimmed, value plain |
| template value | `area: work` | key italic, value plain |
| colour | `colour: 0060ff` | a swatch of the colour beside it |
| target | `offtopic` | plain, underlined dotted until it has a URL |
| unknown | `whatever` | red wavy underline |

The label itself is plain text.

### Completion

Typing in a row's brackets offers what can go there, as a list to choose
from with ↑ ↓ and Return or Tab:

| Where | Offered |
|---|---|
| a new item — after `[` or `, ` | the action keywords, while the node names no type; the keys the type in force takes and that aren't set yet, with their `: ` — `title: `, `start: ` — and `colour: `, `instant: `, `type: `; the names other nodes give values, `when: `; lists, `@when`; templates, `standup.md`; and, once something's typed, installed apps |
| after `@` | the lists |
| a pair's value — after `key: ` | what that key takes: a choice's words (`auto`, `rich`, `plain`), `true` or `false`, a type's name after `type:`, an action's keyword after `ok:`, a template after `template:`, an app after `app:` |
| after `{{`, in a value | the {{values}} for the key, as in the inspector; after `{{#`, the blocks |

The list opens as `[`, `, `, `: `, `@` and `{{` are typed, narrows as a name
goes on, and closes when nothing fits; ⌥Esc opens it anywhere in the brackets.
Choosing a key offers its values next; choosing a value closes its `}}`, and a
block its `{{/ai}}`, with the caret inside. Anything else typed — a comma, a
colon, Esc — leaves what was typed as it was. Return and Tab take the item
while the list is showing, and do their usual work once it's gone.

---

## The inspector

For the selected node:

- **Where it is:** the path, the tree, and the row and key it occupies.
- **What pressing does** — for a leaf, the action with its values filled in, as
  the overlay would show it: "New event · Meeting · Sun 27 Sep, 09:00 · alert 5
  min before". For a branch, what its leaves will do by default. Missing values
  are shown in orange: "needs contact.phone".
- **Label** — a text field. For a step, a name for it, shown as it runs; for a
  condition, **Condition**: the If itself.
- **Steps** — for a key with steps, *Pressing this runs, in turn* lists them,
  as the overlay would sum each up, with its Ifs. For a step, *This step* says
  what it does, and the header where it runs: "Step 2 of “Standup”: runs once
  the one before has finished". Each has **Add Step**, as ⇧Return. A step has
  no colour, contact or project of its own, and *Run at once* is the key's;
  everything else — its type, fields, values, and where each comes from, the
  key or an If above it — is as for a key.
- **Action** — the type, and the fields that type uses, each showing its value
  and **where it comes from**: *set here*, *from Meeting* (an ancestor), or *from
  the defaults*. Setting a field writes a pair into this node's brackets;
  clearing one removes the pair, so the inherited value shows through again.
  The type is a menu: *inherit*, or a type, each beside the word that writes
  it in the outline — *Reminder done  [Done]* — and choosing one writes that
  word. Under the menu, every word for the chosen type: `[Done]`,
  `[Complete Reminder]` or `[Tick Off]`; for one with no word, `[type: …]`.
- **Fields that take {{values}}** — an action's text fields, a value's, and
  OK's and Cancel's — are written in with the values coloured as they're
  typed: values purple, blocks indigo, a fallback or a format quieter than the
  name. Resting the pointer on one says what it is and what it comes to for
  this key: *The key's label … Here: Standup*. Mistakes are underlined and
  said beneath the field — red for what won't run (a block in a link, or one
  nothing replies to; a `{{quote}}` with no `file=`), orange for what probably
  isn't meant (a name nothing gives, a format on what isn't a date, an
  attribute it doesn't take). What's known comes from the values for the key:
  every one built in and from modules, the data sources by name, what the
  tree sets on the way to it, and — on a branch — what the keys under it set,
  so a Meeting's `{{when}}` is known from its Today and Tomorrow. Inside a
  list, `{{#each}}…{{/each}}`, a name nothing gives is taken for one of the
  row's columns and isn't marked, and the pointer says so; what the list goes
  through is checked like any value, and a list's own `{{@count}}` and the
  rest are marked only outside one. Lists, coloured as blocks, may go in a
  link: they aren't replies.
  - **`{{` offers the values** there are, as a list to complete from, and
    `{{#` the blocks; choosing one closes the tag — a block with its
    `{{/ai}}`. A family goes as far as its part to fill in: `home.`,
    `contact.`. Esc offers them anywhere in a tag.
  - **ƒx** beside the field opens every value there is, in groups, with a
    search: what each holds, an example, what it comes to here, a date's
    formats to choose from and what each gives, and what a call or a block
    takes. Below, the field's text, larger, with what it comes to and what's
    wrong with it. Double-click a value, or **Insert**, to put it in at the
    caret — a part to fill in, like `<entity>`, comes selected. **Done** writes
    the field.
- **Values** — template values set here, editable as key and value, as values
  (above); and those inherited from above, read-only, with where each comes
  from.
- **Contact / project** — when the node's label names a contact or project, its
  fields, editable here; they're written to `# contacts` or `# projects`. For a
  contact, **Look Up in Contacts** searches the Contacts app for the name and
  lists each match's numbers and addresses; clicking one fills it in. (It asks
  for Contacts access once, and works in KeybowNotes.app only.)
- **App** — for *Open an app*, a combo box of every app in `/Applications`,
  `/System/Applications` and `~/Applications` (and their folders), with
  completion as you type, and **Choose…** to pick one in a file browser. Picking
  replaces the app word in the brackets (`[Rider]` → `[VSCode]`); a bundle ID is
  written only if the name alone wouldn't find the app. **Open** has its own
  **Choose…** for the file or folder.
- **Shortcut** — for *Run a shortcut*, a combo box of the shortcuts in the
  Shortcuts app (from `shortcuts list`, read again whenever the editor comes
  back to the front), with completion as you type. A name that matches no
  shortcut is flagged. **Edit…** opens the shortcut in Shortcuts, or **Open
  Shortcuts** to make one.
- **Music** — for *Play music*, *Song*, *Album*, *Playlist*, *Artist* and
  *Genre* are combo boxes of what's in your Music library, read without opening
  Music: one choice follows another — a genre's artists, an artist's albums
  and songs — the most played first. The first time, macOS asks for Media &
  Apple Music access.
- **A module's lists** — fields whose module knows what can go in them are
  combo boxes too: for *Home Assistant*, the entities it has, then the services,
  modes, options and warmths that entity takes, each with its name and state.
  Anything can still be typed, `{{…}}` values included. A list that can't be
  had says why under the field — no token, nothing answering. A module can
  also show only the fields that apply: a thermostat's temperature and mode,
  not a lamp's brightness; a field that's been set is always shown.
- **Colour** — for a module field that takes one, a swatch that opens the
  colour panel, beside the field it's written in: `#ff8800`, or a name from
  its list. Dragging in the panel is written once it settles.
- **Key colour** — the key's light: a colour well that opens the colour panel,
  and swatches that read well on the keys, one click each. Shows the colour in
  force and where it comes from; **Use Inherited** removes the node's own. Writes
  `colour: rrggbb`. Dragging in the colour panel is written once it settles, so
  it's one undo step.
- **Run at once** — for every action: skip the time to cancel (`instant:`).
  Left to inherit, it says what the key will do — "at once" for a stopwatch's
  Start, "after 1 s" for most — and the preview notes a key that runs the
  moment it's pressed.
- **Module types** — a module's action types are in the Type menu with the
  built-in ones, and its fields show like theirs; a field with a few set
  values, like the stopwatch's *Do*, is a menu.
- **When OK is chosen / When Cancel is chosen** — for *Display* and *Ask*, what
  each button runs: a Type menu of its own (*Nothing: just close*, or any action
  type, beside how it's written: *Copy to clipboard  ok: Copy*) and that type's
  fields, indented under it. Choosing a type writes
  `ok: Copy` — its keyword where it has one — and each field `ok.text: …`. A
  display's sections appear once its Buttons include that button; an Ask always
  has both. A note under each says what `{{displayed}}` or `{{answer}}` holds,
  and, for Copy and Insert, that it's what they use with no text. Fields the
  chosen type doesn't use are listed under *Not used here*.
- **Spaces** — for *Switch Spaces*, every screen connected, one under
  another as they're counted from the left, each with its name and a row of
  boxes: *No change*, then one per desktop, shaped like the screen and in
  Mission Control's order, with a dot under the one it shows now. A screen's
  choice is filled in when it's set here and outlined when it's inherited,
  with where it comes from beside the screen's name; choosing what the branch
  above gives takes this node's own away again, and **Use Inherited** does
  the same. A desktop the screen doesn't have is marked. An app's
  full-screen space is shown but can't be chosen. A screen the node sets
  that isn't connected is listed, to remove.
- **Clock timer setup** — for *Clock timer*, if the helper shortcut doesn't
  exist yet, the steps to make it, with **Open Shortcuts**.
- **Template file** — which file the action uses: a combo box of the files in
  the templates folder, and in folders inside it, completing as you type;
  **Choose…** for one anywhere; or drag one in from the Finder. A file in the
  templates folder is written by its name there, `standup.md`; any other by its
  path, `~/Documents/reply.md`. Where an action takes a file *or* text — Copy's
  and Insert's *Text*, a note's *Entry*, a message's *Message* — the file is
  used when there is one, so whichever of the two is out of use is greyed, with
  a line saying why, and each one's tooltip names the other.
- **Template** — when the action uses one, the file itself, editable in place
  with headings in bold and its values coloured, explained and checked as in
  a field — as this node would use it — with **Save Template**,
  **Revert** and **Open in TextEdit**. If the file doesn't exist yet, **Create
  It**. A template is shared by every node that uses it; saving writes the file
  straight away, outside the outline's undo.
- **Fields that are set by words** — `[Rider]`, `[worklog.md]`, `[5 min alert]`,
  `[https://…]` — show as set here, just as their `key: value` forms do.
  Editing one writes the pair in place of the word. Links are underlined in the
  outline, in the link colour.
- **Not used here** — anything in the node's brackets that does nothing and has
  no field above: a field the action doesn't use (a `target:` left from when
  the node opened an app), or a word that wasn't understood and was kept as a
  note. Each says why, with a button to remove it.
- **Problems** — everything the compiler said about this node.
- **Tooltips** — resting the pointer on any field, or its label, says what it
  does, what can go in it, and gives an example. A built-in action's fields
  carry their own wording, in `BuiltInActions` in KeybowKit, since `title` or
  `duration` mean different things in different actions; a module's fields
  bring theirs. `Editor/FieldHelp.swift` has the rest: the label, colour,
  type and values.

Edits in the inspector change the node's annotations in place: an existing pair
is updated where it stands; a new one is added at the end; bare words are kept.
The row in the outline updates as you type, and the preview line with it.

---

## The keypad

A 4×4 drawing of the keys, lit as the Keybow would be with the selected node
chosen:

- the node's **ancestors** lit on their rows;
- the node's **own row** showing all its siblings, the selected one brightest;
- its **children** dimmed on the next row, if it's a branch;
- **empty keys** as outlines.

Rows follow the tab's direction: in the bottom tree, the root row is at the
bottom and the tree climbs.

**Clicking a key** selects the node on it: an ancestor or one of its siblings, a
sibling of the selected node, or one of its children. Clicking an empty key on
the selected node's row selects that placeholder, ready to type into.

### Mirroring on the Keybow

While the editor is the front window, the Keybow itself shows the same lights,
and pressing a key on it moves the selection exactly as clicking the drawing
does. Switching away from the editor puts the Keybow back to normal. Building a
tree then becomes something you can feel as well as see.

---

## Files

- The editor opens the **`tree.md`** the app is using.
- **Save** writes `tree.md` in the outline's standard form, and the app loads it
  at once. With mistakes, the app runs the rest of the tree, leaving out what
  each mistake touches, and the editor says so; the mistakes stay marked in place.
  The version before is kept beside it as `tree.md.previous`.
- An **edited** marker shows unsaved changes; closing the window with unsaved
  changes asks whether to save.
- If `tree.md` changes outside the editor — saved from another editor, by a
  script or an agent — the editor shows the change: as the app picks it up,
  on Reload Config, on coming back to the editor's window, and on opening it
  again. With nothing unsaved it reloads at once, keeping what was selected,
  and says so. Over unsaved changes it offers instead: **Reload**, losing
  them, or **Keep Mine**, and saving writes over the change.
- **Don't Save**, on closing, throws the changes away: the editor opens again
  on the file as it is.
- Lines between items that aren't items (comments) aren't kept when the outline
  is written back. The editor says so the first time it opens a file that has
  any.

---

## How it's built

**KeybowKit** (pure, tested):

- `Outline.swift` — the document model, parser and writer. Nodes have stable
  identities so the selection can follow them as they move.
- `OutlineCompiler.swift` — the compiler, with its per-node analysis: each
  annotation's role, each node's problems, and the action type in force.
- `OutlineEditing.swift` — the edit operations and their rules: insert, indent,
  outdent, move, delete, set the text, set or remove a pair — and for steps,
  add, indent, outdent, move and paste. Each returns the new document or the
  reason it's refused. A step is an `OutlineNode` in its key's `steps`; the
  editor selects it by ID as it does a key, and `stepAddress(of:)` finds it.

**The app:**

- `EditorModel` — the document, the selection, the latest compilation, undo.
  Every edit replaces the document through an operation, registers the previous
  one for undo, and recompiles (a few milliseconds for hundreds of nodes).
- `TreeEditorViewController` — the editor as one component: the tabs, the
  outline, the inspector and the keypad, for any window to hold — the editor's
  own, or *Design with Claude*'s.
- `EditorWindowController` — the editor's window, save and close.
- `OutlinePane` — an `NSOutlineView`, editing rows with its own field editor,
  `OutlineFieldEditor`, which completes what's typed in the brackets from
  `OutlineCompletion` in KeybowKit. `Highlighter` colours a line, as it's
  typed too, by the roles the compiler gives its annotations.
- `InspectorPane` and `KeypadPane` — SwiftUI, bound to the model.
- `ValueText` — text with {{values}}: `ValueTextEditor`, an `NSTextView` for a
  field or a page, which colours, explains, checks and completes them;
  `TemplateField`, the inspector's field built from it; and `ValueBrowser`,
  what ƒx opens. What they know comes from KeybowKit: `ValueCatalog` (every
  value, described, and those for a key: `atKey`) and `TemplateSyntax` (each
  tag where it is, and `check`, what's wrong).

**Adding to the inspector.** An action's fields come from its type's
`ModuleField`s, built in (`BuiltInActions`) or a module's, and `fieldRow` in
`InspectorPane` draws each by its kind — flag, choice, colour, text. A field
that needs more than a text field gets a view of its own, chosen there by its
key: `AppField`, `ShortcutField`, `TemplateFileField` (in `TemplateEditor`),
and `ModuleChoiceField` for any field whose module lists choices. Such views
are built from `InspectorRow` (the label column), `NameComboBox` (a list to
pick from that still takes typing), `DraftField` (commits on Return or on
leaving, so one edit is one undo step; `TemplateField` the same, for text
that takes {{values}}) and `FieldFooter` (why a field is
greyed, and where its value comes from). Tooltips are `FieldHelp`'s, starting
from each field's own `help`. Writing goes through `setField`, which also
replaces a word that set the field — `[worklog.md]` — with the pair.

## Phases

1. ✅ **The language, version 3**: square brackets, pairs, sections, lossless
   reading and writing; `keybow upgrade-outline`.
2. ✅ **The outline pane**: the window, the tabs, keyboard editing with its
   rules, highlighting, problem markers, undo, save and compile.
3. ✅ **The inspector**, editing in both directions.
4. ✅ **The keypad drawing**, with click to jump.
5. ✅ **Values in fields**: coloured, explained, checked and completed, with
   ƒx for the list of them all.
6. ✅ **Completion in the outline's brackets**: keywords, keys, lists,
   templates, apps, a key's values, and {{values}}.
7. **Mirroring on the Keybow**; panes for lists, contacts and projects.
