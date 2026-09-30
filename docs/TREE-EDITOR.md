# The tree editor

**Status:** phases 1–4 built; mirroring on the Keybow and completion are next (see the end). The outline
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

- **Tabs** switch between the four trees, or ⌘1 to ⌘4. Each has a diagram of the
  keypad in the tree's colour — Main blue, Row 2 teal, Row 3 orange, Bottom
  pink — with its starting row at full strength and the rows it goes on to
  fading in order, so it shows which way the tree runs. The overlay's tree badge
  uses the same diagram and colour. A dot marks a tree with problems.
- **Outline** on the left; **inspector** at top right; **keypad** at bottom right.
- The window opens from the menu bar: **Edit Tree…** (⌘E).

---

## The outline pane

Each row is one node:

- its **key number** (1–4) in a small badge — its position on the keypad row;
- a disclosure triangle for branches;
- the **label**, then the **brackets** with each annotation coloured by what it
  means (below);
- a **problem marker** when the node has one, with the message as a tooltip and
  in the inspector.

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
| Return on an empty new node | — | removes it again |
| Tab | **indent**: the node becomes a child of the node above it | ends the edit, indents, carries on editing |
| Shift-Tab | **outdent**: the node moves up a level, after its parent | ends the edit, outdents, carries on editing |
| ⌃⌘↑ / ⌃⌘↓, or ⇧⌘↑ / ⇧⌘↓ | **move** the node to the key before / after, swapping with what's there or moving into an empty key | the same, ending the edit |
| ↑ / ↓ | select the previous / next row | end the edit and select |
| ← / → | collapse / expand | move the cursor |
| Delete | delete the node and everything under it | edits |
| Esc | — | abandon the edit |
| ⌘Z / ⇧⌘Z | undo / redo | the same, for the text |
| ⌘S | save | end the edit and save |

A new node isn't made until something is typed: Esc, or Return on the empty
row, leaves nothing behind. So Return on a full row can offer a child without
risk, which is how a branch's fourth node gets children — the Return, Tab way
needs a free key beside it first. *Add Child* is in the Edit menu too.

⌃⌘↑/↓ follows OmniOutliner. Shift with the arrows would be the obvious choice,
but it already extends a text selection while editing. ⇧⌘↑/↓ works too: ⌃ and
⇧ are easily mistaken for each other, and in a one-line field ⇧⌘↑/↓ only
duplicates ⇧⌘←/→.

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

---

## The inspector

For the selected node:

- **Where it is:** the path, the tree, and the row and key it occupies.
- **What pressing does** — for a leaf, the action with its values filled in, as
  the overlay would show it: "New event · Meeting · Sun 27 Sep, 09:00 · alert 5
  min before". For a branch, what its leaves will do by default. Missing values
  are shown in orange: "needs contact.phone".
- **Label** — a text field.
- **Action** — the type, and the fields that type uses, each showing its value
  and **where it comes from**: *set here*, *from Meeting* (an ancestor), or *from
  the defaults*. Setting a field writes a pair into this node's brackets;
  clearing one removes the pair, so the inherited value shows through again.
  The type is a menu: *inherit*, or a type — which writes the keyword.
- **Values** — template values set here, editable as key and value; and those
  inherited from above, read-only, with where each comes from.
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
  type) and that type's fields, indented under it. Choosing a type writes
  `ok: Copy` — its keyword where it has one — and each field `ok.text: …`. A
  display's sections appear once its Buttons include that button; an Ask always
  has both. A note under each says what `{{displayed}}` or `{{answer}}` holds,
  and, for Copy and Insert, that it's what they use with no text. Fields the
  chosen type doesn't use are listed under *Not used here*.
- **Clock timer setup** — for *Clock timer*, if the helper shortcut doesn't
  exist yet, the steps to make it, with **Open Shortcuts**.
- **Template** — when the action uses one, the file itself, editable in place
  with `{{placeholders}}` and headings highlighted, with **Save Template**,
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
  does, what can go in it, and gives an example. The wording is in
  `Editor/FieldHelp.swift`, looked up by action type then field, since `title`
  or `duration` mean different things in different actions; a module's fields
  bring their own.

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
- An **edited** marker shows unsaved changes; closing the window with unsaved
  changes asks whether to save.
- If `tree.md` changes on disk while it's open — edited by hand — the editor
  offers to reload it.
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
  outdent, move, delete, set the text, set or remove a pair. Each returns the new
  document or the reason it's refused.

**The app:**

- `EditorModel` — the document, the selection, the latest compilation, undo.
  Every edit replaces the document through an operation, registers the previous
  one for undo, and recompiles (a few milliseconds for hundreds of nodes).
- `EditorWindowController` — the window, the tabs in its toolbar, save and close.
- `OutlineController` — an `NSOutlineView`, with its own field editor for
  highlighting as you type and for the keys above.
- `InspectorView` and `KeypadView` — SwiftUI, bound to the model.

## Phases

1. ✅ **The language, version 3**: square brackets, pairs, sections, lossless
   reading and writing; `keybow upgrade-outline`.
2. ✅ **The outline pane**: the window, the tabs, keyboard editing with its
   rules, highlighting, problem markers, undo, save and compile.
3. ✅ **The inspector**, editing in both directions.
4. ✅ **The keypad drawing**, with click to jump.
5. **Mirroring on the Keybow**; completion inside brackets (keywords, installed
   apps, templates, lists, field names); panes for lists, contacts and projects.
