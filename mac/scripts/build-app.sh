#!/bin/zsh
# Builds KeybowNotes.app: a universal release binary, an Info.plist, the icon,
# the example config and templates, the keypad firmware, all signed.
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
swift build -c release --arch arm64 --arch x86_64 --product keybow
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

# What AppleScript can ask of it.
cp Packaging/KeybowNotes.sdef "$APP/Contents/Resources/KeybowNotes.sdef"

# For AI agents: the command line, whose `keybow mcp` an MCP client runs, and
# the guides it — and the app's own drafting — give them.
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/Guide"
cp "$BIN_DIR/keybow" "$APP/Contents/Helpers/keybow"
cp ../docs/AGENT-GUIDE.md ../docs/CONFIG-LANGUAGE.md "$APP/Contents/Resources/Guide/"

# Shortcuts' actions: the metadata Shortcuts reads them from, which Xcode
# would make. The compiler records the app's App Intents types as constant
# values — type-checking alone, against the release build's modules — and
# Xcode's processor turns those into Metadata.appintents.
echo "==> Extracting Shortcuts' actions"
INTENTS=$(mktemp -d)
find Sources/KeybowNotesApp -name '*.swift' | sed "s|^|$PWD/|" > "$INTENTS/sources.txt"
cat > "$INTENTS/protocols.json" <<'JSON'
["AppIntent", "EntityQuery", "AppEntity", "TransientEntity", "AppEnum", "AppShortcutProviding", "AppShortcutsProvider",
 "AnyResolverProviding", "AppIntentsPackage", "DynamicOptionsProvider", "_IntentValueRepresentable",
 "_AssistantIntentsProvider", "_GenerativeFunctionExtractable", "IntentValueQuery", "EntityStringQuery",
 "EntityPropertyQuery", "UniqueAppEntity"]
JSON
SDK=$(xcrun --show-sdk-path --sdk macosx)
xcrun swiftc -typecheck -module-name KeybowNotesApp -target arm64-apple-macos15.0 -sdk "$SDK" -swift-version 5 \
    -I "$BIN_DIR" -wmo $(cat "$INTENTS/sources.txt") \
    -emit-const-values-path "$INTENTS/KeybowNotesApp.swiftconstvalues" \
    -Xfrontend -const-gather-protocols-file -Xfrontend "$INTENTS/protocols.json" 2> "$INTENTS/typecheck.log" \
    || { cat "$INTENTS/typecheck.log"; exit 1; }
echo "$INTENTS/KeybowNotesApp.swiftconstvalues" > "$INTENTS/constvalues.txt"
xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" \
    --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" \
    --module-name KeybowNotesApp --sdk-root "$SDK" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
    --platform-family macOS --deployment-target 15.0 --target-triple arm64-apple-macos15.0 \
    --source-file-list "$INTENTS/sources.txt" --swift-const-vals-list "$INTENTS/constvalues.txt" \
    --binary-file "$BIN_DIR/keybownotes" --force > "$INTENTS/metadata.log" 2>&1 \
    || { cat "$INTENTS/metadata.log"; exit 1; }
[[ -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]] || { echo "No Shortcuts metadata was made"; exit 1; }
rm -rf "$INTENTS"

# Installed into ~/Library/Application Support/KeybowNotes on first run, when
# there is no tree yet.
cp tree.demo.md "$APP/Contents/Resources/tree.demo.md"
cp -R templates "$APP/Contents/Resources/templates"

# The keypad's firmware, for setting keypads up: what the manifest names.
# Without extended attributes, which would end up as ._ files on a keypad.
FIRMWARE=$APP/Contents/Resources/Firmware
mkdir -p "$FIRMWARE"
cp -X ../firmware/manifest.json ../firmware/boot.py ../firmware/code.py ../firmware/keymap.py "$FIRMWARE/"
rsync -a --exclude '.*' --exclude 'README.md' --exclude '__pycache__' ../firmware/lib/ "$FIRMWARE/lib/"
xattr -cr "$FIRMWARE"

echo "==> Signing"
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')
if [[ -n "$identity" ]]; then
    echo "    The first time, macOS asks whether codesign may use your signing key."
    echo "    That dialog can open behind other windows and isn't in Exposé or the Dock;"
    echo "    if this seems stuck, look for it, and choose Always Allow."
    codesign --force --sign "$identity" --timestamp=none "$APP/Contents/Helpers/keybow"
    codesign --force --sign "$identity" --timestamp=none "$APP"
    echo "    signed as: $identity"
else
    codesign --force --sign - "$APP/Contents/Helpers/keybow"
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
    # Told to the system at once, so Shortcuts sees the actions it has now.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "/Applications/$APP_NAME.app" || true
    echo "    installed /Applications/$APP_NAME.app"
fi

echo "==> Done: $APP ($VERSION, build $BUILD)"
