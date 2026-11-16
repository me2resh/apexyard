#!/usr/bin/env bash
# me2resh/apexyard#2028 / AgDR-0302 — /launch-check open-PR lookup.
#
# /launch-check offers /security-review only when its PR lookup finds an open
# PR for the project's branch. The first version used a PR view command with
# --repo and no PR argument, which gh always rejects, so the offer never fired.
#
# This test extracts the lookup block from launch-check/SKILL.md and RUNS it:
#   1. Against a fake gh that applies gh's argument rules: a branch with a PR
#      gives one entry, a branch without a PR gives [], a detached HEAD gives
#      [] without a gh call. Each run must exit 0.
#   2. The old view form fails against the same fake (the regression).
#
# The test never calls the real gh. A hook test must not reach the network
# (_test-session-isolation.sh, #1528). The PR records a manual live run.
#
# Exit 0 = all pass, exit 1 = at least one failure.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT=${LAUNCH_CHECK_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
SKILL="$ROOT/.claude/skills/launch-check/SKILL.md"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

block=$(awk '/<!-- launch-check:pr-lookup/{m=1; next} m && /^```bash$/{on=1; next} on && /^```$/{exit} on' "$SKILL")
if [ -n "$block" ]; then ok "lookup block found in launch-check/SKILL.md"; else bad "lookup block found in launch-check/SKILL.md"; echo "0 left to run"; exit 1; fi
if printf '%s\n' "$block" | grep -q 'gh pr view'; then bad "lookup does not use gh pr view"; else ok "lookup does not use gh pr view"; fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Fake gh. It follows the gh rules that matter here:
#   gh pr view --repo R            -> exit 1, "argument required when using the --repo flag"
#   gh pr list --repo R --head B --state open --json number,url
#                                   -> [] or one entry (branch "has-pr")
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_GH_LOG"
[ "${1-}" = pr ] || { echo "fake gh: unsupported" >&2; exit 2; }
sub=${2-}; shift 2
repo=""; head=""; state=""; json=""; positional=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|-R) repo=${2-}; shift 2 ;;
    --head|-H) head=${2-}; shift 2 ;;
    --state|-s) state=${2-}; shift 2 ;;
    --json) json=${2-}; shift 2 ;;
    -*) echo "unknown flag: $1" >&2; exit 1 ;;
    *) positional=$1; shift ;;
  esac
done
case "$sub" in
  view)
    if [ -n "$repo" ] && [ -z "$positional" ]; then
      echo "argument required when using the --repo flag" >&2; exit 1
    fi
    echo '{"number":7,"url":"https://example.invalid/pull/7"}' ;;
  list)
    [ -n "$repo" ] || { echo "repo required" >&2; exit 1; }
    [ -n "$json" ] || { echo "json required" >&2; exit 1; }
    if [ "$head" = has-pr ] && [ "$state" = open ]; then
      echo '[{"number":7,"url":"https://example.invalid/pull/7"}]'
    else
      echo '[]'
    fi ;;
  *) echo "fake gh: unsupported" >&2; exit 2 ;;
esac
FAKE
chmod +x "$work/bin/gh"

make_repo() { # dir branch
  git init -q "$1"
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  git -C "$1" checkout -q -b "$2"
}
make_repo "$work/proj-pr" has-pr
make_repo "$work/proj-nopr" no-pr
make_repo "$work/proj-detached" main-line
git -C "$work/proj-detached" checkout -q --detach

run_lookup() { # project-path repo -> sets OUT and RC
  local script
  script=$(printf '%s\n' "$block" | sed -e "s#<project-path>#$1#g" -e "s#<owner/repo>#$2#g")
  OUT=$(PATH="$work/bin:$PATH" FAKE_GH_LOG="$work/gh.log" bash -c "$script" 2>"$work/err")
  RC=$?
}

: > "$work/gh.log"
run_lookup "$work/proj-pr" example/project
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.[0].number')" = 7 ]; then ok "branch with a PR: exit 0, one entry"; else bad "branch with a PR: rc=$RC out=$OUT err=$(cat "$work/err")"; fi
grep -q -- '--head has-pr --state open' "$work/gh.log" && ok "lookup filters on the branch and open state" || bad "lookup filters on the branch and open state"

run_lookup "$work/proj-nopr" example/project
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r 'length')" = 0 ]; then ok "branch without a PR: exit 0, empty list"; else bad "branch without a PR: rc=$RC out=$OUT"; fi

: > "$work/gh.log"
run_lookup "$work/proj-detached" example/project
if [ "$RC" -eq 0 ] && [ "$OUT" = '[]' ] && [ ! -s "$work/gh.log" ]; then ok "detached HEAD: exit 0, empty list, no gh call"; else bad "detached HEAD: rc=$RC out=$OUT"; fi

# Regression: the first version of the lookup fails against the same fake.
if PATH="$work/bin:$PATH" FAKE_GH_LOG="$work/gh.log" gh pr view --repo example/project --json number,url >/dev/null 2>&1; then
  bad "the old view form fails (fake gh follows the real rule)"
else
  ok "the old view form fails (fake gh follows the real rule)"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
