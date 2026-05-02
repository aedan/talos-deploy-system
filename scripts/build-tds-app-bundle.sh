#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${CONFIGURATION:-debug}"
OUTPUT_APP="${1:-build-cache/tds.app}"

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
done

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
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "Built $OUTPUT_APP"
