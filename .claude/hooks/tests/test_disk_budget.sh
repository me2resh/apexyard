#!/bin/bash
# check() reads the captured variables through eval.
# shellcheck disable=SC2034
# test_disk_budget.sh - me2resh/apexyard#2070 step 4 (AgDR-0306).
#
# Covers:
#   - check-disk-budget.sh (SessionStart): silent under budget, proposes a
#     sweep over the size limit or under the free-space limit, skips
#     compaction and a disabled config, stops at the time limit, uses the
#     cache, falls back on a bad config value, never removes anything.
#   - bin/apexyard-disk-sweep.sh: dry run lists remove and keep items with
#     the reason, saves a plan, --apply checks each item again, removes only
#     qualifying items, logs each result, and never uses --force.
#
# A fake gh on PATH answers PR lookups. No network.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/check-disk-budget.sh"
LIB="$ROOT/.claude/hooks/_lib-disk-budget.sh"
SWEEP="$ROOT/bin/apexyard-disk-sweep.sh"

PASS=0
FAIL=0
pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-disk-budget.XXXXXX")
TMP=$(cd -P "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

OPS="$TMP/ops"
mkdir -p "$OPS/.claude"
git init -q "$OPS"
touch "$OPS/.apexyard-fork"
cp "$ROOT/.claude/project-config.defaults.json" "$OPS/.claude/"
RC_ROOT="$TMP/review-copies"
mkdir -p "$RC_ROOT"
# Keep the step-3 review-copy root inside the sandbox for every case.
export APEXYARD_REVIEW_COPY_ROOT="$RC_ROOT"

override() {
  printf '%s\n' "$1" > "$OPS/.claude/project-config.json"
}

run_hook() {
  local source_kind="${1:-startup}"
  printf '{"hook_event_name":"SessionStart","source":"%s","cwd":"%s"}' "$source_kind" "$OPS" \
    | (cd "$OPS" && bash "$HOOK")
}

clear_cache() {
  rm -f "$OPS/.claude/session/disk-budget-size"
}

echo "== Static safety checks"
check "sweep script never passes --force" "! grep -n -e '--force' '$SWEEP' | grep -v '^[0-9]*:#' | grep -q ."
check "hook has no removal command" "! grep -Eq 'rm -rf|worktree remove' '$HOOK'"
check "library has no removal command" "! grep -Eq 'rm -rf|worktree remove' '$LIB'"
check "defaults ship the three limits" \
  "[ \"\$(jq -r '.disk_budget | [.max_owned_gb, .min_free_percent, .sweep_min_age_days] | map(tostring) | join(\" \")' '$ROOT/.claude/project-config.defaults.json')\" = '10 10 7' ]"
check "files are ASCII only" "! LC_ALL=C grep -n '[^ -~	]' '$HOOK' '$LIB' '$SWEEP' | grep -q ."

echo "== SessionStart check"
mkdir -p "$OPS/.claude/worktrees/big"
dd if=/dev/zero of="$OPS/.claude/worktrees/big/blob" bs=1024 count=2048 2>/dev/null

override '{"disk_budget":{"max_owned_gb":1000,"min_free_percent":0}}'
clear_cache
out=$(run_hook 2>/dev/null); rc=$?
check "under budget: silent" "[ -z \"\$out\" ] && [ $rc -eq 0 ]"

override '{"disk_budget":{"max_owned_gb":0.001,"min_free_percent":0}}'
clear_cache
out=$(run_hook 2>/dev/null); rc=$?
check "over size: proposes a sweep" "printf '%s' \"\$out\" | grep -q 'owned folders use' && printf '%s' \"\$out\" | grep -q 'apexyard-disk-sweep.sh'"
check "over size: asks for the user's yes" "printf '%s' \"\$out\" | grep -q 'Remove nothing until the user says yes'"
check "over size: exit 0" "[ $rc -eq 0 ]"
check "over size: nothing removed" "[ -f '$OPS/.claude/worktrees/big/blob' ]"
check "over size: size cached" "[ -f '$OPS/.claude/session/disk-budget-size' ]"

out=$(run_hook compact 2>/dev/null)
check "compact: silent" "[ -z \"\$out\" ]"

override '{"disk_budget":{"enabled":false,"max_owned_gb":0.001,"min_free_percent":100}}'
out=$(run_hook 2>/dev/null)
check "disabled: silent" "[ -z \"\$out\" ]"

override '{"disk_budget":{"max_owned_gb":1000,"min_free_percent":100}}'
clear_cache
out=$(run_hook 2>/dev/null)
check "low free space: proposes a sweep" "printf '%s' \"\$out\" | grep -q 'free disk space is'"

override '{"disk_budget":{"max_owned_gb":"abc","min_free_percent":0}}'
clear_cache
err=$(run_hook 2>&1 >/dev/null)
out=$(run_hook 2>/dev/null)
check "bad value: falls back to 10 GB and stays silent" "[ -z \"\$out\" ]"
check "bad value: warns on stderr" "printf '%s' \"\$err\" | grep -q 'max_owned_gb is not a number'"

# A slow disk: a fake du that never ends.
mkdir -p "$TMP/slowbin"
printf '#!/bin/bash\nexec sleep 30\n' > "$TMP/slowbin/du"
chmod +x "$TMP/slowbin/du"
override '{"disk_budget":{"max_owned_gb":0.001,"min_free_percent":0,"measure_timeout_seconds":1}}'
clear_cache
start=$(date +%s)
out=$(printf '{"hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$OPS" \
  | (cd "$OPS" && PATH="$TMP/slowbin:$PATH" bash "$HOOK") 2>/dev/null); rc=$?
elapsed=$(( $(date +%s) - start ))
check "slow disk: stops at the time limit (${elapsed}s)" "[ $elapsed -lt 8 ]"
check "slow disk: skips the size check and stays silent" "[ -z \"\$out\" ] && [ $rc -eq 0 ]"
check "slow disk: writes no cache" "[ ! -f '$OPS/.claude/session/disk-budget-size' ]"

printf '%s 999999999\n' "$(date +%s)" > "$OPS/.claude/session/disk-budget-size"
out=$(printf '{"hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$OPS" \
  | (cd "$OPS" && PATH="$TMP/slowbin:$PATH" bash "$HOOK") 2>/dev/null)
check "fresh cache: used without a new measurement" "printf '%s' \"\$out\" | grep -q 'owned folders use'"
clear_cache

mkdir -p "$TMP/outside/deep"
out=$(printf '{"hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$TMP/outside/deep" \
  | (cd "$TMP/outside/deep" && bash "$HOOK") 2>/dev/null); rc=$?
check "outside an ops fork: silent" "[ -z \"\$out\" ] && [ $rc -eq 0 ]"
rm -rf "$OPS/.claude/worktrees/big"

echo "== Sweep"
# Fake gh. pr list --head <branch> reads list-<branch>.json.
# pr view <n> reads view-<n>.json.
MOCK="$TMP/mock-gh"
mkdir -p "$MOCK" "$TMP/ghbin"
cat > "$TMP/ghbin/gh" <<'EOF'
#!/bin/bash
sub="$1 $2"
shift 2
head="" num=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head) head="$2"; shift 2 ;;
    --repo|--state|--json|--limit|--jq) shift 2 ;;
    *) num="$1"; shift ;;
  esac
done
printf '%s %s %s\n' "$sub" "$head" "$num" >> "$MOCK_GH_DIR/calls"
case "$sub" in
  "pr list")
    f="$MOCK_GH_DIR/list-${head//\//_}.json"
    if [ -f "$f" ]; then cat "$f"; else printf '[]\n'; fi ;;
  "pr view")
    f="$MOCK_GH_DIR/view-$num.json"
    if [ -f "$f" ]; then cat "$f"; else echo "not found" >&2; exit 1; fi ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/ghbin/gh"
