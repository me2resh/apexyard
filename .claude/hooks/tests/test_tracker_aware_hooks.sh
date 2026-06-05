#!/bin/bash
# Tests for the tracker-abstraction layer (_lib-tracker.sh + the four
# consumers refactored against it: /start-ticket, validate-pr-create.sh,
# verify-commit-refs.sh, validate-branch-name.sh).
#
# Cases:
#   1. Default GH adopter (tracker.kind = gh) — regression: existing
#      behaviour preserved (validate-pr-create.sh and verify-commit-refs.sh
#      still work via mock gh).
#   2. Linear adopter (tracker.kind = linear) — end-to-end with mock `linear`.
#   3. Jira adopter (tracker.kind = jira) — end-to-end with mock `jira`.
#   4. None adopter (tracker.kind = none) — existence check short-circuits.
#   5. Custom adopter (tracker.kind = custom) — operator-supplied command.
#   6. id_pattern sourcing — validate-branch-name.sh reads .tracker.id_pattern.
#
# Exit 0 = all pass. Exit 1 on first failure.

set -u

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACKER_LIB="$HOOK_DIR/_lib-tracker.sh"
CONFIG_LIB="$HOOK_DIR/_lib-read-config.sh"
PR_CREATE_HOOK="$HOOK_DIR/validate-pr-create.sh"
COMMIT_REFS_HOOK="$HOOK_DIR/verify-commit-refs.sh"
BRANCH_NAME_HOOK="$HOOK_DIR/validate-branch-name.sh"
DEFAULTS="$(cd "$HOOK_DIR/.." && pwd)/project-config.defaults.json"

for f in "$TRACKER_LIB" "$CONFIG_LIB" "$PR_CREATE_HOOK" "$COMMIT_REFS_HOOK" "$BRANCH_NAME_HOOK" "$DEFAULTS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file not found: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

