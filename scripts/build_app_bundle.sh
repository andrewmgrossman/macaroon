#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="debug"

if [[ "${1:-}" == "--release" ]]; then
  CONFIGURATION="release"
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
export SWIFTPM_ENABLE_PLUGINS="${SWIFTPM_ENABLE_PLUGINS:-0}"

swift build --package-path "$ROOT_DIR" --configuration "$CONFIGURATION"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" --configuration "$CONFIGURATION" --show-bin-path)"

APP_NAME="Macaroon"
APP_DIR="$ROOT_DIR/builds/${APP_NAME}.app"
STAGING_DIR="$ROOT_DIR/builds/.${APP_NAME}.app.staging"
EXECUTABLE_PATH="$BIN_DIR/$APP_NAME"
RESOURCE_BUNDLE_PATH="$BIN_DIR/${APP_NAME}_Macaroon.bundle"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Missing executable at $EXECUTABLE_PATH" >&2
  exit 1
fi

if [[ ! -d "$RESOURCE_BUNDLE_PATH" ]]; then
  echo "Missing resource bundle at $RESOURCE_BUNDLE_PATH" >&2
  exit 1
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/Contents/MacOS" "$STAGING_DIR/Contents/Resources" "$ROOT_DIR/builds"

cp "$EXECUTABLE_PATH" "$STAGING_DIR/Contents/MacOS/$APP_NAME"
cp -R "$RESOURCE_BUNDLE_PATH" "$STAGING_DIR/${APP_NAME}_Macaroon.bundle"

cat > "$STAGING_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Macaroon</string>
  <key>CFBundleIdentifier</key>
  <string>com.andrewmg.macaroon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Macaroon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$STAGING_DIR/Contents/PkgInfo"

rm -rf "$APP_DIR"
mv "$STAGING_DIR" "$APP_DIR"

echo "Built $APP_DIR"
