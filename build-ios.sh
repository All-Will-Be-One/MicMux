#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
IOS_DIR="$PROJECT_DIR/iOS"
MODE="${1:---simulator}"

cd "$IOS_DIR"
xcodegen generate --spec project.yml

if [[ "$MODE" == "--simulator" ]]; then
    xcodebuild \
        -project MicMuxPhone.xcodeproj \
        -scheme MicMuxPhone \
        -sdk iphonesimulator \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath build \
        CODE_SIGNING_ALLOWED=NO \
        build
    echo "$IOS_DIR/build/Build/Products/Debug-iphonesimulator/MicMux Phone.app"
elif [[ "$MODE" == "--device" ]]; then
    xcodebuild \
        -project MicMuxPhone.xcodeproj \
        -scheme MicMuxPhone \
        -sdk iphoneos \
        -destination 'generic/platform=iOS' \
        -derivedDataPath device-build \
        -allowProvisioningUpdates \
        build
    echo "$IOS_DIR/device-build/Build/Products/Debug-iphoneos/MicMux Phone.app"
elif [[ "$MODE" == "--install" && -n "${2:-}" ]]; then
    DEVICE_ID="$2"
    "$PROJECT_DIR/build-ios.sh" --device
    xcrun devicectl device install app \
        --device "$DEVICE_ID" \
        "$IOS_DIR/device-build/Build/Products/Debug-iphoneos/MicMux Phone.app"
else
    echo "usage: ./build-ios.sh [--simulator | --device | --install DEVICE_ID]" >&2
    exit 2
fi
