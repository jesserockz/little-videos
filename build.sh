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

# "debug" builds a debuggable copy with its own applicationId, so it installs
# beside the real app. It writes only under build/debug and dist/debug.
BUILD_VARIANT="${BUILD_VARIANT:-release}"

# Overridable by the environment so a release build can stamp the version from
# the release tag. The defaults are what a plain local build gets.
VERSION_CODE="${VERSION_CODE:-1}"
VERSION_NAME="${VERSION_NAME:-1.0}"

# Reproducible builds. F-Droid rebuilds this from the tagged source and compares
# the result byte for byte against the published APK, so nothing in the output may
# depend on when or where it was built.
#   TZ      - zip stores DOS timestamps in local time.
#   LC_ALL  - keeps glob and sort ordering stable.
#   SOURCE_DATE_EPOCH - the standard knob; defaults to the commit date so any
#                       checkout of a given commit agrees, and stays overridable.
export TZ=UTC
export LC_ALL=C
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  if COMMIT_EPOCH="$(git -C "$ROOT" log -1 --pretty=%ct 2>/dev/null)" && [ -n "$COMMIT_EPOCH" ]; then
    SOURCE_DATE_EPOCH="$COMMIT_EPOCH"
  else
    # No git metadata (a source tarball). Fall back to a fixed constant rather
    # than the wall clock, so the build stays reproducible.
    SOURCE_DATE_EPOCH=1600000000
  fi
fi
export SOURCE_DATE_EPOCH

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

BT="$SDK/build-tools/$BUILD_TOOLS_VERSION"
ANDROID_JAR="$SDK/platforms/android-$COMPILE_SDK/android.jar"
SRC="$ROOT/app/src/main"
OUT="$ROOT/build"
DIST="$ROOT/dist"
APK_SUFFIX=""
case "$BUILD_VARIANT" in
  release) ;;
  debug)
    APP_ID="$APP_ID.debug"
    OUT="$ROOT/build/debug"
    DIST="$ROOT/dist/debug"
    APK_SUFFIX="-debug"
    ;;
  *) die "BUILD_VARIANT must be release or debug, not '$BUILD_VARIANT'" ;;
esac

# Signing material. In CI these come from secrets; locally they fall back to the
# throwaway sideload key that build.sh generates on first run.
KS="${ANDROID_KEYSTORE:-$ROOT/keystore/little-videos.jks}"
KS_PASS="${ANDROID_KEYSTORE_PASSWORD:-littlevideos}"
KS_ALIAS="${ANDROID_KEY_ALIAS:-littlevideos}"
APK="$DIST/little-videos-$VERSION_NAME$APK_SUFFIX.apk"

# The JDK major version is a reproducibility input, not a detail: javac 17 and
# javac 21 emit different bytecode for these same sources, so the APK hash
# changes with the JDK. It is therefore pinned and verified rather than
# discovered, and the Android toolchain will not accept anything newer than 21
# anyway. Override only if you accept a different output hash.
JDK_VERSION="${JDK_VERSION:-17}"

jdk_major() { "$1/bin/javac" -version 2>&1 | awk '{print $2}' | cut -d. -f1; }

# An already-correct JAVA_HOME wins, which is what actions/setup-java gives CI.
if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/javac" ] &&
   [ "$(jdk_major "$JAVA_HOME")" = "$JDK_VERSION" ]; then
  :
else
  JAVA_HOME=""
  for CANDIDATE in \
    "/usr/lib/jvm/java-$JDK_VERSION-openjdk" \
    "/usr/lib/jvm/java-$JDK_VERSION-openjdk-amd64" \
    "/usr/lib/jvm/temurin-$JDK_VERSION-jdk-amd64" \
    "/usr/lib/jvm/jdk-$JDK_VERSION"; do
    if [ -x "$CANDIDATE/bin/javac" ]; then
      JAVA_HOME="$CANDIDATE"
      break
    fi
  done
fi
[ -n "$JAVA_HOME" ] || die "no JDK $JDK_VERSION found.
       The APK is only reproducible when built with JDK $JDK_VERSION. Install it, or
       point JAVA_HOME at it, or set JDK_VERSION to accept a different one."
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
ACTUAL_JDK="$(jdk_major "$JAVA_HOME")"
[ "$ACTUAL_JDK" = "$JDK_VERSION" ] || die "JAVA_HOME is JDK $ACTUAL_JDK, expected $JDK_VERSION"

