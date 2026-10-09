# Controlling KeybowNotes from other apps and AI agents

KeybowNotes can be driven from outside, as well as by its keys: from
AppleScript, from Shortcuts, and from AI agents through the Model Context
Protocol. Each can run an entry as though its keys were pressed, read and
change the trees, and work the stopwatch. And with an Anthropic API key, the
app can draft trees itself from a description of what you'd like the keypads
for.

All of them work the same way underneath:

- **An entry is named by its labels** from the top of its tree, separated by
  slashes: `Window Management/Left Screen`. A label is matched whatever its
  case; a key's number, 1 to 4, works in place of a label.
- **A tree** is `main`, `row 2`, `row 3` or `bottom`; **a keypad** is
  `Default`, or a keypad section's name, model or board ID. Left out, they're
  the main tree of the trees the keypad that's plugged in uses.
- **Entries are written as the outline writes them:** `Desk lamp [Home,
  entity: light.desk_lamp]`, or several outline lines, indented for keys under
  keys. New entries go on the first free keys, by the tree editor's rules.
- **Changes go to the tree file,** which KeybowNotes loads at once, as it does a
  save from the tree editor. The file as it was before the last change — from
  here or the editor — is kept beside it as `tree.md.previous`. While the tree
  editor has unsaved changes, nothing is changed from outside — one or the
  other would be lost — and an open editor with nothing unsaved reloads.
- **Running an entry** does what its key does, through the same path: what it
  fetches, asks or refuses, and what the overlay shows. The answer is what
  happened: *Event: Standup · tomorrow 09:00*, or why it didn't.

## AppleScript

Script Editor's *File → Open Dictionary…* shows KeybowNotes' commands.

```applescript
tell application "KeybowNotes"
    trigger "Window Management/Left Screen" tree "row 2"
    add entry "Desk lamp [Home, entity: light.desk_lamp]" under "Lights" tree "row 2"
    change entry "Lights/Desk lamp" to "Lamp [Home, entity: light.desk_lamp, brightness: 40]" tree "row 2"
    remove entry "Lights/Lamp" tree "row 2"
    set myTree to tree outline tree "row 2" keypad "Desk"
    set runnable to tree entries tree "row 2"     -- a list of paths
    replace tree tree "row 3" with outline "1. Tea [Timer, duration: 4 min]"
    check outline "1. Work [Notes]"                -- what the compiler says; changes nothing
    keypad names
    add keypad "Spare" model "RGB Keypad"
    whole outline
    start stopwatch
    lap stopwatch
    stop stopwatch
    reset stopwatch
    toggle stopwatch
    stopwatch reading                               -- "4:12, running"
    music library "artists" genre "Jazz" limit 4    -- the most played, as text: as much as Settings → Privacy shares
end tell
```

A refusal is the script's error: `try … on error message`. The first script
from an app makes macOS ask whether it may control KeybowNotes; the prompt
can open behind other windows. The answer is kept in System Settings →
Privacy & Security → Automation.

## Shortcuts

KeybowNotes adds these actions to Shortcuts, under its name:

| Action | |
|---|---|
| **Run Keypad Entry** | Choose the entry from a list of every one that runs an action, in every keypad's trees. Gives back what happened. |
| **Add Keypad Entry** | An entry's line — or outline lines — under an entry or on a tree's top row. |
| **Change Keypad Entry** | Rewrites an entry's line, keeping what's under it. |
| **Remove Keypad Entry** | Removes an entry, with everything under it. |
| **Get Keypad Tree** | A tree, as outline text. |
| **Control the Stopwatch** | Start, stop, lap, reset, or start or stop; gives back what it reads. |

They run in KeybowNotes without bringing it forward. *Run AppleScript* in
Shortcuts reaches the AppleScript commands too.

## AI agents: the MCP server

