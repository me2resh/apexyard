#!/usr/bin/env bash
# Tests for bin/apexyard-pr-status (me2resh/apexyard#2030).
#
# The command runs against a fake `gh` and a temporary git repo that is also
# the ops root. Cases:
#   1. all satisfied (and nothing under the ops root or HOME changes, and no
#      write verb reaches gh)
#   2. a new commit after approval: stale
#   3. a carry-over after a base merge: satisfied, carried over
#   4. a formal changes-requested review that outlives local approval
#   5. missing CI: "CI gate" and "CI green" stay apart
#   6. a checks API failure: not verified, never satisfied
#   7. no session pin, run from a linked worktree
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CLI="$SRC_ROOT/bin/apexyard-pr-status"
PASS=0
FAIL=0
ok() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
starts_with() { case "$1" in "$2"*) return 0 ;; esac; return 1; }
exits_2() { "$@" >/dev/null 2>&1; [ $? -eq 2 ]; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed"
  exit 0
fi
if ! git merge-tree --write-tree HEAD HEAD >/dev/null 2>&1 && ! git -C "$SRC_ROOT" merge-tree --write-tree HEAD HEAD >/dev/null 2>&1; then
  echo "SKIP: git merge-tree --write-tree is not available"
  exit 0
fi

SB=$(mktemp -d "${TMPDIR:-/tmp}/pr-status-test.XXXXXX")
SB=$(cd "$SB" && pwd -P)
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/gh" "$SB/home" "$SB/tmp"
GHLOG="$SB/gh.log"

# --- Fake gh: answers from $FAKE_GH_DIR/<name>.json; <name>.fail = HTTP 502.
cat > "$SB/bin/gh" <<'FAKE'
#!/usr/bin/env bash
D="$FAKE_GH_DIR"
printf '%s\n' "$(printf '%s ' "$@" | tr '\n' ' ')" >> "$FAKE_GH_LOG"
jqf=""; query=""; pos=()
args=("$@"); i=0
while [ "$i" -lt "${#args[@]}" ]; do
  a="${args[$i]}"
  case "$a" in
    --jq|-q) i=$((i + 1)); jqf="${args[$i]}" ;;
    -f|-F|--field|--raw-field) i=$((i + 1)); case "${args[$i]}" in query=*) query="${args[$i]#query=}" ;; esac ;;
    --repo|-R|--json|--hostname|-X|--method|-H|--header) i=$((i + 1)) ;;
    --paginate|--slurp|-i) ;;
    *) pos+=("$a") ;;
  esac
  i=$((i + 1))
done
emit() {
  [ -f "$D/$1.fail" ] && { echo "HTTP 502: fake failure" >&2; exit 1; }
  [ -f "$D/$1" ] || { echo "HTTP 404: Not Found ($1)" >&2; exit 1; }
  if [ -n "$jqf" ]; then jq -r "$jqf" < "$D/$1"; exit $?; fi
  cat "$D/$1"; exit 0
}
case "${pos[0]:-} ${pos[1]:-}" in
  "pr view") emit pr.json ;;
  "pr checks")
    [ -f "$D/checks.fail" ] && { echo "HTTP 502: fake failure" >&2; exit 1; }
    cat "$D/checks.txt"; exit "$(cat "$D/checks.rc")" ;;
