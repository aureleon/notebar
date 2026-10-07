#!/bin/bash
# Generates AppIcon.icns from scripts/make-icon.swift (drawn in code, no assets).
# Usage: scripts/make-icon.sh [output.icns]   (default: build/AppIcon.icns)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/AppIcon.icns}"
mkdir -p "$(dirname "$OUT")"
WORK="${TMPDIR:-/tmp}/notebar-icon.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/make-icon" scripts/make-icon.swift -framework AppKit 2>&1 | grep -v "search path" || true
"$WORK/make-icon" "$WORK/AppIcon.iconset"
iconutil -c icns -o "$OUT" "$WORK/AppIcon.iconset"
echo "Wrote $OUT"
