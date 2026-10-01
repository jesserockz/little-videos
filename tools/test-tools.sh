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

# Every throwaway tree lives under one root so a single trap cleans them all.
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT:?}"' EXIT

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

# yq -o=json is the mikefarah/yq v4 spelling; jq pulls the template out.
body() { # renders the real drafter template with the given changes block
  local t
  t="$(yq -o=json '.' .github/release-drafter.yml | jq -r '.template')"
  t="${t//\$CHANGES/"$1"}"
  t="${t//\$RESOLVED_VERSION/"${2:-1.1.0}"}"
  t="${t//\$PREVIOUS_TAG/v1.0.0}"
  printf '%s\n' "$t"
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

LONG="$(for i in $(seq 1 29); do
  printf -- '- A reasonably wordy change number %s taking up room (#%s) @jesserockz\n' "$i" "$i"
done)"
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
echo "fdroid-add-build.sh"

APP="$(sed -n 's/^APP_ID="\(.*\)"$/\1/p' build.sh)"
META_NAME="$APP.yml"
ab_tree() { # name -> prints a throwaway tree holding just what the tools read
  local T="$TMP_ROOT/ab-$1"
  mkdir -p "$T/tools" "$T/fdroid"
  cp build.sh "$T/"
  cp tools/fdroid-add-build.sh tools/check-metadata.sh tools/version-code.sh "$T/tools/"
  cp "fdroid/$META_NAME" "$T/fdroid/"
  cp -r fastlane "$T/"
  echo "$T"
}
ab() { (cd "$AB" && ./tools/fdroid-add-build.sh "$@" 2>&1); }

AB="$(ab_tree main)"
META="$AB/fdroid/$META_NAME"
cp "$META" "$AB/orig.yml"

OUT="$(ab 1.1.0)"
check "adds a new version" "added 1.1.0 (10100) to $META_NAME" "$OUT"

N="$(grep -c '^  - versionName: 1.1.0$' "$META")"
check "writes exactly one entry" "1" "$N"
check "derives the versionCode" "    versionCode: 10100" "$(grep '^    versionCode: 10100$' "$META")"
check "derives the commit tag" "    commit: v1.1.0" "$(grep '^    commit: v1.1.0$' "$META")"
check "derives the output path" "    output: dist/little-videos-1.1.0.apk" "$(grep '^    output: dist/little-videos-1.1.0.apk$' "$META")"
check "stamps VERSION_NAME" "      - export VERSION_NAME=1.1.0" "$(grep '^      - export VERSION_NAME=1.1.0$' "$META")"
check "stamps VERSION_CODE" "      - export VERSION_CODE=10100" "$(grep '^      - export VERSION_CODE=10100$' "$META")"
check "bumps CurrentVersion" "CurrentVersion: 1.1.0" "$(grep '^CurrentVersion:' "$META")"
check "bumps CurrentVersionCode" "CurrentVersionCode: 10100" "$(grep '^CurrentVersionCode:' "$META")"

# The build block explains the versionCode formula in prose. A blanket
# search and replace rewrites the multiplier in that comment.
K="$(grep -c 'major\*10000 + minor\*100 + patch' "$META")"
check "leaves the formula comment alone" "2" "$K"
check "carries the toolchain forward" "2" "$(grep -c 'openjdk-17-jdk-headless' "$META")"

# Only the two Current* lines may be removed, and the new entry must equal the
# old one once its version and code are mapped back.
diff "$AB/orig.yml" "$META" > "$AB/diff.txt" || true
check "removes only the Current* lines" "$(printf '< CurrentVersion: 1.0.0\n< CurrentVersionCode: 10000')" "$(grep '^<' "$AB/diff.txt")"
sed -n '/^  - versionName: 1.1.0$/,/^      - .\/build.sh$/p' "$META" | sed 's/1\.1\.0/1.0.0/g; s/10100/10000/g' > "$AB/new-entry.txt"
sed -n '/^  - versionName: 1.0.0$/,/^      - .\/build.sh$/p' "$AB/orig.yml" > "$AB/old-entry.txt"
check "new entry is the old one with only the version fields changed" "$(cat "$AB/old-entry.txt")" "$(cat "$AB/new-entry.txt")"
check "inserts right after the last entry" "$(printf '      - ./build.sh\n  - versionName: 1.1.0')" "$(grep -B1 '^  - versionName: 1.1.0$' "$META")"
check "keeps the blank line after the entries" "[]" "$(awk '/^      - export VERSION_CODE=10100$/ {f=1} f && /^      - \.\/build\.sh$/ {getline n; print "[" n "]"; exit}' "$META")"