esac
if [ "${pos[0]:-}" = api ]; then
  case "${pos[1]:-}" in
    graphql)
      case "$query" in
        *statusCheckRollup*) emit rollup.json ;;
        *firstParent*) emit chain.json ;;
      esac ;;
    */pulls/*/reviews*) emit reviews.json ;;
    */issues/*/comments*) emit comments.json ;;
    */pulls/*/files*) emit files.json ;;
    */pulls/*) emit pull.json ;;
    */rules/branches/*) emit rules.json ;;
    */branches/*/protection) emit protection.json ;;
    */branches/*) emit branch.json ;;
    */actions/runs*) emit runs.json ;;
    */actions/workflows*) emit workflows.json ;;
    */check-runs*) emit checkruns.json ;;
    */commits/*/status*) emit status.json ;;
    */compare/*) emit compare.json ;;
  esac
fi
echo "fake gh: unsupported: $*" >&2
exit 1
FAKE
chmod +x "$SB/bin/gh"

# --- Temporary repo, also the ops root. ------------------------------------
OPS="$SB/ops"
g() { git -C "$OPS" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
git init -q "$OPS"
g checkout -q -b main
touch "$OPS/.apexyard-fork"
echo base > "$OPS/base.txt"
g add .apexyard-fork base.txt
g commit -q -m B0
g remote add origin https://github.com/acme/widget.git
g checkout -q -b feature/GH-12-thing
echo f1 > "$OPS/feat.txt"; g add feat.txt; g commit -q -m F1
F1=$(g rev-parse HEAD)
g checkout -q main
echo b1 >> "$OPS/base.txt"; g commit -q -a -m B1
B1=$(g rev-parse HEAD)
g checkout -q -b other "$F1"
echo f2 >> "$OPS/feat.txt"; g commit -q -a -m F2
F2=$(g rev-parse HEAD)
g checkout -q feature/GH-12-thing
g merge -q --no-ff -m M main
M=$(g rev-parse HEAD)
g checkout -q main
git -C "$OPS" worktree add -q "$SB/wt" feature/GH-12-thing
tree() { g rev-parse "$1^{tree}"; }
REVIEWS_DIR="$OPS/.claude/session/reviews"
mkdir -p "$REVIEWS_DIR"

# --- Fake forge data. -------------------------------------------------------
D="$SB/gh"
# base_data <head>: everything green and approved at <head>.
base_data() {
  local h="$1"
  rm -f "$D"/*
  jq -n --arg h "$h" --arg b "$B1" '{number:7,state:"OPEN",isDraft:false,headRefOid:$h,
    headRefName:"feature/GH-12-thing",baseRefName:"main",baseRefOid:$b,changedFiles:1,
    body:"## Summary\nCloses #12\n",url:"https://github.com/acme/widget/pull/7",
    reviewDecision:"APPROVED",mergeStateStatus:"CLEAN"}' > "$D/pr.json"
  echo '{"changed_files":1}' > "$D/pull.json"
  echo '[{"filename":"src/lib.sh"}]' > "$D/files.json"
  printf 'build\tpass\t10s\thttps://example.invalid/1\n' > "$D/checks.txt"
  echo 0 > "$D/checks.rc"
  jq -n '{total_count:1,workflow_runs:[{workflow_id:1,run_number:1,event:"pull_request",
    created_at:"2026-11-10T00:00:00Z",id:1,name:"CI",status:"completed",conclusion:"success"}]}' > "$D/runs.json"
  echo '{"total_count":1,"workflows":[{"state":"active"}]}' > "$D/workflows.json"
  jq -n --arg h "$h" '{data:{repository:{pullRequest:{commits:{nodes:[{commit:{oid:$h,
    statusCheckRollup:{state:"SUCCESS",contexts:{pageInfo:{hasNextPage:false},nodes:[
    {__typename:"CheckRun",name:"build",status:"COMPLETED",conclusion:"SUCCESS",isRequired:true}]}}}}]}}}}}' > "$D/rollup.json"
  jq -n --arg h "$h" '[{id:1,user:{login:"rex-bot"},state:"COMMENTED",commit_id:$h,
    submitted_at:"2026-11-10T01:00:00Z",author_association:"MEMBER",body:"## Code Review"}]' > "$D/reviews.json"
  jq -n --arg h "$h" '[{id:2,user:{login:"qa"},author_association:"MEMBER",
    body:("## Pre-merge QA (Salim)\n<!-- apexyard-pre-merge-qa: sha=" + $h + " status=PASS -->")}]' > "$D/comments.json"
  echo '[{"type":"pull_request","parameters":{"required_approving_review_count":1}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}}]' > "$D/rules.json"
  echo '{"protected":false}' > "$D/branch.json"
  echo '{"behind_by":0}' > "$D/compare.json"
}
# approve_at <sha>: Rex and human records at <sha>.
approve_at() {
  rm -f "$REVIEWS_DIR"/*
  printf '%s\n' "$1" > "$REVIEWS_DIR/acme__widget__7-rex.approved"
  printf 'sha=%s\napproved_by=user\nskill_version=2\napproved_at=2026-11-10T00:00:00Z\napproval_summary=test\n' "$1" \
    > "$REVIEWS_DIR/acme__widget__7-ceo.approved"
}
# commit_node <sha> <parents...>: one GraphQL commit node with no first parent.
commit_node() {
  local sha="$1"; shift
  jq -n --arg s "$sha" --arg t "$(tree "$sha")" --args '{oid:$s,tree:{oid:$t},
    allParents:{nodes:[$ARGS.positional[] | {oid:.}]},firstParent:{nodes:[]}}' "$@"
}

: > "$GHLOG"
# run_cli <dir> [--json]
run_cli() {
  local dir="$1"; shift
  ( cd "$dir" && env HOME="$SB/home" TMPDIR="$SB/tmp" PATH="$SB/bin:$PATH" \
      FAKE_GH_DIR="$D" FAKE_GH_LOG="$GHLOG" "$CLI" acme/widget#7 "$@" 2>/dev/null )
}
status_of() { printf '%s' "$1" | jq -r --arg n "$2" '.items[] | select(.name == $n) | .status'; }
detail_of() { printf '%s' "$1" | jq -r --arg n "$2" '.items[] | select(.name == $n) | .detail'; }
snapshot() {
  ( cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r f; do
      if [ -f "$f" ]; then printf '%s %s\n' "$(cksum < "$f")" "$f"; else printf 'dir %s\n' "$f"; fi
    done )
}

echo "== 1. all satisfied; no write"
base_data "$F1"; approve_at "$F1"
# A live session: a session id, a valid ops-root pin, and the resolution
# cache ON. The snapshot covers the ops root (with .claude/session/), the
# worktree, HOME, the pin directory and the dedicated TMPDIR.
mkdir -p "$SB/pins"
printf '%s\n' "$OPS" > "$SB/pins/ops-root-pr-status-test"
live_run() {
  ( unset APEXYARD_DISABLE_RESOLUTION_CACHE APEXYARD_OPS_DISABLE_PIN
    export CLAUDE_CODE_SESSION_ID=pr-status-test APEXYARD_OPS_PIN_DIR="$SB/pins"
    run_cli "$@" )
}
all_dirs() { snapshot "$OPS"; snapshot "$SB/home"; snapshot "$SB/wt"; snapshot "$SB/pins"; snapshot "$SB/tmp"; }
before=$(all_dirs)
TXT=$(live_run "$OPS")
J=$(live_run "$OPS" --json)
after=$(all_dirs)
for n in rex ceo "required checks" "CI green" "changes requested" "branch rules" "merge state" "pre-merge QA" "review gate" "CI gate"; do
  check "1: $n is satisfied" test "$(status_of "$J" "$n")" = satisfied
done
for n in design architecture security; do
  check "1: $n is not required" test "$(status_of "$J" "$n")" = "not required"
done
check "1: head and base SHA" test "$(printf '%s' "$J" | jq -r '.head.sha + " " + .base.sha')" = "$F1 $B1"
check "1: linked ticket" test "$(printf '%s' "$J" | jq -r '.ticket.from_body')" = "acme/widget#12"
check "1: last line is the next action" test "$(printf '%s\n' "$TXT" | tail -n 1)" = "Next: Ready to merge at ${F1:0:12}. The merge gates check again at merge time."
check "1: no file changed under the ops root, worktree, HOME, pin dir or TMPDIR" test "$before" = "$after"
if [ "$before" != "$after" ]; then
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/    /' >&2
fi
check "1: no write verb reached gh" test -z "$(grep -E '^(pr (merge|review|comment|edit|close|reopen|ready|update-branch|create)|issue |label |repo (edit|delete))|(-X|--method) (POST|PATCH|PUT|DELETE)|mutation' "$GHLOG")"
check "1: no gh api call with fields except GraphQL queries" test -z "$(grep '^api ' "$GHLOG" | grep -v '^api graphql' | grep -E ' (-f|-F|--field|--raw-field) ')"
check "1: gh was called" test -s "$GHLOG"

echo "== 2. new commit after approval"
base_data "$F2"; approve_at "$F1"
jq -n --argjson c "$(commit_node "$F2" "$F1")" --arg b "$B1" '{data:{repository:{ref:{target:{oid:$b}},c0:$c}}}' > "$D/chain.json"
J=$(run_cli "$OPS" --json); TXT=$(run_cli "$OPS")
check "2: rex is stale" test "$(status_of "$J" rex)" = stale
check "2: ceo is stale" test "$(status_of "$J" ceo)" = stale
check "2: rex stored SHA is the approved commit" test "$(printf '%s' "$J" | jq -r '.items[] | select(.name == "rex") | .stored_sha')" = "$F1"
check "2: next action names Rex at the head" test "$(printf '%s\n' "$TXT" | tail -n 1)" = "Next: Rex review needed at ${F2:0:12} (/code-review 7)."

echo "== 3. carry-over after a base merge"
base_data "$M"; approve_at "$F1"
jq -n --arg m "$M" --arg tm "$(tree "$M")" --arg f "$F1" --arg b "$B1" --argjson p "$(commit_node "$F1" "$(g rev-parse "$F1^")")" \
  '{data:{repository:{ref:{target:{oid:$b}},c0:{oid:$m,tree:{oid:$tm},
    allParents:{nodes:[{oid:$f},{oid:$b}]},firstParent:{nodes:[$p]}}}}}' > "$D/chain.json"
J=$(run_cli "$OPS" --json)
check "3: rex is satisfied" test "$(status_of "$J" rex)" = satisfied
check "3: rex is carried over" test "$(detail_of "$J" rex)" = "carried over through verified base merges"
check "3: ceo is satisfied and carried over" test "$(status_of "$J" ceo) $(detail_of "$J" ceo)" = "satisfied carried over through verified base merges"
check "3: review gate passes" test "$(status_of "$J" "review gate")" = satisfied

echo "== 4. formal changes requested outlives local approval"
base_data "$F1"; approve_at "$F1"
jq -n --arg h "$F1" '[{id:3,user:{login:"sec-bot"},state:"CHANGES_REQUESTED",commit_id:$h,submitted_at:"2026-11-09T00:00:00Z"},
  {id:4,user:{login:"sec-bot"},state:"COMMENTED",commit_id:$h,submitted_at:"2026-11-10T02:00:00Z"},
  {id:5,user:{login:"other"},state:"CHANGES_REQUESTED",commit_id:$h,submitted_at:"2026-11-09T00:00:00Z"},
  {id:6,user:{login:"other"},state:"APPROVED",commit_id:$h,submitted_at:"2026-11-10T03:00:00Z"}]' > "$D/reviews.json"
jq '.reviewDecision = "CHANGES_REQUESTED" | .mergeStateStatus = "BLOCKED"' "$D/pr.json" > "$D/pr.tmp" && mv "$D/pr.tmp" "$D/pr.json"
J=$(run_cli "$OPS" --json); TXT=$(run_cli "$OPS")
check "4: local rex and ceo are satisfied" test "$(status_of "$J" rex) $(status_of "$J" ceo)" = "satisfied satisfied"
check "4: changes requested is missing" test "$(status_of "$J" "changes requested")" = missing
check "4: only the reviewer whose latest state is CHANGES_REQUESTED" test "$(detail_of "$J" "changes requested")" = "a formal changes-requested review is in force: sec-bot at ${F1:0:12}"
check "4: next action names the review" test "$(printf '%s\n' "$TXT" | tail -n 1)" = "Next: Dismiss or replace the formal changes-requested review: sec-bot at ${F1:0:12}."

echo "== 5. missing CI"
base_data "$F1"; approve_at "$F1"
echo "no checks reported on the 'feature/GH-12-thing' branch" > "$D/checks.txt"; echo 1 > "$D/checks.rc"
echo '{"total_count":0,"workflow_runs":[]}' > "$D/runs.json"
echo '{"total_count":0,"workflows":[]}' > "$D/workflows.json"
jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup = null' "$D/rollup.json" > "$D/r.tmp" && mv "$D/r.tmp" "$D/rollup.json"
echo '[{"type":"pull_request","parameters":{"required_approving_review_count":1}}]' > "$D/rules.json"
J=$(run_cli "$OPS" --json); TXT=$(run_cli "$OPS")
check "5: CI gate passed but is not verified" test "$(status_of "$J" "CI gate")" = "not verified"
check "5: CI gate detail says it passed" starts_with "$(detail_of "$J" "CI gate")" "passed without a verified result: NOTE:"
check "5: CI green is missing" test "$(status_of "$J" "CI green")" = missing
check "5: required checks not required" test "$(status_of "$J" "required checks")" = "not required"
check "5: text shows CI gate and CI green as separate rows" test "$(printf '%s\n' "$TXT" | grep -cE '^  CI (gate|green) ')" = 2
check "5: next action names CI" test "$(printf '%s\n' "$TXT" | tail -n 1)" = "Next: CI must be green at ${F1:0:12}: no check reported a result for the head."

echo "== 6. checks API failure"
base_data "$F1"; approve_at "$F1"
touch "$D/rollup.json.fail" "$D/checks.fail" "$D/checkruns.json.fail"
J=$(run_cli "$OPS" --json); TXT=$(run_cli "$OPS")
check "6: required checks not verified" test "$(status_of "$J" "required checks")" = "not verified"
check "6: CI green not verified" test "$(status_of "$J" "CI green")" = "not verified"
check "6: CI gate not verified" test "$(status_of "$J" "CI gate")" = "not verified"
check "6: next action asks to verify" starts_with "$(printf '%s\n' "$TXT" | tail -n 1)" "Next: Verify "
check "6: no CI row is satisfied" test -z "$(printf '%s' "$J" | jq -r '.items[] | select((.name == "required checks" or .name == "CI green" or .name == "CI gate") and .status == "satisfied") | .name')"

echo "== 7. no session pin, from a linked worktree"
base_data "$F1"; approve_at "$F1"
before=$(snapshot "$OPS"; snapshot "$SB/wt")
J=$( unset CLAUDE_CODE_SESSION_ID APEXYARD_SESSION_ID; run_cli "$SB/wt" --json )
after=$(snapshot "$OPS"; snapshot "$SB/wt")
check "7: rex record found from the worktree" test "$(status_of "$J" rex)" = satisfied
check "7: ceo record found from the worktree" test "$(status_of "$J" ceo)" = satisfied
check "7: worktree of the head branch is found" test "$(printf '%s' "$J" | jq -r '.worktree.path')" = "$SB/wt"
check "7: marker home is the ops root" test "$(printf '%s' "$J" | jq -r '.marker_home')" = "$OPS"
check "7: nothing changed" test "$before" = "$after"

echo "== usage"
check "usage: a bad target exits 2" exits_2 "$CLI" not-a-target
check "usage: '..' as owner exits 2" exits_2 "$CLI" '../widget#7'
check "usage: '..' as repo exits 2" exits_2 "$CLI" 'acme/..#7'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
