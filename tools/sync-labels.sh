#!/usr/bin/env bash
# Create or update the GitHub labels the Release Drafter config depends on.
# Idempotent: --force updates an existing label rather than failing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="$ROOT/.github/labels.yml"
REPO="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

[ -f "$FILE" ] || { echo "no $FILE" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh is not on PATH" >&2; exit 1; }

echo "syncing labels to $REPO"
python3 -c "
import sys, yaml
for l in yaml.safe_load(open('$FILE')):
    print('\t'.join([l['name'], l['color'], l.get('description', '')]))
" | while IFS=$'\t' read -r NAME COLOR DESC; do
  [ -n "$NAME" ] || continue
  gh label create "$NAME" --repo "$REPO" --color "$COLOR" --description "$DESC" --force > /dev/null
  echo "  $NAME"
done
echo "done"
