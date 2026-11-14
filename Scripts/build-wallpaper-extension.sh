#!/usr/bin/env bash
# Compiles the macOS 26+ system wallpaper extension's executable.
# Usage: build-wallpaper-extension.sh <output executable path>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/NativeWallpaperExtension"
OUTPUT="${1:?usage: build-wallpaper-extension.sh <output executable path>}"
mkdir -p "$(dirname "$OUTPUT")"

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