export MOCK_GH_DIR="$MOCK"

WS="$OPS/workspace"
PROJ="$WS/proj"
mkdir -p "$WS"
git init -q --bare "$TMP/remote.git"
git init -q "$PROJ"
git -C "$PROJ" commit -q --allow-empty -m init
git -C "$PROJ" remote add origin "$TMP/remote.git"
git -C "$PROJ" push -q origin HEAD:refs/heads/main 2>/dev/null
git -C "$PROJ" fetch -q origin
git -C "$PROJ" remote set-url origin "https://github.com/acme/proj.git"
WT="$WS/proj.worktrees"
mkdir -p "$WT"

OLD=202601010000
make_wt() {
  local name="$1" state="$2"
  git -C "$PROJ" worktree add -q "$WT/$name" -b "feature/GH-1-$name" 2>/dev/null
  git -C "$WT/$name" commit -q --allow-empty -m "$name"
  local sha
  sha=$(git -C "$WT/$name" rev-parse HEAD)
  if [ -n "$state" ]; then
    printf '[{"number":%s,"state":"%s","headRefOid":"%s"}]\n' "$((RANDOM % 900 + 10))" "$state" "$sha" \
      > "$MOCK/list-feature_GH-1-$name.json"
  fi
}
age_wt() {
  local adm
  adm=$(git -C "$WT/$1" rev-parse --absolute-git-dir)
  touch -t "$OLD" "$adm/gitdir" "$adm/HEAD" "$adm/logs/HEAD" 2>/dev/null
}

