#!/bin/bash
# Tests for validate-search-config.sh (apexyard-premium#514).
#
# The hook validates (read-only, LOUD-warn by default) the apexyard-search
# MCP config at SessionStart. The load-bearing acceptance criterion is the
# INTENT GATE: with no evidence the operator wants search (no
# "apexyard-search" entry in .mcp.json AND no vector_index.enabled: true in
# features.yaml), the hook MUST be a totally silent no-op — zero output,
# exit 0, no file writes. That's what every non-premium framework adopter
# sees at every session start, so it's tested first and most thoroughly.
#
# Auto-rewrite of .mcp.json is opt-in (APEXYARD_SEARCH_SELFHEAL=1) and
# off by default per the course-correction on this ticket — the default
# behaviour under test is detect + warn, never mutate.
#
# Each case builds an isolated sandbox under $TMPDIR with synthetic
# onboarding.yaml + apexyard.projects.yaml (the legacy v1 ops-fork anchor
# _lib-ops-root.sh recognises), runs the hook from inside it, and asserts
# stdout+stderr / exit code / file-unchanged as appropriate.
#
# Run: bash .claude/hooks/tests/test_validate_search_config.sh

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/validate-search-config.sh"
PASS=0
FAIL=0
FAILED_CASES=""

if [ ! -f "$HOOK" ]; then
  echo "FAIL: hook not found at $HOOK" >&2
  exit 1
fi

# Disable the ops-root session pin so every case resolves by walk-up to its
# own sandbox, never escaping onto the real ops fork (same isolation used by
# bin/run-hook-tests.sh for the whole suite).
export APEXYARD_OPS_DISABLE_PIN=1

mark_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
mark_fail() { FAIL=$((FAIL + 1)); FAILED_CASES="$FAILED_CASES|$1"; echo "  FAIL: $1 -- $2" >&2; }

# build_sandbox <dir>: minimal ops-fork anchor (legacy v1 shape).
build_sandbox() {
  mkdir -p "$1"
  : > "$1/onboarding.yaml"
  : > "$1/apexyard.projects.yaml"
}

run_hook_in() {
  # run_hook_in <dir> [env assignments...]
  local dir="$1"; shift
  ( cd "$dir" && env "$@" bash "$HOOK" ) 2>&1
}

# ---------------------------------------------------------------------------
# Case 1: no .mcp.json apexyard-search entry, no features.yaml at all —
# the non-premium / unconfigured shape. MUST be silent, exit 0.
# ---------------------------------------------------------------------------
test_no_intent_at_all_is_silent() {
  local sb; sb=$(mktemp -d)
  build_sandbox "$sb"

  local out rc
  out=$(run_hook_in "$sb"); rc=$?
  rm -rf "$sb"

  if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
    mark_pass "no intent evidence -> silent, exit 0"
  else
    mark_fail "no intent evidence -> silent, exit 0" "got output=[$out] rc=$rc"
  fi
}

# ---------------------------------------------------------------------------
# Case 2: .mcp.json exists but has no "apexyard-search" entry, and
# features.yaml exists but vector_index.enabled is false/absent — still
# the unconfigured shape (a different MCP server is configured). Silent.
# ---------------------------------------------------------------------------
test_other_mcp_server_no_vector_index_is_silent() {
  local sb; sb=$(mktemp -d)
  build_sandbox "$sb"
  cat > "$sb/.mcp.json" <<'EOF'
{"mcpServers":{"some-other-server":{"command":"something"}}}
EOF
  cat > "$sb/features.yaml" <<'EOF'
version: 1
features:
  budget:
    enabled: true
vector_index:
  enabled: false
EOF

  local out rc
  out=$(run_hook_in "$sb"); rc=$?
  rm -rf "$sb"

  if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
    mark_pass "other MCP server + vector_index disabled -> silent, exit 0"
  else
    mark_fail "other MCP server + vector_index disabled -> silent, exit 0" "got output=[$out] rc=$rc"
  fi
}

