#!/usr/bin/env bash
# Check the store metadata against reality before it reaches F-Droid.
#
# F-Droid rejects or mis-publishes on things that are invisible locally: a
# description over the length limit, a Builds entry whose versionCode does not
# match the APK, a toolchain in the recipe that no longer matches build.sh.
# All of those surface days later as a failed build in someone else's
# infrastructure, so they are worth catching here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for tool in yq jq; do
  command -v "$tool" > /dev/null || { echo "$tool is not on PATH" >&2; exit 1; }
done

FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=1; }
ok()   { echo "  ok: $*"; }

FL="fastlane/metadata/android/en-US"
APP_ID="$(sed -n 's/^APP_ID="\(.*\)"$/\1/p' build.sh)"
JDK_RE='s/^JDK_VERSION="${JDK_VERSION:-\([0-9]*\)}"$/\1/p'
JDK="$(sed -n "$JDK_RE" build.sh)"
BT_VER="$(sed -n 's/^BUILD_TOOLS_VERSION="\(.*\)"$/\1/p' build.sh)"
SDK_VER="$(sed -n 's/^COMPILE_SDK="\(.*\)"$/\1/p' build.sh)"
META="fdroid/$APP_ID.yml"

echo "== build.sh =="
for v in APP_ID JDK BT_VER SDK_VER; do
  [ -n "${!v}" ] || fail "could not read $v out of build.sh"
done
ok "app id $APP_ID, JDK $JDK, build-tools $BT_VER, sdk $SDK_VER"

echo "== fastlane text limits =="
limit() {
  local f="$FL/$1" lim="$2"
  [ -f "$f" ] || { fail "$f is missing"; return; }
  local n; n="$(wc -c < "$f")"
  [ "$n" -le "$lim" ] && ok "$1 is $n/$lim chars" || fail "$1 is $n chars, over the $lim limit"
}
limit title.txt 50
limit short_description.txt 80
limit full_description.txt 4000

# F-Droid's submission guide asks for the short description to have no
# trailing dot; it is rendered as a caption, not a sentence.
SHORT="$FL/short_description.txt"
if [ -f "$SHORT" ]; then
  case "$(tr -d '\n' < "$SHORT")" in
    *.) fail "short_description.txt ends with a full stop; F-Droid asks for none" ;;
    *)  ok "short_description.txt has no trailing full stop" ;;
  esac
fi

