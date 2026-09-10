#!/bin/bash
# Tests for require-migration-ticket.sh Gate 2/3 after the #755 refactor that
# routes issue verification through the tracker abstraction (_lib-tracker.sh)
# instead of a hardcoded `gh issue view`.
#
# Cases:
#   1. gh happy path — OPEN + migration label + AgDR ref in body → allow (0)
#   2. glab happy path — GitLab "opened" issue + label + AgDR ref → allow (0)
#   3. tracker.kind=none — online gates skipped, allow (0), no CLI call
#   4. missing migration label → block (2)
#   5. closed ticket (gh CLOSED) → block (2)
#   6. closed ticket (glab "closed") → block (2)
#   7. body missing the AgDR reference → block (2)
#   8. gh unfetchable (issue view empty) → block (2)
#   9. glab unfetchable → block (2) — migration gate is fail-closed by design
#  10. non-migration path → pass-through allow (0)
#  11. no active-ticket marker → block (2)
#  12. jira happy path — ADF (Cloud) body links AgDR → allow (0) (#761)
#  12b. jira happy path — plain-string (Server/DC) body links AgDR → allow (0)
#  12c. linear happy path — description body links AgDR → allow (0) (#761)
#  12d. asana happy path — notes body links AgDR → allow (0) (#761)
#  12e. custom (body unmapped) reaches Gate 3, blocks with scoping note (2)
#  13. injection: metachar marker `number=` → block (2) and NOT executed
#  14. injection: metachar marker `repo=` → block (2) and NOT executed
#  15. guard: `#`-prefixed number passes and is shell-safe (printf %q escapes #)
#
# Exit 0 = all pass. Exit 1 on any failure.

set -u

# Test isolation: don't let a live session pin escape onto the real fork.
unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export APEXYARD_OPS_DISABLE_PIN=1

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$HOOK_DIR/require-migration-ticket.sh"
DEFAULTS="$(cd "$HOOK_DIR/.." && pwd)/project-config.defaults.json"

for f in "$HOOK_SCRIPT" "$HOOK_DIR/_lib-tracker.sh" "$HOOK_DIR/_lib-read-config.sh" "$DEFAULTS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file not found: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""
record_pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
record_fail() {
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  - $1"
  echo "FAIL: $1"
  [ -n "${2:-}" ] && echo "  $2"
}

# -----------------------------------------------------------------------------
# make_fork: an isolated apexyard fork sandbox with the hook + its libs.
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
    printf '' > .apexyard-fork
    cat > apexyard.projects.yaml <<'YAML'
version: 1
projects:
  - name: example
    repo: example/example
