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

Not yet run.

## Spike 3 — Calendar: create then show

Not yet run.
