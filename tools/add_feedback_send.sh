#!/bin/zsh
# Puts the FeedbackSend service into an app and signs it (build.sh, release.sh, Tests/updates/run.sh).
# The app itself must be signed after this.
#
#   tools/add_feedback_send.sh APP FEEDBACKSEND_BINARY
set -euo pipefail
root=${0:A:h:h}
app=${1:?app}; bin=${2:?binary}
xpc="$app/Contents/XPCServices/FeedbackSend.xpc"
mkdir -p "$xpc/Contents/MacOS"
cp "$bin" "$xpc/Contents/MacOS/FeedbackSend"
strip -x "$xpc/Contents/MacOS/FeedbackSend"
cp "$root/Resources/FeedbackSend-Info.plist" "$xpc/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $build" "$xpc/Contents/Info.plist"
xattr -cr "$xpc"
codesign --force --options runtime --entitlements "$root/Resources/FeedbackSend.entitlements" --sign - "$xpc"