make_wt merged MERGED;   age_wt merged
make_wt merged2 MERGED;  age_wt merged2
make_wt closed CLOSED;   age_wt closed
make_wt open OPEN;       age_wt open
make_wt dirty MERGED;    printf 'x\n' > "$WT/dirty/new.txt"; age_wt dirty
make_wt young MERGED
make_wt nopr "";         age_wt nopr
make_wt unpushed MERGED; git -C "$WT/unpushed" commit -q --allow-empty -m extra; age_wt unpushed
make_wt locked MERGED;   git -C "$PROJ" worktree lock "$WT/locked"; age_wt locked

# A worktree outside the owned folders must never appear.
mkdir -p "$TMP/elsewhere"
git -C "$PROJ" worktree add -q "$TMP/elsewhere/wt" -b feature/GH-1-elsewhere 2>/dev/null
printf '[{"number":5,"state":"MERGED","headRefOid":"x"}]\n' > "$MOCK/list-feature_GH-1-elsewhere.json"

# Review copies in the step-3 shape (AgDR-0305): a standalone clone with
# <copy>/.git/apexyard-review-copy.json. The root comes from
# APEXYARD_REVIEW_COPY_ROOT, as review-copy.sh reads it.
make_copy() {
  local dir="$1" pr="$2" created="$3" sha
  git init -q "$dir"
  git -C "$dir" remote add origin "https://github.com/acme/proj.git"
  git -C "$dir" commit -q --allow-empty -m "pr head"
  sha=$(git -C "$dir" rev-parse HEAD)
  if [ -n "$pr" ]; then
    jq -n --arg repo proj --argjson pr "$pr" --arg sha "$sha" --arg created "$created" --arg path "$dir" \
      '{repo:$repo,pr:$pr,head_sha:$sha,session:"s1",created_at:$created,path:$path}' \
      > "$dir/.git/apexyard-review-copy.json"
  fi
}
# copy-a: record, PR merged later at another head. The copy HEAD is the recorded head.
make_copy "$RC_ROOT/copy-a" 7 2026-01-01T00:00:00Z
printf '{"number":7,"state":"MERGED","headRefOid":"0123456789abcdef"}\n' > "$MOCK/view-7.json"
# copy-b: a clone with no record.
make_copy "$RC_ROOT/copy-b" "" ""
# copy-c: a plain folder, not a git clone.
mkdir -p "$RC_ROOT/copy-c"
# copy-d: record, but a local commit on top of the recorded head.
make_copy "$RC_ROOT/copy-d" 8 2026-01-01T00:00:00Z
git -C "$RC_ROOT/copy-d" commit -q --allow-empty -m "local work"
printf '{"number":8,"state":"MERGED","headRefOid":"0123456789abcdef"}\n' > "$MOCK/view-8.json"
# copy-y: record, but created today.
make_copy "$RC_ROOT/copy-y" 9 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"number":9,"state":"MERGED","headRefOid":"0123456789abcdef"}\n' > "$MOCK/view-9.json"
# copy-e: under a configured extra root.
mkdir -p "$TMP/extra-rc"
make_copy "$TMP/extra-rc/copy-e" 7 2026-01-01T00:00:00Z
ln -s "$TMP/elsewhere" "$RC_ROOT/link"

override "{\"disk_budget\":{\"review_copy_roots\":[\"$TMP/extra-rc\"],\"sweep_min_age_days\":7}}"

dry=$(cd "$OPS" && PATH="$TMP/ghbin:$PATH" bash "$SWEEP" 2>&1); rc=$?
printf '%s\n' "$dry" > "$TMP/dry.txt"
removes=$(sed -n '/^Remove/,/^$/p' "$TMP/dry.txt")
keeps=$(sed -n '/^Keep:/,/^$/p' "$TMP/dry.txt")
check "dry run: exit 0" "[ $rc -eq 0 ]"
check "dry run: says nothing was removed" "grep -q 'Nothing was removed' '$TMP/dry.txt'"
check "dry run: merged worktree is in the remove list" "printf '%s' \"\$removes\" | grep -q '/merged '"
check "dry run: closed worktree is in the remove list" "printf '%s' \"\$removes\" | grep -q '/closed '"
check "dry run: review copy with record is in the remove list" "printf '%s' \"\$removes\" | grep -q 'copy-a .*acme/proj#7 MERGED'"
check "dry run: copy under a configured root is in the remove list" "printf '%s' \"\$removes\" | grep -q 'copy-e'"
check "dry run: copy with a local commit kept" "printf '%s' \"\$keeps\" | grep 'copy-d' | grep -q 'not pushed'"
check "dry run: young copy kept (record time)" "printf '%s' \"\$keeps\" | grep 'copy-y' | grep -q 'newer than 7 days'"
check "dry run: folder that is not a clone kept" "printf '%s' \"\$keeps\" | grep 'copy-c' | grep -q 'not a git clone'"
check "dry run: open PR kept" "printf '%s' \"\$keeps\" | grep '/open ' | grep -q 'PR is open'"
check "dry run: dirty worktree kept" "printf '%s' \"\$keeps\" | grep '/dirty ' | grep -q 'uncommitted'"
check "dry run: young worktree kept" "printf '%s' \"\$keeps\" | grep '/young ' | grep -q 'newer than 7 days'"
check "dry run: worktree with no PR kept" "printf '%s' \"\$keeps\" | grep '/nopr ' | grep -q 'no PR found'"
check "dry run: unpushed commits kept" "printf '%s' \"\$keeps\" | grep '/unpushed ' | grep -q 'not pushed'"
check "dry run: locked worktree kept" "printf '%s' \"\$keeps\" | grep '/locked ' | grep -q 'locked'"
check "dry run: copy without record kept" "printf '%s' \"\$keeps\" | grep 'copy-b' | grep -q 'no review-copy record'"
check "dry run: symbolic link kept" "printf '%s' \"\$keeps\" | grep '/link ' | grep -q 'symbolic link'"
check "dry run: worktree outside owned folders not listed" "! grep -q 'elsewhere' '$TMP/dry.txt'"
check "dry run: nothing removed" "[ -d '$WT/merged' ] && [ -d '$RC_ROOT/copy-a' ]"

