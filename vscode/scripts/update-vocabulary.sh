#!/bin/sh
# Rewrites data/vocabulary.json from the app's own descriptions of its
# keywords, fields and {{values}}, then the grammars made from it. Run it after
# adding an action type, a field or a value to the app.
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here/../mac"
swift build --product keybow
.build/debug/keybow vocabulary > "$here/data/vocabulary.json"
node "$here/scripts/build-grammars.mjs"
