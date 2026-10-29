#!/bin/bash
# Convenience wrapper: build the app bundle and open it.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
open "dist/Parametric EQ.app"
