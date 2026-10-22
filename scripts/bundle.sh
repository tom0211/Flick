#!/usr/bin/env bash
# Builds Flick and wraps it in build/Flick.app.
#
#   CONFIG=debug scripts/bundle.sh                      debug build
#   CODESIGN_IDENTITY="Apple Development: …" scripts/bundle.sh
#
# macOS ties Accessibility and Screen Recording approval to the code signature. By default this signs with the
# "Flick Local Signing" identity from scripts/make-signing-identity.sh, so approval survives rebuilds. Without that
# identity it falls back to ad-hoc signing, which changes with every build and needs re-approval each time.
set -euo pipefail

if [[ -z "${CODESIGN_IDENTITY:-}" ]] && security find-identity -p codesigning | grep -q '"Flick Local Signing"'; then
  CODESIGN_IDENTITY="Flick Local Signing"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/Flick.app"

swift build -c "$CONFIG" --package-path "$ROOT"
BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"

if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  "$ROOT/scripts/make-icon.sh"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Flick" "$APP/Contents/MacOS/Flick"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
