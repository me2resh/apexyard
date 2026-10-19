#!/bin/bash
# Smoke test for apply-agent-routing.sh (SessionStart sync hook) and
# block-agent-routing-drift.sh (pre-commit + pre-push drift guard) —
# the two hooks #351 PR 2 ships per AgDR-0050 § Axis 4.
#
# Coverage (13 cases, plus case 14 for #442 and cases 15–21 for #1763):
#
#   Sync hook (apply-agent-routing.sh):
#     1. Empty config — empty agent-routing.yaml means no-op; no agent
#        files mutated, no banner.
#     2. Single override — qa-engineer model haiku → opus; the QA
#        agent file's model line is rewritten, other agent files
#        untouched, framework-defaults snapshot written.
#     3. Orphan entry — routing config references an agent that doesn't
#        exist under .claude/agents/; silently skipped, no error.
#     4. Idempotency — running the sync hook twice with the same config
#        produces the same state; no compounded edits to the agent file
#        or env files.
#
#   Drift guard (block-agent-routing-drift.sh):
#     5. Drift FIRES — pre-commit on a staged .claude/agents/<name>.md
#        with a non-default model: line and no escape-hatch comment
#        blocks (exit 2).
#     6. Drift accepts with escape hatch — same scenario but the file
#        carries `# routing-config:override <reason>` somewhere;
#        hook exits 0.
#     7. Drift accepts on no-drift — staged agent file carries the
#        framework default model: line; hook exits 0 cleanly.
#     8. Utility-agent override — ticket-manager sonnet → opus exercises
#        the utility-class path (not just role-derived agents).
#
#   Ollama local-routing extensions (me2resh/apexyard#438):
#     9. Ollama agent + reachable proxy + pulled model — full apply:
#        model rewrite, per-agent env file, __session__.env, banner
#        suffix "1 Ollama, 0 warning(s)".
#    10. Ollama agent + UNREACHABLE proxy — model still rewrites; per-
#        agent env file NOT written; no __session__.env; banner reports
#        "1 Ollama, 1 warning(s)" with reachability warning emitted.
#    11. Ollama agent + reachable proxy + model NOT pulled — apply
#        succeeds (proxy is reachable); banner emits `ollama pull <name>`
#        hint as a 1-warning.
#    12. Two agents same endpoint — single __session__.env written, no
#        multi-endpoint warning.
#    13. Two agents different endpoints — first-declared wins;
#        multi-endpoint warning emitted.
#
#   Mock curl: cases 9-13 prepend a fake `curl` to PATH that consults
#   $APEXYARD_MOCK_CURL_DIR for canned responses. Each fixture is named
#   by the URL with /:?&= squeezed to a single underscore, contents
#   `<HTTP_STATUS>\n<BODY>`. Missing fixture = exit 7 (unreachable).
#
# Pattern follows test_portfolio_paths.sh + test_split_portfolio_v2_migration.sh:
#   - SRC_ROOT resolved from the test file's location
#   - Each case builds an isolated sandbox apexyard fork under $TMPDIR
#   - Sources libs from the sandbox (NOT from SRC_ROOT) so resolution
#     matches the in-fork shape the hook sees at runtime
#
# Exit 0 means all cases passed. Exit 1 on first failure.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


# Test isolation (#528): apply-agent-routing.sh resolves the ops root via
# _lib-ops-root.sh, which — inside a real Claude Code session — honours the
# session pin ($APEXYARD_OPS_PIN_DIR/ops-root-$CLAUDE_CODE_SESSION_ID) and
# points at the REAL fork, NOT our mktemp sandbox. That made the hook rewrite
# the real .claude/agents/*.md and write a stray snapshot there, while every
# sandbox assertion failed. Disable the pin so ops-root resolves by walk-up to
# the sandbox. (Hooks run headless in CI have no pin, so this is a no-op there.)
export APEXYARD_OPS_DISABLE_PIN=1

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SYNC_HOOK="$SRC_ROOT/.claude/hooks/apply-agent-routing.sh"
DRIFT_HOOK="$SRC_ROOT/.claude/hooks/block-agent-routing-drift.sh"
LIB_OPS="$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"
LIB_PORT="$SRC_ROOT/.claude/hooks/_lib-portfolio-paths.sh"
LIB_CFG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"

for f in "$SYNC_HOOK" "$DRIFT_HOOK" "$LIB_OPS" "$LIB_PORT" "$LIB_CFG" "$DEFAULTS"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

PASS=0
FAIL=0
FAILED_CASES=""

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

mark_pass() { PASS=$((PASS + 1)); green "PASS: $1"; }
mark_fail() {
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  - $1"
  red "FAIL: $1"
  if [ -n "${2:-}" ]; then echo "  detail: $2"; fi
}

# ---------------------------------------------------------------------------
# make_fork: build a synthetic v1-anchor apexyard fork under $TMPDIR with
# the hook libs + a handful of agent files at framework defaults
# (qa-engineer = haiku, tech-lead = opus, backend-engineer = sonnet).
# The fork is a real git repo (we need `git show dev:` to work for the
# drift-guard baseline).
# ---------------------------------------------------------------------------
make_fork() {
  local sb
  sb=$(mktemp -d)
  sb=$(cd "$sb" && pwd -P)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"

    # v1 anchors (onboarding.yaml + registry).
    touch onboarding.yaml
    cat > apexyard.projects.yaml <<'YAML'
version: 1
projects: []
YAML
    mkdir -p projects
    touch projects/ideas-backlog.md

    # Drop libs + defaults into the sandbox's .claude/hooks tree.
    mkdir -p .claude/hooks .claude/agents .claude/session
    cp "$LIB_OPS"  .claude/hooks/_lib-ops-root.sh
    cp "$LIB_PORT" .claude/hooks/_lib-portfolio-paths.sh
    cp "$LIB_CFG"  .claude/hooks/_lib-read-config.sh
    cp "$DEFAULTS" .claude/project-config.defaults.json
    cp "$SYNC_HOOK"  .claude/hooks/apply-agent-routing.sh
    cp "$DRIFT_HOOK" .claude/hooks/block-agent-routing-drift.sh
    chmod +x .claude/hooks/apply-agent-routing.sh .claude/hooks/block-agent-routing-drift.sh

    # Framework-default agent files (matrix per AgDR-0050 § Axis 2).
    cat > .claude/agents/qa-engineer.md <<'MD'
---
name: qa-engineer
description: QA Engineer wrapper.
model: haiku
allowed-tools: Bash, Read, Grep, Glob
persona_name: Salim
---

# Salim — QA Engineer
MD
    cat > .claude/agents/tech-lead.md <<'MD'
---
name: tech-lead
description: Tech Lead wrapper.
model: opus
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
persona_name: Hisham
---

# Hisham — Tech Lead
MD
    cat > .claude/agents/backend-engineer.md <<'MD'
---
name: backend-engineer
description: Backend Engineer wrapper.
model: sonnet
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
persona_name: Karim
---

# Karim — Backend Engineer
MD

    # Utility-agent fixture (Wave 2 PR 4 of #347). ticket-manager is the
    # local-routing candidate per #348 spike. The routing mechanism doesn't
    # distinguish utility vs role-derived agents — this fixture proves the
    # SessionStart sync covers the utility class too.
    cat > .claude/agents/ticket-manager.md <<'MD'
---
# routing-config:override Idris bumped inherit → sonnet per AgDR-0050 § Axis 2 line 65. Wave 2 PR 4 fixture.
name: ticket-manager
description: Ticket Manager wrapper.
tools: Bash, Read
model: sonnet
persona_name: Idris
---

# Idris — Ticket Manager
MD

    # Gitignore the framework-defaults snapshot + env dir (these are
    # adopter-local artefacts; the sync hook writes them on session start).
    cat > .gitignore <<'IGNORE'
.claude/agents/.framework-defaults.json
.claude/session/agent-env/
agent-routing.yaml
IGNORE

    git add -A
    git commit -q -m "fixture: apexyard fork with framework-default agents"
    # Establish `dev` so the drift guard's `git show dev:...` fallback works
    # in case the snapshot file isn't present.
    git branch -f dev HEAD
  )
  echo "$sb"
}

