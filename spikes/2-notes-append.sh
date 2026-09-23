#!/bin/zsh
# Spike 2: does appending to a note via AppleScript damage checklists, tables or attachments?
#
# THIS MODIFIES THE NAMED NOTE. Use a throwaway note (see README.md for what to put in it).

set -eu
cd "${0:A:h}"

name=${1:-KeybowNotes Append Test}
helper=./notes-append-test.applescript
out=results/2-notes
mkdir -p $out

echo "Target note: \"$name\""
read -r "?This will append a line to that note. Press Enter to continue, Ctrl-C to abort… "

osascript $helper info "$name" > $out/info-before.txt
osascript $helper read "$name" > $out/before.html

osascript $helper append "$name"
sleep 3   # let Notes save and re-render

osascript $helper info "$name" > $out/info-after.txt
osascript $helper read "$name" > $out/after.html

echo
echo "== Before"; cat $out/info-before.txt
echo "== After";  cat $out/info-after.txt
echo
echo "== HTML diff (before → after)"
diff $out/before.html $out/after.html || true
echo
echo "Now look at the note in Notes (it should be in front) and check:"
echo "  • checklist items still tick-able and still ticked/unticked as before?"
echo "  • table still a table?"
echo "  • image/attachment still present?"
echo "  • heading and other formatting intact?"
echo "  • the appended line at the bottom, bold?"
echo "Later, check the same note on your iPhone/iPad after it syncs."
echo "Files saved in spikes/$out"
