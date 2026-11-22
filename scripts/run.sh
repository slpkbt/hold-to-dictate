#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
app="$root/build/Hold to Dictate.app"
if [[ ! -x "$app/Contents/MacOS/HoldToDictate" ]]; then
    "$root/scripts/build.sh"
fi
if [[ "${1:-}" == "--preview" && $# == 1 ]]; then
    open -n "$app" --args --preview
elif [[ "${1:-}" == "--preview-clipboard" && $# == 2 && -f "$2" ]]; then
    image="$(cd -- "$(dirname -- "$2")" && pwd)/$(basename -- "$2")"
    open -n "$app" --args --preview-clipboard "$image"
elif [[ $# == 0 ]]; then
    open "$app"
else
    echo "Usage: scripts/run.sh [--preview | --preview-clipboard IMAGE]" >&2
    exit 2
fi
