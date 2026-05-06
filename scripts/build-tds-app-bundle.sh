#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${CONFIGURATION:-debug}"
OUTPUT_APP="${1:-build-cache/TDS.app}"
VERSION="${TDS_VERSION:-$(cat VERSION 2>/dev/null || echo 0.1.0-alpha.1)}"
BUNDLE_SHORT_VERSION="${TDS_BUNDLE_SHORT_VERSION:-${VERSION%%-*}}"
if [[ -n "${TDS_BUNDLE_BUILD_NUMBER:-}" ]]; then
  BUNDLE_BUILD_NUMBER="$TDS_BUNDLE_BUILD_NUMBER"
elif [[ "$VERSION" =~ alpha\.([0-9]+)$ ]]; then
  BUNDLE_BUILD_NUMBER="${BASH_REMATCH[1]}"
else
  BUNDLE_BUILD_NUMBER="1"
fi
APP_ICON="${TDS_APP_ICON:-Sources/TalosDeployApp/Resources/tds.icns}"
APP_ICON_CATALOG="${TDS_APP_ICON_CATALOG:-Packaging/AppIcon.xcassets}"
APP_EXECUTABLE_NAME="${TDS_APP_EXECUTABLE_NAME:-TDS}"
APP_BUNDLE_IDENTIFIER="${TDS_BUNDLE_IDENTIFIER:-com.aedan.tds.desktop}"
APP_NAME="${TDS_APP_NAME:-TDS}"
APP_DISPLAY_NAME="${TDS_APP_DISPLAY_NAME:-$APP_NAME}"

swift build --product tds-app -c "$CONFIGURATION"

BIN_DIR=".build/$CONFIGURATION"
EXECUTABLE="$BIN_DIR/tds-app"
if [[ ! -x "$EXECUTABLE" ]]; then
  echo "error: built executable not found: $EXECUTABLE" >&2
  exit 1
fi

rm -rf "$OUTPUT_APP"
mkdir -p "$OUTPUT_APP/Contents/MacOS" "$OUTPUT_APP/Contents/Resources"
cp "$EXECUTABLE" "$OUTPUT_APP/Contents/MacOS/$APP_EXECUTABLE_NAME"
printf 'APPL????' >"$OUTPUT_APP/Contents/PkgInfo"
for bundle in "$BIN_DIR"/TDS_*.bundle; do
  [[ -e "$bundle" ]] || continue
  cp -R "$bundle" "$OUTPUT_APP/Contents/Resources/"
done
if [[ -d "$APP_ICON_CATALOG" ]] && command -v xcrun >/dev/null 2>&1 && xcrun --find actool >/dev/null 2>&1; then
  ACTOOL_PARTIAL="$(mktemp -t tds-actool-partial).plist"
  xcrun actool "$APP_ICON_CATALOG" \
    --compile "$OUTPUT_APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ACTOOL_PARTIAL" >/dev/null
  rm -f "$ACTOOL_PARTIAL"
fi
if [[ -f "$APP_ICON" ]]; then
  cp "$APP_ICON" "$OUTPUT_APP/Contents/Resources/AppIcon.icns"
  cp "$APP_ICON" "$OUTPUT_APP/Contents/Resources/tds.icns"
fi

cat >"$OUTPUT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>__APP_EXECUTABLE_NAME__</string>
  <key>CFBundleIdentifier</key>
  <string>__APP_BUNDLE_IDENTIFIER__</string>
  <key>CFBundleName</key>
  <string>__APP_NAME__</string>
  <key>CFBundleDisplayName</key>
  <string>__APP_DISPLAY_NAME__</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleSignature</key>
  <string>????</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>__BUNDLE_SHORT_VERSION__</string>
  <key>CFBundleVersion</key>
  <string>__BUNDLE_BUILD_NUMBER__</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key>
  <true/>
  <key>NSSupportsSuddenTermination</key>
  <true/>
</dict>
</plist>
PLIST

python3 - "$OUTPUT_APP/Contents/Info.plist" "$BUNDLE_SHORT_VERSION" "$BUNDLE_BUILD_NUMBER" "$APP_EXECUTABLE_NAME" "$APP_BUNDLE_IDENTIFIER" "$APP_NAME" "$APP_DISPLAY_NAME" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace("__BUNDLE_SHORT_VERSION__", sys.argv[2])
text = text.replace("__BUNDLE_BUILD_NUMBER__", sys.argv[3])
text = text.replace("__APP_EXECUTABLE_NAME__", sys.argv[4])
text = text.replace("__APP_BUNDLE_IDENTIFIER__", sys.argv[5])
text = text.replace("__APP_NAME__", sys.argv[6])
text = text.replace("__APP_DISPLAY_NAME__", sys.argv[7])
path.write_text(text)
PY

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$OUTPUT_APP" >/dev/null
fi

echo "Built $OUTPUT_APP"
