#!/usr/bin/env bash
set -euo pipefail

VERSION="${TDS_VERSION:-$(cat VERSION)}"
CONFIGURATION="${CONFIGURATION:-release}"
RELEASE_DIR="${RELEASE_DIR:-build-cache/release}"
APP_PATH="build-cache/tds.app"
CLI_PATH=".build/$CONFIGURATION/tds"
CLI_STAGE="build-cache/tds-cli"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

CONFIGURATION="$CONFIGURATION" scripts/build-tds-app-bundle.sh "$APP_PATH"
swift build --product tds -c "$CONFIGURATION"

rm -rf "$CLI_STAGE"
mkdir -p "$CLI_STAGE"
cp "$CLI_PATH" "$CLI_STAGE/tds"
for bundle in ".build/$CONFIGURATION"/TDS_*.bundle; do
  [[ -e "$bundle" ]] || continue
  cp -R "$bundle" "$CLI_STAGE/"
done

ditto -c -k --keepParent "$APP_PATH" "$RELEASE_DIR/tds-app-$VERSION-macos.zip"
ditto -c -k "$CLI_STAGE" "$RELEASE_DIR/tds-cli-$VERSION-macos.zip"

(
  cd "$RELEASE_DIR"
  shasum -a 256 "tds-app-$VERSION-macos.zip" "tds-cli-$VERSION-macos.zip" > "tds-$VERSION-sha256.txt"
)

echo "Packaged release artifacts in $RELEASE_DIR"
