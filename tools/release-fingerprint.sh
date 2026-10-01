#!/usr/bin/env bash
# Build and sign a release APK with the real key, then print the signing
# certificate fingerprint that F-Droid's AllowedAPKSigningKeys field wants.
#
#   ./tools/release-fingerprint.sh [version] [keystore]
#
# Prompts for the keystore password. The password is never echoed, never put on
# a command line where `ps` could see it, and never written to disk.
set -euo pipefail

VERSION="${1:-1.0.0}"
KS="${2:-$HOME/keys/jesserockz.p12}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ -f "$KS" ] || { echo "no keystore at $KS" >&2; exit 1; }
# Also rejects a malformed version.
VC="$("$ROOT/tools/version-code.sh" "$VERSION")" || exit 1

read -rsp "Keystore password for $KS: " KSPASS; echo
export KSPASS

echo
echo "==> Aliases"
# Piped rather than -storepass, so the password stays out of the process list.
if ! LISTING="$(printf '%s\n' "$KSPASS" | keytool -list -keystore "$KS" -storetype PKCS12 2>&1)"; then
  printf '%s\n' "$LISTING" >&2
  echo "error: could not open the keystore, wrong password?" >&2
  exit 1
fi
ALIAS="$(printf '%s\n' "$LISTING" | awk -F, '/PrivateKeyEntry/ {print $1; exit}')"
[ -n "$ALIAS" ] || { echo "error: no PrivateKeyEntry in $KS" >&2; exit 1; }
echo "$ALIAS"

echo
echo "==> Building $VERSION ($VC)"
cd "$ROOT"
CI=true \
ANDROID_KEYSTORE="$KS" \
ANDROID_KEYSTORE_PASSWORD="$KSPASS" \
ANDROID_KEY_ALIAS="$ALIAS" \
VERSION_NAME="$VERSION" \
VERSION_CODE="$VC" \
./build.sh

# The verify rebuild inherits these, so it must see the same values.
CI=true \
ANDROID_KEYSTORE="$KS" \
ANDROID_KEYSTORE_PASSWORD="$KSPASS" \
ANDROID_KEY_ALIAS="$ALIAS" \
VERSION_NAME="$VERSION" \
VERSION_CODE="$VC" \
./tools/verify-reproducible.sh

APK="$ROOT/dist/little-videos-$VERSION.apk"
[ -f "$APK" ] || { echo "error: expected $APK" >&2; exit 1; }

echo
echo "==> Signing certificate"
CERTS="$("${ANDROID_HOME:-/opt/android-sdk}/build-tools/35.0.0/apksigner" \
  verify --print-certs "$APK" 2>/dev/null)"
printf '%s\n' "$CERTS" | grep -E 'certificate (DN|SHA-256)'

SHA="$(printf '%s\n' "$CERTS" | awk '/Signer #1 certificate SHA-256/ {print tolower($NF)}')"

echo
echo "================================================================"
echo "ANDROID_KEY_ALIAS secret should be:  $ALIAS"
echo
echo "F-Droid AllowedAPKSigningKeys:"
echo "  $SHA"
echo "================================================================"
echo
echo "APK: $APK"
