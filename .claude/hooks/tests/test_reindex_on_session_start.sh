#!/bin/bash
# Tests for reindex-on-session-start.sh AFTER its retrofit onto
# _lib-premium-hook.sh (me2resh/apexyard#890). Behaviour-preservation is the
# load-bearing property: everything this hook did before the retrofit must
# still hold, plus the new features.yaml opt-out becomes available.
#
# Each case builds an isolated sandbox with a synthetic ops-fork anchor and
# a stub `apexyard-search` binary on PATH, then runs the hook as a real
# script (not sourced) — same invocation shape Claude Code uses at
# SessionStart.
#
# Run: bash .claude/hooks/tests/test_reindex_on_session_start.sh

set -u

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HOOK_DIR/reindex-on-session-start.sh"

if [ ! -f "$HOOK" ]; then
  echo "FAIL: hook not found at $HOOK" >&2
  exit 1
fi

export APEXYARD_OPS_DISABLE_PIN=1

PASS=0
FAIL=0
FAILED_CASES=""

mark_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
mark_fail() { FAIL=$((FAIL + 1)); FAILED_CASES="$FAILED_CASES|$1"; echo "  FAIL: $1 -- $2" >&2; }

build_sandbox() {
  mkdir -p "$1"
  : > "$1/onboarding.yaml"
  : > "$1/apexyard.projects.yaml"
}

# Installs a stub `apexyard-search` on PATH (via $1/bin) that records its
# invocation to $1/bin-marker and behaves per $2 ("ok" | "fail" | "hang").
install_stub_cli() {
  local sb="$1" mode="$2"
  mkdir -p "$sb/bin"
  cat > "$sb/bin/apexyard-search" <<EOF
#!/bin/bash
echo "\$@" >> "$sb/bin-marker"
case "$mode" in
  fail) exit 1 ;;
  hang) sleep 30 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$sb/bin/apexyard-search"
}

run_hook_in() {
  local sb="$1"; shift
  ( cd "$sb" && env "$@" PATH="$sb/bin:$PATH" bash "$HOOK" 2>&1 )
}

# ---------------------------------------------------------------------------
# Case 1: no apexyard-search on PATH at all -> silent no-op (unchanged from
# pre-retrofit behaviour; the free/framework-only case).
# ---------------------------------------------------------------------------
test_no_cli_is_silent_noop() {
  local sb out rc
  sb=$(mktemp -d)
  build_sandbox "$sb"

  out=$(cd "$sb" && bash "$HOOK" 2>&1)
  rc=$?

  if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
    mark_pass "no apexyard-search on PATH -> silent no-op"
  else
    mark_fail "no CLI -> silent no-op" "out=[$out] rc=$rc"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 2: operator kill-switch (APEXYARD_SEARCH_REINDEX_DISABLE) -> silent
# no-op even with a working CLI present.
# ---------------------------------------------------------------------------
test_kill_switch_is_silent_noop() {
  local sb out rc
  sb=$(mktemp -d)
  build_sandbox "$sb"
  install_stub_cli "$sb" ok

  out=$(run_hook_in "$sb" APEXYARD_SEARCH_REINDEX_DISABLE=1)
  rc=$?

  if [ -z "$out" ] && [ "$rc" -eq 0 ] && [ ! -f "$sb/bin-marker" ]; then
    mark_pass "APEXYARD_SEARCH_REINDEX_DISABLE=1 -> silent no-op, CLI never invoked"
  else
    mark_fail "kill switch -> silent no-op" \
      "out=[$out] rc=$rc invoked=$([ -f "$sb/bin-marker" ] && echo yes || echo no)"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 3: CLI present, NO features.yaml at all (the pre-#890 shape — this
# hook never checked features.yaml before) -> the reindex still runs. This
# is the no-regression acceptance criterion: adopters who never configured
# features.yaml must see identical behaviour after the retrofit.
# ---------------------------------------------------------------------------
test_cli_present_no_features_yaml_still_runs() {
  local sb out rc
  sb=$(mktemp -d)
  build_sandbox "$sb"
  install_stub_cli "$sb" ok

  out=$(run_hook_in "$sb")
  rc=$?

  if [ "$rc" -eq 0 ] && [ -f "$sb/bin-marker" ] && grep -q "reindex" "$sb/bin-marker"; then
    mark_pass "CLI present + no features.yaml -> reindex still runs (no regression)"
  else
    mark_fail "CLI present, no features.yaml -> still runs" \
      "rc=$rc invoked=$([ -f "$sb/bin-marker" ] && echo yes || echo no)"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 4: CLI present, features.yaml explicitly opts OUT (search.enabled:
# false) -> silent no-op. This is the NEW capability the harness adds — an
# admin kill-switch that doesn't require uninstalling the CLI.
# ---------------------------------------------------------------------------
test_features_yaml_explicit_disable_wins() {
  local sb out rc
  sb=$(mktemp -d)
  build_sandbox "$sb"
  install_stub_cli "$sb" ok
  cat > "$sb/features.yaml" <<'YAML'
search:
  enabled: false
YAML

  out=$(run_hook_in "$sb")
  rc=$?

  if [ -z "$out" ] && [ "$rc" -eq 0 ] && [ ! -f "$sb/bin-marker" ]; then
    mark_pass "features.yaml search.enabled:false -> silent no-op even with CLI present"
  else
    mark_fail "features.yaml explicit disable" \
      "out=[$out] rc=$rc invoked=$([ -f "$sb/bin-marker" ] && echo yes || echo no)"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 5: the underlying apexyard-search invocation exits non-zero -> the
# hook still exits 0 (unchanged from pre-retrofit: `|| true` behaviour).
# ---------------------------------------------------------------------------
test_cli_failure_does_not_propagate() {
  local sb out rc
  sb=$(mktemp -d)
  build_sandbox "$sb"
  install_stub_cli "$sb" fail

  out=$(run_hook_in "$sb")
  rc=$?

  if [ "$rc" -eq 0 ]; then
    mark_pass "apexyard-search exits 1 -> hook still exits 0"
  else
    mark_fail "CLI failure swallowed" "out=[$out] rc=$rc"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 6: the underlying apexyard-search hangs past the configured timeout
# -> the hook still exits 0 promptly (bounded wall-clock).
# ---------------------------------------------------------------------------
test_cli_hang_is_bounded() {
  local sb start end elapsed rc
  sb=$(mktemp -d)
  build_sandbox "$sb"
  install_stub_cli "$sb" hang

  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    echo "  SKIP: neither timeout nor gtimeout is installed on this machine"
    rm -rf "$sb"
    return 0
  fi

  start=$(date +%s)
  run_hook_in "$sb" APEXYARD_SEARCH_REINDEX_TIMEOUT=1 >/dev/null
  rc=$?
  end=$(date +%s)
  elapsed=$((end - start))

  if [ "$rc" -eq 0 ] && [ "$elapsed" -lt 15 ]; then
    mark_pass "hanging apexyard-search killed within timeout, hook exits 0 (elapsed=${elapsed}s)"
  else
    mark_fail "hang is bounded" "rc=$rc elapsed=${elapsed}s"
  fi
  rm -rf "$sb"
}

test_no_cli_is_silent_noop
test_kill_switch_is_silent_noop
test_cli_present_no_features_yaml_still_runs
test_features_yaml_explicit_disable_wins
test_cli_failure_does_not_propagate
test_cli_hang_is_bounded

echo ""
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED_CASES" >&2
  exit 1
fi
exit 0
