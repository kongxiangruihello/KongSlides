#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]]; then
    echo "KongSlides 需要在 macOS 15 或更新版本上构建。" >&2
    exit 1
fi

swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
bundle="dist/KongSlides.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Helpers"
cp "$binary_dir/KongSlides" "$bundle/Contents/MacOS/KongSlides"
cp "$binary_dir/KongSlidesUpdater" "$bundle/Contents/Helpers/KongSlidesUpdater"
codesign --force --sign - "$bundle/Contents/Helpers/KongSlidesUpdater"
cp Scripts/Info.plist "$bundle/Contents/Info.plist"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
