#!/usr/bin/env bash
#
# Builds Speakit.app from the Swift package and ad-hoc signs it.
# Run on macOS 14+ with Xcode (or Command Line Tools) installed:
#
#   ./scripts/build-app.sh
#   open build/Speakit.app
#
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Building release binary…"
swift build -c release

APP="build/Speakit.app"
BINARY="$(swift build -c release --show-bin-path)/Speakit"

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Speakit"
cp Support/Info.plist "$APP/Contents/Info.plist"

echo "==> Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP"
echo "    Move it to /Applications or run: open $APP"
