#!/bin/zsh
# Makes a disk image to install KeybowNotes from: the app, a shortcut to
# Applications to drag it onto, and a note on opening it.
#
#   scripts/make-dmg.sh              build the app, then the disk image
#   scripts/make-dmg.sh --no-build   use the app already in mac/build/
#
# The image is mac/build/KeybowNotes-<version>-<build>.dmg, signed with the
# same identity as the app when there is one. Without a Developer ID and
# notarization, macOS on another Mac blocks the app the first time it's
# opened, until it's allowed in Privacy & Security — the note says how.

set -euo pipefail
cd "${0:A:h}/.."    # the mac/ directory

[[ "${1:-}" == "--no-build" ]] || scripts/build-app.sh

APP=build/KeybowNotes.app
[[ -d "$APP" ]] || { echo "There's no $APP: run without --no-build"; exit 1; }
codesign --verify --strict --deep "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
DMG=build/KeybowNotes-$VERSION-$BUILD.dmg

echo "==> Making $DMG"
STAGE=$(mktemp -d)
mkdir "$STAGE/KeybowNotes"
# ditto keeps the app exactly as signed.
ditto "$APP" "$STAGE/KeybowNotes/KeybowNotes.app"
ln -s /Applications "$STAGE/KeybowNotes/Applications"
cp "Packaging/Opening KeybowNotes.txt" "$STAGE/KeybowNotes/If macOS won't open it.txt"
rm -f "$DMG"
hdiutil create -volname KeybowNotes -srcfolder "$STAGE/KeybowNotes" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -quiet "$DMG"
rm -rf "$STAGE"

identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')
if [[ -n "$identity" ]]; then
    codesign --force --sign "$identity" --timestamp=none "$DMG"
    echo "    signed as: $identity"
fi
hdiutil verify -quiet "$DMG"
echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