plan_id=$(sed -n 's/^Plan: //p' "$TMP/dry.txt")
check "dry run: plan saved" "[ -n '$plan_id' ] && [ -f '$OPS/.claude/session/disk-sweep/plan-$plan_id' ]"

# The state changes after the dry run: merged2 gets a new file.
printf 'later\n' > "$WT/merged2/later.txt"

(cd "$OPS" && PATH="$TMP/ghbin:$PATH" bash "$SWEEP" --apply "bad/id") >/dev/null 2>&1; rc=$?
check "apply: bad plan id refused" "[ $rc -ne 0 ]"

applied=$(cd "$OPS" && PATH="$TMP/ghbin:$PATH" bash "$SWEEP" --apply "$plan_id" 2>&1); rc=$?
printf '%s\n' "$applied" > "$TMP/apply.txt"
LOG="$OPS/.claude/session/disk-sweep/removed.log"
check "apply: exit 0" "[ $rc -eq 0 ]"
check "apply: merged worktree removed" "[ ! -e '$WT/merged' ]"
check "apply: git no longer lists the merged worktree" "! git -C '$PROJ' worktree list | grep -q '/merged '"
check "apply: closed worktree removed" "[ ! -e '$WT/closed' ]"
check "apply: review copies removed" "[ ! -e '$RC_ROOT/copy-a' ] && [ ! -e '$TMP/extra-rc/copy-e' ]"
check "apply: item changed since the dry run is kept" "[ -f '$WT/merged2/later.txt' ] && grep -q 'kept.*merged2' '$TMP/apply.txt'"
check "apply: items not in the plan untouched" "[ -d '$WT/open' ] && [ -d '$WT/dirty' ] && [ -d '$WT/young' ] && [ -d '$RC_ROOT/copy-b' ] && [ -d '$RC_ROOT/copy-c' ] && [ -d '$RC_ROOT/copy-d' ] && [ -d '$RC_ROOT/copy-y' ] && [ -d '$TMP/elsewhere/wt' ]"
check "apply: log has removed lines" "[ \"\$(grep -c \$'\\tremoved\\t' '$LOG')\" -eq 4 ]"
check "apply: log has the kept line" "grep -q \$'\\tkept\\t.*merged2' '$LOG'"
check "apply: plan deleted" "[ ! -e '$OPS/.claude/session/disk-sweep/plan-$plan_id' ]"
(cd "$OPS" && PATH="$TMP/ghbin:$PATH" bash "$SWEEP" --apply "$plan_id") >/dev/null 2>&1; rc=$?
check "apply: a used plan cannot run again" "[ $rc -ne 0 ]"

# The tracker is not gh: no PR lookup, everything is kept.
override '{"tracker":{"kind":"none"}}'
rm -f "$MOCK/calls"
dry=$(cd "$OPS" && PATH="$TMP/ghbin:$PATH" bash "$SWEEP" 2>&1)
check "tracker not gh: nothing to remove" "printf '%s' \"\$dry\" | grep -q '^Remove: none'"
check "tracker not gh: no gh call" "[ ! -f '$MOCK/calls' ]"

measured=$(cd "$OPS" && bash "$SWEEP" --measure 2>&1); rc=$?
check "measure: lists owned folders" "[ $rc -eq 0 ] && printf '%s' \"\$measured\" | grep -q 'proj.worktrees'"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