YAML
    mkdir -p .claude/hooks migrations
    for f in _lib-tracker.sh _lib-read-config.sh _lib-portfolio-paths.sh _lib-ops-root.sh _lib-detect-bash-write.sh _lib-path-resolve.sh _lib-active-ticket.sh; do
      [ -f "$HOOK_DIR/$f" ] && cp "$HOOK_DIR/$f" ".claude/hooks/$f"
    done
    cp "$HOOK_SCRIPT" .claude/hooks/require-migration-ticket.sh
    chmod +x .claude/hooks/*.sh
    cp "$DEFAULTS" .claude/project-config.defaults.json
    git add -A
    git commit -q -m "test fixture"
  )
  echo "$sb"
}

install_mock() {
  local sb="$1" name="$2" body="$3"
  mkdir -p "$sb/bin"
  cat > "$sb/bin/$name" <<EOF
#!/bin/bash
$body
EOF
  chmod +x "$sb/bin/$name"
}

set_marker() {
  local sb="$1" repo="$2" num="$3"
  mkdir -p "$sb/.claude/session"
  printf 'repo=%s\nnumber=%s\n' "$repo" "$num" > "$sb/.claude/session/current-ticket"
}

# Run the hook (Write tool) against a target path; check exit code.
run_hook() {
  local sb="$1" file_path="$2" expected_rc="$3"
  local input rc
  input=$(jq -nc --arg fp "$file_path" '{tool_name:"Write", tool_input:{file_path:$fp}}')
  (
    cd "$sb" || exit 99
    PATH="$sb/bin:$PATH" .claude/hooks/require-migration-ticket.sh <<<"$input" >/dev/null 2>&1
  )
  rc=$?
  [ "$rc" = "$expected_rc" ]
}

# Run the hook (Bash tool) against a synthetic shell command; check exit code.
# #886: used to prove the hook judges EVERY extracted write target, not
# just the first — a command naming a non-migration path FIRST and a
# migration path SECOND must still hit the migration gate on the second.
run_hook_bash() {
  local sb="$1" command="$2" expected_rc="$3" payload_cwd="${4-}" cwd_where="${5-top}"
  local input rc
  # #1159: an optional 4th arg injects a `.cwd` into the payload. The hook
  # NO LONGER READS IT -- round 9 removed the join after security review found
  # it approved a write against a ticket that did not govern it. The argument
  # is kept so the payloads these cases send stay realistic (the harness does
  # supply `.cwd` in production), not because any assertion depends on it.
  if [ $# -ge 4 ] && [ "$cwd_where" = "tool_input" ]; then
    # The hook reads `.cwd // .tool_input.cwd`. Exercising the SECOND arm needs
    # a payload that omits the top-level key entirely (Rex, round 4 on #1180 --
    # dropping that fallback left the suite at 42/42).
    input=$(jq -nc --arg c "$command" --arg d "$payload_cwd" '{tool_name:"Bash", tool_input:{command:$c, cwd:$d}}')
  elif [ $# -ge 4 ]; then
    input=$(jq -nc --arg c "$command" --arg d "$payload_cwd" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}')
  else
    input=$(jq -nc --arg c "$command" '{tool_name:"Bash", tool_input:{command:$c}}')
  fi
  (
    cd "$sb" || exit 99
    [ -n "${RHB_HOME:-}" ] && export HOME="$RHB_HOME"
    PATH="$sb/bin:$PATH" .claude/hooks/require-migration-ticket.sh <<<"$input" >/dev/null 2>&1
  )
  rc=$?
  [ "$rc" = "$expected_rc" ]
}

run_hook_bash_from_dir() {
  local sb="$1" run_dir="$2" command="$3" expected_rc="$4" input
  input=$(jq -nc --arg c "$command" '{tool_name:"Bash", tool_input:{command:$c}}')
  (
    cd "$run_dir" || exit 99
    PATH="$sb/bin:$PATH" "$sb/.claude/hooks/require-migration-ticket.sh" <<<"$input" >/dev/null 2>&1
  )
  [ "$?" = "$expected_rc" ]
}

MIG="migrations/001_add_table.sql"   # matches */migrations/*.sql
GH_OPEN_OK='
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf "{\"state\":\"OPEN\",\"title\":\"T\",\"url\":\"https://gh/42\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"refs docs/agdr/AgDR-0009-db-migration.md\"}\n"
  exit 0
fi
exit 0
'
GLAB_OPEN_OK='
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf "{\"state\":\"opened\",\"title\":\"GL\",\"web_url\":\"https://gitlab/g/p/-/issues/42\",\"description\":\"refs docs/agdr/AgDR-0010-schema-migration.md\",\"labels\":[\"migration\"]}\n"
  exit 0
fi
exit 0
'

# =============================================================================
# Case 1: gh happy path.
# =============================================================================
SB=$(make_fork)
set_marker "$SB" test-org/test-repo 42
install_mock "$SB" gh "$GH_OPEN_OK"
if run_hook "$SB" "$SB/$MIG" 0; then
  record_pass "gh: OPEN + migration label + AgDR body → allow"
else
  record_fail "gh: OPEN + migration label + AgDR body → allow"
fi
rm -rf "$SB"

# --- Cases 49-54 (#1182): per-target and marker-domain coverage -------------
SB=$(make_fork)
mkdir -p "$SB/workspace/example/migrations" "$SB/workspace/other/migrations" "$SB/.claude/session/tickets"
set_marker "$SB" "test-org/test-repo" 42
printf 'repo=%s\nnumber=%s\n' "test-org/test-repo" 99 > "$SB/.claude/session/tickets/example"
printf 'repo=%s\nnumber=%s\n' "test-org/test-repo" 77 > "$SB/.claude/session/tickets/other"
install_mock "$SB" gh 'case "$*" in
  *99*) echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}" ;;
  *)    echo "{\"state\":\"OPEN\",\"labels\":[],\"body\":\"\"}" ;;
esac'
if run_hook_bash "$SB" "cat > $SB/workspace/other/$MIG; cat > $SB/workspace/example/$MIG" 2; then
  record_pass "#1182 reverse argument order still blocks the failing project"
else
  record_fail "#1182 reverse argument order still blocks the failing project"
fi
rm -rf "$SB"

SB=$(make_fork)
mkdir -p "$SB/workspace/example/migrations" "$SB/workspace/other/migrations" "$SB/.claude/session/tickets"
set_marker "$SB" "test-org/test-repo" 42
printf 'repo=%s\nnumber=%s\n' "test-org/test-repo" 99 > "$SB/.claude/session/tickets/example"
printf 'repo=%s\nnumber=%s\n' "test-org/test-repo" 99 > "$SB/.claude/session/tickets/other"
install_mock "$SB" gh 'echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}"'
if run_hook_bash "$SB" "cat > $SB/workspace/example/$MIG; cat > $SB/workspace/other/$MIG" 0; then
  record_pass "#1182 two projects with one ticket domain both allow"
else
  record_fail "#1182 two projects with one ticket domain both allow"
fi
rm -rf "$SB"

SB=$(make_fork)
mkdir -p "$SB/workspace/example/migrations"
set_marker "$SB" "test-org/test-repo" 42
install_mock "$SB" gh 'echo "{\"state\":\"OPEN\",\"labels\":[],\"body\":\"\"}"'
if run_hook_bash "$SB" "cat > $SB/migrations/ops.sql; cat > $SB/workspace/example/$MIG" 2; then
  record_pass "#1182 ops-domain target is evaluated independently"
else
  record_fail "#1182 ops-domain target is evaluated independently"
fi
rm -rf "$SB"

SB=$(make_fork)
mkdir -p "$SB/workspace/example/migrations" "$SB/.claude/session/tickets/example"
printf 'repo=%s\nnumber=%s\n' "test-org/test-repo" 99 > "$SB/.claude/session/tickets/example/feature__1182"
install_mock "$SB" gh 'case "$*" in
  *99*) echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}" ;;
  *)    echo "{\"state\":\"OPEN\",\"labels\":[],\"body\":\"\"}" ;;
esac'
export CLAUDE_WORKTREE_BRANCH=feature/1182
if run_hook_bash "$SB" "cat > $SB/workspace/example/$MIG" 0; then
  record_pass "#1182 tier-0 worktree marker wins for migration writes"
else
  record_fail "#1182 tier-0 worktree marker wins for migration writes"
fi
unset CLAUDE_WORKTREE_BRANCH
rm -rf "$SB"

SB=$(make_fork)
mkdir -p "$SB/workspace/example"
set_marker "$SB" "test-org/test-repo" 42
mkdir -p "$SB/.claude/session/tickets"
printf 'repo=%s\nnumber=%s\n' "test-org/test-repo" 99 > "$SB/.claude/session/tickets/example"
install_mock "$SB" gh 'case "$*" in
  *99*) echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}" ;;
  *)    echo "{\"state\":\"OPEN\",\"labels\":[],\"body\":\"\"}" ;;
esac'
if run_hook_bash "$SB" "cat > $SB/workspace/example/new/migrations/001.sql" 0; then
  record_pass "#1182 absent migration directory uses nearest existing ancestor"
else
  record_fail "#1182 absent migration directory uses nearest existing ancestor"
fi
rm -rf "$SB"

# =============================================================================
# Case 2: glab happy path (the #755 core fix).
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{ "tracker": { "kind": "glab" } }
JSON
set_marker "$SB" g/p 42
install_mock "$SB" glab "$GLAB_OPEN_OK"
# A gh stub that would fail loudly if the hook wrongly reached for gh.
install_mock "$SB" gh 'exit 99'
if run_hook "$SB" "$SB/$MIG" 0; then
  record_pass "glab: opened + migration label + AgDR body → allow (#755)"
else
  record_fail "glab: opened + migration label + AgDR body → allow (#755)"
fi
rm -rf "$SB"

# =============================================================================
# Case 3: tracker.kind=none → online gates skipped, allow, no CLI call.
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{ "tracker": { "kind": "none" } }
JSON
set_marker "$SB" test-org/test-repo 42
# Any CLI call would be a bug — install stubs that fail.
install_mock "$SB" gh 'exit 99'
install_mock "$SB" glab 'exit 99'
if run_hook "$SB" "$SB/$MIG" 0; then
  record_pass "none: online verification skipped → allow (operator-trusted)"
else
  record_fail "none: online verification skipped → allow (operator-trusted)"
fi
rm -rf "$SB"

# =============================================================================
# Case 4: missing migration label → block.
# =============================================================================
SB=$(make_fork)
set_marker "$SB" test-org/test-repo 42
install_mock "$SB" gh '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf "{\"state\":\"OPEN\",\"title\":\"T\",\"url\":\"https://gh/42\",\"labels\":[{\"name\":\"backend\"}],\"body\":\"docs/agdr/AgDR-0009-db-migration.md\"}\n"
  exit 0
fi
exit 0
'
if run_hook "$SB" "$SB/$MIG" 2; then
  record_pass "gh: missing migration label → block"
else
  record_fail "gh: missing migration label → block"
fi
rm -rf "$SB"

# =============================================================================
# Case 5: closed ticket (gh CLOSED) → block.
# =============================================================================
SB=$(make_fork)
set_marker "$SB" test-org/test-repo 42
install_mock "$SB" gh '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf "{\"state\":\"CLOSED\",\"title\":\"T\",\"url\":\"https://gh/42\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0009-db-migration.md\"}\n"
  exit 0
fi
exit 0
'
if run_hook "$SB" "$SB/$MIG" 2; then
  record_pass "gh: CLOSED ticket → block"
else
  record_fail "gh: CLOSED ticket → block"
fi
rm -rf "$SB"

# =============================================================================
# Case 6: closed ticket (glab "closed") → block (tracker-agnostic state check).
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{ "tracker": { "kind": "glab" } }
JSON
set_marker "$SB" g/p 42
install_mock "$SB" glab '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf "{\"state\":\"closed\",\"title\":\"GL\",\"web_url\":\"https://gitlab/g/p/-/issues/42\",\"description\":\"docs/agdr/AgDR-0010-schema-migration.md\",\"labels\":[\"migration\"]}\n"
  exit 0
fi
exit 0
'
if run_hook "$SB" "$SB/$MIG" 2; then
  record_pass "glab: closed ticket → block (tracker-agnostic state)"
else
  record_fail "glab: closed ticket → block (tracker-agnostic state)"
fi
rm -rf "$SB"

# =============================================================================
# Case 7: body missing the AgDR reference → block (Gate 3).
# =============================================================================
SB=$(make_fork)
set_marker "$SB" test-org/test-repo 42
install_mock "$SB" gh '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf "{\"state\":\"OPEN\",\"title\":\"T\",\"url\":\"https://gh/42\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"no agdr link here\"}\n"
  exit 0
fi
exit 0
'
if run_hook "$SB" "$SB/$MIG" 2; then
  record_pass "gh: labelled but no AgDR ref in body → block (Gate 3)"
else
  record_fail "gh: labelled but no AgDR ref in body → block (Gate 3)"
fi
rm -rf "$SB"

# =============================================================================
# Case 8: gh unfetchable (issue view empty / exit 1) → block.
# =============================================================================
SB=$(make_fork)
set_marker "$SB" test-org/test-repo 42
install_mock "$SB" gh '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then exit 1; fi
exit 0
'
if run_hook "$SB" "$SB/$MIG" 2; then
  record_pass "gh: unfetchable issue → block (fail-closed)"
else
  record_fail "gh: unfetchable issue → block (fail-closed)"
fi
rm -rf "$SB"

# =============================================================================
# Case 9: glab unfetchable → block. The migration gate is deliberately
# fail-closed even for non-gh trackers (stricter than the #501 existence
# checks) — a high-blast-radius edit is not allowed against an unverifiable
# ticket. Adopters who genuinely can't query set tracker.kind=none.
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{ "tracker": { "kind": "glab" } }
JSON
set_marker "$SB" g/p 42
install_mock "$SB" glab '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then exit 1; fi
exit 0
'
if run_hook "$SB" "$SB/$MIG" 2; then
  record_pass "glab: unfetchable issue → block (migration gate fail-closed)"
else
  record_fail "glab: unfetchable issue → block (migration gate fail-closed)"
fi
rm -rf "$SB"

# =============================================================================
# Case 10: non-migration path → pass-through (allow), no tracker call.
# =============================================================================
SB=$(make_fork)
set_marker "$SB" test-org/test-repo 42
install_mock "$SB" gh 'exit 99'
if run_hook "$SB" "$SB/src/app.ts" 0; then
  record_pass "non-migration path → pass-through allow"
else
  record_fail "non-migration path → pass-through allow"
fi
rm -rf "$SB"

# =============================================================================
# Case 11: no active-ticket marker → block (Gate 1).
# =============================================================================
SB=$(make_fork)
install_mock "$SB" gh 'exit 99'
if run_hook "$SB" "$SB/$MIG" 2; then
  record_pass "no active-ticket marker → block (Gate 1)"
else
  record_fail "no active-ticket marker → block (Gate 1)"
fi
rm -rf "$SB"

# =============================================================================
# Case 12: jira happy path (#761). Body is now mapped for jira, so an OPEN,
# migration-labelled ticket whose ADF description (Jira Cloud) links a migration
# AgDR passes Gate 3 → allow (0). This replaces the pre-#761 case that asserted
# jira blocked with a body-scoping note (that limitation is now closed).
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{ "tracker": { "kind": "jira", "view_command": "jira issue view {id} --raw" } }
JSON
set_marker "$SB" test-org/test-repo JIRA-42
install_mock "$SB" jira '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf "{\"self\":\"https://jira/JIRA-42\",\"fields\":{\"status\":{\"name\":\"In Progress\"},\"summary\":\"S\",\"labels\":[\"migration\"],\"description\":{\"type\":\"doc\",\"version\":1,\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"refs docs/agdr/AgDR-0011-schema-migration.md\"}]}]}}}\n"
  exit 0
fi
exit 0
'
if run_hook "$SB" "$SB/$MIG" 0; then
  record_pass "jira: OPEN + migration label + AgDR in ADF body → allow (#761)"
else
  record_fail "jira: OPEN + migration label + AgDR in ADF body → allow (#761)"
fi
rm -rf "$SB"

# =============================================================================
# Case 12b: jira Server/DC plain-string description → allow (#761). Same as 12
# but the description comes back as a plain string (not ADF), exercising the
# adapter's string pass-through branch.
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{ "tracker": { "kind": "jira", "view_command": "jira issue view {id} --raw" } }
JSON
set_marker "$SB" test-org/test-repo JIRA-43
install_mock "$SB" jira '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf "{\"self\":\"https://jira/JIRA-43\",\"fields\":{\"status\":{\"name\":\"In Progress\"},\"summary\":\"S\",\"labels\":[\"migration\"],\"description\":\"refs docs/agdr/AgDR-0012-data-migration.md\"}}\n"
  exit 0
fi
exit 0
'
if run_hook "$SB" "$SB/$MIG" 0; then
  record_pass "jira: OPEN + label + AgDR in plain-string (Server/DC) body → allow (#761)"
else
  record_fail "jira: OPEN + label + AgDR in plain-string (Server/DC) body → allow (#761)"
fi
rm -rf "$SB"

# =============================================================================
# Case 12c: linear happy path (#761). Body maps to .description (markdown).
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{ "tracker": { "kind": "linear", "view_command": "linear issue view {id} --json" } }
JSON
set_marker "$SB" test-org/test-repo LIN-42
install_mock "$SB" linear '
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf "{\"state\":{\"name\":\"In Progress\"},\"title\":\"L\",\"url\":\"https://linear/LIN-42\",\"labels\":[{\"name\":\"migration\"}],\"description\":\"refs docs/agdr/AgDR-0013-schema-migration.md\"}\n"
  exit 0
fi
exit 0
'
if run_hook "$SB" "$SB/$MIG" 0; then
  record_pass "linear: OPEN + migration label + AgDR in description body → allow (#761)"
else
  record_fail "linear: OPEN + migration label + AgDR in description body → allow (#761)"
fi
rm -rf "$SB"

# =============================================================================
# Case 12d: asana happy path (#761). Body maps to .notes; state derives from
# .completed (false → Open). Asana uses a numeric task gid.
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{ "tracker": { "kind": "asana", "view_command": "asana task get {id} --json" } }
JSON
set_marker "$SB" test-org/test-repo 1122334455
install_mock "$SB" asana '
if [ "$1" = "task" ] && [ "$2" = "get" ]; then
  printf "{\"data\":{\"name\":\"A\",\"completed\":false,\"permalink_url\":\"https://asana/1\",\"tags\":[{\"name\":\"migration\"}],\"notes\":\"refs docs/agdr/AgDR-0014-schema-migration.md\"}}\n"
  exit 0
fi
exit 0
'
if run_hook "$SB" "$SB/$MIG" 0; then
  record_pass "asana: Open + migration tag + AgDR in notes body → allow (#761)"
else
  record_fail "asana: Open + migration tag + AgDR in notes body → allow (#761)"
fi
rm -rf "$SB"

# =============================================================================
# Case 12e: custom tracker WITHOUT body still reaches Gate 3 with an empty body
# and blocks WITH the scoping note. Custom is deliberately out of #761 scope —
# its body depends on the operator's normalise_jq — so the KIND_NOTE path must
# still fire for it (and must NOT name jira/linear/asana as unsupported).
# =============================================================================
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{ "tracker": { "kind": "custom", "view_command": "customcli view {id}" } }
JSON
set_marker "$SB" test-org/test-repo CUST-42
# Identity normalise (default): raw already shaped as {state,labels}; no body key.
install_mock "$SB" customcli '
printf "{\"state\":\"OPEN\",\"labels\":[\"migration\"]}\n"
exit 0
'
OUT=$(
  cd "$SB" || exit 99
  PATH="$SB/bin:$PATH" .claude/hooks/require-migration-ticket.sh \
    <<<"$(jq -nc --arg fp "$SB/$MIG" '{tool_name:"Write", tool_input:{file_path:$fp}}')" 2>&1
)
RC=$?
if [ "$RC" = "2" ] && echo "$OUT" | grep -q "tracker.kind=custom"; then
  record_pass "custom: Gate 3 blocks with body-scoping note (custom out of #761 scope)"
else
  record_fail "custom: Gate 3 blocks with body-scoping note (custom out of #761 scope)" "rc=$RC note-present=$(echo "$OUT" | grep -c 'tracker.kind=custom')"
fi
rm -rf "$SB"

# =============================================================================
# Case 13: command-injection guard — a marker `number=` carrying shell
# metacharacters must be BLOCKED (exit 2) and must NOT execute. Regression for
# the #755 security review: Gate 2 routes marker-derived TICKET_NUM through
# tracker_view → eval, so an unvalidated `number=42; touch X` would run the
# injected command. The shape guard rejects it before the tracker call.
# =============================================================================
SB=$(make_fork)
# gh stub returns a valid OPEN+labelled+AgDR issue, so the ONLY thing that can
# stop the injected `touch` from running is the caller-side shape guard.
install_mock "$SB" gh "$GH_OPEN_OK"
mkdir -p "$SB/.claude/session"
printf 'repo=test-org/test-repo\nnumber=42; touch %s/PWNED_NUM ;\n' "$SB" > "$SB/.claude/session/current-ticket"
if run_hook "$SB" "$SB/$MIG" 2 && [ ! -e "$SB/PWNED_NUM" ]; then
  record_pass "injection: metachar number= blocked (exit 2) and not executed"
else
  record_fail "injection: metachar number= blocked (exit 2) and not executed" "pwned-exists=$([ -e "$SB/PWNED_NUM" ] && echo yes || echo no)"
fi
rm -rf "$SB"

# =============================================================================
# Case 14: command-injection guard — same, via the marker `repo=` field
# ({owner_repo} is independently substituted into the eval'd command).
# =============================================================================
SB=$(make_fork)
install_mock "$SB" gh "$GH_OPEN_OK"
mkdir -p "$SB/.claude/session"
printf 'repo=x/y; touch %s/PWNED_REPO #\nnumber=42\n' "$SB" > "$SB/.claude/session/current-ticket"
if run_hook "$SB" "$SB/$MIG" 2 && [ ! -e "$SB/PWNED_REPO" ]; then
  record_pass "injection: metachar repo= blocked (exit 2) and not executed"
else
  record_fail "injection: metachar repo= blocked (exit 2) and not executed" "pwned-exists=$([ -e "$SB/PWNED_REPO" ] && echo yes || echo no)"
fi
rm -rf "$SB"

# =============================================================================
# Case 15: the shape guard allows a `#`-prefixed number (a legitimate display
# form). `#` is the one char in the number whitelist with shell meaning — an
# UNescaped `#` inside the eval'd command would start a comment and swallow the
# rest of the args. This asserts `#42` passes the guard AND is handled safely
# (the lib's printf %q escapes the `#`), so the whole flow allows (exit 0).
# =============================================================================
SB=$(make_fork)
install_mock "$SB" gh "$GH_OPEN_OK"
mkdir -p "$SB/.claude/session"
printf 'repo=test-org/test-repo\nnumber=#42\n' > "$SB/.claude/session/current-ticket"
if run_hook "$SB" "$SB/$MIG" 0; then
  record_pass "guard: #-prefixed number passes and is shell-safe (printf %q escapes #)"
else
  record_fail "guard: #-prefixed number passes and is shell-safe (printf %q escapes #)"
fi
rm -rf "$SB"

# =============================================================================
# Case 16: #886 — Bash command names a NON-migration target FIRST and a
# migration-path target SECOND. With an OPEN, labelled, AgDR-linked ticket
# → allow (0). Before #886, the hook judged only the first extracted
# target (src/app.ts, not migration-shaped) and exited 0 without ever
# consulting the tracker for the second target — this proves the second
# target is now the one that drives the gate.
# =============================================================================
SB=$(make_fork)
set_marker "$SB" test-org/test-repo 42
install_mock "$SB" gh "$GH_OPEN_OK"
if run_hook_bash "$SB" "echo x > src/app.ts; echo y > ./$MIG" 0; then
  record_pass "#886 bash: non-migration target then migration target, valid ticket → allow"
else
  record_fail "#886 bash: non-migration target then migration target, valid ticket → allow"
fi
rm -rf "$SB"

# =============================================================================
# Case 17: #886 — same shape, but NO active-ticket marker at all → block (2).
# Confirms Gate 1 fires for the migration-shaped SECOND target even though
# the FIRST target in the command is an ordinary source file.
# =============================================================================
SB=$(make_fork)
install_mock "$SB" gh 'exit 99'
if run_hook_bash "$SB" "echo x > src/app.ts; echo y > ./$MIG" 2; then
  record_pass "#886 bash: non-migration target then migration target, no ticket → block"
else
  record_fail "#886 bash: non-migration target then migration target, no ticket → block"
fi
rm -rf "$SB"

# =============================================================================
# Case 18: #886/#926 (Hakim security-review finding) — NO-SPACE `;` then
# redirect into a migration path: `echo x > src/app.ts;> ./migrations/...`.
# After splitting on `;`, the second segment BEGINS with `>` (no space
# between the separator and the redirection) — the pre-fix regex required
# a character before `>` to exist, so this migration-shaped target was
# silently dropped and the command passed through ungated. No ticket →
# block (2).
# =============================================================================
SB=$(make_fork)
install_mock "$SB" gh 'exit 99'
if run_hook_bash "$SB" "echo x > src/app.ts;> ./$MIG" 2; then
  record_pass "#886 bash: no-space ';' into migration target, no ticket → block"
else
  record_fail "#886 bash: no-space ';' into migration target, no ticket → block"
fi
rm -rf "$SB"

# =============================================================================
# Case 19: #886/#926 round 3 (Hakim adversarial re-hunt) — `&>` (redirect
# BOTH stdout and stderr to a file) directly into a migration path. The
# pre-round-3 operator alternation only modelled `>`/`>>`/`n>`; it missed
# `&>` entirely. No ticket → block (2).
# =============================================================================
SB=$(make_fork)
install_mock "$SB" gh 'exit 99'
if run_hook_bash "$SB" "echo x &> ./$MIG" 2; then
  record_pass "#886 bash: '&>' directly into migration target, no ticket → block"
else
  record_fail "#886 bash: '&>' directly into migration target, no ticket → block"
fi
rm -rf "$SB"

# =============================================================================
# Case 20: #886/#926 round 3 — `>|` (force-clobber) after a no-space `;`,
# non-migration target FIRST, migration target SECOND. Same shape as case
# 18 but with the force-clobber operator instead of a plain redirect. No
# ticket → block (2).
# =============================================================================
SB=$(make_fork)
install_mock "$SB" gh 'exit 99'
if run_hook_bash "$SB" "echo x > src/app.ts;>| ./$MIG" 2; then
  record_pass "#886 bash: '>|' force-clobber into migration target, no ticket → block"
else
  record_fail "#886 bash: '>|' force-clobber into migration target, no ticket → block"
fi
rm -rf "$SB"

# =============================================================================
# Case 21: #886/#926 round 4 (Hakim's fourth adversarial re-hunt) — ZERO
# whitespace between the operator and the migration-path target:
# `echo x > src/app.ts;>./migrations/...` (no space after the `;>`). The
# mandatory whitespace requirement this pattern used through round 3 was
# itself a bypass — bash accepts zero whitespace here. No ticket → block (2).
# =============================================================================
SB=$(make_fork)
install_mock "$SB" gh 'exit 99'
if run_hook_bash "$SB" "echo x > src/app.ts;>./$MIG" 2; then
  record_pass "#886 bash: no-space '>' into migration target, no ticket → block"
else
  record_fail "#886 bash: no-space '>' into migration target, no ticket → block"
fi
rm -rf "$SB"

# =============================================================================
# Case 22: #886/#926 round 5 (Hakim's fifth adversarial re-hunt — the
# STRUCTURAL fix). DETECTION (bash_command_appears_to_write) used to run
# the redirection matcher on the WHOLE, unsplit command; a `|`-preceded
# `>` (from `||`) is excluded by the leading-context class and isn't at
# `^` either, so `false ||> ./migrations/...` was never even recognised
# as a write. No ticket → block (2).
# =============================================================================
SB=$(make_fork)
install_mock "$SB" gh 'exit 99'
if run_hook_bash "$SB" "false ||> ./$MIG" 2; then
  record_pass "#886 bash: '||>' directly into migration target, no ticket → block"
else
  record_fail "#886 bash: '||>' directly into migration target, no ticket → block"
fi
rm -rf "$SB"

# =============================================================================
# Case 23 (#1159): an unexpanded shell variable in a migration write target is
# UNRESOLVABLE, and the gate must refuse rather than silently fall back to the
# ops-level marker. Before the fix, extraction returned the literal text
# `$WD/migrations/...`; it matched the migration matcher, so the gate fired,
# but it could not match any workspace prefix, so PROJECT stayed empty and the
# three-tier lookup landed on `current-ticket` — a DIFFERENT ticket, with no
# warning. A gate that resolves against the wrong marker is worse than one
# that fails, because the failure is invisible.
#
# The ops marker here is DELIBERATELY valid and migration-labelled: before the
# fix this case exited 0 (allowed, against the wrong ticket). Exit 2 proves the
# refusal comes from unresolvability, not from a missing/!unlabelled ticket.
# =============================================================================
SB=$(make_fork)
set_marker "$SB" "test-org/test-repo" 42
install_mock "$SB" gh 'echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}"'
if run_hook_bash "$SB" "cat > \"\$WD/$MIG\" <<EOF
x
EOF" 2; then
  record_pass "#1159 bash: unexpanded variable in migration target → refuse, no marker fallback"
else
  record_fail "#1159 bash: unexpanded variable in migration target → refuse, no marker fallback"
fi
rm -rf "$SB"

# =============================================================================
# Case 24 (#1159 regression guard): the fix must be NARROW. A LITERAL absolute
# path that is also outside any `workspace/<project>/` leaves PROJECT empty for
# an entirely legitimate reason — a migration inside the ops fork itself — and
# MUST still fall back to the ops-level marker and be allowed. Widening the
# refusal to "PROJECT is empty" instead of "target is unresolvable" would break
# this case, so it is pinned.
# =============================================================================
SB=$(make_fork)
set_marker "$SB" "test-org/test-repo" 42
install_mock "$SB" gh 'echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}"'
if run_hook "$SB" "$SB/$MIG" 0; then
  record_pass "#1159 guard: literal ops-fork migration path still uses ops marker → allow"
else
  record_fail "#1159 guard: literal ops-fork migration path still uses ops marker → allow"
fi
rm -rf "$SB"

# =============================================================================
# Case 25 (#1159, Rex review of PR #1180): Gate 0 must apply to the Bash path
# ONLY. An Edit/Write `file_path` is a literal string that never passed through
# a shell, so a `$` in it is an ordinary filename character — not an unexpanded
# variable. The first cut of the guard sat after the tool branches converged
# and hard-blocked such a path, with a message asserting a cause that had not
# been observed. Fully resolvable, inside the workspace, valid ticket → allow.
# =============================================================================
SB=$(make_fork)
set_marker "$SB" "test-org/test-repo" 42
install_mock "$SB" gh 'echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}"'
if run_hook "$SB" "$SB/migrations/001_price\$usd.sql" 0; then
  record_pass "#1159 guard: literal Write path containing '\$' is not a shell variable → allow"
else
  record_fail "#1159 guard: literal Write path containing '\$' is not a shell variable → allow"
fi
rm -rf "$SB"

# =============================================================================
# Cases 26-28 (#1159, Hakim review of PR #1180): the ORIGINAL fix refused only
# the `$` spelling. Backticks and $(...) are the same bash feature and were
# not caught, so they still reached the marker gates unresolved — the same
# Failure-1 signature in a different spelling. All three must now refuse.
# =============================================================================
for spelling in 'backtick' 'cmdsub' 'braced-var'; do
  case "$spelling" in
    backtick)   CMD='cat > `pwd`/'"$MIG" ;;
    cmdsub)     CMD='cat > $(pwd)/'"$MIG" ;;
    braced-var) CMD='cat > "${WD}/'"$MIG"'"' ;;
  esac
  SB=$(make_fork)
  set_marker "$SB" "test-org/test-repo" 42
  install_mock "$SB" gh 'echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}"'
  if run_hook_bash "$SB" "$CMD" 2; then
    record_pass "#1159 bash: unresolvable ($spelling) migration target → refuse"
  else
    record_fail "#1159 bash: unresolvable ($spelling) migration target → refuse"
  fi
  rm -rf "$SB"
done

# =============================================================================
# Case 29 (#1159, Hakim's ORDERING finding on PR #1180): the first cut placed
# the resolvability check AFTER the #886 loop, which `break`s on its first
# migration-shaped match. A compliant literal target named FIRST therefore
# smuggled a later unresolvable target straight past the gate (rc=0).
# Refusal must not depend on argument order.
# =============================================================================
SB=$(make_fork)
set_marker "$SB" "test-org/test-repo" 42
install_mock "$SB" gh 'echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}"'
if run_hook_bash "$SB" "echo a > ./$MIG; cat > \"\$WD/$MIG\"" 2; then
  record_pass "#1159 bash: literal target first must not smuggle an unresolvable one past the gate"
else
  record_fail "#1159 bash: literal target first must not smuggle an unresolvable one past the gate"
fi
rm -rf "$SB"

# =============================================================================
# Case 30 (#1159): a RELATIVE migration target is resolvable, not unresolvable.
# It must be normalised and gated normally — never refused by the resolvability
# check, and never silently passed through. With a valid migration ticket set,
# it is allowed.
# =============================================================================
SB=$(make_fork)
mkdir -p "$SB/workspace/example/migrations" "$SB/.claude/session/tickets"
set_marker "$SB" "test-org/test-repo" 42
printf 'repo=%s\nnumber=%s\n' "test-org/test-repo" 99 > "$SB/.claude/session/tickets/example"
install_mock "$SB" gh 'case "$*" in
  *99*) echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}" ;;
  *)    echo "{\"state\":\"OPEN\",\"labels\":[],\"body\":\"\"}" ;;
esac'
if run_hook_bash_from_dir "$SB" "$SB/workspace/example" "cat > ./$MIG" 0; then
  record_pass "#1182 relative migration target resolves against the actual cwd"
else
  record_fail "#1182 relative migration target resolves against the actual cwd"
fi
rm -rf "$SB"

# =============================================================================
# Cases 31-35 REMOVED (round 9) -- they covered the `.cwd` join, which is gone.
#
# The hook read the harness-supplied `.cwd` and joined relative write targets to
# it. Security review found the fail-open in round 9: `.cwd` is fixed when the
# tool call is FORMED and cannot see a `cd` inside the command, so a write into
# project B was approved against project A's ticket. Validating that `.cwd` is a
# real directory does not establish it is the directory the write happens in.
#
# These cases pinned the validation (absolute, exists, the `.tool_input.cwd`
# fallback, no-fabrication) -- all properties of a feature that no longer
# exists. The relative-path question moves to me2resh/apexyard#1182 with the
# shared resolver.
# =============================================================================

# =============================================================================
# Case 35 (#1159): with no base to join against, a relative target is returned
# VERBATIM -- it must not acquire a fabricated leading slash.
#
# The canonicaliser emits "/" unconditionally, so without the early return
# `workspace/e/migrations/1.sql` becomes `/workspace/e/migrations/1.sql`: an
# absolute path that never existed and can match a workspace prefix. That is
# the wrong-marker failure this gate exists to stop.
#
# It asserts the function directly, because the whole-hook exit code hides it.
# Originally added in round 3 (the suite passed 38/38 with the bug present),
# deleted in round 9 with the `.cwd` block it sat beside, and restored the same
# round when the mutation sweep showed the early return had gone unpinned. That
# is the round-9 lesson twice over: a case can stop discriminating when the code
# around it moves, and deleting a neighbour can disarm one just as easily.
# =============================================================================
_c35_fail=0
_c35_base=$(pwd -P)
for _c35_in in 'migrations/001.sql' './migrations/y.sql' 'workspace/e/migrations/1.sql' '../../../etc/migrations/x.sql'; do
  case "$_c35_in" in
    migrations/001.sql) _c35_want="$_c35_base/migrations/001.sql" ;;
    ./migrations/y.sql) _c35_want="$_c35_base/migrations/y.sql" ;;
    workspace/e/migrations/1.sql) _c35_want="$_c35_base/workspace/e/migrations/1.sql" ;;
    ../../../etc/migrations/x.sql) _c35_want="$(cd /etc && pwd -P)/migrations/x.sql" ;;
  esac
  _c35_out=$(
    . "$HOOK_DIR/_lib-path-resolve.sh"
    eval "$(sed -n '/^_rmt_normalise_target() {/,/^}/p' "$HOOK_SCRIPT")"
    _rmt_normalise_target "$_c35_in"
  )
  [ "$_c35_out" = "$_c35_want" ] || { _c35_fail=1; echo "    got '$_c35_out' for '$_c35_in' (want '$_c35_want')"; }
done
if [ "$_c35_fail" -eq 0 ]; then
  record_pass "#1182 relative target resolves from the hook cwd"
else
  record_fail "#1182 relative target resolves from the hook cwd"
fi

# =============================================================================
# Cases 36-38 (#1159, Rex round-3 on PR #1180): DISCRIMINATING coverage for
# normalisation. Cases 31-34 all passed against the unfixed commit-2 hook, and
# two mutation runs — normalisation replaced by a pass-through, and the
# round-2 bug restored verbatim — both still scored 38/38. The feature had no
# test that could tell it was working.
#
# The missing ingredient is a fixture where the two markers give OPPOSITE
# verdicts, so the exit code reveals WHICH ONE answered:
#   ops marker      #42 -> no migration label -> would BLOCK (rc=2)
#   project marker  #99 -> migration + AgDR   -> would ALLOW (rc=0)
# A target under workspace/example reaches #99 only if it was normalised into
# an absolute path first; un-normalised it misses the workspace prefix and
# falls to #42. rc=0 therefore proves normalisation happened.
# =============================================================================
# The relative shape is covered above by #1182. The two absolute shapes below
# continue to pin lexical canonicalisation and symlink-safe resolution.
for shape in 'dot-segment' 'double-slash'; do
  SB=$(make_fork)
  mkdir -p "$SB/workspace/example/migrations"
  # Ops-level marker: valid ticket, but NOT migration-labelled -> blocks.
  set_marker "$SB" "test-org/test-repo" 42
  # Per-project marker: migration-labelled + AgDR -> allows.
  mkdir -p "$SB/.claude/session/tickets"
  printf 'repo=%s\nnumber=%s\n' "test-org/test-repo" 99 > "$SB/.claude/session/tickets/example"
  install_mock "$SB" gh 'case "$*" in
  *99*) echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}" ;;
  *)    echo "{\"state\":\"OPEN\",\"labels\":[],\"body\":\"\"}" ;;
esac'
  case "$shape" in
    dot-segment)  TGT="$SB/./workspace/example/$MIG" ;;
    double-slash) TGT="$SB//workspace/example/$MIG" ;;
  esac
  if run_hook_bash "$SB" "cat > $TGT" 0 "$SB"; then
    record_pass "#1159 normalisation ($shape) reaches the PROJECT marker, not the ops fallback"
  else
    record_fail "#1159 normalisation ($shape) reaches the PROJECT marker, not the ops fallback"
  fi
  rm -rf "$SB"
done

# =============================================================================
# Cases 39-44 (#1159, round 4 on PR #1180). Every case here uses the
# opposite-verdict fixture from cases 36-38, because round 3 established that
# a same-verdict fixture cannot tell a working feature from a broken one:
#   ops marker      #42 -> no migration label -> BLOCK (rc=2)
#   project marker  #99 -> migration + AgDR   -> ALLOW (rc=0)
# The exit code therefore names which marker answered.
# =============================================================================
mk_opposing_fixture() {           # echoes the sandbox path
  local sb; sb=$(make_fork)
  mkdir -p "$sb/workspace/example/migrations"
  set_marker "$sb" "test-org/test-repo" 42
  mkdir -p "$sb/.claude/session/tickets"
  printf 'repo=%s\nnumber=%s\n' "test-org/test-repo" 99 > "$sb/.claude/session/tickets/example"
  install_mock "$sb" gh 'case "$*" in
  *99*) echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}" ;;
  *)    echo "{\"state\":\"OPEN\",\"labels\":[],\"body\":\"\"}" ;;
esac'
  echo "$sb"
}

# --- Cases 39-41: ~user / ~+ / ~- must NOT be joined to the caller's cwd -----
# Hakim, round 4: `_rmt_normalise_target` handled `~` and `~/`, then treated
# every other non-absolute target as cwd-relative -- so `~root/...` was joined
# and came back ABSOLUTE, which meant the still-relative early return added in
# round 3 never saw it. What `~root` / `~+` / `~-` expand to depends on the
# passwd database or on the caller shell's $PWD/$OLDPWD, none of which this
# process can read. Joining them yields a path bash never writes to, resolved
# under whichever project the caller happens to be sitting in.
# rc=2 proves the target stayed verbatim and fell to the ops marker.
for tilde in '~root' '~+' '~-'; do
  SB=$(mk_opposing_fixture)
  if run_hook_bash "$SB" "cat > $tilde/$MIG" 2 "$SB/workspace/example"; then
    record_pass "#1159 '$tilde/' target is not joined to the caller cwd (ops marker answers)"
  else
    record_fail "#1159 '$tilde/' target is not joined to the caller cwd (ops marker answers)"
  fi
  rm -rf "$SB"
done

# --- Case 42 REMOVED (round 8, b1+) -----------------------------------------
# It asserted that pass 1 refuses a target which only becomes migration-shaped
# after normalisation (`$F.sql` from a `migrations/` cwd). Selection now asks
# the RAW spelling in both passes, so that write is outside the set this gate
# governs -- exactly as on dev. Refusing it would be a refusal for a write the
# same change declared out of scope. The behaviour is not lost, it is not ours:
# it returns with me2resh/apexyard#1182.

# --- Cases 43-44 REMOVED (round 9) with the `.cwd` join ----------------------
# They pinned the absolute-and-exists validation and the `.tool_input.cwd`
# fallback. Both are properties of the removed feature.

# --- Case 45: the Bash gate must still fire on ADOPTER-configured paths ------
# Hakim, round 5 -- the blocker. Pass 2 selected on the NORMALISED spelling
# only. The default patterns are `*/`-anchored and survive absolutisation, but
# a project-configured pattern is repo-relative (this hook's own header
# documents `["src/db/**", "db/migrations/**"]`, and workflow-gates.md lists
# the same shapes) and matches nothing against an absolute path. So on any fork
# that sets `migration_paths`, RESOLVED_TARGET stayed empty and the Bash half
# of the gate silently stopped firing -- dev BLOCKED, this PR ALLOWED. Not the
# wrong ticket approving a migration: no ticket at all.
#
# Zero of the previous 48 cases set `migration_paths`, which is why four review
# rounds missed it.
SB=$(make_fork)
printf '{ "migration_paths": ["src/db/**", "db/migrations/**"] }\n' > "$SB/.claude/project-config.json"
mkdir -p "$SB/workspace/example/src/db"
set_marker "$SB" "test-org/test-repo" 42          # no migration label -> blocks
install_mock "$SB" gh 'echo "{\"state\":\"OPEN\",\"labels\":[],\"body\":\"\"}"'
if run_hook_bash "$SB" "cat > src/db/001.sql" 2 "$SB/workspace/example"; then
  record_pass "#1159 Bash gate still fires when migration_paths is adopter-configured (relative)"
else
  record_fail "#1159 Bash gate still fires when migration_paths is adopter-configured (relative)"
fi
rm -rf "$SB"

# --- Case 46: `<abs>/migrations/../1.sql` is selected, exactly as on dev -----
# THIS CELL REVERTED IN ROUND 8, deliberately. While selection normalised, this
# path was not migration-shaped once collapsed (`<abs>/1.sql`) and was allowed --
# recorded as one of the nine cells this PR moved. Under (b1+) selection asks
# the raw spelling, which does carry a `migrations/` segment, so the write is
# governed again and dev's false positive comes back with it.
#
# That is the price of the narrowing and it is paid knowingly: the cell was
# never part of fixing #1159, it arrived with normalisation-in-selection, and
# keeping it costs the checkable property that selection matches dev exactly.
# Retiring it properly belongs to me2resh/apexyard#1182.
SB=$(make_fork)
mkdir -p "$SB/workspace/example/migrations"
set_marker "$SB" "test-org/test-repo" 42
install_mock "$SB" gh 'echo "{\"state\":\"OPEN\",\"labels\":[],\"body\":\"\"}"'
if run_hook_bash "$SB" "cat > $SB/workspace/example/migrations/../1.sql" 2 "$SB/workspace/example"; then
  record_pass "#1159 selection matches dev on '<abs>/migrations/../1.sql' (cell reverted in round 8)"
else
  record_fail "#1159 selection matches dev on '<abs>/migrations/../1.sql' (cell reverted in round 8)"
fi
rm -rf "$SB"

# --- Case 47 REMOVED (round 9) -----------------------------------------------
# It pinned the relative-cwd reject arm. Two reasons it goes: the arm is gone
# with the join, and code review measured in round 9 that the case had ALREADY
# stopped discriminating when selection moved to raw-only in round 8 -- its
# comment stated a mechanism ("honouring the relative cwd makes it
# workspace/example/migrations/001.sql, which DOES match") that selection no
# longer performs. It was passing for a reason that had ceased to exist.
#
# That is the round-9 instance of the standing question: a previously
# mutation-checked case can stop discriminating when the code AROUND it moves,
# and nothing re-checks it. See the mutation note in the commit message.

# --- Case 48: the `~/` expansion arm is actually exercised -------------------
# Rex, round 5. Deleting `'~/'*) t="$HOME/${t#\~/}" ;;` left the suite at 48/48
# while materially changing output, because $HOME is never inside the fixture:
# both branches land outside workspace/ and the ops marker answers identically.
# Pointing HOME at workspace/example gives the two arms opposite verdicts --
# expanded reaches project #99 (allow), unexpanded falls through the `'~'*)`
# catch-all to ops #42 (block).
SB=$(mk_opposing_fixture)
if RHB_HOME="$SB/workspace/example" run_hook_bash "$SB" "cat > ~/$MIG" 0 "$SB/workspace/example"; then
  record_pass "#1159 '~/' is expanded via \$HOME, not left verbatim"
else
  record_fail "#1159 '~/' is expanded via \$HOME, not left verbatim"
fi
rm -rf "$SB"

# =============================================================================
# Cases 49-54 REMOVED (round 8) -- they move to me2resh/apexyard#1182.
#
# They covered the multi-target accumulator and its refusal: two projects in one
# command, the ops domain as an accumulator member, and one marker governing two
# projects. Rounds 6, 7 and 8 each produced a defect in that machinery, every one
# an adjacent case escaping the same single-representative election, and round 8
# tripped the stopping rule AgDR-0131 adopts. The machinery is gone; the cases go
# with it rather than lingering as tests that pass by accident of first-match
# selection. #1182 restores both together.
# =============================================================================

# --- Case 55: pass 1's RAW arm (Rex, round 7 -- the third silent arm) --------
# Deleting pass 1's raw spelling check left the suite at 55/55 while flipping a
# refusal into an allow. The arm is argued for in the pass-1 comment, in the
# pass-2 comment, and in AgDR-0131, and had no case anywhere.
#
# `<abs>/migrations/../$V.sql` is migration-shaped RAW and unresolvable, so
# pass 1 must refuse it. Normalised it is `<abs>/$V.sql`, which is not
# migration-shaped -- so with the raw arm gone, nothing matches and the write
# passes ungated. Case 46 is the control for this fixture: the same path with a
# resolvable filename is correctly allowed.
SB=$(mk_opposing_fixture)
if run_hook_bash "$SB" 'cat > '"$SB"'/workspace/example/migrations/../$V.sql' 2 "$SB/workspace/example"; then
  record_pass "#1159 pass 1 refuses an unresolvable target that is migration-shaped RAW only"
else
  record_fail "#1159 pass 1 refuses an unresolvable target that is migration-shaped RAW only"
fi
rm -rf "$SB"

# =============================================================================
# The DIFFERENTIAL test was REMOVED in round 9. It was not evidence.
#
# It extracted `is_migration_path` from the dev blob and from HEAD and compared
# them over 16 fixed strings. Three independent reviewers measured the same
# thing: the function is BYTE-IDENTICAL between the two, so the test compared a
# predicate to itself. It never invoked either selection pass, so it could not
# observe WHICH SPELLING selection hands the predicate -- and the spelling is
# what every rounds 5-8 divergence broke. Reintroducing the round-5 defect left
# it passing; enumerated cases caught it instead, the reverse of what its
# comment claimed.
#
# Worse, it never ran in CI at all: the tests workflow checks out at
# `fetch-depth: 1`, so the dev blob is not an object, `git show` fails, the test
# prints SKIP, records neither pass nor fail, and the suite exits 0 one case
# short. `bin/run-hook-tests.sh` discards suite stdout on pass, so the SKIP was
# invisible.
#
# Testing the property properly means comparing what each version SELECTS from
# the same payload, with a baseline available in CI and an absent baseline
# treated as a FAILURE rather than a skip. That is carried into
# me2resh/apexyard#1182's acceptance criteria rather than rebuilt here.
# =============================================================================

# =============================================================================
# Cases 45-47 (#1159, round 9). Each closes a mutation survivor that backed a
# claim the record makes. Found by sweeping EVERY surviving behaviour rather
# than only the ones changed this round -- which is the round-9 lesson.
# =============================================================================

# --- Case 45: a non-.sql file under migrations/ is still governed ------------
# The generic `*/migrations/*` arm is what governs anything that is not one of
# the named extensions. Dropping it is a real gate weakening and nothing
# noticed: the whole suite stayed green.
SB=$(make_fork)
mkdir -p "$SB/workspace/example/migrations"
set_marker "$SB" "test-org/test-repo" 42          # no migration label -> blocks
install_mock "$SB" gh 'echo "{\"state\":\"OPEN\",\"labels\":[],\"body\":\"\"}"'
if run_hook_bash "$SB" "cat > $SB/workspace/example/migrations/001_up.py" 2; then
  record_pass "#1159 a non-.sql file under migrations/ is governed (generic arm)"
else
  record_fail "#1159 a non-.sql file under migrations/ is governed (generic arm)"
fi
rm -rf "$SB"

# --- Case 46: every migration target is evaluated independently --------------
# Two migration targets in two projects must not be reduced to a representative.
# tickets/example #99 satisfies; tickets/other #77 does not. The command blocks
# regardless of argument order.
SB=$(make_fork)
mkdir -p "$SB/workspace/example/migrations" "$SB/workspace/other/migrations"
mkdir -p "$SB/.claude/session/tickets"
printf 'repo=%s\nnumber=%s\n' "test-org/test-repo" 99 > "$SB/.claude/session/tickets/example"
printf 'repo=%s\nnumber=%s\n' "test-org/test-repo" 77 > "$SB/.claude/session/tickets/other"
set_marker "$SB" "test-org/test-repo" 77
install_mock "$SB" gh 'case "$*" in
  *99*) echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}" ;;
  *)    echo "{\"state\":\"OPEN\",\"labels\":[],\"body\":\"\"}" ;;
esac'
if run_hook_bash "$SB" "cat > $SB/workspace/example/$MIG; cat > $SB/workspace/other/$MIG" 2; then
  record_pass "#1182 multi-target command blocks on the failing project"
else
  record_fail "#1182 multi-target command blocks on the failing project"
fi
rm -rf "$SB"

# --- Case 47: pass 1 refuses only MIGRATION-shaped unresolvable targets ------
# AgDR-0131 offers this as reassurance: an unrelated `$LOG` redirect is not
# refused. The claim had no test, so widening the refusal to every unresolvable
# target went undetected. rc=0 proves the scope holds.
SB=$(make_fork)
set_marker "$SB" "test-org/test-repo" 42
install_mock "$SB" gh 'echo "{\"state\":\"OPEN\",\"labels\":[],\"body\":\"\"}"'
if run_hook_bash "$SB" 'echo x > $LOG' 0; then
  record_pass "#1159 pass 1 does not refuse an unresolvable NON-migration target"
else
  record_fail "#1159 pass 1 does not refuse an unresolvable NON-migration target"
fi
rm -rf "$SB"

# --- Case 48: the `..` arm of the lexical canonicaliser ----------------------
# Security review (round 10) found this unpinned: the `//` and `/./` arms are
# covered by cases 36-38, `..` was not. It is the least defensible gap in the
# suite, because `..` is the mechanism behind BOTH the intended fix and the
# symlinked-anchor divergence recorded in AgDR-0131.
#
# Asserts the function directly: `<abs>/x/../y` must collapse to `<abs>/y`.
# Without the `..` arm it stays `<abs>/x/../y`, which fails the workspace
# prefix test and falls to the tier-2 ops marker -- the Failure 1 signature.
#
# #1181: the probe now sources the REAL _lib-path-resolve.sh alongside the
# extracted function, since _rmt_normalise_target composes _resolve_real_path
# after this lexical pass. Without it, calling the composed function here
# hits "command not found" on every probe (bash treats the undefined name as
# an external command) and the fallback in _rmt_normalise_target silently
# masks it by returning the lexical form unchanged -- these `/ws/...` probe
# paths don't exist on any real filesystem, so the resolve step, when it DOES
# run, degrades to the same doubled-slash-then-squashed answer regardless.
# Sourcing the real helper makes this probe exercise the actual composition.
_c48_fail=0
_c48_probe() {
  local got; got=$(
    # shellcheck source=/dev/null
    . "$HOOK_DIR/_lib-path-resolve.sh"
    eval "$(sed -n '/^_rmt_normalise_target() {/,/^}/p' "$HOOK_SCRIPT")"
    _rmt_normalise_target "$1"
  )
  [ "$got" = "$2" ] || { _c48_fail=1; echo "    got '$got' for '$1' (want '$2')"; }
}
_c48_probe '/ws/proj/x/../migrations/1.sql' '/ws/proj/migrations/1.sql'
_c48_probe '/ws/a/b/../../c/migrations/1.sql' '/ws/c/migrations/1.sql'
_c48_probe '/ws/proj/migrations/../1.sql'    '/ws/proj/1.sql'
_c48_probe '/../ws/migrations/1.sql'         '/ws/migrations/1.sql'
if [ "$_c48_fail" -eq 0 ]; then
  record_pass "#1159 the '..' arm of the canonicaliser collapses parent segments"
else
  record_fail "#1159 the '..' arm of the canonicaliser collapses parent segments"
fi

# =============================================================================
# Cases 1181-1..1181-5 (#1181): compose `_resolve_real_path` after the
# lexical collapse, and canonicalise the WORKSPACE_DIR/OPS_ROOT anchors with
# `pwd -P`, closing AgDR-0131's "symlinked anchor" and "un-canonicalised
# anchors" known gaps. Each case's own comment says whether it discriminates
# a full revert: 1181-1 pins a property that already held pre-#1181 (a
# non-regression pin, not a discriminator on its own) -- 1181-2 discriminates
# a narrower mistake (resolve in place of, rather than composed after,
# lexical); 1181-3, 1181-4 and 1181-5 discriminate a full revert and are the
# load-bearing pins for this ticket's acceptance criteria.
# =============================================================================

# --- Case 1181-1: a not-yet-created file with NO symlink still resolves -----
# (AC: "no regression on the property the lexical pass was chosen for.")
# This property predates #1181 -- lexical-only already got it right, since
# there is nothing here for _resolve_real_path to change. Reverting #1181
# does NOT fail this case; it is a non-regression pin, not a discriminator.
SB=$(mktemp -d); SB=$(cd "$SB" && pwd -P)
mkdir -p "$SB/workspace/example"
_c1181_1_target="$SB/workspace/example/migrations/003_new.sql"
_c1181_1_got=$(
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-path-resolve.sh"
  eval "$(sed -n '/^_rmt_normalise_target() {/,/^}/p' "$HOOK_SCRIPT")"
  _rmt_normalise_target "$_c1181_1_target"
)
if [ "$_c1181_1_got" = "$_c1181_1_target" ]; then
  record_pass "#1181 a not-yet-created migration file (no symlink) still resolves"
else
  record_fail "#1181 a not-yet-created migration file (no symlink) still resolves" \
    "got '$_c1181_1_got' want '$_c1181_1_target'"
fi
rm -rf "$SB"

# --- Case 1181-2: a dot-segment in an ABSENT tail is collapsed --------------
# (AC: "Dot-segments in an absent tail are collapsed, not passed through.")
# `newdir` does not exist -- `_resolve_real_path` walks up to `example`
# (which does) and re-appends the rest VERBATIM. Discriminates the mistake
# the ticket names: calling _resolve_real_path in place of the lexical pass
# rather than composed after it -- resolve-only on this exact input returns
# the UNCOLLAPSED `.../newdir/../migrations/2.sql`.
SB=$(mktemp -d); SB=$(cd "$SB" && pwd -P)
mkdir -p "$SB/workspace/example"
_c1181_2_raw="$SB/workspace/example/newdir/../migrations/2.sql"
_c1181_2_want="$SB/workspace/example/migrations/2.sql"
_c1181_2_got=$(
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-path-resolve.sh"
  eval "$(sed -n '/^_rmt_normalise_target() {/,/^}/p' "$HOOK_SCRIPT")"
  _rmt_normalise_target "$_c1181_2_raw"
)
if [ "$_c1181_2_got" = "$_c1181_2_want" ]; then
  record_pass "#1181 a dot-segment in an absent tail is collapsed, not passed through"
else
  record_fail "#1181 a dot-segment in an absent tail is collapsed, not passed through" \
    "got '$_c1181_2_got' want '$_c1181_2_want'"
fi
rm -rf "$SB"

# --- Case 1181-3: a symlinked ancestor resolves to the REAL path (unit) -----
# (AC: "A migration write reached through a symlinked ancestor resolves to
# the same marker the kernel's write would be governed by.") Discriminates a
# full revert: pre-#1181 (lexical-only) returns the alias spelling
# unchanged, since lexical collapse cannot see a symlink.
SB=$(mktemp -d); SB=$(cd "$SB" && pwd -P)
mkdir -p "$SB/workspace/example/migrations"
ln -s "$SB/workspace/example" "$SB/example_alias"
_c1181_3_raw="$SB/example_alias/migrations/001.sql"
_c1181_3_want="$SB/workspace/example/migrations/001.sql"
_c1181_3_got=$(
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-path-resolve.sh"
  eval "$(sed -n '/^_rmt_normalise_target() {/,/^}/p' "$HOOK_SCRIPT")"
  _rmt_normalise_target "$_c1181_3_raw"
)
if [ "$_c1181_3_got" = "$_c1181_3_want" ]; then
  record_pass "#1181 a symlinked ancestor resolves to the real, kernel-accurate path"
else
  record_fail "#1181 a symlinked ancestor resolves to the real, kernel-accurate path" \
    "got '$_c1181_3_got' want '$_c1181_3_want'"
fi
rm -rf "$SB"

# --- Case 1181-4: symlinked ancestor reaches the PROJECT marker (end-to-end)
# Whole-hook proof of AC#1, using the opposing-marker fixture from cases
# 36-38 (mk_opposing_fixture): ops marker #42 has no migration label
# (BLOCK); project marker #99 for "example" has one (ALLOW). A target
# spelled through a symlink alias OUTSIDE workspace/ must reach #99 (rc=0),
# not fall through to #42 (rc=2) the way an un-normalised alias spelling
# would. Discriminates a full revert.
SB=$(mk_opposing_fixture)
ln -s "$SB/workspace/example" "$SB/example_alias"
if run_hook_bash "$SB" "cat > $SB/example_alias/$MIG" 0 "$SB"; then
  record_pass "#1181 symlinked ancestor reaches the project marker, not the ops fallback"
else
  record_fail "#1181 symlinked ancestor reaches the project marker, not the ops fallback"
fi
rm -rf "$SB"

# --- Case 1181-5: canonicalised workspace anchor (end-to-end) --------------
# AC: "The workspace boundary is canonicalised, so the same file addressed
# via /tmp and /private/tmp resolves to one marker." Reproduced portably
# (CI may not run on a host where /tmp is itself a symlink): `workspace/`
# ITSELF is turned into a symlink to `real_workspace/`, and the write is
# spelled through the REAL directory -- bypassing the `workspace` symlink
# entirely, so this isolates the ANCHOR fix from the target-resolution fix
# in cases 1181-3/1181-4 (the raw target here needs no resolution of its
# own; only the anchor comparison needs canonicalising).
#
# _lib-portfolio-paths.sh and _lib-read-config.sh are DELETED from this one
# sandbox after make_fork() copies them in. Debugging this case found that
# portfolio_workspace_dir() -- when both libs ARE present, as they are in
# every other case in this file -- already canonicalises WORKSPACE_DIR
# itself via its own _portfolio_canonicalize, which masks whether THIS
# gate's anchor fix does anything at all: the case passed even against the
# pre-#1181 hook. Removing the two libs forces require-migration-ticket.sh's
# override block to skip (its guard requires both present) and WORKSPACE_DIR
# to stay this file's raw "$OPS_ROOT/workspace" -- the documented "library
# missing" fallback shape used elsewhere in this file -- which is exactly
# the shape the anchor-canonicalisation fix protects. Confirmed by probing
# both hook versions directly: pre-#1181, raw WORKSPACE_DIR ($SB/workspace)
# does not literally prefix a target spelled via $SB/real_workspace/..., so
# PROJECT resolution fails and falls to the ops marker (#42, rc=2); post-fix
# it reaches #99 (rc=0). Discriminates a full revert.
SB=$(mk_opposing_fixture)
rm -f "$SB/.claude/hooks/_lib-portfolio-paths.sh" "$SB/.claude/hooks/_lib-read-config.sh"
mv "$SB/workspace" "$SB/real_workspace"
ln -s "$SB/real_workspace" "$SB/workspace"
if run_hook_bash "$SB" "cat > $SB/real_workspace/example/$MIG" 0 "$SB"; then
  record_pass "#1181 workspace anchor canonicalised: a target spelled around the workspace/ symlink still reaches the project marker"
else
  record_fail "#1181 workspace anchor canonicalised: a target spelled around the workspace/ symlink still reaches the project marker"
fi
rm -rf "$SB"

# =============================================================================
# Cases 1181-6..1181-9 (#1198 review -- B1): the anchor block above composes
# `_resolve_real_path`, but the version of this fix originally submitted on
# this PR instead kept an `[ -n "$X" ] && [ -d "$X" ]` existence guard around
# a raw `cd ... && pwd -P` -- i.e. it canonicalised the anchor only when the
# directory already existed on disk, and left it EMPTY otherwise.
# AgDR-0131's own "un-canonicalised workspace anchors" bullet claimed this
# class of gap was retired by #1181; it was not -- the submitted fix
# reintroduced the same class of gap in a spelling of its own: an absent or
# dangling-symlink WORKSPACE_DIR/OPS_ROOT empties the anchor,
# `_rmt_project_for_path`'s first branch is skipped, and the write silently
# falls to the tier-2 ops marker instead of the project that actually owns
# it -- #1137's cross-repo authorisation hole, reachable on a brand-new
# path. Every case below is BOTH a regression pin (fails against that
# existence-gated anchor block) and a coverage gap-closer: AgDR-0131 records
# zero cases exercising an absent or dangling-symlink anchor at all -- every
# 1181-* case above uses a workspace dir that already exists on disk.
#
# The fixture MUST place the workspace dir OUTSIDE the ops root -- a
# split-portfolio-v2-shaped `.portfolio.workspace_dir` override pointing at
# a sibling directory -- or `_rmt_project_for_path`'s second branch
# ($OPS_ROOT_REAL/workspace/*) silently rescues a broken first branch and
# the case proves nothing. That mistake already happened once on this
# ticket; see case 1181-5's own comment.
# =============================================================================

# mk_opposing_fixture_external_ws: like mk_opposing_fixture (ops marker #42
# unlabelled -> BLOCK; project marker #99 for "example" migration+AgDR ->
# ALLOW), but points .portfolio.workspace_dir at a SIBLING directory outside
# the ops root instead of the in-fork default $sb/workspace. Echoes
# "<sb> <external-workspace-dir>" on one line. The workspace dir itself is
# deliberately NOT created here -- each case below decides whether it stays
# wholly absent or becomes a dangling symlink, then removes both $sb and the
# external parent it created.
mk_opposing_fixture_external_ws() {
  local sb ws_parent ws_dir
  sb=$(make_fork)
  ws_parent="$(dirname "$sb")/$(basename "$sb")-ext-portfolio"
  ws_dir="$ws_parent/workspace"
  cat > "$sb/.claude/project-config.json" <<JSON
{ "portfolio": { "workspace_dir": "../$(basename "$ws_parent")/workspace" } }
JSON
  set_marker "$sb" "test-org/test-repo" 42
  mkdir -p "$sb/.claude/session/tickets"
  printf 'repo=%s\nnumber=%s\n' "test-org/test-repo" 99 > "$sb/.claude/session/tickets/example"
  install_mock "$sb" gh 'case "$*" in
  *99*) echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}" ;;
  *)    echo "{\"state\":\"OPEN\",\"labels\":[],\"body\":\"\"}" ;;
esac'
  printf '%s %s' "$sb" "$ws_dir"
}

# --- Case 1181-6: absent workspace anchor -- Bash target (B1) ---------------
# Neither the workspace dir nor its parent exists on disk. The FIXED anchor
# still resolves it (_resolve_real_path's realpath -m semantics) to the same
# spelling the target itself normalises to, so branch 1 of
# _rmt_project_for_path matches and the PROJECT marker (#99, valid) answers:
# rc=0. Reverting to the existence-gated anchor empties WORKSPACE_DIR_REAL;
# branch 2 does not rescue it (the workspace dir is OUTSIDE the ops root),
# PROJECT resolves to empty, and the tier-2 ops marker (#42, unlabelled)
# answers instead: rc=2. Discriminates a full revert of the anchor fix.
read -r SB WS_DIR <<<"$(mk_opposing_fixture_external_ws)"
if run_hook_bash "$SB" "cat > $WS_DIR/example/$MIG" 0 "$SB"; then
  record_pass "#1198 B1: absent workspace anchor still reaches the project marker (Bash)"
else
  record_fail "#1198 B1: absent workspace anchor still reaches the project marker (Bash)"
fi
rm -rf "$SB" "$(dirname "$WS_DIR")"

# --- Case 1181-7: absent workspace anchor -- Edit/Write file_path (B1) ------
# Same fixture and the same anchor bug, exercised through the Edit/Write
# tool path instead of Bash. FILE_PATH is the literal string here -- never
# normalised, by design (see _rmt_normalise_target's own docstring) -- so
# this isolates the ANCHOR fix from target normalisation entirely: the
# literal path already matches WORKSPACE_DIR_REAL byte-for-byte once the
# anchor resolves correctly.
read -r SB WS_DIR <<<"$(mk_opposing_fixture_external_ws)"
if run_hook "$SB" "$WS_DIR/example/$MIG" 0; then
  record_pass "#1198 B1: absent workspace anchor still reaches the project marker (Write)"
else
  record_fail "#1198 B1: absent workspace anchor still reaches the project marker (Write)"
fi
rm -rf "$SB" "$(dirname "$WS_DIR")"

# --- Case 1181-8: dangling-symlink workspace anchor -- Bash target (B1) -----
# The workspace dir EXISTS as a symlink, but its target does not -- a
# distinct filesystem shape from case 1181-6: `[ -d ]` follows symlinks and
# reports false for a broken one, so the existence-gated anchor block
# empties WORKSPACE_DIR_REAL here too, by a different trigger. Same
# verdicts: fixed anchor -> rc=0 (project marker), reverted -> rc=2 (ops
# fallback).
read -r SB WS_DIR <<<"$(mk_opposing_fixture_external_ws)"
mkdir -p "$(dirname "$WS_DIR")"
ln -s "$(dirname "$WS_DIR")/does-not-exist" "$WS_DIR"
if run_hook_bash "$SB" "cat > $WS_DIR/example/$MIG" 0 "$SB"; then
  record_pass "#1198 B1: dangling-symlink workspace anchor still reaches the project marker (Bash)"
else
  record_fail "#1198 B1: dangling-symlink workspace anchor still reaches the project marker (Bash)"
fi
rm -rf "$SB" "$(dirname "$WS_DIR")"

# --- Case 1181-9: dangling-symlink workspace anchor -- Edit/Write (B1) ------
# Case 1181-8's fixture, exercised through the Edit/Write tool path.
read -r SB WS_DIR <<<"$(mk_opposing_fixture_external_ws)"
mkdir -p "$(dirname "$WS_DIR")"
ln -s "$(dirname "$WS_DIR")/does-not-exist" "$WS_DIR"
if run_hook "$SB" "$WS_DIR/example/$MIG" 0; then
  record_pass "#1198 B1: dangling-symlink workspace anchor still reaches the project marker (Write)"
else
  record_fail "#1198 B1: dangling-symlink workspace anchor still reaches the project marker (Write)"
fi
rm -rf "$SB" "$(dirname "$WS_DIR")"

# --- Selection parity: compare the raw target selected by dev and this hook --
# The baseline is the parent commit, not a copied predicate. If the checkout
# cannot provide it, the test fails instead of silently skipping.
_parity_base=$(git rev-parse HEAD^ 2>/dev/null || true)
_parity_fail=0
if [ -z "$_parity_base" ]; then
  record_fail "#1182 selection parity baseline is available"
else
  _parity_baseline=$(mktemp "$HOOK_DIR/.baseline-1182.XXXXXX")
  if ! git show "$_parity_base:.claude/hooks/require-migration-ticket.sh" >"$_parity_baseline" 2>/dev/null; then
    record_fail "#1182 selection parity baseline can be read"
    _parity_fail=1
  else
    # Instrument only the baseline's first-match selector. The current hook's
    # explicit selection-test branch emits the same raw spelling before gating.
    _parity_instrumented=$(mktemp "$HOOK_DIR/.baseline-1182-instrumented.XXXXXX")
    awk '
      /if is_migration_path "\$_tgt"; then/ && !done { print; print "      if [ \"${APEXYARD_SELECTION_TEST:-}\" = \"1\" ]; then printf \"%s\\n\" \"$_tgt\"; exit 0; fi"; done=1; next }
      { print }
    ' "$_parity_baseline" >"$_parity_instrumented"
    for _payload_target in "/tmp/migrations/001.sql" "/tmp/db/002.sql"; do
      _payload=$(jq -nc --arg c "cat > $_payload_target" '{tool_name:"Bash",tool_input:{command:$c}}')
      _current=$(APEXYARD_SELECTION_TEST=1 bash "$HOOK_SCRIPT" <<<"$_payload" 2>/dev/null || true)
      _baseline=$(APEXYARD_SELECTION_TEST=1 bash "$_parity_instrumented" <<<"$_payload" 2>/dev/null || true)
      if [ "$_current" != "$_baseline" ]; then
        _parity_fail=1
        echo "FAIL: #1182 selection parity for $_payload_target (current='$_current' baseline='$_baseline')"
      fi
    done
    rm -f "$_parity_instrumented"
    if [ "$_parity_fail" -eq 0 ]; then
      record_pass "#1182 selection parity compares current and parent implementations"
    else
      FAIL=$((FAIL + 1))
      FAILED_CASES="$FAILED_CASES\n  - #1182 selection parity compares current and parent implementations"
    fi
  fi
  rm -f "$_parity_baseline"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "===== test_require_migration_ticket.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0
