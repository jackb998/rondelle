#!/bin/zsh
# Puts the UpdateCheck service into an app and signs it (build.sh, release.sh, Tests/updates/run.sh).
# The app itself must be signed after this.
#
#   tools/add_update_check.sh APP UPDATECHECK_BINARY
set -euo pipefail
root=${0:A:h:h}
app=${1:?app}; bin=${2:?binary}
xpc="$app/Contents/XPCServices/UpdateCheck.xpc"
mkdir -p "$xpc/Contents/MacOS"
cp "$bin" "$xpc/Contents/MacOS/UpdateCheck"
strip -x "$xpc/Contents/MacOS/UpdateCheck"
cp "$root/Resources/UpdateCheck-Info.plist" "$xpc/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $build" "$xpc/Contents/Info.plist"
xattr -cr "$xpc"
codesign --force --options runtime --entitlements "$root/Resources/UpdateCheck.entitlements" --sign - "$xpc"
