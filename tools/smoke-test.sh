#!/usr/bin/env bash
# Install the built APK on a connected device/emulator, launch it, capture a
# screenshot and surface any crash. Usage: tools/smoke-test.sh [serial]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB="${ANDROID_HOME:-/opt/android-sdk}/platform-tools/adb"
SERIAL="${1:-}"
APP_ID="dev.jesserockz.littlevideos"
APK="$(ls -t "$ROOT"/dist/*.apk 2>/dev/null | head -1)"
SHOTS="$ROOT/shots"

[ -n "$APK" ] || { echo "no APK in $ROOT/dist; run ./build.sh first" >&2; exit 1; }
if [ -n "$SERIAL" ]; then ADB=("$ADB" -s "$SERIAL"); else ADB=("$ADB"); fi
mkdir -p "$SHOTS"

echo "==> installing $(basename "$APK")"
"${ADB[@]}" install -r -g "$APK"

echo "==> declared permissions on device (expect none)"
GRANTED="$("${ADB[@]}" shell dumpsys package "$APP_ID" | sed -n '/requested permissions:/,/^ *[a-zA-Z]*:/p' | grep -E '^\s+android\.permission' || true)"
if [ -n "$GRANTED" ]; then echo "UNEXPECTED: $GRANTED"; else echo "none - correct"; fi

echo "==> clearing logcat and launching"
"${ADB[@]}" logcat -c
"${ADB[@]}" shell am start -n "$APP_ID/.GridActivity" -W

echo "==> screenshot"
STAMP="$(date +%H%M%S)"
"${ADB[@]}" exec-out screencap -p > "$SHOTS/launch-$STAMP.png"
echo "wrote $SHOTS/launch-$STAMP.png"

echo "==> crash check"
CRASH="$("${ADB[@]}" logcat -d -b crash 2>/dev/null | tail -40 || true)"
if [ -n "$CRASH" ]; then echo "$CRASH"; else echo "no crash buffer output"; fi
echo
echo "==> app log lines"
"${ADB[@]}" logcat -d 2>/dev/null | grep -iE "littlevideos|AndroidRuntime" | tail -25 || echo "(none)"
