#!/usr/bin/env bash
# Ensure the F-Droid changelog at a release's target commit matches the draft
# body; print the SHA to tag (target, or a new child commit that fixes it).
#
#   tools/release-changelog.sh <version> <target-sha> < body.md
#
# The commit is built in the object database only: no checkout, no branch move.
# It keeps target's committer date as author and committer date, with a fixed
# identity and message. build.sh derives SOURCE_DATE_EPOCH from that date, so
# the APK is unchanged, and the SHA is deterministic so retries are idempotent.
# Diagnostics go to stderr; stdout is only the SHA.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <version> <target-sha> < body.md" >&2
  exit 2
fi
VERSION="$1"
TARGET_REF="$2"

# Also validates the version.
if ! CODE="$("$ROOT/tools/version-code.sh" "$VERSION")"; then
  exit 1
fi
if ! TARGET="$(git rev-parse --verify --quiet "$TARGET_REF^{commit}")"; then
  echo "::error::'$TARGET_REF' is not a commit in this checkout" >&2
  exit 1
fi

FILE="fastlane/metadata/android/en-US/changelogs/$CODE.txt"

BODY="$(cat)"
if ! RENDERED="$(printf '%s\n' "$BODY" | "$ROOT/tools/fdroid-changelog.sh")"; then
  echo "::error::could not render the changelog from the body" >&2
  exit 1
fi

# A missing file counts as different. $(...) drops trailing newlines on both sides.
if CURRENT="$(git show "$TARGET:$FILE" 2>/dev/null)" && [ "$CURRENT" = "$RENDERED" ]; then
  echo "changelog at $TARGET already matches the draft body" >&2
  printf '%s\n' "$TARGET"
  exit 0
fi

echo "changelog $FILE differs from the draft body at $TARGET, rewriting" >&2

# Fixed values, so the commit SHA is deterministic.
EPOCH="$(git show -s --format=%ct "$TARGET")"
NAME="github-actions[bot]"
EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
DATE="@$EPOCH +0000"

# Throwaway index, so the caller's index and working tree are untouched.
GIT_DIR_ABS="$(git rev-parse --absolute-git-dir)"
TMP_INDEX="$(mktemp "$GIT_DIR_ABS/release-changelog-index.XXXXXX")"
trap 'rm -f "$TMP_INDEX"' EXIT
# read-tree needs the index absent or valid, not an empty file.
rm -f "$TMP_INDEX"

export GIT_INDEX_FILE="$TMP_INDEX"
git read-tree "$TARGET"
BLOB="$(printf '%s\n' "$RENDERED" | git hash-object -w --stdin)"
git update-index --add --cacheinfo "100644,$BLOB,$FILE"
TREE="$(git write-tree)"
unset GIT_INDEX_FILE

NEW="$(printf 'Update F-Droid changelog for %s\n' "$VERSION" \
  | GIT_AUTHOR_NAME="$NAME" GIT_AUTHOR_EMAIL="$EMAIL" GIT_AUTHOR_DATE="$DATE" \
    GIT_COMMITTER_NAME="$NAME" GIT_COMMITTER_EMAIL="$EMAIL" GIT_COMMITTER_DATE="$DATE" \
    git commit-tree "$TREE" -p "$TARGET")"
echo "created $NEW on top of $TARGET" >&2
printf '%s\n' "$NEW"
