# Spikes

Throwaway experiments to settle open questions before building the real app.
Run them yourself from Terminal; they act on your real Messages, Notes and Calendar.
The first run of each will trigger a macOS Automation permission prompt for Terminal.

Results land in `spikes/results/` (git-ignored).

## 1. Messages: pre-filled compose via URL

```bash
spikes/1-messages-compose.sh +15551234567
```

Use your own number or Apple ID email. It opens six URL variants one by one and asks
what happened. **Never press Return in Messages** during this test.

## 2. Notes: append without damage

First, in Notes, create a throwaway note titled exactly **KeybowNotes Append Test** containing:

- a heading
- a checklist with at least one ticked and one unticked item
- a small table
- an image (drag one in)
- a link and some bold text

Then:

```bash
spikes/2-notes-append.sh
```

(Pass a different note name as the first argument if you like.) Compare the note visually
before and after, and on another device after sync. The HTML before/after is saved for diffing.

## 3. Calendar: create, then show for editing

```bash
osascript spikes/3-calendar-create-show.applescript
osascript spikes/3-calendar-create-show.applescript "Home"
```

The first lists your calendars; the second creates a test event tomorrow at 10:00 in the
named calendar and shows it. Judge: does it open the event where you can edit it
immediately, or just jump to the day? How long did it take? Delete the event afterwards.

## Results

See [FINDINGS.md](FINDINGS.md) for detail.

| # | Question | Result |
|---|----------|--------|
| 1 | Which URL form (if any) pre-fills an editable message? | not yet run |
| 2 | Does append preserve checklist / table / image / formatting? | partly — table kept, checklist flattened to bullets, inline photo becomes an attachment, heading downgraded. Accepted with limitations. |
| 3 | Does create + show give a usable "edit it now" experience? | not yet run |
