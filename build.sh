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

SCRCPY_VERSION="5.0.1"
SCRCPY_SHA256="33611e51977a8289e2e124b220f727895181ef2eb9060e0987a4dc2db9cf0d6b"
SCRCPY_DIR="scrcpy-macos-aarch64-v$SCRCPY_VERSION"
SCRCPY_TAR="vendor/$SCRCPY_DIR.tar.gz"
SCRCPY_URL="https://github.com/Genymobile/scrcpy/releases/download/v$SCRCPY_VERSION/$SCRCPY_DIR.tar.gz"

sha_ok() { [ -f "$1" ] && [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$SCRCPY_SHA256" ]; }

mkdir -p vendor
if ! sha_ok "$SCRCPY_TAR" || [ ! -x "vendor/$SCRCPY_DIR/scrcpy" ]; then
  if ! sha_ok "$SCRCPY_TAR"; then
    echo "Downloading scrcpy v$SCRCPY_VERSION..."
    curl -fL --retry 3 --progress-bar -o "$SCRCPY_TAR.part" "$SCRCPY_URL"
    mv "$SCRCPY_TAR.part" "$SCRCPY_TAR"
    if ! sha_ok "$SCRCPY_TAR"; then
      rm -f "$SCRCPY_TAR"
      echo "error: scrcpy SHA256 mismatch, refusing to build" >&2
      exit 1
    fi
  fi
  rm -rf "vendor/$SCRCPY_DIR"
  tar -xzf "$SCRCPY_TAR" -C vendor
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -framework AVFoundation -framework CoreMediaIO -framework CoreImage \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/DeviceMirror"

cp Info.plist "$APP/Contents/Info.plist"

# Android tools. Mach-O files go in Helpers (not Resources) so codesign accepts them.
mkdir -p "$APP/Contents/Helpers"
cp -R "vendor/$SCRCPY_DIR" "$APP/Contents/Helpers/scrcpy"
rm -f "$APP"/Contents/Helpers/scrcpy/*.png "$APP"/Contents/Helpers/scrcpy/scrcpy.1  # unused icons/man page
# Non-code files live in Resources (loose files in Helpers fail codesign); scrcpy is pointed at the server via SCRCPY_SERVER_PATH.
mkdir -p "$APP/Contents/Resources/scrcpy"
mv "$APP/Contents/Helpers/scrcpy/scrcpy-server" "$APP/Contents/Helpers/scrcpy/LICENSE" "$APP/Contents/Resources/scrcpy/"
xattr -cr "$APP/Contents/Helpers" 2>/dev/null || true

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

# Sign nested binaries first, then the app.
for bin in "$APP/Contents/Helpers/scrcpy/scrcpy" "$APP/Contents/Helpers/scrcpy/adb"; do
  codesign --force --sign - "$bin" >/dev/null
done
codesign --force --sign - "$APP" >/dev/null
codesign --verify --strict "$APP"
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
