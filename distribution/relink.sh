#!/bin/zsh
# Relinks Rondelle against a version of LAME, modified or not, as LAME's LGPL licence provides.
# Needs Xcode or the Command Line Tools (xcode-select --install).
#
#   ./relink.sh LAME_SOURCE_FOLDER /path/to/a/copy/of/Rondelle.app
#
# The LAME folder is the «LAME-source» one (or a modified version of it, with the same files).
# The Rondelle executable in the given copy is replaced and the app is signed again (ad hoc).
set -euo pipefail
here=${0:A:h}
src=${1:?LAME source folder}; src=${src:A}
app=${2:?copy of Rondelle.app}; app=${app:A}
[[ -f "$app/Contents/MacOS/Rondelle" ]] || { echo "$app doesn't look like Rondelle.app" >&2; exit 1; }
work=$(mktemp -d)
for arch in arm64 x86_64; do
    objs=()
    for c in "$src"/*.c; do
        o="$work/$arch-${c:t:r}.o"
        xcrun clang -c -O2 -w -arch $arch -mmacosx-version-min=13.0 -DHAVE_CONFIG_H -I"$src" -I"$src/include" "$c" -o "$o"
        objs+=("$o")
    done
    xcrun swiftc -target $arch-apple-macos13 "$here/Rondelle-$arch.o" "${objs[@]}" -o "$work/Rondelle-$arch"
done
lipo -create "$work/Rondelle-arm64" "$work/Rondelle-x86_64" -output "$app/Contents/MacOS/Rondelle"
codesign --force --options runtime --entitlements "$here/Rondelle.entitlements" --sign - "$app"
rm -rf "${work:?}"
echo "Relinked: $app"
