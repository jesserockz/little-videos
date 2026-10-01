#!/usr/bin/env bash
# Create or update the GitHub labels the Release Drafter config depends on.
# Idempotent: --force updates an existing label rather than failing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in gh yq jq; do
  command -v "$tool" > /dev/null || { echo "$tool is not on PATH" >&2; exit 1; }
done

FILE="$ROOT/.github/labels.yml"
REPO="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

[ -f "$FILE" ] || { echo "no $FILE" >&2; exit 1; }

echo "syncing labels to $REPO"
# yq only converts YAML to JSON (-o=json is the mikefarah/yq v4 spelling); jq does the rest.
if ! LABELS="$(yq -o=json '.' "$FILE" | jq -r '.[] | [.name, .color, (.description // "")] | join("\t")')"; then
  echo "could not read $FILE" >&2
  exit 1
fi
[ -n "$LABELS" ] || { echo "no labels in $FILE" >&2; exit 1; }
while IFS=$'\t' read -r NAME COLOR DESC; do
  gh label create "$NAME" --repo "$REPO" --color "$COLOR" --description "$DESC" --force > /dev/null
  echo "  $NAME"
done <<< "$LABELS"
echo "done"
