#!/bin/bash
set -euo pipefail

root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo "Сборка поддерживается только на macOS." >&2; exit 1; }
product="$root/build/Hold to Dictate.app"
architecture="$(uname -m)"
if [[ "${1:-}" == "--universal" ]]; then
    architecture=universal
    shift
fi
if [[ $# != 0 ]]; then
    echo "Usage: scripts/build.sh [--universal]" >&2
    exit 2
fi

mkdir -p "$root/build"
scratch="$(mktemp -d "$root/build/.build.XXXXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
app="$scratch/Hold to Dictate.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/settings.json" "$app/Contents/Resources/settings.json"
cp -R "$root/Resources/clipboard-agent" "$app/Contents/Resources/"

compile() {
    xcrun swiftc -swift-version 5 -module-cache-path "$root/build/module-cache" -O -target "$1-apple-macos13.0" \
        -sdk "$(xcrun --sdk macosx --show-sdk-path)" "$root"/Sources/*.swift \
        -o "$2"
}

binary="$app/Contents/MacOS/HoldToDictate"
if [[ "$architecture" == universal ]]; then
    compile arm64 "$scratch/arm64"
    compile x86_64 "$scratch/x86_64"
    xcrun lipo -create "$scratch/arm64" "$scratch/x86_64" -output "$binary"
else
    compile "$architecture" "$binary"
fi
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
mkdir -p "$product"
ditto "$app" "$product"
codesign --verify --strict "$product"
echo "$product"