[ -d "$BT" ] || die "build-tools $BUILD_TOOLS_VERSION not found at $BT"
[ -f "$ANDROID_JAR" ] || die "android.jar not found at $ANDROID_JAR"
command -v javac >/dev/null || die "javac not on PATH"
command -v zip   >/dev/null || die "zip not on PATH"
command -v unzip >/dev/null || die "unzip not on PATH"
command -v strings >/dev/null || die "strings not on PATH (install binutils)"

step "Toolchain"
# Printed because these are exactly the inputs that decide the output hash.
printf 'javac             %s\n' "$(javac -version 2>&1 | awk '{print $2}')"
printf 'build-tools       %s\n' "$BUILD_TOOLS_VERSION"
printf 'compile sdk       %s\n' "$COMPILE_SDK"
printf 'zip               %s\n' "$(zip -v 2>/dev/null | awk '/This is Zip/ {print $4; exit}')"
printf 'SOURCE_DATE_EPOCH %s (%s)\n' "$SOURCE_DATE_EPOCH" "$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"
printf 'version           %s (%s)\n' "$VERSION_NAME" "$VERSION_CODE"

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
  # keytool has no env:/file: password option, unlike apksigner, so this one
  # call still passes the password as an argument. It only ever runs for the
  # local throwaway key, never on the release path, which refuses to generate.
  keytool -genkeypair -keystore "$KS" \
    -storepass "$KS_PASS" -keypass "$KS_PASS" -alias "$KS_ALIAS" \
    -keyalg RSA -keysize 2048 -validity 10950 \
    -dname "CN=Little Videos, OU=Sideload, O=Little Videos, C=AU" >/dev/null 2>&1
  echo "created $KS"
fi

step "Compiling resources (aapt2 compile)"
"$BT/aapt2" compile --dir "$SRC/res" -o "$OUT/res/resources.zip"

# Debug: relabel the launcher icon. The overlay is linked last so it wins.
LINK_EXTRA=()
if [ "$BUILD_VARIANT" = debug ]; then
  mkdir -p "$OUT/overlay/values"
  cat > "$OUT/overlay/values/strings.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">Little Videos Debug</string>
</resources>
XML
  "$BT/aapt2" compile --dir "$OUT/overlay" -o "$OUT/res/overlay.zip"
  LINK_EXTRA=(-R "$OUT/res/overlay.zip" --rename-manifest-package "$APP_ID" --debug-mode)
fi

step "Linking resources (aapt2 link)"
"$BT/aapt2" link \
  -o "$OUT/base.apk" \
  -I "$ANDROID_JAR" \
  --manifest "$SRC/AndroidManifest.xml" \
  -R "$OUT/res/resources.zip" \
  ${LINK_EXTRA[@]+"${LINK_EXTRA[@]}"} \
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
# aapt2 already writes fixed entry timestamps. The dex entries come from the zip
# CLI, which would otherwise stamp them with the wall clock, so normalise the
# mtimes first and pass -X to drop the Unix extended-timestamp extra field.
# LC_ALL=C above makes the classes*.dex glob order stable.
find "$OUT/dex" -name 'classes*.dex' -exec touch -d "@$SOURCE_DATE_EPOCH" {} +
(cd "$OUT/dex" && zip -q -X -D ../unsigned.apk classes*.dex)

step "Aligning and signing"
"$BT/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
# The password goes through the environment, not the command line: an argument
# is visible to anyone who can run `ps` for as long as the process lives, which
# on a shared CI runner is not nothing. apksigner reads env:<name> itself.
# stderr is captured rather than discarded so a signing failure is legible;
# apksigner is noisy on success, hence not printing it when it works.
if ! SIGN_ERR="$(APKSIGNER_PASS="$KS_PASS" "$BT/apksigner" sign \
    --ks "$KS" \
    --ks-pass env:APKSIGNER_PASS \
    --key-pass env:APKSIGNER_PASS \
    --out "$APK" "$OUT/aligned.apk" 2>&1)"; then
  printf '%s\n' "$SIGN_ERR" >&2
  die "apksigner failed to sign $APK"
fi
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

# The applicationId is permanent once published: Android and F-Droid both treat
# a changed one as a different app, and F-Droid matches the rebuilt APK to the
# metadata by it. Assert rather than trust the manifest.
BUILT_ID="$(printf '%s\n' "$BADGING" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
[ "$BUILT_ID" = "$APP_ID" ] || die "APK declares package '$BUILT_ID', expected '$APP_ID'"
echo "package id is $APP_ID: ok"

step "Done"
printf '%s\n' "$BADGING" | grep -E "^(package|sdkVersion|targetSdkVersion|application-label)" || true
echo
ls -lh "$APK"
echo
echo "Install with:  adb install -r $APK"
