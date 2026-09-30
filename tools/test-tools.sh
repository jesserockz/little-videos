#!/usr/bin/env bash
# Tests for the shell tooling in tools/.
#
# fdroid-changelog.sh turns a drafted release body into an F-Droid changelog.
# It runs unattended in the Release Drafter workflow and its output is
# committed to the repo and published to F-Droid, so its edge cases are worth
# pinning down: an over-long body silently truncated in the wrong place, or a
# placeholder treated as real content, both ship.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CL="./tools/fdroid-changelog.sh"

PASS=0
FAIL=0
check() { # name, expected, actual
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$(printf '%s' "$2" | head -3)" "$(printf '%s' "$3" | head -3)"
  fi
}

body() { # renders the real drafter template with the given changes block
  python3 - "$1" "${2:-1.1.0}" <<'PY'
import sys, yaml
t = yaml.safe_load(open(".github/release-drafter.yml"))["template"]
print(t.replace("$CHANGES", sys.argv[1])
       .replace("$RESOLVED_VERSION", sys.argv[2])
       .replace("$PREVIOUS_TAG", "v1.0.0"), end="")
PY
}

echo "fdroid-changelog.sh"

OUT="$(body '- Fix the cache evicting too early (#12) @jesserockz' | $CL)"
check "strips the trailing @author" "- Fix the cache evicting too early (#12)" "$OUT"

OUT="$(body '- Add a **repeat** mode (#11) @jesserockz' | $CL)"
check "strips bold markers" "- Add a repeat mode (#11)" "$OUT"

OUT="$(body '- Bump [actions/checkout](https://github.com/actions/checkout) (#10) @dependabot' | $CL)"
check "unwraps markdown links" "- Bump actions/checkout (#10)" "$OUT"

OUT="$(body '- One (#1) @a' | $CL)"
check "drops the caution block" "- One (#1)" "$OUT"

OUT="$(body '- One (#1) @a' | sed '/<!-- ASSETS_PENDING -->/,/<!-- \/ASSETS_PENDING -->/d' | $CL)"
check "idempotent once the caution is gone" "- One (#1)" "$OUT"

OUT="$(body '- One (#1) @a' | $CL)"
case "$OUT" in
  *Install*|*Download*|*changelog:*) check "drops the install section" "no install text" "$OUT" ;;
  *) PASS=$((PASS + 1)); echo "  ok   drops the install section" ;;
esac

OUT="$(body '- No changes' | $CL)"
check "passes the no-changes placeholder through" "- No changes" "$OUT"

OUT="$(printf '' | $CL)"
check "handles an empty body" "no changes recorded" "$OUT"

LONG="$(python3 -c "print('\n'.join(f'- A reasonably wordy change number {i} taking up room (#{i}) @jesserockz' for i in range(1, 30)))")"
OUT="$(body "$LONG" | $CL)"
N="$(printf '%s' "$OUT" | wc -c)"
if [ "$N" -le 500 ]; then PASS=$((PASS+1)); echo "  ok   truncates to $N/500 chars"; else FAIL=$((FAIL+1)); echo "  FAIL truncated to $N chars, over 500"; fi
case "$OUT" in
  *$'\n...') PASS=$((PASS+1)); echo "  ok   marks truncation with an ellipsis" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL truncation is not marked" ;;
esac
if printf '%s' "$OUT" | grep -qE '^- .*\(#[0-9]+\)$|^\.\.\.$'; then
  PASS=$((PASS+1)); echo "  ok   truncates on a whole bullet"
else
  FAIL=$((FAIL+1)); echo "  FAIL truncated mid-bullet"
fi

OUT="$(body "$(printf -- '- First (#1) @a\n- Second (#2) @b\n- Third (#3) @c')" | $CL)"
check "keeps bullet order" "$(printf -- '- First (#1)\n- Second (#2)\n- Third (#3)')" "$OUT"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