cp "$META" "$AB/after110.yml"
OUT="$(ab 1.1.0)"
check "is idempotent" "1.1.0 is already in $META_NAME, nothing to do" "$OUT"
check "idempotent run leaves the file alone" "yes" "$(cmp -s "$AB/after110.yml" "$META" && echo yes || echo no)"

OUT="$(ab 1.0.5 | tail -1)"
check "refuses to go backwards" "error: 1.0.5 is not newer than the last entry 1.1.0" "$OUT"
OUT="$(ab 01.1.0 | tail -1)"
check "refuses an equal versionCode" "error: 01.1.0 is not newer than the last entry 1.1.0" "$OUT"
check "a refusal leaves the file alone" "yes" "$(cmp -s "$AB/after110.yml" "$META" && echo yes || echo no)"

OUT="$(ab 1.1 | tail -1)"
check "refuses a non-semver version" "error: '1.1' is not major.minor.patch" "$OUT"
OUT="$(ab 1.100.0 | tail -1)"
check "refuses a version that would collide" "yes" "$(case "$OUT" in *collide*) echo yes ;; *) echo no ;; esac)"
ab 1.100.0 > /dev/null; check "a colliding version exits 1" "1" "$?"

ab > /dev/null; check "no argument exits 2" "2" "$?"
ab 1.2.0 extra > /dev/null; check "extra argument exits 2" "2" "$?"
OUT="$(ab || true)"
check "usage is printed" "usage: ./tools/fdroid-add-build.sh <MAJOR.MINOR.PATCH>" "$OUT"

# A second release is appended after the first, not before it.
OUT="$(ab 1.2.0)"
check "adds a later version" "added 1.2.0 (10200) to $META_NAME" "$OUT"
check "orders entries oldest to newest" "$(printf '1.0.0\n1.1.0\n1.2.0')" "$(sed -n 's/^  - versionName: //p' "$META")"
check "later version copies from the newest entry" "      - export VERSION_CODE=10200" "$(grep '^      - export VERSION_CODE=10200$' "$META")"
check "later version bumps CurrentVersionCode" "CurrentVersionCode: 10200" "$(grep '^CurrentVersionCode:' "$META")"

# An entry that runs to the end of the file, with no Current* lines at all.
AB="$(ab_tree eof)"
META="$AB/fdroid/$META_NAME"
sed -n '/^Builds:/,/^      - .\/build.sh$/p' "fdroid/$META_NAME" > "$META"
OUT="$(ab 1.0.1)"
check "handles an entry at the end of the file" "added 1.0.1 (10001) to $META_NAME" "$OUT"
check "appends it at the end" "  - versionName: 1.0.1" "$(grep '^  - versionName: 1.0.1$' "$META")"
check "does not invent Current* lines" "0" "$(grep -c '^CurrentVersion' "$META")"

AB="$(ab_tree noentries)"
printf 'Builds:\nCurrentVersion: 1.0.0\n' > "$AB/fdroid/$META_NAME"
OUT="$(ab 1.1.0)"
check "no Builds entries is an error" "no Builds entries to copy from" "$OUT"
ab 1.1.0 > /dev/null; check "no Builds entries exits 1" "1" "$?"

AB="$(ab_tree badprev)"
printf 'Builds:\n  - versionName: nightly\n    versionCode: 1\n' > "$AB/fdroid/$META_NAME"
OUT="$(ab 1.1.0)"
check "an unreadable last version is an error" "::error::version 'nightly' is not MAJOR.MINOR.PATCH" "$OUT"

AB="$(ab_tree nometa)"
rm "$AB/fdroid/$META_NAME"
OUT="$(ab 1.1.0)"
check "missing metadata file is an error" "error: $AB/fdroid/$META_NAME does not exist" "$OUT"
ab 1.1.0 > /dev/null; check "missing metadata file exits 1" "1" "$?"

