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
    for f in _lib-tracker.sh _lib-read-config.sh _lib-portfolio-paths.sh _lib-ops-root.sh _lib-detect-bash-write.sh; do
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
  local sb="$1" command="$2" expected_rc="$3" payload_cwd="${4-}"
  local input rc
  # #1159: an optional 4th arg injects a `.cwd` into the payload, so tests can
  # exercise the harness-supplied working directory the hook trusts for
  # resolving relative write targets.
  if [ $# -ge 4 ]; then
    input=$(jq -nc --arg c "$command" --arg d "$payload_cwd" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}')
  else
    input=$(jq -nc --arg c "$command" '{tool_name:"Bash", tool_input:{command:$c}}')
  fi
  (
    cd "$sb" || exit 99
    PATH="$sb/bin:$PATH" .claude/hooks/require-migration-ticket.sh <<<"$input" >/dev/null 2>&1
  )
  rc=$?
  [ "$rc" = "$expected_rc" ]
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
set_marker "$SB" "test-org/test-repo" 42
install_mock "$SB" gh 'echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}"'
if run_hook_bash "$SB" "cat > ./$MIG" 0; then
  record_pass "#1159 bash: relative migration target is resolved, not refused → allow"
else
  record_fail "#1159 bash: relative migration target is resolved, not refused → allow"
fi
rm -rf "$SB"

# =============================================================================
# Cases 31-33 (#1159, Rex re-review of PR #1180): the hook trusts `.cwd` to
# resolve a relative target. An untrustworthy value must be DISCARDED, not
# joined — joining fabricates a plausible absolute path that is
# indistinguishable downstream from a real one and can resolve the write
# against an unrelated project's marker.
#
# Each case sets a valid migration ticket, so a refusal here would be a false
# block, and an allow-via-fabricated-path would be the silent wrong-marker
# failure. Behaviour with an unusable cwd must match the no-cwd case exactly.
# =============================================================================
for cwdcase in 'relative' 'nonexistent' 'empty'; do
  case "$cwdcase" in
    relative)    CWDVAL='relative/dir' ;;
    nonexistent) CWDVAL='/definitely/not/a/real/dir/anywhere' ;;
    empty)       CWDVAL='' ;;
  esac
  SB=$(make_fork)
  set_marker "$SB" "test-org/test-repo" 42
  install_mock "$SB" gh 'echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}"'
  if run_hook_bash "$SB" "cat > ./$MIG" 0 "$CWDVAL"; then
    record_pass "#1159 cwd: untrusted .cwd ($cwdcase) is discarded, not joined"
  else
    record_fail "#1159 cwd: untrusted .cwd ($cwdcase) is discarded, not joined"
  fi
  rm -rf "$SB"
done

# =============================================================================
# Case 34 (#1159): a VALID absolute, existing `.cwd` IS used — this is what
# pins the normalisation actually happening, rather than the target merely
# passing through unresolved. The relative target resolves under the fork, so
# the migration matcher and marker resolution both see the real path.
# =============================================================================
SB=$(make_fork)
set_marker "$SB" "test-org/test-repo" 42
install_mock "$SB" gh 'echo "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"migration\"}],\"body\":\"docs/agdr/AgDR-0001-db-migration.md\"}"'
if run_hook_bash "$SB" "cat > ./$MIG" 0 "$SB"; then
  record_pass "#1159 cwd: valid absolute .cwd is used to resolve a relative target"
else
  record_fail "#1159 cwd: valid absolute .cwd is used to resolve a relative target"
fi
rm -rf "$SB"

# =============================================================================
# Case 35 (#1159, Hakim round-3 on PR #1180): with NO usable cwd, a relative
# target must be returned EXACTLY as received. Commit 3 stopped joining the
# untrusted cwd but still piped the target through the canonicaliser, which
# emits a leading "/" unconditionally — so `migrations/001.sql` became
# `/migrations/001.sql`. That fabricates an absolute path that never existed
# and can match a workspace prefix: the same failure the join was removed to
# avoid, relocated rather than fixed.
#
# This asserts the function directly, because the whole-hook exit code hid it
# (the suite passed 38/38 with the bug present).
# =============================================================================
_c35_fail=0
for _c35_in in 'migrations/001.sql' './migrations/y.sql' '../../../etc/migrations/x.sql'; do
  _c35_out=$(
    PAYLOAD_CWD=""
    eval "$(sed -n '/^_rmt_normalise_target() {/,/^}/p' "$HOOK_SCRIPT")"
    _rmt_normalise_target "$_c35_in"
  )
  [ "$_c35_out" = "$_c35_in" ] || { _c35_fail=1; echo "    got '$_c35_out' for '$_c35_in'"; }
done
if [ "$_c35_fail" -eq 0 ]; then
  record_pass "#1159 no usable cwd: relative target returned verbatim, not fabricated absolute"
else
  record_fail "#1159 no usable cwd: relative target returned verbatim, not fabricated absolute"
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
for shape in 'relative' 'dot-segment' 'double-slash'; do
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
    relative)     TGT="workspace/example/$MIG" ;;
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