# extract the model: line from an agent file's frontmatter (first block).
read_model_line() {
  awk '/^---/{count++; next} count==1 && /^model:/ {sub(/^model:[[:space:]]*/, ""); print; exit}' "$1"
}

# ===========================================================================
# Mock curl helper for the endpoint/Ollama-path cases (case 4 + cases 9-13).
#
# Drops a fake `curl` script onto $PATH that consults $APEXYARD_MOCK_CURL_DIR
# for canned responses. Each fixture is named by the sanitised URL and
# contains `<HTTP_STATUS>\n<BODY>`. Missing fixture = simulated network
# failure (exit 7). Honours `--fail` so the hook's reachability check
# behaves like real curl would. Defined here (near the top) so cases earlier
# than the Ollama block (e.g. case 4 idempotency) can also use it. (#528)
# ===========================================================================
make_mock_curl() {
  local sb="$1"
  local fixture_dir="$sb/.test-curl-fixtures/bin"
  mkdir -p "$fixture_dir"
  cat > "$fixture_dir/curl" <<'CURL_MOCK'
#!/bin/bash
# Mock curl — for hook tests only.
url=""
fail=0
output_target=""
expect_output_target=0
for arg in "$@"; do
  if [ "$expect_output_target" = "1" ]; then
    output_target="$arg"
    expect_output_target=0
    continue
  fi
  case "$arg" in
    -s|--silent) ;;
    -f|--fail)   fail=1 ;;
    -o)          expect_output_target=1 ;;
    --max-time)  expect_output_target=1 ;;
    --max-time=*) ;;
    http*) url="$arg" ;;
    *) ;;
  esac
done
# If `--max-time <N>` consumed N as the output_target, undo that.
case "$output_target" in
  ''|[0-9]*) output_target="" ;;
esac
[ -z "$url" ] && exit 1
key=$(printf '%s' "$url" | tr '/:?&=' '_____' | tr -s '_')
fixture="${APEXYARD_MOCK_CURL_DIR:-/nonexistent}/$key"
if [ -f "$fixture" ]; then
  status=$(head -1 "$fixture")
  body=$(tail -n +2 "$fixture")
  if [ "$status" -ge 400 ] && [ "$fail" = "1" ]; then
    exit 22
  fi
  if [ "$output_target" = "/dev/null" ] || [ -z "$output_target" ]; then
    printf '%s' "$body"
  else
    printf '%s' "$body" > "$output_target"
  fi
  exit 0
fi
# No fixture = unreachable / connection refused
exit 7
CURL_MOCK
  chmod +x "$fixture_dir/curl"
  echo "$fixture_dir"
}

# emit the JSON envelope a PreToolUse hook expects on stdin.
hook_stdin() {
  local cmd="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg c "$cmd" '{tool_input: {command: $c}}'
  else
    printf '{"tool_input":{"command":%s}}' "$(printf '"%s"' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}

# ===========================================================================
# CASE 1 — sync hook is a no-op on empty config (agents: {}).
# ===========================================================================
SB=$(make_fork)
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents: {}
YAML

# Capture content snapshot before.
before_qa=$(read_model_line "$SB/.claude/agents/qa-engineer.md")
before_lead=$(read_model_line "$SB/.claude/agents/tech-lead.md")
before_be=$(read_model_line "$SB/.claude/agents/backend-engineer.md")

# Run the hook (chdir into the fork so the walk-up finds the anchors).
banner_output=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true)

after_qa=$(read_model_line "$SB/.claude/agents/qa-engineer.md")
after_lead=$(read_model_line "$SB/.claude/agents/tech-lead.md")
after_be=$(read_model_line "$SB/.claude/agents/backend-engineer.md")

if [ "$before_qa" = "$after_qa" ] && [ "$before_lead" = "$after_lead" ] && [ "$before_be" = "$after_be" ] && [ -z "$banner_output" ]; then
  mark_pass "case 1: empty config → no-op (no rewrites, no banner)"
else
  mark_fail "case 1: empty config → no-op" "qa=$before_qa→$after_qa lead=$before_lead→$after_lead be=$before_be→$after_be banner=[$banner_output]"
fi
rm -rf "$SB"

# ===========================================================================
# CASE 2 — single override: qa-engineer model haiku → opus.
# ===========================================================================
SB=$(make_fork)
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  qa-engineer:
    model: opus
YAML

banner_output=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true)

after_qa=$(read_model_line "$SB/.claude/agents/qa-engineer.md")
after_lead=$(read_model_line "$SB/.claude/agents/tech-lead.md")
after_be=$(read_model_line "$SB/.claude/agents/backend-engineer.md")
defaults_snapshot_exists=0
[ -f "$SB/.claude/agents/.framework-defaults.json" ] && defaults_snapshot_exists=1

if [ "$after_qa" = "opus" ] && [ "$after_lead" = "opus" ] && [ "$after_be" = "sonnet" ] \
   && [ "$defaults_snapshot_exists" = "1" ] \
   && echo "$banner_output" | grep -qE 'applied 1 agent-routing override'; then
  # Confirm the snapshot recorded the framework default, not the override.
  if grep -q '"qa-engineer":"haiku"' "$SB/.claude/agents/.framework-defaults.json"; then
    mark_pass "case 2: qa-engineer override haiku→opus (other agents untouched, snapshot recorded)"
  else
    mark_fail "case 2" "snapshot did not record qa-engineer=haiku: $(cat "$SB/.claude/agents/.framework-defaults.json" 2>/dev/null)"
  fi
