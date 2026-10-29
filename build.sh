#!/bin/bash
# Builds the release executable, wraps it in a proper .app bundle, copies the
# Info.plist/icon and ad-hoc signs the result. The app is placed in dist/.
# This script intentionally does not touch SwiftPM's global caches.
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$PWD"
export TMPDIR="$ROOT/.tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT/.modulecache"
export SWIFT_MODULECACHE_PATH="$ROOT/.modulecache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH" .spm-cache .spm-config dist

SWIFT_FLAGS=(
  --disable-sandbox
  --cache-path .spm-cache
  --config-path .spm-config
  --manifest-cache local
)

echo "▸ Building Parametric EQ (release)…"
swift build -c release --product ParametricEQ "${SWIFT_FLAGS[@]}"

APP="$ROOT/dist/Parametric EQ.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/ParametricEQ" "$APP/Contents/MacOS/ParametricEQ"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "Resources/AppIcon.icns" ]]; then
  cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -lint "$APP/Contents/Info.plist" >/dev/null
chmod +x "$APP/Contents/MacOS/ParametricEQ"

# Ad-hoc signing is enough for a locally built, non-sandboxed app and gives
# macOS a stable identity for the System Audio Recording permission prompt.
codesign --force --sign - --identifier com.andreyilin.ParametricEQ "$APP" >/dev/null
codesign --verify --strict "$APP"

echo "▸ Built: $APP"
