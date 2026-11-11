#!/bin/bash
# Usage: ./build.sh            -> builds build/DisplayBar.app
#        ./build.sh install    -> also copies it to ~/Applications and launches it
set -euo pipefail
cd "$(dirname "$0")"

APP=build/DisplayBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 6 \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/DisplayBar"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x DisplayBar 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/DisplayBar.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/DisplayBar.app
  echo "Installed to ~/Applications/DisplayBar.app"
fi