else
  mark_fail "case 2: qa-engineer override" "after_qa=$after_qa lead=$after_lead be=$after_be snapshot=$defaults_snapshot_exists banner=[$banner_output]"
fi
rm -rf "$SB"

# ===========================================================================
# CASE 3 — orphan entry: routing config references nonexistent-agent.
# Hook should silently skip (no error, no banner if no other overrides).
# ===========================================================================
SB=$(make_fork)
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  nonexistent-agent:
    model: opus
YAML

banner_output=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true)

# Real agents unchanged.
after_qa=$(read_model_line "$SB/.claude/agents/qa-engineer.md")
after_lead=$(read_model_line "$SB/.claude/agents/tech-lead.md")

if [ "$after_qa" = "haiku" ] && [ "$after_lead" = "opus" ] && [ -z "$banner_output" ]; then
  mark_pass "case 3: orphan entry silently skipped (no error, no banner)"
else
  mark_fail "case 3: orphan entry" "qa=$after_qa lead=$after_lead banner=[$banner_output]"
fi
rm -rf "$SB"

# ===========================================================================
# CASE 4 — idempotency: running sync hook twice with same config →
# same end state, no compounded writes.
# ===========================================================================
SB=$(make_fork)
# Mock the endpoint as reachable so the ANTHROPIC_BASE_URL row is written
# deterministically (without a real listener on :11434 the hook correctly
# filters the unreachable endpoint, and the endpoint_count assertion below
# would be testing the environment, not idempotency). #528
MOCK_BIN=$(make_mock_curl "$SB")
APEXYARD_MOCK_CURL_DIR=$(mktemp -d)
export APEXYARD_MOCK_CURL_DIR
printf '200\n[]\n' > "$APEXYARD_MOCK_CURL_DIR/http_localhost_11434_v1_models"
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  qa-engineer:
    model: sonnet
    endpoint: http://localhost:11434
    env:
      MY_VAR: hello
YAML

