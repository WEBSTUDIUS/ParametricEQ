#!/bin/bash
# Builds the app and copies it to /Applications (or ~/Applications when the
# system location is not writable), then launches it. Documentation is kept
# next to the .app, never inside the signed bundle.
set -euo pipefail
cd "$(dirname "$0")"

DEST="${1:-/Applications}"
if ! mkdir -p "$DEST" 2>/dev/null || [[ ! -w "$DEST" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  echo "▸ /Applications is not writable; installing to $DEST instead."
fi

./build.sh

rm -rf "$DEST/Parametric EQ.app"
ditto "dist/Parametric EQ.app" "$DEST/Parametric EQ.app"

echo "▸ Installed: $DEST/Parametric EQ.app"
open "$DEST/Parametric EQ.app"
