#!/usr/bin/env bash
set -euo pipefail

VERSION="${TDS_VERSION:-$(cat VERSION)}"
CONFIGURATION="${CONFIGURATION:-release}"
RELEASE_DIR="${RELEASE_DIR:-build-cache/release}"
APP_PATH="build-cache/tds.app"
CLI_PATH=".build/$CONFIGURATION/tds"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

CONFIGURATION="$CONFIGURATION" scripts/build-tds-app-bundle.sh "$APP_PATH"
swift build --product tds -c "$CONFIGURATION"

ditto -c -k --keepParent "$APP_PATH" "$RELEASE_DIR/tds-app-$VERSION-macos.zip"
ditto -c -k "$CLI_PATH" "$RELEASE_DIR/tds-cli-$VERSION-macos.zip"

(
  cd "$RELEASE_DIR"
  shasum -a 256 "tds-app-$VERSION-macos.zip" "tds-cli-$VERSION-macos.zip" > "tds-$VERSION-sha256.txt"
)

echo "Packaged release artifacts in $RELEASE_DIR"