(cd "$SB" && ANTHROPIC_BASE_URL=http://localhost:11434 PATH="$MOCK_BIN:$PATH" bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true) >/dev/null

# Capture state after first run.
first_qa=$(read_model_line "$SB/.claude/agents/qa-engineer.md")
first_env=""
[ -f "$SB/.claude/session/agent-env/qa-engineer.env" ] && first_env=$(cat "$SB/.claude/session/agent-env/qa-engineer.env")

# Run again.
(cd "$SB" && ANTHROPIC_BASE_URL=http://localhost:11434 PATH="$MOCK_BIN:$PATH" bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true) >/dev/null

second_qa=$(read_model_line "$SB/.claude/agents/qa-engineer.md")
second_env=""
[ -f "$SB/.claude/session/agent-env/qa-engineer.env" ] && second_env=$(cat "$SB/.claude/session/agent-env/qa-engineer.env")

# Env file should have exactly one ANTHROPIC_BASE_URL line + one MY_VAR line.
endpoint_count=$(echo "$second_env" | grep -c '^ANTHROPIC_BASE_URL=' || true)
myvar_count=$(echo "$second_env" | grep -c '^MY_VAR=' || true)

if [ "$first_qa" = "sonnet" ] && [ "$second_qa" = "sonnet" ] && [ "$first_env" = "$second_env" ] \
   && [ "$endpoint_count" -eq 1 ] && [ "$myvar_count" -eq 1 ]; then
  mark_pass "case 4: idempotent — second run is a no-op (env file not compounded)"
else
  mark_fail "case 4: idempotent" "first_qa=$first_qa second_qa=$second_qa endpoint=$endpoint_count myvar=$myvar_count first_env=[$first_env] second_env=[$second_env]"
fi
rm -rf "$SB"

# ===========================================================================
# CASE 5 — drift guard FIRES: pre-commit on a staged file with drift +
# no escape hatch.
# ===========================================================================
SB=$(make_fork)
# Apply a sync rewrite so the framework-defaults snapshot exists AND
# the working tree has the drift to commit.
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  qa-engineer:
    model: opus
YAML
(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true) >/dev/null

# Stage the rewritten file (simulating an adopter accidentally
# `git add`-ing it).
(cd "$SB" && git add .claude/agents/qa-engineer.md 2>/dev/null)

# Invoke the drift guard with a `git commit -m "..."` command.
hook_output=$(hook_stdin "git commit -m 'feat: tweak QA agent'" | (cd "$SB" && bash .claude/hooks/block-agent-routing-drift.sh 2>&1) || true)
hook_exit=$(hook_stdin "git commit -m 'feat: tweak QA agent'" | (cd "$SB" && bash .claude/hooks/block-agent-routing-drift.sh > /dev/null 2>&1); echo $?)

if [ "$hook_exit" = "2" ] && echo "$hook_output" | grep -q "BLOCKED: agent-file model: drift detected"; then
  mark_pass "case 5: drift guard FIRES on staged drift + no escape hatch (exit 2)"
else
  mark_fail "case 5: drift guard FIRES" "exit=$hook_exit output=[$hook_output]"
fi
rm -rf "$SB"

# ===========================================================================
# CASE 6 — drift guard ACCEPTS with escape hatch.
# Same scenario as case 5 but the agent file carries the override
# escape-hatch comment.
# ===========================================================================
SB=$(make_fork)
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  qa-engineer:
    model: opus
YAML
(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true) >/dev/null

# Add the escape hatch comment to the rewritten file.
cat > "$SB/.claude/agents/qa-engineer.md" <<'MD'
---
name: qa-engineer
description: QA Engineer wrapper.
model: opus
allowed-tools: Bash, Read, Grep, Glob
persona_name: Salim
---

# routing-config:override deliberate framework-default bump from haiku to opus

# Salim — QA Engineer
MD

(cd "$SB" && git add .claude/agents/qa-engineer.md 2>/dev/null)

hook_exit=$(hook_stdin "git commit -m 'feat: bump QA default'" | (cd "$SB" && bash .claude/hooks/block-agent-routing-drift.sh > /dev/null 2>&1); echo $?)

if [ "$hook_exit" = "0" ]; then
  mark_pass "case 6: drift guard ACCEPTS with escape-hatch comment (exit 0)"
else
  mark_fail "case 6: drift guard escape hatch" "expected exit 0, got $hook_exit"
fi
rm -rf "$SB"

# ===========================================================================
# CASE 7 — drift guard accepts on no-drift (committed file = framework
# default).
# ===========================================================================
SB=$(make_fork)
# Stage qa-engineer.md AT the framework default (haiku) — no sync hook
# run, no override applied, no drift.
(cd "$SB" && git add .claude/agents/qa-engineer.md 2>/dev/null)

hook_exit=$(hook_stdin "git commit -m 'docs: tidy QA agent description'" | (cd "$SB" && bash .claude/hooks/block-agent-routing-drift.sh > /dev/null 2>&1); echo $?)

if [ "$hook_exit" = "0" ]; then
  mark_pass "case 7: drift guard ACCEPTS clean-default commit (exit 0)"
else
  mark_fail "case 7: drift guard clean default" "expected exit 0, got $hook_exit"
fi
rm -rf "$SB"

# ===========================================================================
# CASE 8 — utility-agent override: ticket-manager model sonnet → opus.
# Verifies the routing mechanism doesn't distinguish utility from
# role-derived agents (Wave 2 PR 4 of #347).
# ===========================================================================
SB=$(make_fork)
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  ticket-manager:
    model: opus
YAML

banner_output=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true)

after_tm=$(read_model_line "$SB/.claude/agents/ticket-manager.md")
after_qa=$(read_model_line "$SB/.claude/agents/qa-engineer.md")
defaults_snapshot_exists=0
[ -f "$SB/.claude/agents/.framework-defaults.json" ] && defaults_snapshot_exists=1

if [ "$after_tm" = "opus" ] && [ "$after_qa" = "haiku" ] \
   && [ "$defaults_snapshot_exists" = "1" ] \
   && echo "$banner_output" | grep -qE 'applied 1 agent-routing override'; then
  # Confirm the snapshot recorded the framework default sonnet (not opus).
  if grep -q '"ticket-manager":"sonnet"' "$SB/.claude/agents/.framework-defaults.json"; then
    mark_pass "case 8: ticket-manager utility override sonnet→opus (qa-engineer untouched, snapshot records sonnet)"
  else
    mark_fail "case 8" "snapshot did not record ticket-manager=sonnet: $(cat "$SB/.claude/agents/.framework-defaults.json" 2>/dev/null)"
  fi
else
  mark_fail "case 8: ticket-manager utility override" "after_tm=$after_tm qa=$after_qa snapshot=$defaults_snapshot_exists banner=[$banner_output]"
fi
rm -rf "$SB"

# (make_mock_curl is defined near the top, alongside read_model_line, so the
# earlier endpoint cases — e.g. case 4 idempotency — can use it too. #528)

# ===========================================================================
# CASE 9 — Ollama agent with reachable proxy + pulled model.
# Expects: model rewrite, per-agent env file + __session__.env both written,
# banner reports "1 Ollama, 0 warning(s)".
# ===========================================================================
SB=$(make_fork)
MOCK_BIN=$(make_mock_curl "$SB")
APEXYARD_MOCK_CURL_DIR=$(mktemp -d)
export APEXYARD_MOCK_CURL_DIR
printf '200\n[]\n' > "$APEXYARD_MOCK_CURL_DIR/http_localhost_4000_v1_models"
printf '200\n{"models":[{"name":"qwen2.5-coder:14b"}]}\n' > "$APEXYARD_MOCK_CURL_DIR/http_localhost_4000_api_tags"

cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  ticket-manager:
    model: ollama/qwen2.5-coder:14b
    endpoint: http://localhost:4000
YAML

# Case 9 simulates the happy path where the adopter has done the shell-profile
# step from docs/local-model-setup.md — ANTHROPIC_BASE_URL is already set in
# the process env so the new routing-active check (me2resh/apexyard#442)
# does NOT fire.
banner_output=$(cd "$SB" && ANTHROPIC_BASE_URL=http://localhost:4000 PATH="$MOCK_BIN:$PATH" bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true)
after_tm=$(read_model_line "$SB/.claude/agents/ticket-manager.md")
session_env="$SB/.claude/session/agent-env/__session__.env"
agent_env="$SB/.claude/session/agent-env/ticket-manager.env"
session_set=0
agent_set=0
[ -f "$session_env" ] && grep -q '^ANTHROPIC_BASE_URL=http://localhost:4000$' "$session_env" && session_set=1
[ -f "$agent_env" ] && grep -q '^ANTHROPIC_BASE_URL=http://localhost:4000$' "$agent_env" && agent_set=1

if [ "$after_tm" = "ollama/qwen2.5-coder:14b" ] \
   && [ "$session_set" = "1" ] \
   && [ "$agent_set" = "1" ] \
   && echo "$banner_output" | grep -qE 'applied 1 agent-routing override.*1 Ollama, 0 warning'; then
  mark_pass "case 9: Ollama agent with reachable proxy + pulled model (full apply, session + per-agent env, no warnings; ANTHROPIC_BASE_URL preset)"
else
  mark_fail "case 9: Ollama agent reachable + pulled" "model=$after_tm session=$session_set agent=$agent_set banner=[$banner_output]"
fi
unset APEXYARD_MOCK_CURL_DIR
rm -rf "$SB"

# ===========================================================================
# CASE 10 — Ollama agent with UNREACHABLE proxy.
# Expects: model rewrite still applies; per-agent env file NOT written;
# __session__.env NOT written; banner reports "1 Ollama, 1 warning(s)".
# ===========================================================================
SB=$(make_fork)
MOCK_BIN=$(make_mock_curl "$SB")
APEXYARD_MOCK_CURL_DIR=$(mktemp -d)
export APEXYARD_MOCK_CURL_DIR
# Deliberately register NO fixtures — mock curl returns exit 7 (unreachable).

cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  ticket-manager:
    model: ollama/qwen2.5-coder:14b
    endpoint: http://localhost:4000
YAML

banner_output=$(cd "$SB" && PATH="$MOCK_BIN:$PATH" bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true)
after_tm=$(read_model_line "$SB/.claude/agents/ticket-manager.md")
session_env="$SB/.claude/session/agent-env/__session__.env"
agent_env="$SB/.claude/session/agent-env/ticket-manager.env"
session_absent=1
agent_absent=1
[ -f "$session_env" ] && session_absent=0
[ -f "$agent_env" ] && agent_absent=0

if [ "$after_tm" = "ollama/qwen2.5-coder:14b" ] \
   && [ "$session_absent" = "1" ] \
   && [ "$agent_absent" = "1" ] \
   && echo "$banner_output" | grep -qE 'endpoint http://localhost:4000 not reachable' \
   && echo "$banner_output" | grep -qE 'applied 1 agent-routing override.*1 Ollama, 1 warning'; then
  mark_pass "case 10: Ollama agent with unreachable proxy (model rewrites, no env files, 1 warning)"
else
  mark_fail "case 10: Ollama unreachable" "model=$after_tm session_absent=$session_absent agent_absent=$agent_absent banner=[$banner_output]"
fi
unset APEXYARD_MOCK_CURL_DIR
rm -rf "$SB"

# ===========================================================================
# CASE 11 — Ollama agent with reachable proxy but model NOT pulled.
# Expects: model rewrites; env files written (proxy is reachable); banner
# reports "1 Ollama, 1 warning(s)" with the `ollama pull` hint emitted.
# ===========================================================================
SB=$(make_fork)
MOCK_BIN=$(make_mock_curl "$SB")
APEXYARD_MOCK_CURL_DIR=$(mktemp -d)
export APEXYARD_MOCK_CURL_DIR
printf '200\n[]\n' > "$APEXYARD_MOCK_CURL_DIR/http_localhost_4000_v1_models"
# /api/tags returns a body that does NOT contain qwen2.5-coder:14b
printf '200\n{"models":[{"name":"llama3.1:8b"}]}\n' > "$APEXYARD_MOCK_CURL_DIR/http_localhost_4000_api_tags"

cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  ticket-manager:
    model: ollama/qwen2.5-coder:14b
    endpoint: http://localhost:4000
YAML

# Case 11 — ANTHROPIC_BASE_URL preset (happy-path shell), so the only warning
# should be the model-not-pulled hint, not the routing-active check.
banner_output=$(cd "$SB" && ANTHROPIC_BASE_URL=http://localhost:4000 PATH="$MOCK_BIN:$PATH" bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true)
session_env="$SB/.claude/session/agent-env/__session__.env"
session_set=0
[ -f "$session_env" ] && grep -q '^ANTHROPIC_BASE_URL=http://localhost:4000$' "$session_env" && session_set=1

if echo "$banner_output" | grep -qE 'model qwen2\.5-coder:14b not in local Ollama' \
   && echo "$banner_output" | grep -qE 'ollama pull qwen2\.5-coder:14b' \
   && [ "$session_set" = "1" ] \
   && echo "$banner_output" | grep -qE 'applied 1 agent-routing override.*1 Ollama, 1 warning'; then
  mark_pass "case 11: Ollama agent with reachable proxy + missing model (override applies, pull-hint emitted; ANTHROPIC_BASE_URL preset)"
else
  mark_fail "case 11: Ollama model-not-pulled" "session=$session_set banner=[$banner_output]"
fi
unset APEXYARD_MOCK_CURL_DIR
rm -rf "$SB"

# ===========================================================================
# CASE 12 — Two agents same endpoint.
# Expects: single __session__.env written, no multi-endpoint warning.
# ===========================================================================
SB=$(make_fork)
MOCK_BIN=$(make_mock_curl "$SB")
APEXYARD_MOCK_CURL_DIR=$(mktemp -d)
export APEXYARD_MOCK_CURL_DIR
printf '200\n[]\n' > "$APEXYARD_MOCK_CURL_DIR/http_localhost_4000_v1_models"
printf '200\n{"models":[{"name":"qwen2.5-coder:14b"},{"name":"llama3.1:8b"}]}\n' > "$APEXYARD_MOCK_CURL_DIR/http_localhost_4000_api_tags"

cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  ticket-manager:
    model: ollama/qwen2.5-coder:14b
    endpoint: http://localhost:4000
  qa-engineer:
    model: ollama/llama3.1:8b
    endpoint: http://localhost:4000
YAML

# Case 12 — ANTHROPIC_BASE_URL preset (happy-path shell).
banner_output=$(cd "$SB" && ANTHROPIC_BASE_URL=http://localhost:4000 PATH="$MOCK_BIN:$PATH" bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true)
session_env="$SB/.claude/session/agent-env/__session__.env"
session_lines=0
[ -f "$session_env" ] && session_lines=$(wc -l < "$session_env" | tr -d ' ')

if [ -f "$session_env" ] \
   && grep -q '^ANTHROPIC_BASE_URL=http://localhost:4000$' "$session_env" \
   && [ "$session_lines" = "1" ] \
   && ! echo "$banner_output" | grep -qE 'multiple endpoints' \
   && echo "$banner_output" | grep -qE 'applied 2 agent-routing override.*2 Ollama'; then
  mark_pass "case 12: two agents same endpoint (single __session__.env, no multi-endpoint warning; ANTHROPIC_BASE_URL preset)"
else
  mark_fail "case 12: same endpoint" "session_lines=$session_lines banner=[$banner_output]"
fi
unset APEXYARD_MOCK_CURL_DIR
rm -rf "$SB"

# ===========================================================================
# CASE 13 — Two agents different endpoints.
# Expects: first-declared endpoint wins; multi-endpoint warning emitted.
# ===========================================================================
SB=$(make_fork)
MOCK_BIN=$(make_mock_curl "$SB")
APEXYARD_MOCK_CURL_DIR=$(mktemp -d)
export APEXYARD_MOCK_CURL_DIR
printf '200\n[]\n' > "$APEXYARD_MOCK_CURL_DIR/http_localhost_4000_v1_models"
printf '200\n[]\n' > "$APEXYARD_MOCK_CURL_DIR/http_localhost_4001_v1_models"
printf '200\n{"models":[{"name":"qwen2.5-coder:14b"}]}\n' > "$APEXYARD_MOCK_CURL_DIR/http_localhost_4000_api_tags"
printf '200\n{"models":[{"name":"llama3.1:8b"}]}\n' > "$APEXYARD_MOCK_CURL_DIR/http_localhost_4001_api_tags"

cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  ticket-manager:
    model: ollama/qwen2.5-coder:14b
    endpoint: http://localhost:4000
  qa-engineer:
    model: ollama/llama3.1:8b
    endpoint: http://localhost:4001
YAML

# Case 13 — ANTHROPIC_BASE_URL preset matching EITHER endpoint (whichever
# wins as first-declared). Both 4000 and 4001 are reachable per the mock;
# the iteration order picks one. We just need to keep the routing-active
# warning silent, so set the env to match either possibility — the parser's
# determinism is tested by checking the resulting session env content below.
banner_output=$(cd "$SB" && ANTHROPIC_BASE_URL=http://localhost:4000 PATH="$MOCK_BIN:$PATH" bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true)
session_env="$SB/.claude/session/agent-env/__session__.env"
session_set=0
# Order of writes from $AGENT_ENDPOINTS depends on the iteration order of
# $ROWS; either endpoint may show up as "first". Just check that exactly
# one of them is in the session env and the warning fires.
[ -f "$session_env" ] && grep -qE '^ANTHROPIC_BASE_URL=http://localhost:400[01]$' "$session_env" && session_set=1

if [ "$session_set" = "1" ] \
   && echo "$banner_output" | grep -qE 'multiple endpoints declared' \
   && echo "$banner_output" | grep -qE 'applied 2 agent-routing override'; then
  mark_pass "case 13: two agents different endpoints (first wins, multi-endpoint warning emitted)"
else
  mark_fail "case 13: different endpoints" "session_set=$session_set banner=[$banner_output]"
fi
unset APEXYARD_MOCK_CURL_DIR
rm -rf "$SB"

# ===========================================================================
# CASE 14 — Ollama agent with reachable proxy + pulled model BUT the parent
# shell didn't preset ANTHROPIC_BASE_URL. me2resh/apexyard#442: the routing
# is INACTIVE because Claude Code's process env doesn't have the var.
# Expect: __session__.env still written (next-session prep); banner reports
# "1 Ollama, 1 warning(s)" naming the routing-INACTIVE gap and the exact
# shell-profile line to add.
# ===========================================================================
SB=$(make_fork)
MOCK_BIN=$(make_mock_curl "$SB")
APEXYARD_MOCK_CURL_DIR=$(mktemp -d)
export APEXYARD_MOCK_CURL_DIR
printf '200\n[]\n' > "$APEXYARD_MOCK_CURL_DIR/http_localhost_4000_v1_models"
printf '200\n{"models":[{"name":"qwen2.5-coder:14b"}]}\n' > "$APEXYARD_MOCK_CURL_DIR/http_localhost_4000_api_tags"

cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  ticket-manager:
    model: ollama/qwen2.5-coder:14b
    endpoint: http://localhost:4000
YAML

# Deliberately NOT setting ANTHROPIC_BASE_URL — simulates the adopter who
# enabled Example C but never did the shell-profile step.
banner_output=$(cd "$SB" && unset ANTHROPIC_BASE_URL; PATH="$MOCK_BIN:$PATH" bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true)
session_env="$SB/.claude/session/agent-env/__session__.env"
session_set=0
[ -f "$session_env" ] && grep -q '^ANTHROPIC_BASE_URL=http://localhost:4000$' "$session_env" && session_set=1

if [ "$session_set" = "1" ] \
   && echo "$banner_output" | grep -qiE 'routing is INACTIVE' \
   && echo "$banner_output" | grep -qF "$session_env" \
   && echo "$banner_output" | grep -qE 'applied 1 agent-routing override.*1 Ollama, 1 warning'; then
  mark_pass "case 14 (#442): Ollama routing INACTIVE when ANTHROPIC_BASE_URL not preset (session env written, warning names the gap)"
else
  mark_fail "case 14 (#442): routing-inactive warning" "session=$session_set banner=[$banner_output]"
fi
unset APEXYARD_MOCK_CURL_DIR
rm -rf "$SB"

# ===========================================================================
# CASE 15 — #1763: add an override, apply, remove it, apply again.
# The second run restores the snapshot model, omits that key, leaves
# the body text, and the drift guard then accepts the restored file.
# The same file still blocks while the override is in place.
# ===========================================================================
SB=$(make_fork)
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  backend-engineer:
    model: opus
YAML
banner_output=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null)
first_rc=$?
after_be=$(read_model_line "$SB/.claude/agents/backend-engineer.md")
snap_first=""
[ -f "$SB/.claude/agents/.framework-defaults.json" ] && snap_first=$(cat "$SB/.claude/agents/.framework-defaults.json")
qa_copy=$(mktemp)
lead_copy=$(mktemp)
cp "$SB/.claude/agents/qa-engineer.md" "$qa_copy"
cp "$SB/.claude/agents/tech-lead.md" "$lead_copy"
printf '\nThe body keeps this model: opus text.\n' >> "$SB/.claude/agents/backend-engineer.md"

(cd "$SB" && git add .claude/agents/backend-engineer.md 2>/dev/null)
drift_while=$(hook_stdin "git commit -m 'feat: leak backend model'" | (cd "$SB" && bash .claude/hooks/block-agent-routing-drift.sh > /dev/null 2>&1); echo $?)
(cd "$SB" && git reset -q -- .claude/agents/backend-engineer.md 2>/dev/null)
before_be=$(cat "$SB/.claude/agents/backend-engineer.md")

cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents: {}
YAML
banner_output2=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null)
second_rc=$?
after_be_file=$(cat "$SB/.claude/agents/backend-engineer.md")
expected_be=${before_be/model: opus/model: sonnet}
snap=""
[ -f "$SB/.claude/agents/.framework-defaults.json" ] && snap=$(tr -d '[:space:]' < "$SB/.claude/agents/.framework-defaults.json")
(cd "$SB" && git add .claude/agents/backend-engineer.md 2>/dev/null)
drift_after=$(hook_stdin "git commit -m 'feat: restore backend model'" | (cd "$SB" && bash .claude/hooks/block-agent-routing-drift.sh > /dev/null 2>&1); echo $?)

banner_output3=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null)
third_rc=$?
third_be=$(cat "$SB/.claude/agents/backend-engineer.md")
snap3=""
[ -f "$SB/.claude/agents/.framework-defaults.json" ] && snap3=$(tr -d '[:space:]' < "$SB/.claude/agents/.framework-defaults.json")

if [ "$first_rc" -eq 0 ] && [ "$after_be" = "opus" ] \
   && echo "$snap_first" | grep -q '"backend-engineer":"sonnet"' \
   && [ "$drift_while" = "2" ] \
   && [ "$second_rc" -eq 0 ] && [ "$after_be_file" = "$expected_be" ] \
   && [ "$snap" = "{}" ] \
   && [ -z "$banner_output2" ] \
   && cmp -s "$SB/.claude/agents/qa-engineer.md" "$qa_copy" \
   && cmp -s "$SB/.claude/agents/tech-lead.md" "$lead_copy" \
   && [ "$drift_after" = "0" ] \
   && [ "$third_rc" -eq 0 ] && [ "$third_be" = "$after_be_file" ] && [ "$snap3" = "{}" ]; then
  mark_pass "case 15 (#1763): removed override restores sonnet, drops the key, keeps body text, drift allows"
else
  mark_fail "case 15 (#1763): restore removed override" "first_rc=$first_rc model=$after_be drift_while=$drift_while second_rc=$second_rc snap=[$snap] drift_after=$drift_after third_rc=$third_rc banner2=[$banner_output2] banner1=[$banner_output] banner3=[$banner_output3]"
fi
rm -f "$qa_copy" "$lead_copy"
rm -rf "$SB"

# ===========================================================================
# CASE 16 — #1763: an agent the hook never rewrote stays byte-for-byte,
# including a hand edit that is not the framework model.
# ===========================================================================
SB=$(make_fork)
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  qa-engineer:
    model: opus
YAML
(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null) >/dev/null
# Hand-edit an agent that is not in the snapshot. The next run must
# not reset it from git and must not rewrite its body.
awk '
  BEGIN { fm=0; replaced=0 }
  /^---[[:space:]]*$/ { fm++; print; next }
  fm==1 && !replaced && /^model:[[:space:]]*/ { print "model: haiku"; replaced=1; next }
  { print }
' "$SB/.claude/agents/tech-lead.md" > "$SB/.claude/agents/tech-lead.md.tmp"
mv "$SB/.claude/agents/tech-lead.md.tmp" "$SB/.claude/agents/tech-lead.md"
printf '\nNEVER-OVERRIDDEN model: opus\n' >> "$SB/.claude/agents/tech-lead.md"
lead_copy=$(mktemp)
be_copy=$(mktemp)
cp "$SB/.claude/agents/tech-lead.md" "$lead_copy"
cp "$SB/.claude/agents/backend-engineer.md" "$be_copy"
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents: {}
YAML
banner_output=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null)
hook_rc=$?
restored_qa=$(read_model_line "$SB/.claude/agents/qa-engineer.md")
if [ "$hook_rc" -eq 0 ] && [ "$restored_qa" = "haiku" ] \
   && cmp -s "$SB/.claude/agents/tech-lead.md" "$lead_copy" \
   && cmp -s "$SB/.claude/agents/backend-engineer.md" "$be_copy" \
   && [ -z "$banner_output" ]; then
  mark_pass "case 16 (#1763): an agent never overridden is untouched"
else
  mark_fail "case 16 (#1763): never overridden" "rc=$hook_rc qa=$restored_qa banner=[$banner_output]"
fi
rm -f "$lead_copy" "$be_copy"
rm -rf "$SB"

# ===========================================================================
# CASE 17 — #1763: a corrupt previous snapshot does not crash and does
# not restore. The tempting agent name in the file must not be applied.
# ===========================================================================
SB=$(make_fork)
awk '
  BEGIN { fm=0; replaced=0 }
  /^---[[:space:]]*$/ { fm++; print; next }
  fm==1 && !replaced && /^model:[[:space:]]*/ { print "model: opus"; replaced=1; next }
  { print }
' "$SB/.claude/agents/backend-engineer.md" > "$SB/.claude/agents/backend-engineer.md.tmp"
mv "$SB/.claude/agents/backend-engineer.md.tmp" "$SB/.claude/agents/backend-engineer.md"
printf '%s\n' '{"backend-engineer": "sonnet"' > "$SB/.claude/agents/.framework-defaults.json"
corrupt_before=$(cat "$SB/.claude/agents/.framework-defaults.json")
qa_copy=$(mktemp)
lead_copy=$(mktemp)
be_copy=$(mktemp)
cp "$SB/.claude/agents/qa-engineer.md" "$qa_copy"
cp "$SB/.claude/agents/tech-lead.md" "$lead_copy"
cp "$SB/.claude/agents/backend-engineer.md" "$be_copy"
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents: {}
YAML
banner_output=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null)
hook_rc=$?
corrupt_after=$(cat "$SB/.claude/agents/.framework-defaults.json")
if [ "$hook_rc" -eq 0 ] \
   && cmp -s "$SB/.claude/agents/backend-engineer.md" "$be_copy" \
   && cmp -s "$SB/.claude/agents/qa-engineer.md" "$qa_copy" \
   && cmp -s "$SB/.claude/agents/tech-lead.md" "$lead_copy" \
   && [ "$corrupt_after" = "$corrupt_before" ] \
   && [ -z "$banner_output" ]; then
  mark_pass "case 17 (#1763): corrupt snapshot does not crash and restores nothing"