AB="$(ab_tree noappid)"
printf '# nothing here\n' > "$AB/build.sh"
OUT="$(ab 1.1.0)"
check "unreadable APP_ID is an error" "could not read APP_ID out of build.sh" "$OUT"

echo
echo "check-metadata.sh"

cm() { (cd "$AB" && ./tools/check-metadata.sh 2>&1); }
OUT="$(./tools/check-metadata.sh 2>&1)"
check "the real metadata is consistent" "metadata is consistent" "$(printf '%s\n' "$OUT" | tail -1)"

AB="$(ab_tree cmgood)"
OUT="$(cm)"
check "a clean copy is consistent" "metadata is consistent" "$(printf '%s\n' "$OUT" | tail -1)"
check "reads each Builds field" "yes" "$(printf '%s\n' "$OUT" | grep -q 'ok: 1.0.0 -> output dist/little-videos-1.0.0.apk' && echo yes || echo no)"

AB="$(ab_tree cmcode)"
sed -i 's/^    versionCode: 10000$/    versionCode: 99999/' "$AB/fdroid/$META_NAME"
OUT="$(cm)"
check "a wrong versionCode fails" "yes" "$(printf '%s\n' "$OUT" | grep -q 'FAIL: 1.0.0 should be versionCode 10000, not 99999' && echo yes || echo no)"
check "a failure ends with the problems line" "metadata problems found" "$(printf '%s\n' "$OUT" | tail -1)"
(cd "$AB" && ./tools/check-metadata.sh > /dev/null 2>&1); check "a failure exits 1" "1" "$?"

AB="$(ab_tree cmcurrent)"
sed -i 's/^CurrentVersion: 1.0.0$/CurrentVersion: 0.9.0/; s/^CurrentVersionCode: 10000$/CurrentVersionCode: 900/' "$AB/fdroid/$META_NAME"
OUT="$(cm)"
check "a stale CurrentVersion fails" "yes" "$(printf '%s\n' "$OUT" | grep -q "FAIL: CurrentVersion is '0.9.0', newest Builds entry is '1.0.0'" && echo yes || echo no)"
check "a stale CurrentVersionCode fails" "yes" "$(printf '%s\n' "$OUT" | grep -q "FAIL: CurrentVersionCode is '900', newest Builds entry is '10000'" && echo yes || echo no)"

AB="$(ab_tree cmname)"
sed -i 's/^  - versionName: 1.0.0$/  - versionName: 1.100.0/' "$AB/fdroid/$META_NAME"
OUT="$(cm)"
check "a versionName with no versionCode fails" "yes" "$(printf '%s\n' "$OUT" | grep -q "FAIL: versionName '1.100.0' cannot be turned into a versionCode" && echo yes || echo no)"

AB="$(ab_tree cmjunk)"
sed -i 's/^  - versionName: 1.0.0$/  - versionName: nightly/' "$AB/fdroid/$META_NAME"
OUT="$(cm)"
check "a non-semver versionName fails" "yes" "$(printf '%s\n' "$OUT" | grep -q "FAIL: versionName 'nightly' is not major.minor.patch" && echo yes || echo no)"

AB="$(ab_tree cmparse)"
printf 'Builds: [\n' >> "$AB/fdroid/$META_NAME"
OUT="$(cm)"
check "unparsable YAML fails" "yes" "$(printf '%s\n' "$OUT" | grep -q "FAIL: could not parse fdroid/$META_NAME" && echo yes || echo no)"

AB="$(ab_tree cmnoyq)"
NOTOOLS="$TMP_ROOT/notools"
mkdir -p "$NOTOOLS"
ln -sf "$(command -v dirname)" "$NOTOOLS/dirname"
OUT="$(cd "$AB" && PATH="$NOTOOLS" "$(command -v bash)" ./tools/check-metadata.sh 2>&1)"
check "a missing yq is reported" "yq is not on PATH" "$OUT"

echo
echo "sync-labels.sh"

