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

assert_no_dir() {
  local path="$1" label="$2"
  [ ! -d "$path" ] && mark_pass "$label" || mark_fail "$label" "unexpected directory $path"
}

assert_no_file() {
  local path="$1" label="$2"
  [ ! -f "$path" ] && mark_pass "$label" || mark_fail "$label" "unexpected file $path"
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

mkdir -p "$TMPROOT/.claude/skills/status" "$TMPROOT/.claude/hooks" "$TMPROOT/.claude/agents"
touch "$TMPROOT/.apexyard-fork"

cat > "$TMPROOT/.claude/skills/status/SKILL.md" <<'MD'
---
name: status
description: Current status.
---

Source `.claude/hooks/_lib-portfolio-paths.sh` and read `.claude/skills/status/briefing.sh`.
MD

cat > "$TMPROOT/.claude/hooks/block-test.sh" <<'SH'
#!/usr/bin/env bash
input=$(cat)
case "$input" in
  *deny*) exit 2 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMPROOT/.claude/hooks/block-test.sh"

cat > "$TMPROOT/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "if": "Bash(policy *)",
            "command": "bash -c 'r=\"\";if [ -n \"${CLAUDE_CODE_SESSION_ID:-}\" ];then p=\"${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID}\";[ -f \"$p\" ] && IFS= read -r r < \"$p\" && [ -d \"$r/.claude/hooks\" ] || r=\"\";fi;if [ -z \"$r\" ];then r=$PWD;while [ -n \"$r\" ] && [ \"$r\" != / ];do { [ -f \"$r/.apexyard-fork\" ] || [ -f \"$r/onboarding.yaml\" ]; } && [ -d \"$r/.claude/hooks\" ] && break;r=${r%/*};done;fi;[ -d \"$r/.claude/hooks\" ] || exit 0;exec \"$r/.claude/hooks/block-test.sh\"'"
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

# Shared model matrix the generator reads to translate tier labels -> Codex
# models (source of truth for every harness adapter). Its presence is what
# makes the `model = "gpt-5.4"` assertion below config-driven rather than
# hardcoded — omit it and the mapping correctly falls back to the label.
cat > "$TMPROOT/.claude/harness-models.json" <<'JSON'
{
  "opus":   { "codex": "gpt-5.5" },
  "sonnet": { "codex": "gpt-5.4" },
  "haiku":  { "codex": "gpt-5.4-mini" }
}
JSON

echo "== Codex adapter sync smoke"

if bash "$SCRIPT" --root "$TMPROOT" >/tmp/_codex_adapter_sync.out 2>&1; then
  mark_pass "generator writes adapter output"
else
  mark_fail "generator writes adapter output" "$(cat /tmp/_codex_adapter_sync.out)"
fi

assert_file "$TMPROOT/.agents/skills/status/SKILL.md" "skill mirror exists"
assert_file "$TMPROOT/.codex/hooks.json" "hooks.json mirror exists"
assert_file "$TMPROOT/.codex/agents/backend-engineer.toml" "agent TOML exists"
assert_file "$TMPROOT/.codex/apexyard-adapter.json" "adapter ownership manifest exists"
assert_no_dir "$TMPROOT/.codex/hooks" "adapter does not copy hook scripts"

assert_contains "$TMPROOT/.agents/skills/status/SKILL.md" ".agents/skills/status/briefing.sh" "skill rewrites skill paths"
assert_contains "$TMPROOT/.agents/skills/status/SKILL.md" ".claude/hooks/_lib-portfolio-paths.sh" "skill preserves canonical hook paths"
assert_contains "$TMPROOT/.codex/hooks.json" '$r/.claude/hooks/block-test.sh' "hooks.json delegates to canonical hook path"
assert_contains "$TMPROOT/.codex/hooks.json" '$HOME/.claude/apexyard' "hooks.json preserves Claude session pin path"
assert_contains "$TMPROOT/.codex/hooks.json" 'APEXYARD_CODEX_HOOK_GLOB=' "hooks.json wraps command predicates"
assert_not_contains "$TMPROOT/.codex/hooks.json" "$TMPROOT" "hooks.json has no absolute fixture path"
assert_not_contains "$TMPROOT/.codex/hooks.json" '$r/.codex/hooks' "hooks.json does not point at copied hooks"
assert_contains "$TMPROOT/.codex/agents/backend-engineer.toml" 'name = "backend-engineer"' "agent TOML includes name"
assert_contains "$TMPROOT/.codex/agents/backend-engineer.toml" 'model = "gpt-5.4"' "agent TOML maps Claude model to Codex model"
assert_contains "$TMPROOT/.codex/agents/backend-engineer.toml" ".claude/rules/workflow-gates.md" "agent instructions preserve rule paths"
assert_not_contains "$TMPROOT/.codex/agents/backend-engineer.toml" "---" "agent TOML excludes YAML frontmatter"