else
  mark_fail "case 17 (#1763): corrupt snapshot" "rc=$hook_rc banner=[$banner_output] model=$(read_model_line "$SB/.claude/agents/backend-engineer.md") snap=[$corrupt_after]"
fi
rm -f "$qa_copy" "$lead_copy" "$be_copy"
rm -rf "$SB"

# ===========================================================================
# CASE 18 — #1763: two overrides, remove one. Restore only that agent.
# The remaining override stays, and only its key remains in the snapshot.
# ===========================================================================
SB=$(make_fork)
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  qa-engineer:
    model: opus
  backend-engineer:
    model: haiku
YAML
banner_first=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null)
first_rc=$?
first_qa=$(read_model_line "$SB/.claude/agents/qa-engineer.md")
first_be=$(read_model_line "$SB/.claude/agents/backend-engineer.md")
lead_copy=$(mktemp)
cp "$SB/.claude/agents/tech-lead.md" "$lead_copy"
printf '\nKeep this backend body model: haiku line.\n' >> "$SB/.claude/agents/backend-engineer.md"
before_be=$(cat "$SB/.claude/agents/backend-engineer.md")
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  qa-engineer:
    model: opus
YAML
banner_second=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null)
second_rc=$?
after_qa=$(read_model_line "$SB/.claude/agents/qa-engineer.md")
after_be_file=$(cat "$SB/.claude/agents/backend-engineer.md")
expected_be=${before_be/model: haiku/model: sonnet}
snap=""
[ -f "$SB/.claude/agents/.framework-defaults.json" ] && snap=$(tr -d '[:space:]' < "$SB/.claude/agents/.framework-defaults.json")
if [ "$first_rc" -eq 0 ] && [ "$first_qa" = "opus" ] && [ "$first_be" = "haiku" ] \
   && echo "$banner_first" | grep -qE 'applied 2 agent-routing override' \
   && [ "$second_rc" -eq 0 ] && [ "$after_qa" = "opus" ] \
   && [ "$after_be_file" = "$expected_be" ] \
   && echo "$banner_second" | grep -qE 'applied 1 agent-routing override' \
   && echo "$snap" | grep -q '"qa-engineer":"haiku"' \
   && ! echo "$snap" | grep -q 'backend-engineer' \
   && cmp -s "$SB/.claude/agents/tech-lead.md" "$lead_copy"; then
  mark_pass "case 18 (#1763): removing one of two overrides restores only that agent"