STUBBIN="$TMP_ROOT/stubbin"
GH_LOG="$TMP_ROOT/gh.log"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2" = "repo view" ]; then echo stub/repo; exit 0; fi
printf '%s\n' "$*" >> "$GH_LOG"
STUB
chmod +x "$STUBBIN/gh"
sl_tree() { # name -> prints a tree with sync-labels.sh and the real labels.yml
  local T="$TMP_ROOT/sl-$1"
  mkdir -p "$T/tools" "$T/.github"
  cp tools/sync-labels.sh "$T/tools/"
  cp .github/labels.yml "$T/.github/"
  echo "$T"
}
sl() { (cd "$SL" && PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" ./tools/sync-labels.sh 2>&1); }

SL="$(sl_tree main)"
: > "$GH_LOG"
OUT="$(sl)"
EXPECT="$(grep -c '^- name:' .github/labels.yml)"
check "asks gh for the repo when GH_REPO is unset" "syncing labels to stub/repo" "$(printf '%s\n' "$OUT" | head -1)"
check "ends with done" "done" "$(printf '%s\n' "$OUT" | tail -1)"
check "creates every label in labels.yml" "$EXPECT" "$(wc -l < "$GH_LOG" | tr -d ' ')"
check "passes name, color and description" "label create breaking --repo stub/repo --color b60205 --description Incompatible change; bumps the major version --force" "$(head -1 "$GH_LOG")"
ALL="yes"
while IFS=$'\t' read -r N C D; do
  grep -qxF "label create $N --repo stub/repo --color $C --description $D --force" "$GH_LOG" || ALL="no: $N"
done <<< "$(yq -o=json '.' .github/labels.yml | jq -r '.[] | [.name, .color, .description] | join("\t")')"
check "every label is passed with its own fields" "yes" "$ALL"
check "echoes each label name" "$EXPECT" "$(printf '%s\n' "$OUT" | grep -c '^  ')"

: > "$GH_LOG"
OUT="$(GH_REPO=o/r sl)"
check "GH_REPO overrides the lookup" "syncing labels to o/r" "$(printf '%s\n' "$OUT" | head -1)"
check "GH_REPO is passed to gh label" "yes" "$(grep -q -- '--repo o/r ' "$GH_LOG" && echo yes || echo no)"

SL="$(sl_tree nodesc)"
printf -- '- name: bare\n  color: ffffff\n' > "$SL/.github/labels.yml"
: > "$GH_LOG"
sl > /dev/null
check "a label without a description gets an empty one" "label create bare --repo stub/repo --color ffffff --description  --force" "$(cat "$GH_LOG")"

SL="$(sl_tree nofile)"
rm "$SL/.github/labels.yml"
OUT="$(sl)"
check "a missing labels file is an error" "no $SL/.github/labels.yml" "$OUT"
sl > /dev/null; check "a missing labels file exits 1" "1" "$?"

SL="$(sl_tree bad)"
printf 'not: [valid\n' > "$SL/.github/labels.yml"
OUT="$(sl | tail -1)"
check "unparsable labels file is an error" "could not read $SL/.github/labels.yml" "$OUT"

SL="$(sl_tree empty)"
printf '[]\n' > "$SL/.github/labels.yml"
OUT="$(sl | tail -1)"
check "an empty labels file is an error" "no labels in $SL/.github/labels.yml" "$OUT"

SL="$(sl_tree nogh)"
OUT="$(cd "$SL" && PATH="$NOTOOLS" "$(command -v bash)" ./tools/sync-labels.sh 2>&1)"
check "a missing gh is reported" "gh is not on PATH" "$OUT"
ln -sf "$STUBBIN/gh" "$NOTOOLS/gh"
OUT="$(cd "$SL" && PATH="$NOTOOLS" "$(command -v bash)" ./tools/sync-labels.sh 2>&1)"
check "a missing yq is reported" "yq is not on PATH" "$OUT"
rm "$NOTOOLS/gh"

echo
echo "release-changelog.sh"

# Throwaway repo with the real tools copied in; nothing touches this checkout.
RC_TMP="$TMP_ROOT/rc"
mkdir -p "$RC_TMP"
mkdir -p "$RC_TMP/tools"
cp tools/release-changelog.sh tools/fdroid-changelog.sh tools/version-code.sh "$RC_TMP/tools/"
RC="$RC_TMP/tools/release-changelog.sh"
CLDIR="fastlane/metadata/android/en-US/changelogs"
(
  cd "$RC_TMP"
  git init -q -b main .
  git config user.name tester
  git config user.email tester@example.invalid
  git config commit.gpgsign false
  mkdir -p "$CLDIR"
  printf 'x\n' > README
  printf -- '- Old note (#1)\n' > "$CLDIR/10100.txt"
  git add .
  GIT_AUTHOR_DATE="@1700000000 +0000" GIT_COMMITTER_DATE="@1700000000 +0000" git commit -q -m base
) > /dev/null
rc() { (cd "$RC_TMP" && "$RC" "$@"); }
g() { git -C "$RC_TMP" "$@"; }
TGT="$(g rev-parse HEAD)"

NEWBODY="$(body '- Fresh note (#2) @a')"
SAMEBODY="$(body '- Old note (#1) @a')"

OBJ_BEFORE="$(g count-objects -v | grep '^count:')"
OUT="$(printf '%s\n' "$SAMEBODY" | rc 1.1.0 "$TGT" 2>/dev/null)"
check "unchanged prints the target" "$TGT" "$OUT"
check "unchanged writes no objects" "$OBJ_BEFORE" "$(g count-objects -v | grep '^count:')"
check "unchanged leaves HEAD alone" "$TGT" "$(g rev-parse HEAD)"

BEFORE_STATUS="$(g status --porcelain)"
BEFORE_INDEX="$(g ls-files -s)"
OUT="$(printf '%s\n' "$NEWBODY" | rc 1.1.0 "$TGT" 2>/dev/null)"
check "changed prints a new sha" "yes" "$([ -n "$OUT" ] && [ "$OUT" != "$TGT" ] && echo yes || echo no)"
check "new commit is a child of the target" "$TGT" "$(g rev-parse "$OUT^")"
check "author date is the target's committer date" "1700000000" "$(g show -s --format=%at "$OUT")"
check "committer date is the target's committer date" "1700000000" "$(g show -s --format=%ct "$OUT")"
check "uses the bot identity" "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>" "$(g show -s --format='%cn <%ce>' "$OUT")"
check "uses the fixed message" "Update F-Droid changelog for 1.1.0" "$(g show -s --format=%s "$OUT")"
check "file holds the rendered body" "$(printf '%s\n' "$NEWBODY" | ./tools/fdroid-changelog.sh)" "$(g show "$OUT:$CLDIR/10100.txt")"
check "only the changelog changed" "$CLDIR/10100.txt" "$(g diff --name-only "$TGT" "$OUT")"
check "leaves HEAD alone after a change" "$TGT" "$(g rev-parse HEAD)"
check "leaves the branch alone after a change" "$TGT" "$(g rev-parse main)"
check "leaves the index alone after a change" "$BEFORE_INDEX" "$(g ls-files -s)"
check "leaves the working tree alone after a change" "$BEFORE_STATUS" "$(g status --porcelain)"
check "working file is untouched" "- Old note (#1)" "$(cat "$RC_TMP/$CLDIR/10100.txt")"

OUT2="$(printf '%s\n' "$NEWBODY" | rc 1.1.0 "$TGT" 2>/dev/null)"
check "is deterministic across runs" "$OUT" "$OUT2"

OUT="$(printf '%s\n' "$NEWBODY" | rc 1.2.0 "$TGT" 2>/dev/null)"
check "missing file counts as different" "- Fresh note (#2)" "$(g show "$OUT:$CLDIR/10200.txt")"
check "missing file still parents on the target" "$TGT" "$(g rev-parse "$OUT^")"

printf '%s\n' "$NEWBODY" | rc 1.1 "$TGT" > /dev/null 2>&1
check "invalid version fails" "1" "$?"
printf '%s\n' "$NEWBODY" | rc 1.1.0 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef > /dev/null 2>&1
check "unresolvable target fails" "1" "$?"
rc 1.1.0 > /dev/null 2>&1
check "wrong argument count fails" "2" "$?"

echo
echo "version-code.sh"

VC="./tools/version-code.sh"
check "1.0.0" "10000" "$($VC 1.0.0 2>&1)"
check "1.2.3" "10203" "$($VC 1.2.3 2>&1)"
check "0.0.1" "1" "$($VC 0.0.1 2>&1)"
check "99.99.99" "999999" "$($VC 99.99.99 2>&1)"
check "leading zeros are decimal, not octal" "10809" "$($VC 1.08.09 2>&1)"
for BAD in 1.2 1.2.3.4 v1.2.3 "" a.b.c 1.2.x " 1.2.3" "1.2.3 "; do
  $VC "$BAD" > /dev/null 2>&1
  check "rejects '$BAD'" "1" "$?"
done
check "invalid version explains itself" "::error::version '1.2' is not MAJOR.MINOR.PATCH" "$($VC 1.2 2>&1)"
$VC 1.100.0 > /dev/null 2>&1
check "rejects a minor of 100" "1" "$?"
$VC 1.0.100 > /dev/null 2>&1
check "rejects a patch of 100" "1" "$?"
case "$($VC 1.100.0 2>&1)" in
  *collide*) PASS=$((PASS+1)); echo "  ok   collision error says why" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL collision error does not say why" ;;
esac
$VC > /dev/null 2>&1
check "no argument fails" "2" "$?"
$VC 1.2.3 4 > /dev/null 2>&1
check "extra argument fails" "2" "$?"

echo
echo "commit-and-push.sh"

CP="$ROOT/tools/commit-and-push.sh"
CP_TMP="$TMP_ROOT/cp"
mkdir -p "$CP_TMP"
BOT="github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"

# Bare origin plus two clones (the second moves the remote under the first).
# GIT_CONFIG_GLOBAL is nulled so a developer's identity cannot leak in.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
newrepo() { # name -> creates $CP_TMP/<name>.git, <name> and <name>-other
  local N="$1"
  git init -q --bare -b main "$CP_TMP/$N.git"
  git clone -q "$CP_TMP/$N.git" "$CP_TMP/$N" 2> /dev/null
  git -C "$CP_TMP/$N" config user.name tester
  git -C "$CP_TMP/$N" config user.email tester@example.invalid
  git -C "$CP_TMP/$N" config commit.gpgsign false
  mkdir -p "$CP_TMP/$N/dir"
  printf 'one\n' > "$CP_TMP/$N/dir/a.txt"
  printf 'one\n' > "$CP_TMP/$N/other.txt"
  git -C "$CP_TMP/$N" add .
  git -C "$CP_TMP/$N" commit -q -m base
  git -C "$CP_TMP/$N" push -q origin HEAD:main 2> /dev/null
  git clone -q "$CP_TMP/$N.git" "$CP_TMP/$N-other" 2> /dev/null
  git -C "$CP_TMP/$N-other" config user.name other
  git -C "$CP_TMP/$N-other" config user.email other@example.invalid
  git -C "$CP_TMP/$N-other" config commit.gpgsign false
}
cp_run() { # repo name, then script args
  local N="$1"; shift
  (cd "$CP_TMP/$N" && "$CP" "$@" 2> "$CP_TMP/stderr")
}

newrepo nothing
R="$CP_TMP/nothing"
HEAD0="$(git -C "$R" rev-parse HEAD)"
OUT="$(cp_run nothing main "msg" dir)"
check "nothing to commit prints HEAD" "$HEAD0" "$OUT"
check "nothing to commit makes no commit" "$HEAD0" "$(git -C "$R" rev-parse HEAD)"
check "nothing to commit says so" "nothing to commit under: dir" "$(cat "$CP_TMP/stderr")"
cp_run nothing main "msg" dir > /dev/null
check "nothing to commit exits 0" "0" "$?"

newrepo change
R="$CP_TMP/change"
HEAD0="$(git -C "$R" rev-parse HEAD)"
printf 'two\n' > "$R/dir/a.txt"
printf 'new\n' > "$R/dir/b.txt"
printf 'unrelated\n' > "$R/other.txt"
OUT="$(cp_run change main "Update things" dir)"
check "a change creates a commit" "$HEAD0" "$(git -C "$R" rev-parse HEAD^)"
check "stdout is the new HEAD" "$(git -C "$R" rev-parse HEAD)" "$OUT"
check "the remote branch is that commit" "$OUT" "$(git -C "$R.git" rev-parse main)"
check "commit uses the given message" "Update things" "$(git -C "$R" show -s --format=%s "$OUT")"
check "commit is authored by the bot" "$BOT" "$(git -C "$R" show -s --format='%an <%ae>' "$OUT")"
check "commit is committed by the bot" "$BOT" "$(git -C "$R" show -s --format='%cn <%ce>' "$OUT")"
check "stages new files too" "dir/a.txt
dir/b.txt" "$(git -C "$R" diff --name-only HEAD^ HEAD)"
check "an unlisted modified file stays uncommitted" " M other.txt" "$(git -C "$R" status --porcelain)"
check "an unlisted file is not on the remote" "one" "$(git -C "$R.git" show main:other.txt)"
check "the repo config is not given the bot name" "tester" "$(git -C "$R" config user.name)"

newrepo noconfig
R="$CP_TMP/noconfig"
git -C "$R" config --unset user.name
git -C "$R" config --unset user.email
printf 'two\n' > "$R/dir/a.txt"
cp_run noconfig main "msg" dir > /dev/null
check "works with no identity configured" "0" "$?"
check "and still does not write one" "" "$(git -C "$R" config --local --get user.name || true)"

newrepo deletion
R="$CP_TMP/deletion"
rm "$R/dir/a.txt"
OUT="$(cp_run deletion main "Remove a" dir)"
check "a deletion under the path is committed" "dir/a.txt" "$(git -C "$R" diff --name-only --diff-filter=D HEAD^ HEAD)"

# Remote moves on a file the job does not touch.
newrepo race
R="$CP_TMP/race"
printf 'theirs\n' > "$CP_TMP/race-other/other.txt"
git -C "$CP_TMP/race-other" commit -q -am "someone else"
git -C "$CP_TMP/race-other" push -q origin HEAD:main 2> /dev/null
printf 'two\n' > "$R/dir/a.txt"
OUT="$(cp_run race main "Mine" dir)"
check "a rejected push rebases and succeeds" "0" "$?"
check "the remote has both commits" "Mine
someone else" "$(git -C "$R.git" log -2 --format=%s main)"
check "stdout is the rebased HEAD" "$OUT" "$(git -C "$R.git" rev-parse main)"
check "the rebased commit is still the bot's" "$BOT" "$(git -C "$R" show -s --format='%cn <%ce>' "$OUT")"
case "$(cat "$CP_TMP/stderr")" in
  *"push rejected on attempt 1"*) PASS=$((PASS+1)); echo "  ok   reports the retry" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL does not report the retry" ;;
