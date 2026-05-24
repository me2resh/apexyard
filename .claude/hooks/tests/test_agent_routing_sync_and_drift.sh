#!/bin/bash
# Smoke test for apply-agent-routing.sh (SessionStart sync hook) and
# block-agent-routing-drift.sh (pre-commit + pre-push drift guard) —
# the two hooks #351 PR 2 ships per AgDR-0050 § Axis 4.
#
# Coverage (7 cases):
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
#
# Pattern follows test_portfolio_paths.sh + test_split_portfolio_v2_migration.sh:
#   - SRC_ROOT resolved from the test file's location
#   - Each case builds an isolated sandbox apexyard fork under $TMPDIR
#   - Sources libs from the sandbox (NOT from SRC_ROOT) so resolution
#     matches the in-fork shape the hook sees at runtime
#
# Exit 0 means all cases passed. Exit 1 on first failure.

set -u

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
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  qa-engineer:
    model: sonnet
    endpoint: http://localhost:11434
    env:
      MY_VAR: hello
YAML

(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true) >/dev/null

# Capture state after first run.
first_qa=$(read_model_line "$SB/.claude/agents/qa-engineer.md")
first_env=""
[ -f "$SB/.claude/session/agent-env/qa-engineer.env" ] && first_env=$(cat "$SB/.claude/session/agent-env/qa-engineer.env")

# Run again.
(cd "$SB" && bash .claude/hooks/apply-agent-routing.sh 2>&1 < /dev/null || true) >/dev/null

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