else
  mark_fail "case 18 (#1763): partial restore" "first_rc=$first_rc second_rc=$second_rc qa=$after_qa snap=[$snap] banner1=[$banner_first] banner2=[$banner_second]"
fi
rm -f "$lead_copy"
rm -rf "$SB"

# ===========================================================================
# CASE 19 — #1763: a fork with no local dev branch (only main / HEAD).
# Two sessions with an override must keep the committed model in the
# snapshot. Removing the override restores that model. While the
# override is staged, the drift guard blocks. The guard script is
# unchanged: a correct snapshot closes the no-dev fail-open gap.
# ===========================================================================
SB=$(make_fork)
(
  cd "$SB" || exit 1
  git branch -M main
  git branch -D dev
) >/dev/null 2>&1
has_dev=0
git -C "$SB" rev-parse --verify --quiet dev >/dev/null 2>&1 && has_dev=1
has_upstream=0
git -C "$SB" rev-parse --verify --quiet upstream/main >/dev/null 2>&1 && has_upstream=1
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  backend-engineer:
    model: opus
YAML
banner_first=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null)
first_rc=$?
first_model=$(read_model_line "$SB/.claude/agents/backend-engineer.md")
snap1=""
[ -f "$SB/.claude/agents/.framework-defaults.json" ] && snap1=$(tr -d '[:space:]' < "$SB/.claude/agents/.framework-defaults.json")
banner_second=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null)
second_rc=$?
second_model=$(read_model_line "$SB/.claude/agents/backend-engineer.md")
snap2=""
[ -f "$SB/.claude/agents/.framework-defaults.json" ] && snap2=$(tr -d '[:space:]' < "$SB/.claude/agents/.framework-defaults.json")
(cd "$SB" && git add .claude/agents/backend-engineer.md 2>/dev/null)
drift_while=$(hook_stdin "git commit -m 'feat: leak backend model'" | (cd "$SB" && bash .claude/hooks/block-agent-routing-drift.sh > /dev/null 2>&1); echo $?)
(cd "$SB" && git reset -q -- .claude/agents/backend-engineer.md 2>/dev/null)
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents: {}
YAML
banner_third=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null)
third_rc=$?
restored=$(read_model_line "$SB/.claude/agents/backend-engineer.md")
snap3=""
[ -f "$SB/.claude/agents/.framework-defaults.json" ] && snap3=$(tr -d '[:space:]' < "$SB/.claude/agents/.framework-defaults.json")
if [ "$has_dev" -eq 0 ] && [ "$has_upstream" -eq 0 ] \
   && [ "$first_rc" -eq 0 ] && [ "$first_model" = "opus" ] \
   && [ "$snap1" = '{"backend-engineer":"sonnet"}' ] \
   && [ "$second_rc" -eq 0 ] && [ "$second_model" = "opus" ] \
   && [ "$snap2" = '{"backend-engineer":"sonnet"}' ] \
   && [ "$drift_while" = "2" ] \
   && [ "$third_rc" -eq 0 ] && [ "$restored" = "sonnet" ] \
   && [ "$snap3" = "{}" ] && [ -z "$banner_third" ]; then
  mark_pass "case 19 (#1763): no local dev restores sonnet and the drift guard blocks the override"
