#!/usr/bin/env bash
# Turn a drafted GitHub release body into an F-Droid changelog.
#
#   tools/fdroid-changelog.sh < body.md > changelogs/10100.txt
#
# F-Droid caps these at 500 characters and renders them as plain text, so the
# ASSETS_PENDING caution, the install instructions and the markdown all have to
# go. Truncation happens on a whole bullet, never mid-word.
set -euo pipefail

LIMIT="${CHANGELOG_LIMIT:-500}"

BODY="$(cat)"

CHANGES="$(printf '%s\n' "$BODY" \
  | sed '/<!-- ASSETS_PENDING -->/,/<!-- \/ASSETS_PENDING -->/d' \
  | sed -n '/^## What changed/,/^## Install/p' \
  | sed '/^#\{2,\} /d' \
  | sed 's/[[:space:]]*$//' \
  | sed 's/ *@[A-Za-z0-9._-]\+ *$//' \
  | sed 's/\[\([^]]*\)\](\([^)]*\))/\1/g' \
  | sed 's/[*_`]//g' \
  | grep -v '^$' || true)"

if [ -z "$CHANGES" ]; then
  echo "no changes recorded" 
  exit 0
fi

# Keep whole lines until the next one would cross the limit.
printf '%s\n' "$CHANGES" | awk -v lim="$LIMIT" '
  {
    add = length($0) + 1
    if (used + add > lim) { truncated = 1; exit }
    print
    used += add
  }
  END { if (truncated) print "..." }
'
