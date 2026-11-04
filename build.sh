#!/bin/bash
# Builds WallParallax.app into ./build. Usage: ./build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/WallParallax"

APP="build/WallParallax.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WallParallax"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP — run with: open $APP"