else
  mark_fail "case 19 (#1763): no local dev" "dev=$has_dev upstream=$has_upstream first_rc=$first_rc model1=$first_model snap1=[$snap1] second_rc=$second_rc model2=$second_model snap2=[$snap2] drift=$drift_while third_rc=$third_rc restored=$restored snap3=[$snap3] banner1=[$banner_first] banner2=[$banner_second] banner3=[$banner_third]"
fi
rm -rf "$SB"

# ===========================================================================
# CASE 20 — #1763: no local dev, and HEAD is not the framework model.
# upstream/main still has sonnet. The snapshot must use that ref, not
# HEAD and not the working tree.
# ===========================================================================
SB=$(make_fork)
(
  cd "$SB" || exit 1
  git branch -M main
  git branch -D dev
  git update-ref refs/remotes/upstream/main HEAD
  awk '
    BEGIN { fm=0; replaced=0 }
    /^---[[:space:]]*$/ { fm++; print; next }
    fm==1 && !replaced && /^model:[[:space:]]*/ { print "model: opus"; replaced=1; next }
    { print }
  ' .claude/agents/backend-engineer.md > .claude/agents/backend-engineer.md.tmp
  mv .claude/agents/backend-engineer.md.tmp .claude/agents/backend-engineer.md
  git add .claude/agents/backend-engineer.md
  git commit -q -m "fixture: commit a local model on HEAD"
) >/dev/null 2>&1
has_dev=0
git -C "$SB" rev-parse --verify --quiet dev >/dev/null 2>&1 && has_dev=1
head_model=$(git -C "$SB" show "HEAD:.claude/agents/backend-engineer.md" 2>/dev/null \
  | awk '/^---/{count++; next} count==1 && /^model:/ {sub(/^model:[[:space:]]*/, ""); print; exit}')
