#!/usr/bin/env bash
# Build Little Videos into a signed, installable APK using the Android SDK
# command-line tools directly. No Gradle, no network, no third-party deps.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/android-sdk}}"
BUILD_TOOLS_VERSION="35.0.0"
COMPILE_SDK="35"
MIN_SDK="24"
TARGET_SDK="35"
APP_ID="io.github.jesserockz.littlevideos"

# Overridable by the environment so a release build can stamp the version from
# the release tag. The defaults are what a plain local build gets.
VERSION_CODE="${VERSION_CODE:-1}"
VERSION_NAME="${VERSION_NAME:-1.0}"

BT="$SDK/build-tools/$BUILD_TOOLS_VERSION"
ANDROID_JAR="$SDK/platforms/android-$COMPILE_SDK/android.jar"
SRC="$ROOT/app/src/main"
OUT="$ROOT/build"
DIST="$ROOT/dist"

# Signing material. In CI these come from secrets; locally they fall back to the
# throwaway sideload key that build.sh generates on first run.
KS="${ANDROID_KEYSTORE:-$ROOT/keystore/little-videos.jks}"
KS_PASS="${ANDROID_KEYSTORE_PASSWORD:-littlevideos}"
KS_ALIAS="${ANDROID_KEY_ALIAS:-littlevideos}"
APK="$DIST/little-videos-$VERSION_NAME.apk"

# Android's toolchain does not accept a JDK newer than 21, and -bootclasspath
# requires -source 8, so pin javac/keytool/apksigner to JDK 17 when present.
for CANDIDATE in /usr/lib/jvm/java-17-openjdk /usr/lib/jvm/java-21-openjdk; do
  if [ -x "$CANDIDATE/bin/javac" ]; then
    export JAVA_HOME="$CANDIDATE"
    export PATH="$JAVA_HOME/bin:$PATH"
    break
  fi
done

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

[ -d "$BT" ] || die "build-tools $BUILD_TOOLS_VERSION not found at $BT"
[ -f "$ANDROID_JAR" ] || die "android.jar not found at $ANDROID_JAR"
command -v javac >/dev/null || die "javac not on PATH"
command -v zip   >/dev/null || die "zip not on PATH"
command -v unzip >/dev/null || die "unzip not on PATH"
command -v strings >/dev/null || die "strings not on PATH (install binutils)"

rm -rf "$OUT"
mkdir -p "$OUT"/{res,gen,classes,dex} "$DIST"

step "Resolving the signing key"
if [ -f "$KS" ]; then
  echo "using $KS"
elif [ -n "${CI:-}" ] && [ -z "${ALLOW_GENERATED_KEY:-}" ]; then
  die "no signing keystore at $KS.
       Refusing to generate one under CI: a throwaway key would silently produce an
       APK that cannot install over any previous release. Point ANDROID_KEYSTORE at a
       decoded keystore and set ANDROID_KEYSTORE_PASSWORD and ANDROID_KEY_ALIAS, or
       set ALLOW_GENERATED_KEY=1 to opt in to a disposable key for a throwaway build."
else
  [ -z "${CI:-}" ] || echo "ALLOW_GENERATED_KEY is set: generating a disposable key, NOT release-signable"
  mkdir -p "$(dirname "$KS")"
  keytool -genkeypair -keystore "$KS" \
    -storepass "$KS_PASS" -keypass "$KS_PASS" -alias "$KS_ALIAS" \
    -keyalg RSA -keysize 2048 -validity 10950 \
    -dname "CN=Little Videos, OU=Sideload, O=Little Videos, C=AU" >/dev/null 2>&1
  echo "created $KS"
fi

step "Compiling resources (aapt2 compile)"
"$BT/aapt2" compile --dir "$SRC/res" -o "$OUT/res/resources.zip"

step "Linking resources (aapt2 link)"
"$BT/aapt2" link \
  -o "$OUT/base.apk" \
  -I "$ANDROID_JAR" \
  --manifest "$SRC/AndroidManifest.xml" \
  -R "$OUT/res/resources.zip" \
  --java "$OUT/gen" \
  --min-sdk-version "$MIN_SDK" \
  --target-sdk-version "$TARGET_SDK" \
  --version-code "$VERSION_CODE" \
  --version-name "$VERSION_NAME" \
  --auto-add-overlay

step "Compiling Java (javac)"
find "$SRC/java" "$OUT/gen" -name '*.java' > "$OUT/sources.txt"
echo "$(wc -l < "$OUT/sources.txt") source files"
javac -nowarn -Xlint:-options \
  -source 8 -target 8 \
  -bootclasspath "$BT/core-lambda-stubs.jar:$ANDROID_JAR" \
  -d "$OUT/classes" \
  @"$OUT/sources.txt"

step "Dexing (d8)"
find "$OUT/classes" -name '*.class' > "$OUT/classes.txt"
"$BT/d8" --lib "$ANDROID_JAR" --min-api "$MIN_SDK" --release \
  --output "$OUT/dex" @"$OUT/classes.txt"

step "Packaging"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT/dex" && zip -q ../unsigned.apk classes*.dex)

step "Aligning and signing"
"$BT/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign \
  --ks "$KS" --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
  --out "$APK" "$OUT/aligned.apk" 2>/dev/null
"$BT/apksigner" verify "$APK" >/dev/null && echo "signature verified"

step "Verifying the offline guarantee"
BADGING="$("$BT/aapt2" dump badging "$APK")"
if PERMS="$(printf '%s\n' "$BADGING" | grep -E "^(uses-permission|uses-permission-sdk-23)" || true)"; [ -n "$PERMS" ]; then
  echo "$PERMS" >&2
  die "APK declares permissions; this app must declare none"
fi
if unzip -p "$APK" AndroidManifest.xml | strings | grep -qi 'android.permission.INTERNET'; then
  die "INTERNET permission found in the compiled manifest"
fi
echo "no permissions declared, no INTERNET: ok"

step "Done"
printf '%s\n' "$BADGING" | grep -E "^(package|sdkVersion|targetSdkVersion|application-label)" || true
echo
ls -lh "$APK"
echo
echo "Install with:  adb install -r $APK"
