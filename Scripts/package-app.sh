#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Workshop Wallpaper Bridge"
APP_DIR="$ROOT/dist/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

cd "$ROOT"
swift build -c release
rm -rf "$ROOT/dist"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT/.build/release/WorkshopWallpaperBridge" "$MACOS_DIR/Workshop Wallpaper Bridge"
cp "$ROOT/.build/release/wwbctl" "$MACOS_DIR/wwbctl"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Workshop Wallpaper Bridge</string>
  <key>CFBundleIdentifier</key>
  <string>dev.3xhaust.WorkshopWallpaperBridge</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Workshop Wallpaper Bridge</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.1</string>
  <key>CFBundleVersion</key>
  <string>4</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST
chmod +x "$MACOS_DIR/Workshop Wallpaper Bridge" "$MACOS_DIR/wwbctl"
ditto -c -k --keepParent "$APP_DIR" "$ROOT/dist/WorkshopWallpaperBridge-macOS-arm64.zip"
printf '%s\n' "$ROOT/dist/WorkshopWallpaperBridge-macOS-arm64.zip"
