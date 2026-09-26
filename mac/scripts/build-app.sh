#!/bin/zsh
# Builds KeybowNotes.app: a universal release binary, an Info.plist, the icon,
# the example config and templates, all signed.
#
#   scripts/build-app.sh             build into mac/build/KeybowNotes.app
#   scripts/build-app.sh --install   and copy it into /Applications
#
# Signing uses the first "Apple Development" identity in the keychain, if any.
# That matters: macOS remembers permissions (Notes, Calendar…) by signature, and
# a real identity keeps them across rebuilds, where an ad-hoc one does not.

set -euo pipefail
cd "${0:A:h}/.."    # the mac/ directory

APP_NAME=KeybowNotes
BUNDLE_ID=io.github.cwenham.keybownotes
VERSION=0.1.0
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
OUT=build
APP=$OUT/$APP_NAME.app

install=false
[[ "${1:-}" == "--install" ]] && install=true

echo "==> Building a universal release binary"
swift build -c release --arch arm64 --arch x86_64 --product keybownotes
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/keybownotes" "$APP/Contents/MacOS/$APP_NAME"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    Packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" > /dev/null

# The icon only needs redrawing when its script changes.
if [[ ! -f $OUT/AppIcon.icns || Packaging/make-icon.swift -nt $OUT/AppIcon.icns ]]; then
    echo "==> Drawing the icon"
    swift Packaging/make-icon.swift "$OUT/AppIcon.iconset"
    iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
fi
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Installed into ~/Library/Application Support/KeybowNotes on first run, when
# there is no config yet.
cp config.demo.json "$APP/Contents/Resources/config.demo.json"
cp -R templates "$APP/Contents/Resources/templates"

echo "==> Signing"
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')
if [[ -n "$identity" ]]; then
    echo "    The first time, macOS asks whether codesign may use your signing key."
    echo "    That dialog can open behind other windows and isn't in Exposé or the Dock;"
    echo "    if this seems stuck, look for it, and choose Always Allow."
    codesign --force --sign "$identity" --timestamp=none "$APP"
    echo "    signed as: $identity"
else
    codesign --force --sign - "$APP"
    echo "    signed ad hoc — permissions will be asked for again after each rebuild"
fi
codesign --verify --strict "$APP"
lipo -info "$APP/Contents/MacOS/$APP_NAME" | sed 's/^/    /'

if $install; then
    echo "==> Installing to /Applications"
    # Quit a running copy first; it holds the Keybow and would keep the old code.
    if pgrep -x "$APP_NAME" > /dev/null; then
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || pkill -x "$APP_NAME" || true
        sleep 1
    fi
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "    installed /Applications/$APP_NAME.app"
fi

echo "==> Done: $APP ($VERSION, build $BUILD)"
