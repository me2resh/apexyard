#!/bin/bash
# Verify check-dependency-record.sh on fixture repos (#2122).
set -eu
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
PASS=0
FAIL=0
check() {
  if "$@"; then PASS=$((PASS + 1)); else
    echo "FAIL: $*"
    FAIL=$((FAIL + 1))
  fi
}
S="$ROOT/.claude/skills/agdr/scripts/check-dependency-record.sh"
check test -f "$S"

R="$SB/repo"
mkdir -p "$R/docs/agdr"
g() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
git init -q "$R"
echo '{"dependencies":{"express":"1"},"devDependencies":{}}' > "$R/package.json"
g add package.json
g commit -qm base
BASE=$(g rev-parse HEAD)
snap() { g add docs package.json; g commit -aqm snap --allow-empty; }
run() { snap; bash "$S" "$R" "$BASE" 2>&1 || true; }
rc() { snap; bash "$S" "$R" "$BASE" >/dev/null 2>&1 && echo 0 || echo $?; }
setpkg() { echo "{\"dependencies\":{\"express\":\"1\"$1},\"devDependencies\":{$2}}" > "$R/package.json"; }

# No change.
check test "$(rc)" = 0
# Runtime dependency, no record: blocks.
setpkg ',"mongoose":"8"' ''
check test "$(rc)" = 1
check grep -q "^BLOCK	runtime	mongoose" <<< "$(run)"
# Register line: passes.
printf '| mongoose | db | team | MIT | none needed |\n' > "$R/docs/stack-register.md"
check test "$(rc)" = 0
# AgDR mention: passes.
rm "$R/docs/stack-register.md"
printf '# AgDR-0001: Use mongoose\n' > "$R/docs/agdr/AgDR-0001-m.md"
check test "$(rc)" = 0
rm "$R/docs/agdr/AgDR-0001-m.md"
# Dev-only dependency: warns, exit 0.
setpkg '' '"vitest":"1"'
check test "$(rc)" = 0
check grep -q "^WARN	dev	vitest" <<< "$(run)"
# Short name is ignored.
setpkg ',"zod":"3"' ''
check test "$(rc)" = 0
# Whole words: a record for next-auth does not cover next.
setpkg ',"next":"14"' ''
printf 'We use next-auth for sign in.\n' > "$R/docs/stack-register.md"
check test "$(rc)" = 1
# A record for next covers next, and next does not cover next-auth.
printf 'We use next here.\n' > "$R/docs/stack-register.md"
check test "$(rc)" = 0
setpkg ',"next-auth":"4"' ''
check test "$(rc)" = 1
# A record for lodash.merge or next.js does not cover lodash or next.
printf 'We use lodash.merge only.\n' > "$R/docs/stack-register.md"
setpkg ',"lodash":"4"' ''
check test "$(rc)" = 1
printf 'We use next.js here.\n' > "$R/docs/stack-register.md"
setpkg ',"next":"14"' ''
check test "$(rc)" = 1
# A sentence end after the name still matches.
printf 'We use lodash.\n' > "$R/docs/stack-register.md"
setpkg ',"lodash":"4"' ''
check test "$(rc)" = 0
rm "$R/docs/stack-register.md"
# Untracked files are not part of HEAD: a new dependency or host there is ignored.
setpkg '' ''
mkdir -p "$R/scratch"
echo '{"dependencies":{"leftpadder":"1"}}' > "$R/scratch/package.json"
echo "fetch('https://api.untracked-vendor.com/x')" > "$R/scratch/a.js"
check test "$(rc)" = 0
rm -r "$R/scratch"
# export-ignore in .gitattributes must not hide a manifest or forge a record.
setpkg ',"hidden-lib":"1"' ''
printf 'package.json export-ignore\n' > "$R/.gitattributes"
g add .gitattributes
check test "$(rc)" = 1
printf 'docs export-ignore\n' > "$R/.gitattributes"
printf 'hidden-lib is fine\n' > "$R/docs/stack-register.md"
check test "$(rc)" = 0
printf 'package.json export-ignore\ndocs/stack-register.md export-ignore\n' > "$R/.gitattributes"
check test "$(rc)" = 0
rm "$R/.gitattributes"
# Unknown base ref gives a usage error.
check test "$(bash "$S" "$R" nosuchref >/dev/null 2>&1; echo $?)" = 2

echo "Passed: $PASS Failed: $FAIL"
[ "$FAIL" -eq 0 ]
