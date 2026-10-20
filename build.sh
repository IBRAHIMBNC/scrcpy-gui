#!/usr/bin/env bash
# Builds "Device Mirror.app" with swiftc (no Xcode project needed).
#   ./build.sh            -> build/Device Mirror.app
#   ./build.sh --install  -> also copies it to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Device Mirror"
APP="build/$APP_NAME.app"
ICON_SRC="${ICON_SRC:-Resources/AppIcon.png}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -framework AVFoundation -framework CoreMediaIO -framework CoreImage \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/DeviceMirror"

cp Info.plist "$APP/Contents/Info.plist"

if [ -f "$ICON_SRC" ]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  cp -R "$APP" "$INSTALL_DIR/"
  # Make Finder/Dock pick up the new icon instead of a cached one.
  touch "$INSTALL_DIR/$APP_NAME.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR/$APP_NAME.app" || true
  echo "Installed to $INSTALL_DIR/$APP_NAME.app"
fi
