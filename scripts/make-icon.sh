#!/bin/bash
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift (drawn in code, no assets).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="${TMPDIR:-/tmp}/notebar-icon.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/make-icon" scripts/make-icon.swift -framework AppKit 2>&1 | grep -v "search path" || true
"$WORK/make-icon" "$WORK/AppIcon.iconset"
iconutil -c icns -o Resources/AppIcon.icns "$WORK/AppIcon.iconset"
echo "Wrote Resources/AppIcon.icns"