# ---------------------------------------------------------------------------
# Case 3: intent present (apexyard-search entry in .mcp.json), roots don't
# exist and command isn't launchable -> default (no SELFHEAL): LOUD warn on
# stderr, exit 0, .mcp.json UNCHANGED (no auto-mutation without opt-in).
# ---------------------------------------------------------------------------
test_broken_config_warns_loudly_and_does_not_mutate() {
  local sb; sb=$(mktemp -d)
  build_sandbox "$sb"
  cat > "$sb/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "apexyard-search": {
      "command": "apexyard-search-does-not-exist-anywhere",
      "env": {
        "APEXYARD_OPS_ROOT": "/nonexistent/old/path",
        "APEXYARD_PORTFOLIO_ROOT": "/nonexistent/old/portfolio"
      }
    }
  }
}
EOF
  local before after out rc
  before=$(cat "$sb/.mcp.json")
  out=$(run_hook_in "$sb"); rc=$?
  after=$(cat "$sb/.mcp.json")

  local ok=true
  case "$out" in
    *BROKEN*) ;;
    *) ok=false ;;
  esac
  [ "$before" = "$after" ] || ok=false
  [ "$rc" -eq 0 ] || ok=false
  # No backup should have been written without the opt-in.
  find "$sb" -maxdepth 1 -name '*.bak.*' | grep -q . && ok=false

  rm -rf "$sb"

  if $ok; then
    mark_pass "broken config (no opt-in) -> loud warn, unchanged, exit 0"
  else
    mark_fail "broken config (no opt-in) -> loud warn, unchanged, exit 0" "out=[$out] rc=$rc changed=$([ "$before" = "$after" ] && echo no || echo YES)"
  fi
}

# ---------------------------------------------------------------------------
# Case 4: intent present, config is healthy (absolute launchable command,
# both roots exist) -> silent, exit 0.
# ---------------------------------------------------------------------------
test_healthy_config_is_silent() {
  local sb; sb=$(mktemp -d)
  build_sandbox "$sb"
  # A real, always-present executable stands in for the search binary so
  # this test doesn't depend on apexyard-search actually being installed.
  # NOTE: don't use `command -v true` — in many shells `true` is a builtin
  # and `command -v` returns the bare word "true" with no path, which
  # would make this fixture itself unlaunchable-by-absolute-path.
  local real_bin
  if [ -x /usr/bin/true ]; then real_bin=/usr/bin/true; else real_bin=/bin/true; fi
  cat > "$sb/.mcp.json" <<EOF
{
  "mcpServers": {
    "apexyard-search": {
      "command": "$real_bin",
      "env": {
        "APEXYARD_OPS_ROOT": "$sb",
        "APEXYARD_PORTFOLIO_ROOT": "$sb"
      }
    }
  }
}
EOF
  local out rc
  out=$(run_hook_in "$sb"); rc=$?
  rm -rf "$sb"

  if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
    mark_pass "healthy config -> silent, exit 0"
  else
    mark_fail "healthy config -> silent, exit 0" "got output=[$out] rc=$rc"
  fi
}

# ---------------------------------------------------------------------------
# Case 5: intent from features.yaml (vector_index.enabled: true) but NO
# .mcp.json entry at all -> loud warn (nothing to heal, nothing to
# silently miss either), exit 0.
# ---------------------------------------------------------------------------
test_features_intent_without_mcp_entry_warns() {
  local sb; sb=$(mktemp -d)
  build_sandbox "$sb"
  cat > "$sb/features.yaml" <<'EOF'
version: 1
vector_index:
  db: chromadb
  enabled: true
EOF
  local out rc
  out=$(run_hook_in "$sb"); rc=$?
  rm -rf "$sb"

  local ok=true
  case "$out" in
    *"not wired up"*|*"not been wired"*|*"vector_index.enabled"*) ;;
    *) ok=false ;;
  esac
  [ "$rc" -eq 0 ] || ok=false

  if $ok; then
    mark_pass "features.yaml intent, no .mcp.json entry -> loud warn, exit 0"
  else
    mark_fail "features.yaml intent, no .mcp.json entry -> loud warn, exit 0" "out=[$out] rc=$rc"
  fi
}

