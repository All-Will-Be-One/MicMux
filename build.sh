#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
CONFIGURATION="release"

if [[ "${1:-}" == "--debug" ]]; then
    CONFIGURATION="debug"
fi

cd "$PROJECT_DIR"
swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="$PROJECT_DIR/build/MicMux.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/MicMux" "$APP_DIR/Contents/MacOS/MicMux"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

SIGNING_IDENTITY="${MICMUX_SIGNING_IDENTITY:--}"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR"

echo "$APP_DIR"

if [[ "${1:-}" == "--run" || "${2:-}" == "--run" ]]; then
    open "$APP_DIR"
fi
