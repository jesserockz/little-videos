#!/usr/bin/env bash
# Build twice and confirm the APK is byte for byte identical.
#
# This is the property F-Droid checks: it rebuilds the tagged source and
# compares against the published APK, so any wall clock, locale, path or
# toolchain leak into the output makes the app fail verification.
#
# Pass 1 runs with the caller's environment and its output is left on stdout,
# so this can stand in for a plain ./build.sh in CI. Pass 2 re-runs with the
# clock, timezone and locale moved so a leak actually shows, and its artifacts
# are identical to pass 1's by definition of passing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT

echo "==> pass 1"
if ! ./build.sh 2>&1 | tee "$WORK/pass1.log"; then
  echo "build pass 1 failed" >&2
  exit 1
fi
cp build/unsigned.apk "$WORK/pass1.apk"

echo
echo "==> pass 2 (different wall clock, timezone and locale)"
sleep 2
if ! env TZ=Pacific/Kiritimati LC_ALL=C ./build.sh > "$WORK/pass2.log" 2>&1; then
  echo "build pass 2 failed:" >&2
  tail -20 "$WORK/pass2.log" >&2
  exit 1
fi
cp build/unsigned.apk "$WORK/pass2.apk"

if cmp -s "$WORK/pass1.apk" "$WORK/pass2.apk"; then
  echo
  echo "reproducible"
  echo "  sha256 $(sha256sum "$WORK/pass1.apk" | cut -d' ' -f1)  (unsigned)"
  exit 0
fi

echo >&2
echo "NOT reproducible: the two builds differ" >&2
echo >&2
echo "differing byte offsets (first 20):" >&2
cmp -l "$WORK/pass1.apk" "$WORK/pass2.apk" 2>/dev/null | head -20 >&2 || true
echo >&2
echo "zip metadata diff:" >&2
zipinfo -v "$WORK/pass1.apk" > "$WORK/z1.txt" 2>/dev/null || true
zipinfo -v "$WORK/pass2.apk" > "$WORK/z2.txt" 2>/dev/null || true
diff "$WORK/z1.txt" "$WORK/z2.txt" | head -40 >&2 || true
exit 1
