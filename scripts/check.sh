#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo "Проверки поддерживаются только на macOS." >&2; exit 1; }
mkdir -p "$root/build/module-cache"
binary="$(mktemp "$root/build/.check.XXXXXXXX")"
trap 'rm -f -- "$binary"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$root/build/module-cache" \
    "$root/Sources/Settings.swift" "$root/Sources/Microphone.swift" \
    "$root/Sources/Transcription.swift" "$root/Tests/Smoke.swift" -o "$binary"
"$binary"
