#!/usr/bin/env bash
# Add a Builds entry for a released version to the F-Droid metadata.
#
#   tools/fdroid-add-build.sh 1.1.0 [commit]
#
# Edited as text, not round-tripped through a YAML parser: a parser would drop
# every comment, and the comments record why AutoUpdateMode is off and why
# Description lives in the app repo. The new entry is a copy of the last one
# with only versionName, versionCode and commit substituted, so `output:` and
# `build:` (which use F-Droid's $$VERSION$$/$$VERCODE$$) carry forward
# unchanged. The JDK in `sudo:` is the one exception: it is rewritten to the
# JDK_VERSION in build.sh at [commit], or in the working tree when no commit is
# given, so the entry installs what that release is built with. Idempotent: a
# version already present is left alone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <MAJOR.MINOR.PATCH> [commit]" >&2
  exit 2
fi
VERSION="$1"
COMMIT="${2:-}"
if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "error: '$VERSION' is not major.minor.patch" >&2
  exit 1
fi
if ! CODE="$("$ROOT/tools/version-code.sh" "$VERSION" 2>&1)"; then
  echo "$CODE" >&2
  exit 1
fi

APP_ID="$(sed -n 's/^APP_ID="\(.*\)"$/\1/p' "$ROOT/build.sh")"
[ -n "$APP_ID" ] || { echo "could not read APP_ID out of build.sh" >&2; exit 1; }
FILE="$ROOT/fdroid/$APP_ID.yml"
NAME="$(basename "$FILE")"
if [ ! -f "$FILE" ]; then
  echo "error: $FILE does not exist" >&2
  exit 1
fi

# Dots are the only regex metacharacter in a validated version.
VERSION_RE="${VERSION//./\\.}"
if grep -qE "^[[:space:]]*- versionName: ${VERSION_RE}[[:space:]]*$" "$FILE"; then
  echo "$VERSION is already in $NAME, nothing to do"
  exit 0
fi

JDK_RE='s/^JDK_VERSION="${JDK_VERSION:-\([0-9]*\)}"$/\1/p'
if [ -n "$COMMIT" ]; then
  if ! BUILD_SH="$(git -C "$ROOT" show "$COMMIT:build.sh" 2>&1)"; then
    echo "error: could not read build.sh at '$COMMIT': $BUILD_SH" >&2
    exit 1
  fi
else
  BUILD_SH="$(cat "$ROOT/build.sh")"
fi
JDK="$(printf '%s\n' "$BUILD_SH" | sed -n "$JDK_RE")"
[ -n "$JDK" ] || { echo "error: could not read JDK_VERSION out of build.sh${COMMIT:+ at $COMMIT}" >&2; exit 1; }

# Line range [START, END) of the last Builds entry, trailing blanks excluded.
if ! RANGE="$(awk '
  { L[NR] = $0 }
  /^  - versionName:/ { s = NR }
  END {
    if (!s) exit 3
    e = s + 1
    while (e <= NR && (L[e] ~ /^    / || L[e] ~ /^[ \t]*$/)) e++
    while (e > s + 1 && L[e - 1] ~ /^[ \t]*$/) e--
    print s, e
  }' "$FILE")"; then
  echo "no Builds entries to copy from" >&2
  exit 1
fi
read -r START END <<< "$RANGE"

PREV="$(sed -n "${START}s/^[^:]*:[[:space:]]*//;${START}s/[[:space:]]*$//p" "$FILE")"
if ! PREV_CODE="$("$ROOT/tools/version-code.sh" "$PREV" 2>&1)"; then
  echo "$PREV_CODE" >&2
  exit 1
fi
if [ "$CODE" -le "$PREV_CODE" ]; then
  echo "error: $VERSION is not newer than the last entry $PREV" >&2
  exit 1
fi

# Substitute only the version-bearing fields, first matching rule per line. A
# blanket replace would also rewrite "major*10000" in a comment.
OUT="$(awk -v s="$START" -v e="$END" -v old="$PREV" -v oc="$PREV_CODE" \
  -v new="$VERSION" -v nc="$CODE" -v jdk="$JDK" '
  function tail(line, suffix) { # line minus trailing space and the suffix
    sub(/[ \t]+$/, "", line)
    return substr(line, 1, length(line) - length(suffix))
  }
  function render(line,   o, c) {
    o = old; gsub(/\./, "\\.", o)
    c = oc
    if (line ~ ("^[ \t]*- versionName:[ \t]*" o "[ \t]*$")) return tail(line, old) new
    if (line ~ ("^[ \t]*versionCode:[ \t]*" c "[ \t]*$")) return tail(line, oc) nc
    if (line ~ ("^[ \t]*commit:[ \t]*v?" o "[ \t]*$")) return tail(line, old) new
    gsub(/openjdk-[0-9]+-jdk/, "openjdk-" jdk "-jdk", line)
    return line
  }
  { L[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      line = L[i]
      if (line ~ /^CurrentVersion:/) line = "CurrentVersion: " new
      else if (line ~ /^CurrentVersionCode:/) line = "CurrentVersionCode: " nc
      print line
      if (i == e - 1) for (j = s; j < e; j++) print render(L[j])
    }
  }' "$FILE")"
printf '%s\n' "$OUT" > "$FILE"
echo "added $VERSION ($CODE) to $NAME"
