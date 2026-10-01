#!/usr/bin/env bash
# Check that an existing build is byte for byte reproducible, as F-Droid will.
#
#   ./build.sh && tools/verify-reproducible.sh
#
# Copies build/unsigned.apk and the one dist/*.apk aside, rebuilds with a
# different clock, timezone and locale (other env is inherited), and compares
# both APKs. Signing is deterministic only because the key is RSA.
# BUILD_CMD overrides the build command (test hook).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_CMD="${BUILD_CMD:-./build.sh}"

UNSIGNED="build/unsigned.apk"
DIST_APKS=()
for F in dist/*.apk; do
  [ -f "$F" ] && DIST_APKS+=("$F")
done

if [ ! -f "$UNSIGNED" ] || [ "${#DIST_APKS[@]}" -ne 1 ]; then
  echo "error: nothing to verify: need $UNSIGNED and exactly one dist/*.apk" >&2
  echo "run ./build.sh first, then ./tools/verify-reproducible.sh" >&2
  exit 1
fi
SIGNED="${DIST_APKS[0]}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT

cp "$UNSIGNED" "$WORK/pass1-unsigned.apk"
cp "$SIGNED" "$WORK/pass1-signed.apk"

echo "==> rebuild (different wall clock, timezone and locale)"
sleep 2
# Unquoted so BUILD_CMD may carry arguments.
# shellcheck disable=SC2086
if ! env TZ=Pacific/Kiritimati LC_ALL=C $BUILD_CMD > "$WORK/pass2.log" 2>&1; then
  echo "rebuild failed:" >&2
  tail -20 "$WORK/pass2.log" >&2
  exit 1
fi
cp "$UNSIGNED" "$WORK/pass2-unsigned.apk"
cp "$SIGNED" "$WORK/pass2-signed.apk"

BAD=0
report() { # label, file stem
  echo >&2
  echo "NOT reproducible: the $1 APK differs between the two builds" >&2
  echo >&2
  echo "differing byte offsets (first 20):" >&2
  cmp -l "$WORK/pass1-$2.apk" "$WORK/pass2-$2.apk" 2>/dev/null | head -20 >&2 || true
  echo >&2
  echo "zip metadata diff:" >&2
  zipinfo -v "$WORK/pass1-$2.apk" > "$WORK/$2-z1.txt" 2>/dev/null || true
  zipinfo -v "$WORK/pass2-$2.apk" > "$WORK/$2-z2.txt" 2>/dev/null || true
  diff "$WORK/$2-z1.txt" "$WORK/$2-z2.txt" | head -40 >&2 || true
  BAD=1
}

cmp -s "$WORK/pass1-unsigned.apk" "$WORK/pass2-unsigned.apk" || report unsigned unsigned
cmp -s "$WORK/pass1-signed.apk" "$WORK/pass2-signed.apk" || report signed signed

if [ "$BAD" -ne 0 ]; then
  exit 1
fi

echo
echo "reproducible"
echo "  sha256 $(sha256sum "$WORK/pass1-unsigned.apk" | cut -d' ' -f1)  (unsigned)"
echo "  sha256 $(sha256sum "$WORK/pass1-signed.apk" | cut -d' ' -f1)  (signed, $SIGNED)"
