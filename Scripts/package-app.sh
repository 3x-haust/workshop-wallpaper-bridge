#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Workshop Wallpaper Bridge"
APP_DIR="$ROOT/dist/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
SAVER_NAME="Workshop Wallpaper Bridge"
SAVER_DIR="$RESOURCES_DIR/$SAVER_NAME.saver"
SAVER_MACOS_DIR="$SAVER_DIR/Contents/MacOS"
SAVER_EXECUTABLE="Workshop Wallpaper Bridge Lock Screen"
DMG_PATH="$ROOT/dist/WorkshopWallpaperBridge-macOS-arm64.dmg"
APP_VERSION="${APP_VERSION:-1.1.3}"
BUNDLE_VERSION="${BUNDLE_VERSION:-10}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
REQUIRE_SIGNING="${REQUIRE_SIGNING:-0}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"
DMG_STAGING=""
DMG_VERIFY_DIR=""
DMG_VERIFY_MOUNT=""

cleanup() {
  if [ -n "$DMG_VERIFY_MOUNT" ] && mount | grep -q "on $DMG_VERIFY_MOUNT "; then
    hdiutil detach "$DMG_VERIFY_MOUNT" >/dev/null 2>&1 || true
  fi
  if [ -n "$DMG_VERIFY_DIR" ] && [ -d "$DMG_VERIFY_DIR" ]; then
    rm -rf "$DMG_VERIFY_DIR"
  fi
  if [ -n "$DMG_STAGING" ] && [ -d "$DMG_STAGING" ]; then
    rm -rf "$DMG_STAGING"
  fi
}
trap cleanup EXIT

require_notarization_inputs() {
  if [ "$REQUIRE_NOTARIZATION" = "1" ] && [ -z "$NOTARY_PROFILE" ]; then
    printf '%s\n' "NOTARY_PROFILE is required when REQUIRE_NOTARIZATION=1." >&2
    exit 1
  fi

  if [ -n "$NOTARY_PROFILE" ] && [ -z "$SIGN_IDENTITY" ]; then
    printf '%s\n' "NOTARY_PROFILE requires SIGN_IDENTITY because Apple notarization needs a signed app." >&2
    exit 1
  fi
}

strip_quarantine_metadata() {
  local path
  local xattrs

  for path in "$@"; do
    if ! xattrs="$(xattr -lr "$path" 2>/dev/null)"; then
      printf '%s\n' "failed to read extended attributes from $path" >&2
      exit 1
    fi

    if grep -q 'com\.apple\.quarantine' <<<"$xattrs"; then
      xattr -r -d com.apple.quarantine "$path"
    fi
  done
}

assert_no_quarantine_metadata() {
  local path="$1"
  local xattrs

  if ! xattrs="$(xattr -lr "$path" 2>/dev/null)"; then
    printf '%s\n' "failed to read extended attributes from $path" >&2
    exit 1
  fi

  if grep -q 'com\.apple\.quarantine' <<<"$xattrs"; then
    printf '%s\n' "quarantine metadata remains in $path; refusing to package a release artifact that asks users to run xattr manually." >&2
    exit 1
  fi
}

verify_gatekeeper_accepts_quarantined_app_from_dmg() {
  local mounted_app
  local copied_app
  local quarantine_stamp

  DMG_VERIFY_DIR="$(mktemp -d)"
  DMG_VERIFY_MOUNT="$DMG_VERIFY_DIR/mount"
  mkdir -p "$DMG_VERIFY_MOUNT"

  hdiutil attach \
    -nobrowse \
    -readonly \
    -mountpoint "$DMG_VERIFY_MOUNT" \
    "$DMG_PATH" >/dev/null

  mounted_app="$DMG_VERIFY_MOUNT/$APP_NAME.app"
  copied_app="$DMG_VERIFY_DIR/$APP_NAME.app"
  if [ ! -d "$mounted_app" ]; then
    printf '%s\n' "notarized DMG does not contain $APP_NAME.app." >&2
    exit 1
  fi

  cp -R "$mounted_app" "$copied_app"
  hdiutil detach "$DMG_VERIFY_MOUNT" >/dev/null
  DMG_VERIFY_MOUNT=""

  quarantine_stamp="$(printf '%x' "$(date +%s)")"
  xattr -w com.apple.quarantine "0081;${quarantine_stamp};WorkshopWallpaperBridge;https://github.com/3x-haust/workshop-wallpaper-bridge" "$copied_app"
  spctl --assess --type execute --verbose=4 "$copied_app"
}

require_notarization_inputs
cd "$ROOT"
swift build -c release
rm -rf "$ROOT/dist"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$SAVER_MACOS_DIR"
cp "$ROOT/.build/release/WorkshopWallpaperBridge" "$MACOS_DIR/Workshop Wallpaper Bridge"
cp "$ROOT/.build/release/wwbctl" "$MACOS_DIR/wwbctl"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
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
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUNDLE_VERSION}</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST
cat > "$SAVER_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${SAVER_EXECUTABLE}</string>
  <key>CFBundleIdentifier</key>
  <string>dev.3xhaust.WorkshopWallpaperBridge.LockScreenSaver</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Workshop Wallpaper Bridge</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUNDLE_VERSION}</string>
  <key>NSPrincipalClass</key>
  <string>WorkshopWallpaperLockScreenSaverView</string>
</dict>
</plist>
PLIST
clang \
  -fobjc-arc \
  -bundle \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework QuartzCore \
  -framework ScreenSaver \
  "$ROOT/Sources/WorkshopWallpaperLockScreenSaver/WorkshopWallpaperLockScreenSaverView.m" \
  -o "$SAVER_MACOS_DIR/$SAVER_EXECUTABLE"
chmod +x "$MACOS_DIR/Workshop Wallpaper Bridge" "$MACOS_DIR/wwbctl"
chmod +x "$SAVER_MACOS_DIR/$SAVER_EXECUTABLE"
strip_quarantine_metadata "$APP_DIR"
assert_no_quarantine_metadata "$APP_DIR"
if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$MACOS_DIR/wwbctl"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$MACOS_DIR/Workshop Wallpaper Bridge"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SAVER_DIR"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
  codesign --verify --strict --verbose=2 "$APP_DIR"
elif [ "$REQUIRE_SIGNING" = "1" ]; then
  printf '%s\n' "SIGN_IDENTITY is required when REQUIRE_SIGNING=1." >&2
  exit 1
else
  printf '%s\n' "warning: building an unsigned app; set SIGN_IDENTITY for Developer ID distribution." >&2
fi
DMG_STAGING="$(mktemp -d)"
cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
strip_quarantine_metadata "$DMG_STAGING/$APP_NAME.app"
assert_no_quarantine_metadata "$DMG_STAGING/$APP_NAME.app"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null
strip_quarantine_metadata "$DMG_PATH"
assert_no_quarantine_metadata "$DMG_PATH"
if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi
if [ -n "$NOTARY_PROFILE" ]; then
  notary_args=(--keychain-profile "$NOTARY_PROFILE")
  if [ -n "$NOTARY_KEYCHAIN" ]; then
    notary_args+=(--keychain "$NOTARY_KEYCHAIN")
  fi
  xcrun notarytool submit "$DMG_PATH" "${notary_args[@]}" --wait
  xcrun stapler staple "$DMG_PATH"
  spctl -a -vv --type open "$DMG_PATH"
  verify_gatekeeper_accepts_quarantined_app_from_dmg
fi
printf '%s\n' "$DMG_PATH"
