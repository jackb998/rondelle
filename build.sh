#!/bin/zsh
# Builds Rondelle.app into ./build (ad-hoc signed, Apple Silicon).
set -euo pipefail
cd "$(dirname "$0")"

# Shortcuts (App Intents): the compiler also writes the intents' constant values, which
# appintentsmetadataprocessor turns into Contents/Resources/Metadata.appintents (what Xcode does on its own).
INTENTS=.build/appintents
mkdir -p "$INTENTS"
echo '["AppIntent","AppEntity","AppEnum","EntityQuery","DynamicOptionsProvider","AppShortcutsProvider","TransientAppEntity","AppIntentsPackage"]' > "$INTENTS/protocols.json"
SWIFT_FLAGS=(-c release --arch arm64
    -Xswiftc -emit-const-values-path -Xswiftc "$PWD/$INTENTS/Rondelle.swiftconstvalues"
    -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$PWD/$INTENTS/protocols.json")

swift build "${SWIFT_FLAGS[@]}" --product Rondelle
BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)/Rondelle"
# The update check is built on its own: the flags above are for the app's Shortcuts metadata only.
UC_FLAGS=(-c release --arch arm64 --scratch-path .build/updatecheck)
swift build "${UC_FLAGS[@]}" --product UpdateCheck
swift build "${UC_FLAGS[@]}" --product FeedbackSend
UC_BIN="$(swift build "${UC_FLAGS[@]}" --show-bin-path)/UpdateCheck"
FS_BIN="$(swift build "${UC_FLAGS[@]}" --show-bin-path)/FeedbackSend"

MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
ls "$PWD"/Sources/Rondelle/*.swift > "$INTENTS/sources.txt"
echo "$PWD/$INTENTS/Rondelle.swiftconstvalues" > "$INTENTS/constvalues.txt"
rm -rf "$INTENTS/out" && mkdir "$INTENTS/out"
xcrun appintentsmetadataprocessor --quiet-warnings \
    --output "$INTENTS/out" \
    --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
    --module-name Rondelle \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
    --platform-family macOS \
    --deployment-target "$MIN_OS" \
    --target-triple "arm64-apple-macos$MIN_OS" \
    --source-file-list "$INTENTS/sources.txt" \
    --swift-const-vals-list "$INTENTS/constvalues.txt" 2>&1 | grep -v "appintentsmetadataprocessor\[" || true
[[ -d "$INTENTS/out/Metadata.appintents" ]] || { echo "Metadata.appintents not generated" >&2; exit 1; }

APP=build/Rondelle.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Rondelle"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns Resources/AppIconDark.icns "$APP/Contents/Resources/"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"   # translations (it, en, fr)
cp -R "$INTENTS/out/Metadata.appintents" "$APP/Contents/Resources/"
tools/add_update_check.sh "$APP" "$UC_BIN"
tools/add_feedback_send.sh "$APP" "$FS_BIN"
xattr -cr "$APP"   # Desktop/iCloud adds Finder metadata that codesign rejects
# Hardened Runtime + App Sandbox (see Resources/Rondelle.entitlements).
codesign --force --options runtime --entitlements Resources/Rondelle.entitlements --sign - "$APP"

echo "Creata $APP"

# ./build.sh --install  →  also copies the app to /Applications (needed for "Avvia al login").
# RONDELLE_INSTALL_DIR is for testing this step in a temporary folder.
if [[ "${1:-}" == "--install" ]]; then
    DEST="${RONDELLE_INSTALL_DIR:-/Applications}"
    ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
    # Only an earlier Rondelle is replaced: another app with the same name is left alone (0.8.4).
    if [[ -e "$DEST/Rondelle.app" ]]; then
        OLD_ID=""
        [[ -f "$DEST/Rondelle.app/Contents/Info.plist" ]] &&
            OLD_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Rondelle.app/Contents/Info.plist" 2>/dev/null || true)
        if [[ "$OLD_ID" != "$ID" ]]; then
            echo "$DEST/Rondelle.app is not Rondelle (identifier «${OLD_ID:-none}», expected «$ID»): not replacing it." >&2
            echo "Move or rename it, then try again. The new app is in $APP." >&2
            exit 1
        fi
    fi
    # Only the installed app: a test binary of the same name may be running a suite.
    pkill -f "^$DEST/Rondelle.app/Contents/MacOS/Rondelle" 2>/dev/null || true
    rm -rf "$DEST/Rondelle.app"
    cp -R "$APP" "$DEST/"
    rm -rf "${APP:?}"   # one copy only: Spotlight/Finder otherwise list Rondelle twice
    open "$DEST/Rondelle.app" || { sleep 2; open "$DEST/Rondelle.app"; }   # -600 right after pkill
    echo "Installata in $DEST"
fi
