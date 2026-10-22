#!/usr/bin/env bash
# Draws the app icon (scripts/icon.swift) at every size macOS wants and packs it into Resources/AppIcon.icns.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O "$ROOT/scripts/icon.swift" -o "$WORK/icon"
mkdir -p "$WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
  "$WORK/icon" "$size" "$WORK/AppIcon.iconset/icon_${size}x${size}.png"
  "$WORK/icon" "$((size * 2))" "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
echo "Wrote Resources/AppIcon.icns"