esac

# Remote moves on the file this job changes.
newrepo conflict
R="$CP_TMP/conflict"
printf 'theirs\n' > "$CP_TMP/conflict-other/dir/a.txt"
git -C "$CP_TMP/conflict-other" commit -q -am "someone else"
git -C "$CP_TMP/conflict-other" push -q origin HEAD:main 2> /dev/null
printf 'mine\n' > "$R/dir/a.txt"
cp_run conflict main "Mine" dir > /dev/null
check "a conflicting remote change fails" "1" "$?"
check "no rebase is left in progress" "no" "$([ -d "$R/.git/rebase-merge" ] || [ -d "$R/.git/rebase-apply" ] && echo yes || echo no)"
check "the conflict is reported" "yes" "$(grep -q '::error::could not rebase' "$CP_TMP/stderr" && echo yes || echo no)"
check "the remote is left alone" "theirs" "$(git -C "$R.git" show main:dir/a.txt)"

# Remote refuses every push, so the retries run out.
newrepo reject
R="$CP_TMP/reject"
printf '#!/bin/sh\nexit 1\n' > "$R.git/hooks/pre-receive"
chmod +x "$R.git/hooks/pre-receive"
printf 'two\n' > "$R/dir/a.txt"
cp_run reject main "Mine" dir > /dev/null
check "three rejected pushes fail" "1" "$?"
check "all three attempts were made" "3" "$(grep -c 'push rejected on attempt' "$CP_TMP/stderr")"
check "the failure says so" "yes" "$(grep -q '::error::could not push to main after 3 attempts' "$CP_TMP/stderr" && echo yes || echo no)"