# ---------------------------------------------------------------------------
# Case 6: opt-in self-heal (APEXYARD_SEARCH_SELFHEAL=1) with a broken
# config -> backs up the file, heals ONLY the apexyard-search entry,
# leaves sibling MCP server entries untouched, exit 0.
# ---------------------------------------------------------------------------
test_selfheal_opt_in_backs_up_and_heals_only_search_entry() {
  command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not installed, skipping self-heal test"; return 0; }

  local sb; sb=$(mktemp -d)
  build_sandbox "$sb"
  cat > "$sb/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "other-server": {"command": "something-else"},
    "apexyard-search": {
      "command": "apexyard-search-does-not-exist-anywhere",
      "env": {
        "APEXYARD_OPS_ROOT": "/nonexistent/old/path",
        "APEXYARD_PORTFOLIO_ROOT": "/nonexistent/old/portfolio"
      }
    }
  }
}
EOF
  local real_bin
  if [ -x /usr/bin/true ]; then real_bin=/usr/bin/true; else real_bin=/bin/true; fi
  # Make the broken command resolvable via PATH so self-heal has something
  # to resolve to (mirrors "bare command not on PATH" becoming launchable).
  local fakebin; fakebin=$(mktemp -d)
  ln -sf "$real_bin" "$fakebin/apexyard-search-does-not-exist-anywhere"

  local out rc
  out=$(cd "$sb" && env APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_SEARCH_SELFHEAL=1 PATH="$fakebin:$PATH" bash "$HOOK" 2>&1); rc=$?

  local ok=true
  [ "$rc" -eq 0 ] || ok=false
  find "$sb" -maxdepth 1 -name '*.bak.*' | grep -q . || ok=false
  jq -e '.mcpServers["other-server"].command == "something-else"' "$sb/.mcp.json" >/dev/null 2>&1 || ok=false
  jq -e '.mcpServers["apexyard-search"].env.APEXYARD_OPS_ROOT == "'"$sb"'"' "$sb/.mcp.json" >/dev/null 2>&1 || ok=false

  rm -rf "$sb" "$fakebin"

  if $ok; then
    mark_pass "opt-in self-heal: backs up, heals only apexyard-search entry"
  else
    mark_fail "opt-in self-heal: backs up, heals only apexyard-search entry" "out=[$out] rc=$rc"
  fi
}

# ---------------------------------------------------------------------------
# Case 7: the operator kill-switch (APEXYARD_SEARCH_VALIDATE_DISABLE) skips
# the hook entirely, even with a broken + intent-bearing config.
# ---------------------------------------------------------------------------
test_kill_switch_disables_entirely() {
  local sb; sb=$(mktemp -d)
  build_sandbox "$sb"
  cat > "$sb/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "apexyard-search": {
      "command": "apexyard-search-does-not-exist-anywhere",
      "env": {"APEXYARD_OPS_ROOT": "/nope", "APEXYARD_PORTFOLIO_ROOT": "/nope"}
    }
  }
}
EOF
  local out rc
  out=$(run_hook_in "$sb" APEXYARD_SEARCH_VALIDATE_DISABLE=1); rc=$?
  rm -rf "$sb"

  if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
    mark_pass "kill-switch -> silent regardless of config state"
  else
    mark_fail "kill-switch -> silent regardless of config state" "got output=[$out] rc=$rc"
  fi
}

echo "Running validate-search-config.sh tests..."
test_no_intent_at_all_is_silent
test_other_mcp_server_no_vector_index_is_silent
test_broken_config_warns_loudly_and_does_not_mutate
test_healthy_config_is_silent
test_features_intent_without_mcp_entry_warns
test_selfheal_opt_in_backs_up_and_heals_only_search_entry
test_kill_switch_disables_entirely

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED_CASES" >&2
  exit 1
fi
exit 0
