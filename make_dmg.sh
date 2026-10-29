#!/bin/bash
# Builds the app and wraps it in a drag-to-Applications DMG.
# Usage: ./make_dmg.sh [output-directory]
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.1"
OUT_DIR="${1:-dist}"
APP="$OUT_DIR/Parametric EQ.app"
STAGE=".tmp/dmg-stage"
DMG="$OUT_DIR/ParametricEQ-$VERSION.dmg"

./build.sh
mkdir -p "$OUT_DIR"
rm -rf "$STAGE"
mkdir -p "$STAGE/Documentation"

ditto "$APP" "$STAGE/Parametric EQ.app"
ln -s /Applications "$STAGE/Applications"
cp LICENSE "$STAGE/LICENSE"

# The repository README points at docs/; inside the DMG the assets live in
# Documentation/. Rewrite only those two links for the mounted volume.
sed 's#docs/screenshot.png#Documentation/screenshot.png#g; s#docs/icon.png#Documentation/icon.png#g' \
  README.md > "$STAGE/README.md"

cp CHANGELOG.md "$STAGE/CHANGELOG.md"
cp docs/screenshot.png "$STAGE/Documentation/screenshot.png"
cp docs/icon.png "$STAGE/Documentation/icon.png"

rm -f "$DMG"
hdiutil create -volname "Parametric EQ" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"

echo "▸ Built: $DMG"
shasum -a 256 "$DMG"
