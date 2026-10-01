#!/usr/bin/env bash
# Commit the given paths as the Actions bot and push them to a branch.
#
#   tools/commit-and-push.sh <branch> <message> <path>...
#
# Prints the resulting HEAD sha on stdout (existing HEAD if nothing to commit).
# Retries with a rebase when the push is rejected because another merge landed.
# REMOTE overrides the remote name (default origin), for the tests.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <branch> <message> <path>..." >&2
  exit 2
fi
BRANCH="$1"
MESSAGE="$2"
shift 2
REMOTE="${REMOTE:-origin}"

GIT=(git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" -c commit.gpgsign=false)

# -A stages deletions too.
"${GIT[@]}" add -A -- "$@" >&2
if "${GIT[@]}" diff --cached --quiet; then
  echo "nothing to commit under: $*" >&2
  git rev-parse HEAD
  exit 0
fi
"${GIT[@]}" commit -q -m "$MESSAGE" >&2

PUSHED=""
for ATTEMPT in 1 2 3; do
  if git push -q "$REMOTE" "HEAD:$BRANCH" >&2; then
    PUSHED=yes
    break
  fi
  echo "push rejected on attempt $ATTEMPT, rebasing onto $REMOTE/$BRANCH" >&2
  git fetch -q "$REMOTE" "$BRANCH" >&2
  if ! "${GIT[@]}" rebase "$REMOTE/$BRANCH" >&2; then
    "${GIT[@]}" rebase --abort >&2 || true
    echo "::error::could not rebase the commit onto $REMOTE/$BRANCH" >&2
    exit 1
  fi
done
if [ -z "$PUSHED" ]; then
  echo "::error::could not push to $BRANCH after 3 attempts" >&2
  exit 1
fi
echo "pushed to $BRANCH" >&2
git rev-parse HEAD
