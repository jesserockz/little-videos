#!/usr/bin/env bash
# Open a merge request against fdroiddata with the current metadata.
#
#   GITLAB_TOKEN=<api-scoped token> tools/fdroid-open-mr.sh 1.1.0
#
# F-Droid's build metadata lives at gitlab.com/fdroid/fdroiddata in
# metadata/<applicationId>.yml, and changes are submitted as merge requests.
# You cannot push to that project, so the branch goes on your own fork and the
# MR points from the fork to upstream.
#
# Needs, once:
#   - a GitLab account with a fork of fdroid/fdroiddata
#   - a personal access token with the `api` scope, as GITLAB_TOKEN
#   - FDROID_FORK if the fork is not <your-username>/fdroiddata
#
# Does nothing without GITLAB_TOKEN, so it is safe to wire into a workflow
# before you are ready to submit.
set -euo pipefail

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! VERSION_CODE="$(./tools/version-code.sh "$VERSION")"; then
  exit 1
fi

UPSTREAM_ID=36528                 # fdroid/fdroiddata
API=https://gitlab.com/api/v4

if [ -z "${GITLAB_TOKEN:-}" ]; then
  echo "GITLAB_TOKEN is not set, skipping the fdroiddata merge request."
  echo "Add it as a repository secret when you are ready to submit."
  exit 0
fi

api() { # method path [data]
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -sS --fail-with-body -X "$method" \
      -H "PRIVATE-TOKEN: $GITLAB_TOKEN" -H "Content-Type: application/json" \
      --data "$data" "$API$path"
  else
    curl -sS --fail-with-body -X "$method" \
      -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$API$path"
  fi
}

APP_ID="$(sed -n 's/^APP_ID="\(.*\)"$/\1/p' build.sh)"
LOCAL="fdroid/$APP_ID.yml"
[ -f "$LOCAL" ] || { echo "no $LOCAL" >&2; exit 1; }

if ! USER_JSON="$(api GET /user)"; then
  echo "::error::GITLAB_TOKEN was rejected by GitLab" >&2
  exit 1
fi
USERNAME="$(jq -r '.username' <<< "$USER_JSON")"
FORK="${FDROID_FORK:-$USERNAME/fdroiddata}"
FORK_ENC="$(jq -rn --arg s "$FORK" '$s|@uri')"
echo "authenticated as $USERNAME, using fork $FORK"

if ! api GET "/projects/$FORK_ENC" > /dev/null 2>&1; then
  echo "::error::$FORK does not exist. Fork https://gitlab.com/fdroid/fdroiddata first." >&2
  exit 1
fi

# Branch from upstream's current master so the MR diff is only our file.
if ! UP="$(api GET "/projects/$UPSTREAM_ID/repository/branches/master")"; then
  echo "::error::could not read upstream master" >&2
  exit 1
fi
BASE_SHA="$(jq -r '.commit.id' <<< "$UP")"
BRANCH="$APP_ID-$VERSION"
echo "upstream master is $BASE_SHA, branching $BRANCH on the fork"

if ! api POST "/projects/$FORK_ENC/repository/branches?branch=$(jq -rn --arg s "$BRANCH" '$s|@uri')&ref=$BASE_SHA" > /dev/null 2>&1; then
  if api GET "/projects/$FORK_ENC/repository/branches/$(jq -rn --arg s "$BRANCH" '$s|@uri')" > /dev/null 2>&1; then
    echo "branch $BRANCH already exists on the fork, reusing it"
  else
    echo "::error::could not create $BRANCH from $BASE_SHA." >&2
    echo "::error::The fork is probably behind upstream; sync it and re-run." >&2
    exit 1
  fi
fi

PATH_ENC="$(jq -rn --arg s "metadata/$APP_ID.yml" '$s|@uri')"
CONTENT="$(base64 -w0 < "$LOCAL")"
ACTION=update
NEW_APP=""
if ! api GET "/projects/$UPSTREAM_ID/repository/files/$PATH_ENC?ref=master" > /dev/null 2>&1; then
  ACTION=create
  NEW_APP=yes
  echo "$APP_ID is not in fdroiddata yet, this will be a new-app submission"
fi

PAYLOAD="$(jq -n --arg b "$BRANCH" --arg c "$CONTENT" --arg m "$APP_ID: $VERSION" \
  '{branch:$b, content:$c, encoding:"base64", commit_message:$m}')"
METHOD=PUT; [ "$ACTION" = create ] && METHOD=POST
if ! api "$METHOD" "/projects/$FORK_ENC/repository/files/$PATH_ENC" "$PAYLOAD" > /dev/null; then
  echo "::error::could not write metadata/$APP_ID.yml on the fork" >&2
  exit 1
fi
echo "committed metadata/$APP_ID.yml to $BRANCH"

TITLE="$APP_ID: $VERSION"
[ -n "$NEW_APP" ] && TITLE="New app: $APP_ID"
DESC="$(printf '%s\n' \
  "Adds \`$VERSION\` (versionCode $VERSION_CODE) for \`$APP_ID\`." \
  "" \
  "Reproducible build with the developer's signature: the release APK is attached to" \
  "https://github.com/jesserockz/little-videos/releases/tag/v$VERSION and" \
  "\`AllowedAPKSigningKeys\` holds the signing certificate." \
  "" \
  "The build is verified reproducible on every CI run by building twice under a" \
  "different wall clock, timezone and locale." \
  "" \
  "Opened automatically by the project's release workflow.")"

MR="$(jq -n --arg s "$BRANCH" --arg t "$TITLE" --arg d "$DESC" --argjson p "$UPSTREAM_ID" \
  '{source_branch:$s, target_branch:"master", target_project_id:$p, title:$t, description:$d, remove_source_branch:true}')"
if ! OUT="$(api POST "/projects/$FORK_ENC/merge_requests" "$MR")"; then
  echo "::error::could not open the merge request" >&2
  exit 1
fi
echo "merge request: $(jq -r '.web_url' <<< "$OUT")"
