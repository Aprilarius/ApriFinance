#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Build on macOS with Xcode.' >&2; exit 1; }
flutter build macos --release --no-pub
build=$(sed -n 's/^version: [0-9.]*+\([0-9][0-9]*\)$/\1/p' pubspec.yaml)
[[ "$build" =~ ^[0-9]+$ ]]
app='build/macos/Build/Products/Release/ApriFinance.app'
[[ -d "$app" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == 'com.bahadur.personalFinance' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == '1.0.0' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" == "$build" ]]
codesign --verify --deep --strict --verbose=2 "$app"
python3 scripts/check-publication.py --payload "$app"
mkdir -p dist
archs="$(lipo -archs "$app/Contents/MacOS/ApriFinance")"
case "$archs" in
  *arm64*x86_64*|*x86_64*arm64*) platform=universal ;;
  arm64) platform=arm64 ;;
  x86_64) platform=x64 ;;
  *) echo "Unexpected architectures: $archs" >&2; exit 1 ;;
esac
archive="dist/ApriFinance-1.0.0-macOS-$platform-preview.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
shasum -a 256 "$archive" > dist/SHA256SUMS-macOS.txt
printf 'ApriFinance 1.0, build %s\nmacOS 12 or later; %s\nPersonal test build. Ad hoc signature; not notarized by Apple.\nExtract the ZIP and move ApriFinance.app to Applications.\n' "$build" "$archs" > dist/README-macOS.txt