# REMOTE picks a remote other than origin.
newrepo remote
R="$CP_TMP/remote"
git -C "$R" remote rename origin upstream
printf 'two\n' > "$R/dir/a.txt"
OUT="$(cd "$R" && REMOTE=upstream "$CP" main "Via upstream" dir 2> /dev/null)"
check "REMOTE selects the remote" "$OUT" "$(git -C "$R.git" rev-parse main)"

(cd "$R" && "$CP" main "msg" > /dev/null 2>&1)
check "too few arguments fails" "2" "$?"
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM

echo
echo "verify-reproducible.sh"

# The script resolves its root from its own location, so each case gets a tree
# with a copy. BUILD_CMD stubs build.sh; marker files make the rebuild differ.
VR_TMP="$TMP_ROOT/vr"
mkdir -p "$VR_TMP"
vr_tree() { # name -> prints the tree path
  local T="$VR_TMP/$1"
  mkdir -p "$T/tools" "$T/build" "$T/dist"
  cp "$ROOT/tools/verify-reproducible.sh" "$T/tools/"
  cat > "$T/stub.sh" <<'STUB'
#!/usr/bin/env bash
# Rebuild stub: honours the tree's marker files.
[ -f fail.rebuild ] && [ -f built.once ] && { echo "stub failure"; exit 1; }
mkdir -p build dist
if [ -f built.once ] && [ -f differ.unsigned ]; then
  echo "unsigned-two" > build/unsigned.apk
else
  echo "unsigned-one" > build/unsigned.apk
fi
if [ -f built.once ] && [ -f differ.signed ]; then
  echo "signed-two" > dist/little-videos-x.apk
else
  echo "signed-one" > dist/little-videos-x.apk
fi
touch built.once
STUB
  chmod +x "$T/stub.sh"
  echo "$T"
}
vr_first() { # tree: original build; built.once makes the next run the rebuild
  (cd "$1" && ./stub.sh)
}
vr_run() { # tree
  (cd "$1" && BUILD_CMD=./stub.sh ./tools/verify-reproducible.sh > "$1/out" 2> "$1/err")
}

