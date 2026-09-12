#!/usr/bin/env bash
set -euo pipefail

# Builds only public renderer source. Wallpaper Engine/Workshop assets are
# supplied locally by the user and never downloaded or packaged here.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/Scripts/scene-renderer.env"
BUILD_ROOT="$ROOT/.build/external-scene-renderer"
SOURCE_DIR="$BUILD_ROOT/source"
BUILD_DIR="$BUILD_ROOT/build"
DESTINATION="$ROOT/ExternalRenderers"
mkdir -p "$BUILD_ROOT" "$DESTINATION"
if [ ! -d "$SOURCE_DIR/.git" ]; then
  git clone --no-checkout "$PINNED_SCENE_RENDERER_SOURCE_URL" "$SOURCE_DIR"
fi
git -C "$SOURCE_DIR" fetch origin "$PINNED_SCENE_RENDERER_SOURCE_REF"
git -C "$SOURCE_DIR" checkout --detach "$PINNED_SCENE_RENDERER_SOURCE_REF"
git -C "$SOURCE_DIR" submodule update --init --recursive --depth 1
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DWPENGINE_SCENE_ONLY=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build "$BUILD_DIR" --parallel 4
cp "$BUILD_DIR/output/wwb-scene-renderer" "$DESTINATION/"
cp "$BUILD_DIR/output/liblinux-wallpaperengine-lib.dylib" "$DESTINATION/"
cp -L "$BUILD_DIR/lib/libkissfft-float.131.dylib" "$DESTINATION/libkissfft-float.131.dylib"
# Local build libraries travel together. Homebrew runtime libraries remain
# external and are listed in the README's scene setup instructions.
for binary in "$DESTINATION/wwb-scene-renderer" "$DESTINATION/liblinux-wallpaperengine-lib.dylib"; do
  install_name_tool -change '@rpath/liblinux-wallpaperengine-lib.dylib' '@loader_path/liblinux-wallpaperengine-lib.dylib' "$binary"
  install_name_tool -change '@rpath/libkissfft-float.131.dylib' '@loader_path/libkissfft-float.131.dylib' "$binary"
done
mkdir -p "$DESTINATION/Licenses"
cp "$SOURCE_DIR/LICENSE" "$DESTINATION/Licenses/Renderer-GPL-3.0.txt"
for component in kissfft quickjs json glslang-WallpaperEngine SPIRV-Cross-WallpaperEngine stb argparse MimeTypes; do
  for notice in "$SOURCE_DIR/src/External/$component"/LICENSE* "$SOURCE_DIR/src/External/$component"/COPYING; do
    if [ -f "$notice" ]; then
      cp "$notice" "$DESTINATION/Licenses/$component-$(basename "$notice")"
    fi
  done
done
printf '%s\n' "$PINNED_SCENE_RENDERER_SOURCE_REF" > "$DESTINATION/source-ref.txt"
codesign --force --sign - "$DESTINATION/libkissfft-float.131.dylib"
codesign --force --sign - "$DESTINATION/liblinux-wallpaperengine-lib.dylib"
codesign --force --sign - "$DESTINATION/wwb-scene-renderer"
"$DESTINATION/wwb-scene-renderer" --help >/dev/null
