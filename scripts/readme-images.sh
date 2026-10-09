#!/bin/bash
# Renders the README pictures offscreen and writes them to docs/images/ as WebP
# (light on the left, dark on the right). Needs cwebp (`brew install webp`).
# Uses a new temporary data folder; your real notes are not touched. No window is shown.
# Usage: scripts/readme-images.sh [output-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-docs/images}"
command -v cwebp >/dev/null || { echo "cwebp not found: brew install webp" >&2; exit 1; }
swift build --product NoteBar
WORK="$(mktemp -d "${TMPDIR:-/tmp}/notebar-readme-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/data" "$WORK/png" "$OUT"
NOTEBAR_DATA_DIR="$WORK/data" "$(swift build --show-bin-path)/NoteBar" --readme-images "$WORK/png"
for png in "$WORK"/png/*.png; do
    name="$(basename "$png" .png)"
    # Flat Settings panes are smaller lossless; the panel (gradient backdrop) is smaller lossy.
    case "$name" in
        settings-*) cwebp -quiet -lossless -z 9 "$png" -o "$OUT/$name.webp" ;;
        *)          cwebp -quiet -q 90 -m 6 "$png" -o "$OUT/$name.webp" ;;
    esac
    echo "wrote $OUT/$name.webp"
done
