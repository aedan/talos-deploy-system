#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${CONFIGURATION:-debug}"
OUTPUT_APP="${1:-build-cache/tds.app}"
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

swift build --product tds-app -c "$CONFIGURATION"

BIN_DIR=".build/$CONFIGURATION"
EXECUTABLE="$BIN_DIR/tds-app"
if [[ ! -x "$EXECUTABLE" ]]; then
  echo "error: built executable not found: $EXECUTABLE" >&2
  exit 1
fi

rm -rf "$OUTPUT_APP"
mkdir -p "$OUTPUT_APP/Contents/MacOS" "$OUTPUT_APP/Contents/Resources"
cp "$EXECUTABLE" "$OUTPUT_APP/Contents/MacOS/tds"
for bundle in "$BIN_DIR"/TDS_*.bundle; do
  [[ -e "$bundle" ]] || continue
  cp -R "$bundle" "$OUTPUT_APP/Contents/Resources/"
  cp -R "$bundle" "$OUTPUT_APP/"
done
if [[ -f "$APP_ICON" ]]; then
  cp "$APP_ICON" "$OUTPUT_APP/Contents/Resources/tds.icns"
fi

cat >"$OUTPUT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>tds</string>
  <key>CFBundleIdentifier</key>
  <string>com.aedan.tds</string>
  <key>CFBundleName</key>
  <string>tds</string>
  <key>CFBundleDisplayName</key>
  <string>tds</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>tds</string>
  <key>CFBundleIconName</key>
  <string>tds</string>
  <key>CFBundleIcons</key>
  <dict>
    <key>CFBundlePrimaryIcon</key>
    <dict>
      <key>CFBundleIconFiles</key>
      <array>
        <string>tds</string>
      </array>
      <key>CFBundleIconName</key>
      <string>tds</string>
    </dict>
  </dict>
  <key>CFBundleShortVersionString</key>
  <string>__BUNDLE_SHORT_VERSION__</string>
  <key>CFBundleVersion</key>
  <string>__BUNDLE_BUILD_NUMBER__</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

python3 - "$OUTPUT_APP/Contents/Info.plist" "$BUNDLE_SHORT_VERSION" "$BUNDLE_BUILD_NUMBER" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace("__BUNDLE_SHORT_VERSION__", sys.argv[2])
text = text.replace("__BUNDLE_BUILD_NUMBER__", sys.argv[3])
path.write_text(text)
PY

echo "Built $OUTPUT_APP"
