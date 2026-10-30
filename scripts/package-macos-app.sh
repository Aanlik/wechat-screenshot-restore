#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_ROOT="$(cd "$ROOT/.." && pwd)"
BUILD_ROOT="$ROOT/.build/package"
APP="${WSRESTORE_OUTPUT:-$OUT_ROOT/微信截图恢复.app}"
APP_PARENT="$(dirname "$APP")"
APP_NAME="$(basename "$APP")"
PRODUCT="WeChatScreenshotRestoreApp"
STAGE="$APP_PARENT/.$APP_NAME-build-$(/usr/bin/uuidgen).app"
mkdir -p "$BUILD_ROOT" "$STAGE/Contents/MacOS" "$STAGE/Contents/Frameworks" "$STAGE/Contents/Resources"

build_arch() {
  local arch="$1"
  local build_path="$BUILD_ROOT/$arch"
  swift build \
    --package-path "$ROOT" \
    --build-path "$build_path" \
    --configuration release \
    --triple "$arch-apple-macos13.0" \
    --product "$PRODUCT"
  swift build \
    --package-path "$ROOT" \
    --build-path "$build_path" \
    --configuration release \
    --triple "$arch-apple-macos13.0" \
    --product WindowSharingRuntime
  printf '%s\n' "$(swift build --package-path "$ROOT" --build-path "$build_path" --configuration release --triple "$arch-apple-macos13.0" --show-bin-path)"
}

ARM_BIN="$(build_arch arm64 | tail -n 1)"
X86_BIN="$(build_arch x86_64 | tail -n 1)"

/usr/bin/lipo -create \
  "$ARM_BIN/$PRODUCT" "$X86_BIN/$PRODUCT" \
  -output "$STAGE/Contents/MacOS/$PRODUCT"
/usr/bin/lipo -create \
  "$ARM_BIN/libWindowSharingRuntime.dylib" "$X86_BIN/libWindowSharingRuntime.dylib" \
  -output "$STAGE/Contents/Frameworks/libWindowSharingRuntime.dylib"

ICON_SOURCE="$ROOT/Assets/AppIcon-1024.png"
ICONSET="$STAGE/Contents/Resources/AppIcon.iconset"
[[ -r "$ICON_SOURCE" ]] || { echo "Missing app icon source: $ICON_SOURCE" >&2; exit 1; }
mkdir -p "$ICONSET"
make_icon() {
  local size="$1" name="$2"
  /usr/bin/sips -s format png -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/$name" >/dev/null
}
make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png
/usr/bin/iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"
/bin/rm -rf "$ICONSET"

/bin/cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>WeChatScreenshotRestoreApp</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundleIdentifier</key><string>com.codex.wechat-screenshot-restore</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>微信截图恢复</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$STAGE/Contents/Info.plist"

/usr/bin/codesign --force --deep --sign - "$STAGE"
/usr/bin/codesign --verify --deep --strict "$STAGE"
/usr/bin/lipo -archs "$STAGE/Contents/MacOS/$PRODUCT"
/usr/bin/lipo -archs "$STAGE/Contents/Frameworks/libWindowSharingRuntime.dylib"
if [[ -e "$APP" ]]; then
  PREVIOUS="$APP_PARENT/.$APP_NAME-previous-$(/usr/bin/uuidgen).app"
  /bin/mv "$APP" "$PREVIOUS"
fi
if ! /bin/mv "$STAGE" "$APP"; then
  if [[ -n "${PREVIOUS:-}" && -e "$PREVIOUS" ]]; then
    /bin/mv "$PREVIOUS" "$APP"
  fi
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$APP"
printf 'Packaged %s\n' "$APP"