T="$(vr_tree nobuild)"
rm -rf "$T/build" "$T/dist"
vr_run "$T"
check "no prior build fails" "1" "$?"
check "no prior build says to run build.sh" "yes" "$(grep -q 'run ./build.sh first' "$T/err" && echo yes || echo no)"

T="$(vr_tree nodist)"
echo u > "$T/build/unsigned.apk"
vr_run "$T"
check "missing dist apk fails" "1" "$?"

T="$(vr_tree twodist)"
echo u > "$T/build/unsigned.apk"
echo a > "$T/dist/a.apk"; echo b > "$T/dist/b.apk"
vr_run "$T"
check "two dist apks fail" "1" "$?"

T="$(vr_tree good)"
vr_first "$T"
vr_run "$T"
check "deterministic build passes" "0" "$?"
check "prints reproducible" "yes" "$(grep -q '^reproducible$' "$T/out" && echo yes || echo no)"
check "prints both hashes" "2" "$(grep -c 'sha256 ' "$T/out")"
check "artifacts remain" "yes" "$([ -f "$T/build/unsigned.apk" ] && [ -f "$T/dist/little-videos-x.apk" ] && echo yes || echo no)"

T="$(vr_tree unsigned)"
vr_first "$T"; touch "$T/differ.unsigned"
vr_run "$T"
check "unsigned mismatch fails" "1" "$?"
check "unsigned mismatch is reported" "yes" "$(grep -q 'the unsigned APK differs' "$T/err" && echo yes || echo no)"

T="$(vr_tree signed)"
vr_first "$T"; touch "$T/differ.signed"
vr_run "$T"
check "signed-only mismatch fails" "1" "$?"
check "signed mismatch is reported" "yes" "$(grep -q 'the signed APK differs' "$T/err" && ! grep -q 'the unsigned APK differs' "$T/err" && echo yes || echo no)"

T="$(vr_tree rebuildfail)"
vr_first "$T"; touch "$T/fail.rebuild"
vr_run "$T"
check "failing rebuild fails" "1" "$?"
check "failing rebuild shows its log" "yes" "$(grep -q 'stub failure' "$T/err" && echo yes || echo no)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