# -----------------------------------------------------------------------------
# make_fork: build an isolated apexyard fork sandbox.
# Each case starts with a fresh sandbox so per-case CLI mocks don't bleed.
# -----------------------------------------------------------------------------
make_fork() {
  local sb
  sb=$(mktemp -d)
  sb=$(cd "$sb" && pwd -P)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git remote add origin "https://github.com/test-org/test-repo.git" 2>/dev/null || true

    touch onboarding.yaml
    cat > apexyard.projects.yaml <<'YAML'
version: 1
projects:
  - name: example
    repo: example/example
YAML
    mkdir -p projects .claude/hooks/tests
    cp "$TRACKER_LIB"   .claude/hooks/_lib-tracker.sh
    cp "$CONFIG_LIB"    .claude/hooks/_lib-read-config.sh
    cp "$PR_CREATE_HOOK"   .claude/hooks/validate-pr-create.sh
    cp "$COMMIT_REFS_HOOK" .claude/hooks/verify-commit-refs.sh
    cp "$BRANCH_NAME_HOOK" .claude/hooks/validate-branch-name.sh
    chmod +x .claude/hooks/*.sh
    cp "$DEFAULTS" .claude/project-config.defaults.json

    # Other libs the consumer hooks transitively source. validate-branch-name.sh
    # tries to source _lib-extract-push-ref.sh; copy it if present.
    if [ -f "$HOOK_DIR/_lib-extract-push-ref.sh" ]; then
      cp "$HOOK_DIR/_lib-extract-push-ref.sh" .claude/hooks/_lib-extract-push-ref.sh
    fi

    git add -A
    git commit -q -m "test fixture"
    git checkout -q -b feature/GH-1-test
  )
  echo "$sb"
}

# -----------------------------------------------------------------------------
# install_mock <sandbox> <name> <script-body>
# Drops a fake CLI on PATH for the next subshell-rooted call.
# -----------------------------------------------------------------------------
install_mock() {
  local sb="$1" name="$2" body="$3"
  mkdir -p "$sb/bin"
  cat > "$sb/bin/$name" <<EOF
#!/bin/bash
$body
EOF
  chmod +x "$sb/bin/$name"
}

# -----------------------------------------------------------------------------
# pass / fail helpers
# -----------------------------------------------------------------------------
record_pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
record_fail() {
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  - $1"
  echo "FAIL: $1"
  [ -n "${2:-}" ] && echo "  $2"
}

# -----------------------------------------------------------------------------
# Helper: run the validate-pr-create.sh hook against a synthetic command and
# check exit code. Returns 0 if exit matches expected_rc.
# -----------------------------------------------------------------------------
run_pr_hook() {
  local sb="$1" command="$2" expected_rc="$3"
  local input rc
  input=$(jq -nc --arg cmd "$command" '{tool_input:{command:$cmd}}')
  (
    cd "$sb" || exit 99
    PATH="$sb/bin:$PATH" .claude/hooks/validate-pr-create.sh <<<"$input" >/dev/null 2>&1
  )
  rc=$?
  [ "$rc" = "$expected_rc" ]
}

run_commit_hook() {
  local sb="$1" command="$2" expected_rc="$3"
  local input rc
  input=$(jq -nc --arg cmd "$command" '{tool_input:{command:$cmd}}')
  (
    cd "$sb" || exit 99
    PATH="$sb/bin:$PATH" .claude/hooks/verify-commit-refs.sh <<<"$input" >/dev/null 2>&1
  )
  rc=$?
  [ "$rc" = "$expected_rc" ]
}

run_branch_hook() {
  local sb="$1" command="$2" expected_rc="$3"
  local input rc
  input=$(jq -nc --arg cmd "$command" '{tool_input:{command:$cmd}}')
  (
    cd "$sb" || exit 99
    PATH="$sb/bin:$PATH" .claude/hooks/validate-branch-name.sh <<<"$input" >/dev/null 2>&1
  )
  rc=$?
  [ "$rc" = "$expected_rc" ]
}

# =============================================================================
# Case 1: default GH adopter — regression. With a mock `gh` that returns OPEN
# for any number, validate-pr-create.sh exits 0 for a real-looking PR title.
# =============================================================================
SB=$(make_fork)
# Mock gh: respond OPEN for issue view, succeed for everything else.
install_mock "$SB" gh '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  num="$3"
  shift 3
  state="OPEN"
  while [ $# -gt 0 ]; do
    case "$1" in
      --num) num="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf "{\"state\":\"OPEN\",\"title\":\"mock\",\"url\":\"https://example/\",\"labels\":[]}\n"
  exit 0
fi
exit 0
'
cmd='gh pr create --title "feat(#42): add csv export" --body "
## Testing
verify

## Glossary
| Term | Definition |
|------|------------|
| CSV | Comma-separated values |
" --head feature/GH-1-test'
if run_pr_hook "$SB" "$cmd" 0; then
  record_pass "regression: default gh adopter — valid PR title passes"
else
  record_fail "regression: default gh adopter — valid PR title passes"
fi
rm -rf "$SB"

# =============================================================================
# Case 2: default GH adopter — fabricated #N blocks. Mock gh returns nothing
# for issue view (issue doesn't exist).
# =============================================================================
SB=$(make_fork)
install_mock "$SB" gh '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  # Empty stdout + exit 1 emulates "not found".
  exit 1
fi
exit 0
'
cmd='gh pr create --title "feat(#9999): missing ticket" --body "
## Testing
x

## Glossary
| Term | Definition |
|------|------------|
| x | x |
" --head feature/GH-1-test'
if run_pr_hook "$SB" "$cmd" 2; then
  record_pass "regression: default gh adopter — fabricated #N blocks"
else
  record_fail "regression: default gh adopter — fabricated #N blocks"
fi
rm -rf "$SB"

# =============================================================================
# Case 3: Linear adopter — tracker.kind = linear, mock `linear` CLI.
# A Linear-style ID (LIN-42) in a valid PR title passes.
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "tracker": {
    "kind": "linear",
    "view_command": "linear issue view {id} --json",
    "id_pattern": "^[A-Z]+-[0-9]+$"
  }
}
JSON
install_mock "$SB" linear '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  num="$3"
  # Emit Linear-shaped JSON: state as object {name}, labels as object array.
  printf "{\"state\":{\"name\":\"In Progress\"},\"title\":\"mock %s\",\"url\":\"https://linear.app/x/%s\",\"labels\":[{\"name\":\"backend\"}]}\n" "$num" "$num"
  exit 0
fi
exit 0
'
# Linear: no --repo flag in command; PR is still gh-shaped (gh pr create).
cmd='gh pr create --title "feat(LIN-42): linear ticket" --body "
## Testing
x

## Glossary
| Term | Definition |
|------|------------|
| LIN | Linear |
" --head feature/LIN-42-test'
if run_pr_hook "$SB" "$cmd" 0; then
  record_pass "linear: end-to-end — valid LIN-42 PR title passes via mock linear CLI"
else
  record_fail "linear: end-to-end — valid LIN-42 PR title passes via mock linear CLI"
fi

# Linear: ticket reported as "Done" — should block.
install_mock "$SB" linear '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf "{\"state\":{\"name\":\"Done\"},\"title\":\"finished\",\"url\":\"https://linear.app/x/done\",\"labels\":[]}\n"
  exit 0
fi
exit 0
'
cmd='gh pr create --title "feat(LIN-50): linear closed" --body "
## Testing
x

## Glossary
| Term | Definition |
|------|------------|
| LIN | Linear |
" --head feature/LIN-50-test'
if run_pr_hook "$SB" "$cmd" 2; then
  record_pass "linear: closed-state (Done) → blocked"
else
  record_fail "linear: closed-state (Done) → blocked"
fi

# Linear: tracker CLI returns empty (linear exits 1). Under #501 this is
# treated as "not queryable here" — indistinguishable from an absent /
# unauthenticated CLI — so the hook falls back to shape-only and PASSES
# (exit 0) rather than blocking. Prior to #501 this blocked (exit 2); the
# behaviour was reversed because blocking made it impossible to open a PR
# referencing a real, valid non-GitHub ticket when the CLI isn't reachable.
# (Closed-state Linear tickets still block — see the "Done" case above — and
# gh fabricated #N still blocks — see Case 12.)
install_mock "$SB" linear 'exit 1'
cmd='gh pr create --title "feat(LIN-99): unqueryable" --body "
## Testing
x

## Glossary
| Term | Definition |
|------|------------|
| LIN | Linear |
" --head feature/LIN-99-test'
if run_pr_hook "$SB" "$cmd" 0; then
  record_pass "linear: tracker CLI returns empty → shape-only PASS (#501; was block pre-#501)"
else
  record_fail "linear: tracker CLI returns empty → shape-only PASS (#501; was block pre-#501)"
fi
rm -rf "$SB"

# =============================================================================
# Case 4: Jira adopter — tracker.kind = jira, mock `jira` CLI with REST-shaped
# JSON. Verifies the adapter parses .fields.status.name correctly.
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "tracker": {
    "kind": "jira",
    "view_command": "jira issue view {id} --raw",
    "id_pattern": "^[A-Z]+-[0-9]+$"
  }
}
JSON
install_mock "$SB" jira '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  num="$3"
  printf "{\"self\":\"https://jira.x/%s\",\"fields\":{\"status\":{\"name\":\"In Progress\"},\"summary\":\"mock %s\",\"labels\":[\"backend\",\"P1\"]}}\n" "$num" "$num"
  exit 0
fi
exit 0
'
cmd='gh pr create --title "feat(JIRA-100): jira ticket" --body "
## Testing
x

## Glossary
| Term | Definition |
|------|------------|
| JIRA | Atlassian Jira |
" --head feature/JIRA-100-test'
if run_pr_hook "$SB" "$cmd" 0; then
  record_pass "jira: end-to-end — valid JIRA-100 PR title passes via mock jira CLI"
else
  record_fail "jira: end-to-end — valid JIRA-100 PR title passes via mock jira CLI"
fi

# Jira closed state.
install_mock "$SB" jira '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf "{\"self\":\"https://jira.x/200\",\"fields\":{\"status\":{\"name\":\"Resolved\"},\"summary\":\"done\",\"labels\":[]}}\n"
  exit 0
fi
exit 0
'
cmd='gh pr create --title "feat(JIRA-200): jira closed" --body "
## Testing
x

## Glossary
| Term | Definition |
|------|------------|
| JIRA | Atlassian Jira |
" --head feature/JIRA-200-test'
if run_pr_hook "$SB" "$cmd" 2; then
  record_pass "jira: closed-state (Resolved) → blocked"
else
  record_fail "jira: closed-state (Resolved) → blocked"
fi
rm -rf "$SB"

# =============================================================================
# Case 5: tracker.kind = none — existence-check disabled.
# A PR title with a fabricated #N should NOT be blocked by the existence
# check (only the shape check). Format violations (bad shape) still block.
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "tracker": {
    "kind": "none",
    "view_command": "",
    "id_pattern": "^(#[0-9]+|[A-Z]+-[0-9]+)$"
  }
}
JSON
# No mock gh installed — if the hook tried to call gh it would error.
# Provide a stub that always fails so an accidental call is detectable.
install_mock "$SB" gh 'exit 99'

cmd='gh pr create --title "feat(#99999): no-tracker mode" --body "
## Testing
x

## Glossary
| Term | Definition |
|------|------------|
| x | x |
" --head feature/GH-99999-test'
if run_pr_hook "$SB" "$cmd" 0; then
  record_pass "none: existence check short-circuited (no CLI call made)"
else
  record_fail "none: existence check short-circuited (no CLI call made)"
fi

# Same mode — verify-commit-refs.sh should also short-circuit.
cmd='git commit -m "feat: add thing

Closes #99999
"'
if run_commit_hook "$SB" "$cmd" 0; then
  record_pass "none: verify-commit-refs.sh short-circuits on tracker.kind=none"
else
  record_fail "none: verify-commit-refs.sh short-circuits on tracker.kind=none"
fi
rm -rf "$SB"

# =============================================================================
# Case 6: tracker.kind = custom — operator-supplied command.
# Use a custom `view_command` that calls our mock CLI directly. The custom
# adapter passes raw output through, so the command must emit shaped JSON.
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "tracker": {
    "kind": "custom",
    "view_command": "myticket {id}",
    "id_pattern": "^TIC-[0-9]+$"
  }
}
JSON
install_mock "$SB" myticket '
num="$1"
printf "{\"state\":\"open\",\"title\":\"mock %s\",\"url\":\"https://my/%s\",\"labels\":[]}\n" "$num" "$num"
exit 0
'
cmd='gh pr create --title "feat(TIC-7): custom" --body "
## Testing
x

## Glossary
| Term | Definition |
|------|------------|
| TIC | Custom tracker |
" --head feature/TIC-7-test'
if run_pr_hook "$SB" "$cmd" 0; then
  record_pass "custom: end-to-end — operator-supplied command works"
else
  record_fail "custom: end-to-end — operator-supplied command works"
fi
rm -rf "$SB"

# =============================================================================
# Case 7: validate-branch-name.sh sources id_pattern from tracker config.
# With a strict Linear-only pattern, a `feature/GH-1-…` branch should fail
# (no longer matches), but `feature/LIN-1-…` should pass.
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "tracker": {
    "kind": "linear",
    "view_command": "linear issue view {id} --json",
    "id_pattern": "^[A-Z]+-[0-9]+$"
  }
}
JSON
# Push a branch that matches the strict Linear-only pattern.
(
  cd "$SB" || exit 1
  git checkout -q -b feature/LIN-7-test
)
cmd='git push origin feature/LIN-7-test'
if run_branch_hook "$SB" "$cmd" 0; then
  record_pass "branch-name: linear-style branch passes under strict id_pattern"
else
  record_fail "branch-name: linear-style branch passes under strict id_pattern"
fi

# Push a branch that uses `#` notation — should fail under the strict pattern
# (Linear IDs don't use #).
(
  cd "$SB" || exit 1
  git checkout -q -b 'feature/#42-test' 2>/dev/null || true
)
cmd='git push origin feature/#42-test'
if run_branch_hook "$SB" "$cmd" 2; then
  record_pass "branch-name: # notation blocked under strict Linear-only id_pattern"
else
  record_fail "branch-name: # notation blocked under strict Linear-only id_pattern"
fi
rm -rf "$SB"

# =============================================================================
# Case 8: default config (tracker.kind = gh) — branch-name validator still
# accepts the legacy shapes (#N, GH-N, ABC-N). Regression check.
# =============================================================================
SB=$(make_fork)
(
  cd "$SB" || exit 1
  git checkout -q -b feature/GH-1-default-test
)
cmd='git push origin feature/GH-1-default-test'
if run_branch_hook "$SB" "$cmd" 0; then
  record_pass "branch-name: default config — GH-1 branch passes (regression)"
else
  record_fail "branch-name: default config — GH-1 branch passes (regression)"
fi
rm -rf "$SB"

# =============================================================================
# Case 9: tracker_view library API smoke — direct call returns normalised JSON
# for each kind. Catches regressions in the per-adapter jq filters.
# =============================================================================
SB=$(make_fork)
install_mock "$SB" gh '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf "{\"state\":\"OPEN\",\"title\":\"gh ticket\",\"url\":\"https://gh/1\",\"labels\":[{\"name\":\"x\"}]}\n"
  exit 0
fi
exit 0
'
out=$(
  cd "$SB" || exit 99
  PATH="$SB/bin:$PATH"
  . .claude/hooks/_lib-read-config.sh
  . .claude/hooks/_lib-tracker.sh
  tracker_clear_cache
  tracker_view 1 owner/repo
)
got_state=$(echo "$out" | jq -r '.state')
got_labels=$(echo "$out" | jq -r '.labels | join(",")')
if [ "$got_state" = "OPEN" ] && [ "$got_labels" = "x" ]; then
  record_pass "lib: tracker_view (gh) returns normalised {state, labels[]}"
else
  record_fail "lib: tracker_view (gh) returns normalised {state, labels[]}" "got state='$got_state' labels='$got_labels'"
fi
rm -rf "$SB"

# Linear lib smoke.
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "tracker": {
    "kind": "linear",
    "view_command": "linear issue view {id} --json"
  }
}
JSON
install_mock "$SB" linear '
printf "{\"state\":{\"name\":\"In Progress\"},\"title\":\"L1\",\"url\":\"https://l/1\",\"labels\":[{\"name\":\"a\"},{\"name\":\"b\"}]}\n"
exit 0
'
out=$(
  cd "$SB" || exit 99
  PATH="$SB/bin:$PATH"
  . .claude/hooks/_lib-read-config.sh
  . .claude/hooks/_lib-tracker.sh
  tracker_clear_cache
  tracker_view LIN-1
)
got_state=$(echo "$out" | jq -r '.state')
got_labels=$(echo "$out" | jq -r '.labels | join(",")')
if [ "$got_state" = "In Progress" ] && [ "$got_labels" = "a,b" ]; then
  record_pass "lib: tracker_view (linear) flattens state.name + label objects"
else
  record_fail "lib: tracker_view (linear) flattens state.name + label objects" "got state='$got_state' labels='$got_labels'"
fi
rm -rf "$SB"

# Jira lib smoke.
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "tracker": {
    "kind": "jira",
    "view_command": "jira issue view {id} --raw"
  }
}
JSON
install_mock "$SB" jira '
printf "{\"self\":\"https://j/1\",\"fields\":{\"status\":{\"name\":\"To Do\"},\"summary\":\"S1\",\"labels\":[\"x\",\"y\"]}}\n"
exit 0
'
out=$(
  cd "$SB" || exit 99
  PATH="$SB/bin:$PATH"
  . .claude/hooks/_lib-read-config.sh
  . .claude/hooks/_lib-tracker.sh
  tracker_clear_cache
  tracker_view JIRA-1
)
got_state=$(echo "$out" | jq -r '.state')
got_title=$(echo "$out" | jq -r '.title')
got_labels=$(echo "$out" | jq -r '.labels | join(",")')
if [ "$got_state" = "To Do" ] && [ "$got_title" = "S1" ] && [ "$got_labels" = "x,y" ]; then
  record_pass "lib: tracker_view (jira) reads .fields.status.name + summary + labels"
else
  record_fail "lib: tracker_view (jira) reads .fields.status.name + summary + labels" "got state='$got_state' title='$got_title' labels='$got_labels'"
fi
rm -rf "$SB"

# None: tracker_view returns non-zero.
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{ "tracker": { "kind": "none" } }
JSON
rc=$(
  cd "$SB" || exit 99
  . .claude/hooks/_lib-read-config.sh
  . .claude/hooks/_lib-tracker.sh
  tracker_clear_cache
  tracker_view 1 owner/repo >/dev/null
  echo $?
)
if [ "$rc" -ne 0 ]; then
  record_pass "lib: tracker_view (none) exits non-zero (existence-check disabled)"
else
  record_fail "lib: tracker_view (none) exits non-zero (existence-check disabled)" "got rc=$rc"
fi
rm -rf "$SB"

# =============================================================================
# Case 10 (#501): non-gh tracker, CLI absent / returns empty → shape-only
# fallback. The existence check can't run (no working CLI), so a well-formed
# key in a valid PR title must PASS (not block) — blocking would make it
# impossible to open a PR referencing a real non-GitHub ticket.
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "tracker": {
    "kind": "linear",
    "view_command": "linear issue view {id} --json",
    "id_pattern": "^[A-Z]+-[0-9]+$"
  }
}
JSON
# Mock linear CLI that always fails (CLI absent / unauthenticated / not
# queryable from this environment) — tracker_view returns empty.
install_mock "$SB" linear 'exit 1'
cmd='gh pr create --title "feat(LIN-77): real linear ticket" --body "
## Testing
x

## Glossary
| Term | Definition |
|------|------------|
| LIN | Linear |
" --head feature/LIN-77-test'
if run_pr_hook "$SB" "$cmd" 0; then
  record_pass "#501 pr-create: non-gh tracker not queryable → shape-only PASS (no block)"
else
  record_fail "#501 pr-create: non-gh tracker not queryable → shape-only PASS (no block)"
fi

# Same mode — verify-commit-refs.sh must also fall back to shape-only and PASS
# on a #N ref it cannot verify against the (absent) non-gh tracker.
cmd='git commit -m "feat: wire LIN-77

Closes #77
"'
if run_commit_hook "$SB" "$cmd" 0; then
  record_pass "#501 commit-refs: non-gh tracker not queryable → shape-only PASS (no block)"
else
  record_fail "#501 commit-refs: non-gh tracker not queryable → shape-only PASS (no block)"
fi
rm -rf "$SB"

# =============================================================================
# Case 11 (#501): an ill-formed PR title still fails the shape check even
# under a non-gh tracker. Shape-only fallback must NOT become a blanket pass —
# the title regex (type(TICKET): …) still gates malformed titles.
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "tracker": {
    "kind": "linear",
    "view_command": "linear issue view {id} --json",
    "id_pattern": "^[A-Z]+-[0-9]+$"
  }
}
JSON
install_mock "$SB" linear 'exit 1'
# Malformed title: no ticket ref in the type(TICKET): shape → must block (exit 2).
cmd='gh pr create --title "feat: missing ticket parens" --body "
## Testing
x

## Glossary
| Term | Definition |
|------|------------|
| x | x |
" --head feature/LIN-1-test'
if run_pr_hook "$SB" "$cmd" 2; then
  record_pass "#501 pr-create: ill-formed title still fails shape check under non-gh tracker"
else
  record_fail "#501 pr-create: ill-formed title still fails shape check under non-gh tracker"
fi
rm -rf "$SB"

# =============================================================================
# Case 12 (#501): gh behaviour is UNCHANGED — a fabricated #N under the default
# gh tracker still BLOCKS (exit 2). The shape-only fallback is strictly non-gh;
# the GitHub-issue existence check must remain hard for tracker.kind == gh.
# =============================================================================
SB=$(make_fork)
# Default config (no project-config.json) → tracker.kind = gh. Mock gh returns
# nothing (issue doesn't exist).
install_mock "$SB" gh '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  exit 1
fi
exit 0
'
cmd='gh pr create --title "feat(#88888): missing gh ticket" --body "
## Testing
x

## Glossary
| Term | Definition |
|------|------------|
| x | x |
" --head feature/GH-1-test'
if run_pr_hook "$SB" "$cmd" 2; then
  record_pass "#501 pr-create: gh tracker fabricated #N still BLOCKS (gh behaviour unchanged)"
else
  record_fail "#501 pr-create: gh tracker fabricated #N still BLOCKS (gh behaviour unchanged)"
fi

# verify-commit-refs.sh under gh: fabricated #N still blocks.
cmd='git commit -m "feat: thing

Closes #88888
"'
if run_commit_hook "$SB" "$cmd" 2; then
  record_pass "#501 commit-refs: gh tracker fabricated #N still BLOCKS (gh behaviour unchanged)"
else
  record_fail "#501 commit-refs: gh tracker fabricated #N still BLOCKS (gh behaviour unchanged)"
fi
rm -rf "$SB"

# =============================================================================
# Summary
# =============================================================================
echo
echo "===== test_tracker_aware_hooks.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0
