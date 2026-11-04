#!/bin/bash
# Builds WallParallax.app into ./build. Usage: ./build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/WallParallax"

APP="build/WallParallax.app"
# Assemble and sign outside the project folder: iCloud Drive (e.g. ~/Documents) keeps adding
# Finder metadata to bundles, which makes codesign fail with "resource fork ... not allowed".
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
STAGED="$STAGE/WallParallax.app"
mkdir -p "$STAGED/Contents/MacOS" "$STAGED/Contents/Resources"
cp "$BIN" "$STAGED/Contents/MacOS/WallParallax"
cp Resources/Info.plist "$STAGED/Contents/Info.plist"
xattr -cr "$STAGED"
codesign --force --sign - "$STAGED"

rm -rf "$APP"
mkdir -p build
ditto "$STAGED" "$APP"
codesign --verify "$APP"

echo "Built $APP — run with: open $APP"