if jq -e '
  .adapter == "apexyard-codex"
  and .schema == 1
  and .generated_from == ".claude"
' "$TMPROOT/.codex/apexyard-adapter.json" >/dev/null; then
  mark_pass "adapter ownership manifest has the expected schema"
else
  mark_fail "adapter ownership manifest has the expected schema" "$(cat "$TMPROOT/.codex/apexyard-adapter.json")"
fi

if jq -e '.. | objects | select(has("if"))' "$TMPROOT/.codex/hooks.json" >/dev/null; then
  mark_fail "hooks.json omits unsupported if fields" "found handler-level if metadata"
else
  mark_pass "hooks.json omits unsupported if fields"
fi

hook_command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$TMPROOT/.codex/hooks.json")
printf '{"tool_name":"Bash","tool_input":{"command":"policy deny"}}\n' | (cd "$TMPROOT" && bash -c "$hook_command") >/tmp/_codex_adapter_block.out 2>&1
block_rc=$?
if [ "$block_rc" -eq 2 ]; then
  mark_pass "generated hook command preserves blocking exit"
else
  mark_fail "generated hook command preserves blocking exit" "expected exit 2, got $block_rc: $(cat /tmp/_codex_adapter_block.out)"
fi

printf '{"tool_name":"Bash","tool_input":{"command":"policy allow"}}\n' | (cd "$TMPROOT" && bash -c "$hook_command") >/tmp/_codex_adapter_allow.out 2>&1
allow_rc=$?
if [ "$allow_rc" -eq 0 ]; then
  mark_pass "generated hook command preserves allowing exit"
else
  mark_fail "generated hook command preserves allowing exit" "expected exit 0, got $allow_rc: $(cat /tmp/_codex_adapter_allow.out)"
fi

printf '{"tool_name":"Bash","tool_input":{"command":"other deny"}}\n' | (cd "$TMPROOT" && bash -c "$hook_command") >/tmp/_codex_adapter_skip.out 2>&1
skip_rc=$?
if [ "$skip_rc" -eq 0 ]; then
  mark_pass "generated hook command skips nonmatching predicates"
else
  mark_fail "generated hook command skips nonmatching predicates" "expected exit 0, got $skip_rc: $(cat /tmp/_codex_adapter_skip.out)"
fi

# --- fail-loud hook-count guard (#840 B1) -------------------------------
# generate_hooks_json's jq filter is matcher-agnostic today (it walks every
# event/matcher group generically, never filtering by recognized matcher
# name), so the real generator never drops a hook and this positive check
# is the only live-path assertion possible against it. The synthetic check
# below exercises the SAME count-comparison formula the generator's
# assert_hook_counts_match() uses, against a hand-built "generated output
# lost a hook" fixture pair — proving the detection formula itself
# correctly flags a mismatch, which is what would fire if a future edit to
# the generator's jq filter narrowed it to an allowlist (the Cursor
# generator's own failure mode, see #838).
source_hook_count=$(jq '[.hooks[][].hooks[]] | length' "$TMPROOT/.claude/settings.json")
generated_hook_count=$(jq '[.hooks[][].hooks[]] | length' "$TMPROOT/.codex/hooks.json")
if [ "$source_hook_count" = "$generated_hook_count" ] && [ "$source_hook_count" -gt 0 ]; then
  mark_pass "generated hook count matches source settings.json hook count"
else
  mark_fail "generated hook count matches source settings.json hook count" "source=$source_hook_count generated=$generated_hook_count"
fi

DROPPED_FIXTURE=$(mktemp "${TMPDIR:-/tmp}/codex-adapter-dropped.XXXXXX")
jq '{hooks: {PreToolUse: []}}' "$TMPROOT/.codex/hooks.json" > "$DROPPED_FIXTURE"
dropped_generated_count=$(jq '[.hooks[][].hooks[]] | length' "$DROPPED_FIXTURE")
rm -f "$DROPPED_FIXTURE"
if [ "$source_hook_count" != "$dropped_generated_count" ]; then
  mark_pass "count-equality formula detects a synthetically dropped matcher group"
else
  mark_fail "count-equality formula detects a synthetically dropped matcher group" "expected mismatch, got source=$source_hook_count dropped=$dropped_generated_count"
fi

