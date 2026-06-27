#!/usr/bin/env bash
# Smoke tests for bin/sync-codex-adapter.sh.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$ROOT/bin/sync-codex-adapter.sh"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

PASS=0
FAIL=0
FAILED=""

mark_pass() { green "  ok   $1"; PASS=$((PASS+1)); }
mark_fail() {
  red "  FAIL $1: $2" >&2
  FAIL=$((FAIL+1))
  FAILED="$FAILED $1"
}

assert_file() {
  local path="$1" label="$2"
  [ -f "$path" ] && mark_pass "$label" || mark_fail "$label" "missing $path"
}

assert_contains() {
  local path="$1" pattern="$2" label="$3"
  grep -F "$pattern" "$path" >/dev/null 2>&1 && mark_pass "$label" || mark_fail "$label" "missing pattern [$pattern] in $path"
}

assert_not_contains() {
  local path="$1" pattern="$2" label="$3"
  if grep -F "$pattern" "$path" >/dev/null 2>&1; then
    mark_fail "$label" "unexpected pattern [$pattern] in $path"
  else
    mark_pass "$label"
  fi
}

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/codex-adapter-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

mkdir -p "$TMPROOT/.claude/skills/status" "$TMPROOT/.claude/hooks" "$TMPROOT/.claude/agents" "$TMPROOT/.claude/registries"

cat > "$TMPROOT/.claude/skills/status/SKILL.md" <<'MD'
---
name: status
description: Current status.
---

Source `.claude/hooks/_lib-portfolio-paths.sh` and read `.claude/skills/status/briefing.sh`.
MD

cat > "$TMPROOT/.claude/hooks/detect-role-trigger.sh" <<'SH'
#!/usr/bin/env bash
echo "from .claude/hooks"
SH

cat > "$TMPROOT/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash -c 'r=\"\";if [ -n \"${CLAUDE_CODE_SESSION_ID:-}\" ];then p=\"${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID}\";[ -f \"$p\" ] && IFS= read -r r < \"$p\" && [ -d \"$r/.claude/hooks\" ] || r=\"\";fi;if [ -z \"$r\" ];then r=$PWD;while [ -n \"$r\" ] && [ \"$r\" != / ];do { [ -f \"$r/.apexyard-fork\" ] || [ -f \"$r/onboarding.yaml\" ]; } && [ -d \"$r/.claude/hooks\" ] && break;r=${r%/*};done;fi;[ -d \"$r/.claude/hooks\" ] || exit 0;exec \"$r/.claude/hooks/detect-role-trigger.sh\"'"
          }
        ]
      }
    ]
  }
}
JSON

cat > "$TMPROOT/.claude/agents/backend-engineer.md" <<'MD'
---
name: backend-engineer
description: Implements backend work.
model: sonnet
allowed-tools: Bash, Read
---

# Backend Engineer

Read `.claude/rules/workflow-gates.md` before acting in Claude Code.
MD

cat > "$TMPROOT/.claude/registries/ai-crawlers.json" <<'JSON'
[]
JSON

echo "== Codex adapter sync smoke"

if bash "$SCRIPT" --root "$TMPROOT" >/tmp/_codex_adapter_sync.out 2>&1; then
  mark_pass "generator writes adapter output"
else
  mark_fail "generator writes adapter output" "$(cat /tmp/_codex_adapter_sync.out)"
fi

assert_file "$TMPROOT/.agents/skills/status/SKILL.md" "skill mirror exists"
assert_file "$TMPROOT/.codex/hooks/detect-role-trigger.sh" "hook mirror exists"
assert_file "$TMPROOT/.codex/hooks.json" "hooks.json mirror exists"
assert_file "$TMPROOT/.codex/agents/backend-engineer.toml" "agent TOML exists"
assert_file "$TMPROOT/.codex/registries/ai-crawlers.json" "registry mirror exists"

assert_contains "$TMPROOT/.agents/skills/status/SKILL.md" ".codex/hooks/_lib-portfolio-paths.sh" "skill rewrites hook paths"
assert_contains "$TMPROOT/.agents/skills/status/SKILL.md" ".agents/skills/status/briefing.sh" "skill rewrites skill paths"
assert_contains "$TMPROOT/.codex/hooks.json" '$r/.codex/hooks/detect-role-trigger.sh' "hooks.json rewrites hook exec path"
assert_contains "$TMPROOT/.codex/hooks.json" '$HOME/.codex/apexyard' "hooks.json rewrites pin cache path"
assert_not_contains "$TMPROOT/.codex/hooks.json" "$TMPROOT" "hooks.json has no absolute fixture path"
assert_not_contains "$TMPROOT/.codex/hooks.json" ".claude" "hooks.json has no .claude paths"
assert_contains "$TMPROOT/.codex/agents/backend-engineer.toml" 'name = "backend-engineer"' "agent TOML includes name"
assert_contains "$TMPROOT/.codex/agents/backend-engineer.toml" 'model = "gpt-5.4"' "agent TOML maps Claude model to Codex model"
assert_contains "$TMPROOT/.codex/agents/backend-engineer.toml" ".codex/rules/workflow-gates.md" "agent instructions rewrite rule paths"
assert_not_contains "$TMPROOT/.codex/agents/backend-engineer.toml" "---" "agent TOML excludes YAML frontmatter"

if bash "$SCRIPT" --root "$TMPROOT" --check >/tmp/_codex_adapter_check.out 2>&1; then
  mark_pass "--check passes when generated output is current"
else
  mark_fail "--check passes when generated output is current" "$(cat /tmp/_codex_adapter_check.out)"
fi

printf '\nNew source line.\n' >> "$TMPROOT/.claude/skills/status/SKILL.md"
if bash "$SCRIPT" --root "$TMPROOT" --check >/tmp/_codex_adapter_check_drift.out 2>&1; then
  mark_fail "--check detects drift" "expected non-zero exit"
else
  mark_pass "--check detects drift"
fi

echo
echo "===== test_sync_codex_adapter.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED"
  exit 1
fi
exit 0