KeybowNotes comes with a [Model Context Protocol](https://modelcontextprotocol.io)
server, so an AI agent — Claude, or another that speaks MCP — can read the
guide to designing trees, check outline text, read and change your trees, run
entries and work the stopwatch. It's the `keybow` command inside the app:

**Claude Desktop** — in `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "keybownotes": {
      "command": "/Applications/KeybowNotes.app/Contents/Helpers/keybow",
      "args": ["mcp"]
    }
  }
}
```

**Claude Code:**

```bash
claude mcp add keybownotes -- /Applications/KeybowNotes.app/Contents/Helpers/keybow mcp
```

Its tools:

| Tool | |
|---|---|
| `get_guide` | How to design KeybowNotes trees, then the whole configuration language |
| `list_action_types` | The action types this copy has, with their keywords — and modules' fields |
| `check_outline` | What the compiler would make of outline text; changes nothing |
| `list_keypads` | The keypads' trees, and which keypads plugged in use them |
| `get_tree`, `get_outline` | A tree, or the whole file, as outline text |
| `list_entries` | The entries in a tree that run an action |
| `add_entry`, `change_entry`, `remove_entry` | As AppleScript's commands |
| `replace_tree` | A whole tree, from outline text |
| `add_keypad` | A keypad section with trees of its own |
| `run_entry` | Runs an entry, for real |
| `music_library` | What's in the Music library — genres, artists, albums, songs, favourites, playlists — the most played first; no more than Settings → Privacy shares with Claude |
| `stopwatch` | start, stop, lap, reset, toggle or read |

And a prompt, `design_keypad`, that starts an agent off on designing trees for
what you describe — reading the guide and what you have first, checking its
outline, and asking before it changes or removes anything of yours.

Reading the guide, the action types and checking outline text need nothing
else. Everything else is asked of the app, through its AppleScript, so macOS
asks once whether the agent's app may control KeybowNotes — and the app is
opened if it isn't running.

The guide the agent reads is [AGENT-GUIDE.md](AGENT-GUIDE.md), followed by
[CONFIG-LANGUAGE.md](CONFIG-LANGUAGE.md).

## Design with Claude

*Design with Claude…*, in the menu bar, is a conversation about your keypads,
beside a draft of them. It needs your Anthropic API key, in Settings → Claude.

On the left is the conversation; on the right, the whole tree editor — outline,
inspector and keypad — on a working copy of your tree with Claude's draft in it.
Click through the draft as you would your own tree, try the tabs, see which
keys light in which colours, and change anything by hand. Your tree changes
only when you add the draft.

1. **Choose what to draft:** a new keypad section with all its trees; all of a
   keypad's trees; or one tree. Below that, the window says what goes with
   what you write, as Settings → Privacy has it — **Change…** opens it there.
   Each can be ticked or not: your tree file, so the draft fits with it and
   uses your contacts, projects and lists; the names of your apps and
   shortcuts, so it uses the ones you have; and your Home Assistant devices.
   And how much of your Music library Claude may look through when it makes
   music keys: nothing; your genres; your artists too; your albums too; or
   every song, your favourites among them — each with how often it's played —
   and, if ticked, your playlists' names. Ask for "my top 4 genres, then the
   top 4 artists in each". Claude is offered only what's shared, and a question
   about more is refused before the library is read. The first look asks you
   for Media & Apple Music access. It all goes to Anthropic with your key, and
   of your library only what Claude asks for.
2. **Say what you'd like** the keypads for, in your own words: the apps you
   use, what you do again and again, the people you message, the lamps you
   switch. Claude is told what KeybowNotes can do — the same guide an agent
   reads, the language, and the action types here, modules' included — and
   its draft appears in the editor. If the outline has mistakes, Claude is
   shown them and asked once to correct them.
3. **Ask for changes,** as you would a person — "put the lamps on a page of
   their own", "add a key to message Sam". Each turn sends the draft as it
   stands, with anything you've changed by hand, and Claude's new draft
   replaces it in one step: ⌘Z in the editor goes back to the one before.
   Ask a question, and Claude just answers; the draft stays as it is.
4. **Add to My Tree** puts the draft in your tree — a new section, or the
   trees you chose to redraft — with any lists, contacts and projects it
   added. Go on talking afterwards, and **Update My Tree** puts the changes in
   the same place. A new section for the model of a keypad that already has a
   section isn't used by that keypad; the conversation says so, and the tree
   editor sets which keypad it's for.

The long, unchanging parts of each request — the guide, and what you sent
about your tree — are cached by Anthropic for a few minutes, so a
conversation costs much less than its first turn each time. Drafting uses the
model in Settings → Claude, with at least medium effort; a turn can take a
minute or two. Closing the window with a draft you haven't added asks first.
