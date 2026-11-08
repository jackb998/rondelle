#!/bin/bash
# Regenerates distribution/dmg/DS_Store, the Finder layout of the DMG window (background with the install steps,
# icon positions). Run it only when the background or the DMG contents change; release.sh copies the result.
# Needs Finder automation (macOS asks once). The temporary image lives in $TMPDIR, so the alias stored in the
# layout carries no user name. Background: python3 tools/dmg_background.py out.png out@2x.png, then
# tiffutil -cathidpicheck out.png out@2x.png -out distribution/dmg/background.tiff
set -euo pipefail
cd "$(dirname "$0")/.."
T="$(mktemp -d "${TMPDIR%/}/rdmg.XXXXXX")"
trap 'hdiutil detach -quiet /Volumes/Rondelle 2>/dev/null || true; rm -rf "$T"' EXIT
mkdir -p "$T/s/.background" "$T/s/Rondelle.app" "$T/s/Licenses"
cp distribution/dmg/background.tiff "$T/s/.background/"
cp "distribution/dmg/Allow Opening" "$T/s/"
cp distribution/README.txt "$T/s/READ ME.txt"
ln -s /Applications "$T/s/Applications"
ln -s /System/Applications/Utilities/Terminal.app "$T/s/Open Terminal"
hdiutil create -quiet -volname Rondelle -srcfolder "$T/s" -fs HFS+ -format UDRW -ov "$T/Rondelle.dmg"
hdiutil attach -quiet -noautoopen "$T/Rondelle.dmg"
osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "Rondelle"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 820}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 80
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    set position of item "Rondelle.app" of container window to {165, 170}
    set position of item "Applications" of container window to {475, 170}
    set position of item "Open Terminal" of container window to {165, 395}
    set position of item "Allow Opening" of container window to {475, 395}
    set position of item "READ ME.txt" of container window to {250, 595}
    set position of item "Licenses" of container window to {390, 595}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
sleep 2
cp /Volumes/Rondelle/.DS_Store distribution/dmg/DS_Store
echo "Updated distribution/dmg/DS_Store"
