# Spike findings

Tested on macOS 15.7.9 (Intel), Notes via AppleScript.

## Spike 2 — Notes: append to an existing note

**Verdict: usable, but lossy. Accepted with limitations.**

Appending means reading `body` of the note, concatenating, and writing it back.
Notes re-normalises the HTML on the way in, so some content is silently changed:

| Element | Outcome |
|---|---|
| Plain text, bold, links | preserved |
| Table | preserved |
| Bulleted list | preserved |
| Checklist | **downgraded to a plain bulleted list** (tick states lost) |
| Inline photo | **converted to a file attachment** (no longer inline) |
| `<h1>` heading | **downgraded** to `<span style="font-size: 24px">` |

Damage is cumulative in the sense that anything you add to the note by hand
between appends gets flattened by the next append.

### Size

A note with one inline photo exported a **4 MB** body (the JPEG as a
`data:image/jpeg;base64` URI). After the append the body was 2 KB, the image
having moved out to an attachment. Every append round-trips the whole body
through AppleScript, so large notes are slow and memory-hungry.

### Consequences for the app

- Append targets should hold plain text, bullets and tables only.
- **A checklist cannot be detected before flattening it**: exported HTML renders
  both checklists and bulleted lists as `<ul><li>`. We cannot warn about this.
- Inline images *are* detectable (`data:image` in the body), as is body size.
  Planned guard: refuse to append above a size threshold or when an inline image
  is present, overridable per node in the config.
- `notes.create` is unaffected: we supply the HTML, so nothing is round-tripped.

## AppleScript gotchas hit while writing these scripts

1. **Compound expressions are evaluated by the app, not locally.**
   `name of container of theNote` and `length of (plaintext of theNote)` both
   fail with error -1700. Fetch each value into a variable first.
2. **Variable names collide with property names.** A variable called `plainText`
   is parsed as the `plaintext` property ("Can't set plaintext to plaintext").
3. Container and attachment access can fail on some notes; wrap in `try`.

## Spike 1 — Messages: pre-filled compose via URL

**Verdict: works. Every URL form carrying a body pre-filled an editable message.**

| # | URL form | Result |
|---|----------|--------|
| 1 | `sms:<handle>&body=<text>` | pre-filled, ready to edit |
| 2 | `sms:<handle>?body=<text>` | pre-filled, ready to edit |
| 3 | `sms:/open?addresses=<handle>&body=<text>` | pre-filled, ready to edit |
| 4 | `imessage:<handle>?body=<text>` | pre-filled, ready to edit |
| 5 | `imessage:<handle>&body=<text>` | pre-filled, ready to edit |
| 6 | `imessage://<handle>` (control, no body) | conversation opened, field empty |

All six opened the same conversation for the same handle. Percent-encoded
non-ASCII text (accents, emoji, em dash) and a literal `&` survived intact.

Chosen form: **`sms:<handle>&body=<text>`**, which lets Messages decide between
iMessage and SMS rather than forcing iMessage.

Nothing is ever sent by the app: the message sits in the compose field until the
user presses Return. AppleScript's `send` command is deliberately not used —
it sends immediately, with no draft, which is unacceptable behind a key press.

## Spike 3 — Calendar: create then show

**Verdict: works, with one extra step for the user.**

Creating an event with summary, start/end, location, description and URL, then
`show`ing it, took **2 seconds** via AppleScript. Calendar came to the front,
navigated to the day and **selected** the event, but did not open it for editing —
the user still double-clicks it to change anything.

- 2s is slow enough to notice behind a key press. **Use EventKit from Swift
  instead** for this action: faster, proper date types, and a write-only
  permission level for events.
- Optional later: after showing, send Cmd-E via System Events to open the
  inspector. That needs Accessibility permission, so it should be opt-in.

### Calendar names are ambiguous

Listing the calendars showed **two called "Chris Wenham"** (different accounts),
alongside several read-only ones (`Holidays in United States`, `UK Holidays`,
`Scheduled Reminders`, `Siri Suggestions`). AppleScript's `calendar "name"`
silently takes the first match.

- The config must identify a calendar by **stable ID**, keeping the name as a
  display label only.
- Only writable calendars should be offered when choosing one.
