#!/bin/bash
set -euo pipefail

root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$root/Resources/Info.plist")"
if [[ -n "${GITHUB_REF_NAME:-}" && "${GITHUB_REF_TYPE:-}" == tag && "$GITHUB_REF_NAME" != "v$version" ]]; then
    echo "Git tag does not match CFBundleShortVersionString (v$version)." >&2
    exit 1
fi
"$root/scripts/build.sh" --universal
dist="$root/dist"
mkdir -p "$dist"
archive="Hold-to-Dictate-v$version-macOS-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$root/build/Hold to Dictate.app" "$dist/$archive"
(cd "$dist" && shasum -a 256 "$archive" > "$archive.sha256")
echo "$dist/$archive"