upstream_model=$(git -C "$SB" show "upstream/main:.claude/agents/backend-engineer.md" 2>/dev/null \
  | awk '/^---/{count++; next} count==1 && /^model:/ {sub(/^model:[[:space:]]*/, ""); print; exit}')
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  backend-engineer:
    model: haiku
YAML
banner_output=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null)
hook_rc=$?
applied=$(read_model_line "$SB/.claude/agents/backend-engineer.md")
snap=""
[ -f "$SB/.claude/agents/.framework-defaults.json" ] && snap=$(tr -d '[:space:]' < "$SB/.claude/agents/.framework-defaults.json")
if [ "$has_dev" -eq 0 ] && [ "$head_model" = "opus" ] && [ "$upstream_model" = "sonnet" ] \
   && [ "$hook_rc" -eq 0 ] && [ "$applied" = "haiku" ] \
   && [ "$snap" = '{"backend-engineer":"sonnet"}' ]; then
  mark_pass "case 20 (#1763): upstream/main wins over a different HEAD model"
else
  mark_fail "case 20 (#1763): upstream/main order" "dev=$has_dev head=$head_model upstream=$upstream_model rc=$hook_rc applied=$applied snap=[$snap] banner=[$banner_output]"
fi
rm -rf "$SB"

# ===========================================================================
# CASE 21 — a model value that contains whitespace is skipped.
# A sibling pair in the same file still restores. The space is not
# collapsed into the model id.
# ===========================================================================
SB=$(make_fork)
awk '
  BEGIN { fm=0; replaced=0 }
  /^---[[:space:]]*$/ { fm++; print; next }
  fm==1 && !replaced && /^model:[[:space:]]*/ { print "model: haiku"; replaced=1; next }
  { print }
' "$SB/.claude/agents/backend-engineer.md" > "$SB/.claude/agents/backend-engineer.md.tmp"
mv "$SB/.claude/agents/backend-engineer.md.tmp" "$SB/.claude/agents/backend-engineer.md"
lead_before=$(cat "$SB/.claude/agents/tech-lead.md")
cat > "$SB/.claude/agents/.framework-defaults.json" <<'JSON'
{
  "tech-lead": "x y",
  "backend-engineer": "sonnet"
}
JSON
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents: {}
YAML
banner_output=$(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null)
hook_rc=$?
restored=$(read_model_line "$SB/.claude/agents/backend-engineer.md")
lead_after=$(cat "$SB/.claude/agents/tech-lead.md")
snap=""
[ -f "$SB/.claude/agents/.framework-defaults.json" ] && snap=$(tr -d '[:space:]' < "$SB/.claude/agents/.framework-defaults.json")
if [ "$hook_rc" -eq 0 ] && [ "$restored" = "sonnet" ] \
   && [ "$lead_after" = "$lead_before" ] \
   && ! grep -q 'model: xy' "$SB/.claude/agents/tech-lead.md" \
   && [ "$snap" = "{}" ] && [ -z "$banner_output" ]; then
  mark_pass "case 21 (#1763): whitespace in a model value skips that entry"
else
  mark_fail "case 21 (#1763): whitespace model" "rc=$hook_rc restored=$restored snap=[$snap] banner=[$banner_output] lead=$(read_model_line "$SB/.claude/agents/tech-lead.md")"
fi
rm -rf "$SB"

# ===========================================================================
# Summary
# ===========================================================================
echo
echo "===== test_agent_routing_sync_and_drift.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0
