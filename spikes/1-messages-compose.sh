#!/bin/zsh
# Spike 1: can a URL open Messages with a pre-filled, UNSENT message?
#
# Tries several URL forms one at a time and asks you what happened.
# Nothing is sent unless you press Return in Messages — don't.
# Tip: use your own phone number or Apple ID email as the recipient.

set -u
cd "${0:A:h}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <phone-or-email>    e.g. $0 +15551234567"
  exit 1
fi

recipient=$1
# Deliberately includes characters that need URL encoding.
body='KeybowNotes test: café & 🎹 — do not send'
encoded_body=$(osascript -l JavaScript -e 'function run(a) { return encodeURIComponent(a[0]) }' "$body")

variants=(
  "sms:${recipient}&body=${encoded_body}"
  "sms:${recipient}?body=${encoded_body}"
  "sms:/open?addresses=${recipient}&body=${encoded_body}"
  "imessage:${recipient}?body=${encoded_body}"
  "imessage:${recipient}&body=${encoded_body}"
  "imessage://${recipient}"
)

mkdir -p results
results=results/1-messages.txt
echo "# Spike 1 — $(date) — macOS $(sw_vers -productVersion)" > $results

i=1
for url in $variants; do
  echo
  echo "[$i/${#variants}] $url"
  read -r "?Press Enter to open it (make sure Messages has no half-typed draft)… "
  open "$url"
  echo "  t = conversation opened with the text pre-filled, ready to edit"
  echo "  e = conversation opened, but the text field is empty"
  echo "  w = opened the wrong conversation / garbled text"
  echo "  n = nothing happened or an error"
  read -r "answer?Result [t/e/w/n], plus any comment: "
  echo "$i | $url | $answer" >> $results
  echo "  (Clear the text field in Messages without sending before the next one.)"
  (( i++ ))
done

echo
echo "Done. Results written to spikes/$results"