echo "== changelogs =="
shopt -s nullglob
CL=("$FL"/changelogs/*.txt)
[ "${#CL[@]}" -gt 0 ] || fail "no changelogs in $FL/changelogs"
for f in "${CL[@]}"; do
  base="$(basename "$f" .txt)"
  printf '%s' "$base" | grep -qE '^[0-9]+$' || fail "$f is not named after a versionCode"
  n="$(wc -c < "$f")"
  [ "$n" -le 500 ] && ok "changelogs/$base.txt is $n/500 chars" || fail "changelogs/$base.txt is $n chars, over the 500 limit"
done

echo "== F-Droid metadata =="
[ -f "$META" ] || { fail "$META is missing; it must be named after the app id"; echo; exit 1; }

SIGKEY="$(sed -n 's/^AllowedAPKSigningKeys: *\(.*\)$/\1/p' "$META")"
printf '%s' "$SIGKEY" | grep -qE '^[0-9a-f]{64}$' \
  && ok "AllowedAPKSigningKeys is a 64-hex fingerprint" \
  || fail "AllowedAPKSigningKeys is '$SIGKEY', expected 64 lowercase hex"

LICENSE_ID="$(sed -n 's/^License: *\(.*\)$/\1/p' "$META")"
case "$LICENSE_ID" in
  ""|TODO*) fail "License is '$LICENSE_ID'" ;;
  *) ok "License is $LICENSE_ID" ;;
esac

# Every Builds entry has to agree with what build.sh would actually produce,
# including the JDK: each entry installs the JDK its own tagged build.sh needs.
# yq only converts YAML to JSON (-o=json is the mikefarah/yq v4 spelling); jq does the rest.
if ! ENTRIES="$(yq -o=json '.' "$META" | jq -r '
  ((.Builds // [])[] | [.versionName, .versionCode, .commit, .output, ((.build // []) | join(" ")), ((.sudo // []) | join(" "))]
    | map(. // "" | tostring) | join("\t")),
  (["CURRENT", .CurrentVersion, .CurrentVersionCode] | map(. // "" | tostring) | join("\t"))
')"; then
  fail "could not parse $META"
else
  LAST_NAME=""; LAST_CODE=""
  while IFS=$'\t' read -r NAME CODE COMMIT OUTPUT BUILD SUDO; do
    if [ "$NAME" = "CURRENT" ]; then
      [ "$CODE" = "$LAST_NAME" ] && ok "CurrentVersion matches the newest Builds entry" \
        || fail "CurrentVersion is '$CODE', newest Builds entry is '$LAST_NAME'"
      [ "$COMMIT" = "$LAST_CODE" ] && ok "CurrentVersionCode matches the newest Builds entry" \
        || fail "CurrentVersionCode is '$COMMIT', newest Builds entry is '$LAST_CODE'"
      continue
    fi
    LAST_NAME="$NAME"; LAST_CODE="$CODE"
    # fdroidserver substitutes these before running or reading them.
    OUTPUT="${OUTPUT//\$\$VERSION\$\$/$NAME}"; OUTPUT="${OUTPUT//\$\$VERCODE\$\$/$CODE}"
    BUILD="${BUILD//\$\$VERSION\$\$/$NAME}"; BUILD="${BUILD//\$\$VERCODE\$\$/$CODE}"
    printf '%s' "$NAME" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { fail "versionName '$NAME' is not major.minor.patch"; continue; }
    WANT="$(./tools/version-code.sh "$NAME" 2>/dev/null)" || { fail "versionName '$NAME' cannot be turned into a versionCode"; continue; }
    [ "$CODE" = "$WANT" ] && ok "$NAME -> versionCode $CODE" || fail "$NAME should be versionCode $WANT, not $CODE"
    [ "$COMMIT" = "v$NAME" ] && ok "$NAME -> commit v$NAME" || fail "$NAME has commit '$COMMIT', expected v$NAME"
    WANT_OUT="dist/little-videos-$NAME.apk"
    [ "$OUTPUT" = "$WANT_OUT" ] && ok "$NAME -> output $OUTPUT" || fail "$NAME has output '$OUTPUT', build.sh writes $WANT_OUT"
    case "$BUILD" in
      *"VERSION_NAME=$NAME"*) ok "$NAME -> build stamps VERSION_NAME=$NAME" ;;
      *) fail "$NAME does not export VERSION_NAME=$NAME in its build commands" ;;
    esac
    case "$BUILD" in
      *"VERSION_CODE=$CODE"*) ok "$NAME -> build stamps VERSION_CODE=$CODE" ;;
      *) fail "$NAME does not export VERSION_CODE=$CODE in its build commands" ;;
    esac
    # Exactly one JDK package, and the one the tagged build.sh asks for.
    JDKS="$(printf '%s\n' "$SUDO" | grep -oE 'openjdk-[0-9]+-jdk[A-Za-z-]*' || true)"
    if [ "$(printf '%s' "$JDKS" | grep -c .)" != 1 ]; then
      fail "$NAME must install exactly one openjdk-<N>-jdk package, found: ${JDKS:-none}"
    else
      ENTRY_JDK="$(printf '%s' "$JDKS" | sed 's/^openjdk-\([0-9]*\)-jdk.*$/\1/')"
      if ! git rev-parse -q --verify "refs/tags/v$NAME^{commit}" > /dev/null 2>&1; then
        ok "$NAME -> JDK check against build.sh skipped, tag v$NAME is not available locally"
      else
        TAG_JDK="$(git show "v$NAME:build.sh" 2>/dev/null | sed -n "$JDK_RE")"
        if [ -z "$TAG_JDK" ]; then
          ok "$NAME -> JDK check against build.sh skipped, v$NAME has no JDK_VERSION in build.sh"
        elif [ "$TAG_JDK" = "$ENTRY_JDK" ]; then
          ok "$NAME -> installs JDK $ENTRY_JDK, matching build.sh at v$NAME"
        else
          fail "$NAME installs JDK $ENTRY_JDK, but build.sh at v$NAME requires JDK $TAG_JDK"
        fi
      fi
    fi
    [ -f "$FL/changelogs/$CODE.txt" ] && ok "$NAME -> changelogs/$CODE.txt exists" \
      || fail "$NAME has no changelog at $FL/changelogs/$CODE.txt"
  done <<< "$ENTRIES"
fi

echo
[ "$FAIL" = 0 ] && { echo "metadata is consistent"; exit 0; }
echo "metadata problems found" >&2
exit 1
