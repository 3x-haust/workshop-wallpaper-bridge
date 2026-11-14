#!/usr/bin/env bash
# Compiles the macOS 26+ system wallpaper extension's executable.
# Usage: build-wallpaper-extension.sh <output executable path>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/NativeWallpaperExtension"
OUTPUT="${1:?usage: build-wallpaper-extension.sh <output executable path>}"
mkdir -p "$(dirname "$OUTPUT")"

# The extension's code needs Swift 6.2+ (Xcode 26). A runner whose default Xcode is
# older sets WALLPAPER_EXTENSION_DEVELOPER_DIR to a newer one, for this build only.
if [ -n "${WALLPAPER_EXTENSION_DEVELOPER_DIR:-}" ]; then
  export DEVELOPER_DIR="$WALLPAPER_EXTENSION_DEVELOPER_DIR"
fi
xcrun swiftc --version 2>&1 | head -1

# The entry point must be ExtensionKit's: with Swift's own main the extension traps
# before ExtensionMain is set up.
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 -O -application-extension \
  -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -u -Xlinker _main \
  -Xlinker -rpath -Xlinker @executable_path/../../../../Frameworks \
  -import-objc-header "$SOURCE/Extension/WallpaperExtension-Bridging-Header.h" \
  -module-name WorkshopWallpaperBridgeWallpaper \
  "$SOURCE"/Extension/*.swift \
  $(find "$SOURCE/Shared" -name '*.swift' | sort) \
  -o "$OUTPUT"