if bash "$SCRIPT" --root "$TMPROOT" --check >/tmp/_codex_adapter_check.out 2>&1; then
  mark_pass "--check passes when generated output is current"
else
  mark_fail "--check passes when generated output is current" "$(cat /tmp/_codex_adapter_check.out)"
fi

# The manifest participates in drift detection just like skills, agents, and
# hooks. Restore it through normal generation after proving the drift signal.
printf '{"adapter":"apexyard-codex","schema":999,"generated_from":".claude"}\n' \
  > "$TMPROOT/.codex/apexyard-adapter.json"
if bash "$SCRIPT" --root "$TMPROOT" --check >/tmp/_codex_adapter_manifest_drift.out 2>&1; then
  mark_fail "--check detects ownership-manifest drift" "expected non-zero exit"
else
  mark_pass "--check detects ownership-manifest drift"
fi
bash "$SCRIPT" --root "$TMPROOT" >/dev/null 2>&1

# A pre-manifest adapter is recognised only when all three legacy surfaces
# exist. Reconciliation refreshes stale skills and writes the durable marker.
rm "$TMPROOT/.codex/apexyard-adapter.json"
printf '\nLegacy refresh line.\n' >> "$TMPROOT/.claude/skills/status/SKILL.md"
if bash "$SCRIPT" --root "$TMPROOT" --reconcile-installed >/tmp/_codex_adapter_legacy.out 2>&1; then
  mark_pass "--reconcile-installed refreshes a complete legacy adapter"
else
  mark_fail "--reconcile-installed refreshes a complete legacy adapter" "$(cat /tmp/_codex_adapter_legacy.out)"
fi
assert_file "$TMPROOT/.codex/apexyard-adapter.json" "legacy reconciliation writes ownership manifest"
assert_contains "$TMPROOT/.agents/skills/status/SKILL.md" "Legacy refresh line." "legacy reconciliation refreshes skills"

# No install means no harness-specific output is created.
NOINSTALL="$TMPROOT/no-install"
mkdir -p "$NOINSTALL"
cp -R "$TMPROOT/.claude" "$NOINSTALL/.claude"
if bash "$SCRIPT" --root "$NOINSTALL" --reconcile-installed >/tmp/_codex_adapter_noinstall.out 2>&1; then
  mark_pass "--reconcile-installed is a no-op when Codex is not installed"
else
  mark_fail "--reconcile-installed is a no-op when Codex is not installed" "$(cat /tmp/_codex_adapter_noinstall.out)"
fi
assert_no_dir "$NOINSTALL/.agents" "uninstalled fork keeps .agents absent"
assert_no_dir "$NOINSTALL/.codex" "uninstalled fork keeps .codex absent"

# Every two-of-three partial legacy shape remains untouched. This prevents a
# user-owned .agents or .codex tree from being claimed by ApexYard.
for missing in skills agents hooks; do
  PARTIAL="$TMPROOT/partial-$missing"
  mkdir -p "$PARTIAL/.agents/skills" "$PARTIAL/.codex/agents"
  cp -R "$TMPROOT/.claude" "$PARTIAL/.claude"
  printf '{}\n' > "$PARTIAL/.codex/hooks.json"
  case "$missing" in
    skills) rmdir "$PARTIAL/.agents/skills" "$PARTIAL/.agents" ;;
    agents) rmdir "$PARTIAL/.codex/agents" ;;
    hooks)  rm "$PARTIAL/.codex/hooks.json" ;;
  esac
  if bash "$SCRIPT" --root "$PARTIAL" --reconcile-installed >/tmp/_codex_adapter_partial.out 2>&1; then
    mark_pass "partial legacy shape missing $missing is ignored"
  else
    mark_fail "partial legacy shape missing $missing is ignored" "$(cat /tmp/_codex_adapter_partial.out)"
  fi
  assert_no_file "$PARTIAL/.codex/apexyard-adapter.json" "partial shape missing $missing gets no manifest"
done

# A detected install with an invalid canonical config must fail loudly.
FAILROOT="$TMPROOT/failing-install"
mkdir -p "$FAILROOT/.agents/skills" "$FAILROOT/.codex/agents"
cp -R "$TMPROOT/.claude" "$FAILROOT/.claude"
printf '{}\n' > "$FAILROOT/.codex/hooks.json"
printf '{ invalid json\n' > "$FAILROOT/.claude/settings.json"
if bash "$SCRIPT" --root "$FAILROOT" --reconcile-installed >/tmp/_codex_adapter_failure.out 2>&1; then
  mark_fail "--reconcile-installed propagates generation failure" "expected non-zero exit"
else
  mark_pass "--reconcile-installed propagates generation failure"
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
