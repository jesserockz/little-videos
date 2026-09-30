#!/usr/bin/env bash
# Grab a screenshot from the emulator into shots/<name>.png
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB="${ANDROID_HOME:-/opt/android-sdk}/platform-tools/adb"
SERIAL="${SERIAL:-emulator-5584}"
NAME="${1:-shot}"
mkdir -p "$ROOT/shots"
"$ADB" -s "$SERIAL" exec-out screencap -p > "$ROOT/shots/$NAME.png"
echo "$ROOT/shots/$NAME.png"
