#!/bin/zsh
# Builds a Rondelle to share: one app for Apple silicon and Intel (universal), ad-hoc signed like build.sh,
# packed in a disk image with reading notes and what LAME's licence (LGPL) asks for. Nothing is installed.
#
#   ./release.sh            →  dist/Rondelle-<version>.dmg
#
# Without an Apple Developer ID the app isn't notarized: macOS 15+ blocks the first opening. The image shows the
# steps on its background and carries «Allow Opening», a script that clears the block for Rondelle only when it
# is dragged into Terminal (the image also has an «Open Terminal» shortcut); System Settings → Privacy & Security → «Open Anyway» stays the alternative.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
DIST=dist
WORK="$DIST/work"
rm -rf "${WORK:?}" && mkdir -p "$WORK"

# Same Shortcuts metadata step as build.sh, for both architectures.
INTENTS=.build/appintents-universal
mkdir -p "$INTENTS"
echo '["AppIntent","AppEntity","AppEnum","EntityQuery","DynamicOptionsProvider","AppShortcutsProvider","TransientAppEntity","AppIntentsPackage"]' > "$INTENTS/protocols.json"
SWIFT_FLAGS=(-c release --arch arm64 --arch x86_64
    -Xswiftc -emit-const-values-path -Xswiftc "$PWD/$INTENTS/Rondelle.swiftconstvalues"
    -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$PWD/$INTENTS/protocols.json")
swift build "${SWIFT_FLAGS[@]}" --product Rondelle
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/Rondelle"
[[ " $(lipo -archs "$BIN") " == *" arm64 "* && " $(lipo -archs "$BIN") " == *" x86_64 "* ]] ||
    { echo "the binary does not contain arm64 and x86_64" >&2; exit 1; }

# The update check is built on its own: the flags above are for the app's Shortcuts metadata only.
UC_FLAGS=(-c release --arch arm64 --arch x86_64 --scratch-path .build/updatecheck-universal)
swift build "${UC_FLAGS[@]}" --product UpdateCheck
swift build "${UC_FLAGS[@]}" --product FeedbackSend
UC_BIN="$(swift build "${UC_FLAGS[@]}" --show-bin-path)/UpdateCheck"
FS_BIN="$(swift build "${UC_FLAGS[@]}" --show-bin-path)/FeedbackSend"

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

STAGE="$WORK/Rondelle"
APP="$STAGE/Rondelle.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Rondelle"
# Local symbols out: smaller, and fewer names of this Mac's folders in what is shared.
strip -x "$APP/Contents/MacOS/Rondelle"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/AppIconLight.icns Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp -R "$INTENTS/out/Metadata.appintents" "$APP/Contents/Resources/"
tools/add_update_check.sh "$APP" "$UC_BIN"
tools/add_feedback_send.sh "$APP" "$FS_BIN"
xattr -cr "$APP"
codesign --force --options runtime --entitlements Resources/Rondelle.entitlements --sign - "$APP"
codesign --verify --strict --deep "$APP"

# Beside the app: Applications shortcut, reading notes, the licences.
ln -s /Applications "$STAGE/Applications"
# Shortcut to Terminal for the first opening (a link to the system app: nothing downloaded is run by it).
ln -s /System/Applications/Utilities/Terminal.app "$STAGE/Open Terminal"
cp distribution/README.txt "$STAGE/READ ME.txt"
mkdir -p "$STAGE/Licenses"
cp distribution/LICENSES.txt "$STAGE/Licenses/LICENSES.txt"
cp LICENSE "$STAGE/Licenses/LICENSE-Rondelle.txt"
cp Sources/CWebP/COPYING "$STAGE/Licenses/libwebp-COPYING.txt"
cp Sources/CWebP/PATENTS "$STAGE/Licenses/libwebp-PATENTS.txt"
cp Sources/CLame/COPYING "$STAGE/Licenses/LAME-COPYING.txt"
# LGPL: LAME's source as compiled into the app, and the rest of the app as object files, so that it can be
# relinked with a modified LAME (distribution/relink.sh, tested on every release below).
mkdir -p "$STAGE/Licenses/LAME-source" "$STAGE/Licenses/LAME-relink"
cp -R Sources/CLame/. "$STAGE/Licenses/LAME-source/"
OBJ_DIR="$(dirname "$BIN_DIR")/../Intermediates.noindex/Rondelle.build/Release"
for arch in arm64 x86_64; do
    list="$WORK/oggetti-$arch.txt"
    # Every object of the app but LAME's (CWebP is part of «the work that uses the library»).
    python3 -c 'import shlex, sys; print("\n".join(i for i in shlex.split(open(sys.argv[1]).read()) if not i.endswith(("/CLame.o", "/CWebP.o"))))' \
        "$OBJ_DIR/Rondelle-p.build/Objects-normal/$arch/Rondelle.LinkFileList" > "$list"
    lipo "$BIN_DIR/CWebP.o" -thin $arch -output "$WORK/CWebP-$arch.o"
    echo "$WORK/CWebP-$arch.o" >> "$list"
    ld -r -arch $arch -filelist "$list" -o "$STAGE/Licenses/LAME-relink/Rondelle-$arch.o" 2>/dev/null
    strip -S "$STAGE/Licenses/LAME-relink/Rondelle-$arch.o"   # no debug info: no paths of this Mac
done
cp distribution/relink.sh Resources/Rondelle.entitlements "$STAGE/Licenses/LAME-relink/"
# The relinking must work with what is shipped: done on a copy, with the shipped LAME source.
cp -R "$APP" "$WORK/Prova.app"
"$STAGE/Licenses/LAME-relink/relink.sh" "$STAGE/Licenses/LAME-source" "$WORK/Prova.app" >/dev/null
[[ " $(lipo -archs "$WORK/Prova.app/Contents/MacOS/Rondelle") " == *" arm64 "* ]] || { echo "relinking failed" >&2; exit 1; }
# First opening without System Settings: the script removes the download mark from Rondelle only (Rondelle is
# not notarized). The window layout (background with the steps, icon positions) is a Finder .DS_Store made once
# by tools/dmg_layout.sh; it points to the volume by name, so the volume is always called «Rondelle».
cp "distribution/dmg/Allow Opening" "$STAGE/Allow Opening"
chmod 755 "$STAGE/Allow Opening"
mkdir -p "$STAGE/.background"
cp distribution/dmg/background.tiff "$STAGE/.background/background.tiff"
cp distribution/dmg/DS_Store "$STAGE/.DS_Store"
xattr -cr "$STAGE"

mkdir -p "$DIST"
DMG="$DIST/Rondelle-$VERSION.dmg"
rm -f "$DMG" "$DMG.sha256"
hdiutil create -quiet -volname "Rondelle" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
HASH="$(shasum -a 256 "$DMG" | awk '{print $1}')"
# The hash goes by another channel than the image (a message, not the same link): if the link were tampered
# with, a hash beside it would be tampered with too.
cat > "$DIST/Rondelle-$VERSION-hash-to-send-separately.txt" <<MSG
Rondelle $VERSION — download check

SHA-256: $HASH

In Terminal:  shasum -a 256 ~/Downloads/Rondelle-$VERSION.dmg
The result must match exactly. If it doesn't, don't open the file.
MSG
echo "SHA-256 $HASH (message to send separately: $DIST/Rondelle-$VERSION-hash-to-send-separately.txt)"
rm -rf "${WORK:?}"
echo "Creata $DMG"
