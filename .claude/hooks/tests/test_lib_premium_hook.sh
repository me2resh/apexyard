#!/bin/bash
# Tests for _lib-premium-hook.sh — the shared safe-fallback harness for
# premium hooks (me2resh/apexyard#890).
#
# The load-bearing property under test is the three-part safe shape:
#   1. GATE       — feature-flag disabled/unconfigured OR component absent
#                    -> silent no-op (zero stdout, exit 0, payload never runs).
#   2. FAIL-SAFE   — a throwing or hanging payload is swallowed / killed;
#                    the guard still returns 0 promptly.
#   3. ALWAYS 0    — premium_hook_run never propagates a non-zero exit.
#
# Each case builds an isolated sandbox under $TMPDIR with a synthetic
# ops-fork anchor (onboarding.yaml + apexyard.projects.yaml — the legacy v1
# shape _lib-ops-root.sh recognises) and an optional features.yaml, sources
# the lib with that sandbox as cwd, and calls premium_hook_run directly.
#
# Run: bash .claude/hooks/tests/test_lib_premium_hook.sh

set -u

LIB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$LIB_DIR/_lib-premium-hook.sh"

if [ ! -f "$LIB" ]; then
  echo "FAIL: lib not found at $LIB" >&2
  exit 1
fi

# Same isolation used across the suite (see bin/run-hook-tests.sh): disable
# the ops-root session pin so every case resolves by walk-up to its own
# sandbox, never escaping onto the real ops fork.
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

# ---------------------------------------------------------------------------
# Case 1: feature absent from features.yaml entirely, default_enabled=false
# -> silent no-op: exit 0, zero stdout, and the payload never actually runs
# (verified via a marker file the payload would otherwise create).
# ---------------------------------------------------------------------------
test_feature_absent_is_silent_noop() {
  local sb marker out rc
  sb=$(mktemp -d)
  build_sandbox "$sb"
  marker="$sb/ran.marker"

  # shellcheck source=/dev/null
  out=$(cd "$sb" && . "$LIB" && premium_hook_run "nope" "" "touch '$marker'" "false" 2>&1)
  rc=$?

  if [ -z "$out" ] && [ "$rc" -eq 0 ] && [ ! -f "$marker" ]; then
    mark_pass "feature absent + default=false -> silent no-op, payload never runs"
  else
    mark_fail "feature absent -> silent no-op" \
      "out=[$out] rc=$rc marker_exists=$([ -f "$marker" ] && echo yes || echo no)"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 1b: feature key absent, default_enabled=true (the retrofit-compat
# shape used by reindex-on-session-start.sh) -> the flag gate passes, so the
# payload runs as long as presence also passes. Proves the "no regression
# for hooks that never had a features.yaml check" design goal.
# ---------------------------------------------------------------------------
test_feature_absent_defaults_to_enabled_when_asked() {
  local sb marker out rc
  sb=$(mktemp -d)
  build_sandbox "$sb"
  marker="$sb/ran.marker"

  # shellcheck source=/dev/null
  out=$(cd "$sb" && . "$LIB" && premium_hook_run "search" "true" "touch '$marker'" "true" 2>&1)
  rc=$?

  if [ "$rc" -eq 0 ] && [ -f "$marker" ]; then
    mark_pass "feature absent + default=true + present -> payload runs (retrofit-compat)"
  else
    mark_fail "feature absent + default=true -> payload runs" \
      "out=[$out] rc=$rc marker_exists=$([ -f "$marker" ] && echo yes || echo no)"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 1c: features.yaml has the key explicitly false -> silent no-op EVEN
# when default_enabled=true (explicit false always wins over the default).
# ---------------------------------------------------------------------------
test_feature_explicitly_false_overrides_default_true() {
  local sb marker out rc
  sb=$(mktemp -d)
  build_sandbox "$sb"
  cat > "$sb/features.yaml" <<'YAML'
search:
  enabled: false
YAML
  marker="$sb/ran.marker"

  # shellcheck source=/dev/null
  out=$(cd "$sb" && . "$LIB" && premium_hook_run "search" "true" "touch '$marker'" "true" 2>&1)
  rc=$?

  if [ -z "$out" ] && [ "$rc" -eq 0 ] && [ ! -f "$marker" ]; then
    mark_pass "features.yaml search.enabled:false overrides default_enabled=true -> silent no-op"
  else
    mark_fail "explicit false overrides default true" \
      "out=[$out] rc=$rc marker_exists=$([ -f "$marker" ] && echo yes || echo no)"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 2: feature explicitly enabled + presence check passes -> the payload
# runs, and the guard still returns 0.
# ---------------------------------------------------------------------------
test_enabled_and_present_runs_payload() {
  local sb marker out rc
  sb=$(mktemp -d)
  build_sandbox "$sb"
  cat > "$sb/features.yaml" <<'YAML'
search:
  enabled: true
YAML
  marker="$sb/ran.marker"

  # shellcheck source=/dev/null
  out=$(cd "$sb" && . "$LIB" && premium_hook_run "search" "true" "touch '$marker'" "false" 2>&1)
  rc=$?

  if [ "$rc" -eq 0 ] && [ -f "$marker" ]; then
    mark_pass "enabled + present -> payload runs, guard returns 0"
  else
    mark_fail "enabled + present -> payload runs" \
      "rc=$rc marker_exists=$([ -f "$marker" ] && echo yes || echo no)"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 2b: feature enabled but the presence check FAILS (component absent)
# -> silent no-op, payload never runs.
# ---------------------------------------------------------------------------
test_enabled_but_component_absent_is_silent_noop() {
  local sb marker out rc
  sb=$(mktemp -d)
  build_sandbox "$sb"
  cat > "$sb/features.yaml" <<'YAML'
search:
  enabled: true
YAML
  marker="$sb/ran.marker"

  # shellcheck source=/dev/null
  out=$(cd "$sb" && . "$LIB" && premium_hook_run "search" "false" "touch '$marker'" "false" 2>&1)
  rc=$?

  if [ -z "$out" ] && [ "$rc" -eq 0 ] && [ ! -f "$marker" ]; then
    mark_pass "enabled but component absent -> silent no-op"
  else
    mark_fail "enabled but component absent -> silent no-op" \
      "out=[$out] rc=$rc marker_exists=$([ -f "$marker" ] && echo yes || echo no)"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 3: payload exits non-zero -> the guard swallows it and still returns
# 0 (a genuine premium failure can never propagate to the caller).
# ---------------------------------------------------------------------------
test_throwing_payload_is_swallowed() {
  local sb out rc
  sb=$(mktemp -d)
  build_sandbox "$sb"
  cat > "$sb/features.yaml" <<'YAML'
search:
  enabled: true
YAML

  # shellcheck source=/dev/null
  out=$(cd "$sb" && . "$LIB" && premium_hook_run "search" "true" "exit 1" "false" 2>&1)
  rc=$?

  if [ "$rc" -eq 0 ]; then
    mark_pass "payload exits 1 -> guard still returns 0"
  else
    mark_fail "payload exits 1 -> guard still returns 0" "rc=$rc out=[$out]"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 4: payload sleeps well past the configured timeout -> it gets killed
# and the guard returns 0 promptly (bounded wall-clock — never hangs the
# session). Skips gracefully if neither `timeout` nor `gtimeout` exists.
# ---------------------------------------------------------------------------
test_hanging_payload_is_killed_and_swallowed() {
  local sb start end elapsed rc
  sb=$(mktemp -d)
  build_sandbox "$sb"
  cat > "$sb/features.yaml" <<'YAML'
search:
  enabled: true
YAML

  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    echo "  SKIP: neither timeout nor gtimeout is installed on this machine"
    rm -rf "$sb"
    return 0
  fi

  start=$(date +%s)
  # shellcheck source=/dev/null
  ( cd "$sb" && export PREMIUM_HOOK_TIMEOUT_SECS=1 && . "$LIB" && premium_hook_run "search" "true" "sleep 30" "false" )
  rc=$?
  end=$(date +%s)
  elapsed=$((end - start))

  if [ "$rc" -eq 0 ] && [ "$elapsed" -lt 10 ]; then
    mark_pass "hanging payload killed within timeout, guard returns 0 (elapsed=${elapsed}s)"
  else
    mark_fail "hanging payload killed within timeout" "rc=$rc elapsed=${elapsed}s"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 5: missing feature_key or missing payload_cmd -> silent no-op, never
# a shell error. Input hygiene, not just the happy path.
# ---------------------------------------------------------------------------
test_missing_required_args_are_silent_noop() {
  local sb out1 rc1 out2 rc2
  sb=$(mktemp -d)
  build_sandbox "$sb"

  # shellcheck source=/dev/null
  out1=$(cd "$sb" && . "$LIB" && premium_hook_run "" "true" "echo should-not-run" 2>&1)
  rc1=$?
  # shellcheck source=/dev/null
  out2=$(cd "$sb" && . "$LIB" && premium_hook_run "search" "true" "" 2>&1)
  rc2=$?

  if [ -z "$out1" ] && [ "$rc1" -eq 0 ] && [ -z "$out2" ] && [ "$rc2" -eq 0 ]; then
    mark_pass "missing feature_key / missing payload_cmd -> silent no-op"
  else
    mark_fail "missing required args -> silent no-op" "out1=[$out1] rc1=$rc1 out2=[$out2] rc2=$rc2"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 6: premium_feature_enabled is independently callable (not just
# through premium_hook_run) — sanity check for the exposed public function.
# ---------------------------------------------------------------------------
test_premium_feature_enabled_standalone() {
  local sb rc_true rc_false rc_absent
  sb=$(mktemp -d)
  build_sandbox "$sb"
  cat > "$sb/features.yaml" <<'YAML'
loops:
  enabled: true
budget:
  enabled: false
YAML

  # shellcheck source=/dev/null
  ( cd "$sb" && . "$LIB" && premium_feature_enabled "loops" ); rc_true=$?
  # shellcheck source=/dev/null
  ( cd "$sb" && . "$LIB" && premium_feature_enabled "budget" ); rc_false=$?
  # shellcheck source=/dev/null
  ( cd "$sb" && . "$LIB" && premium_feature_enabled "playbooks" "false" ); rc_absent=$?

  if [ "$rc_true" -eq 0 ] && [ "$rc_false" -eq 1 ] && [ "$rc_absent" -eq 1 ]; then
    mark_pass "premium_feature_enabled: true/false/absent-with-default=false all resolve correctly"
  else
    mark_fail "premium_feature_enabled standalone" "rc_true=$rc_true rc_false=$rc_false rc_absent=$rc_absent"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 7 (#929): premium_hook_probe — feature disabled -> NOT_APPLICABLE (2),
# same "nothing to report on" outcome premium_hook_run treats as a silent
# no-op, but as its own distinguishable return code so callers can branch.
# ---------------------------------------------------------------------------
test_probe_not_applicable_when_feature_disabled() {
  local sb rc
  sb=$(mktemp -d)
  build_sandbox "$sb"
  cat > "$sb/features.yaml" <<'YAML'
search:
  enabled: false
YAML

  # shellcheck source=/dev/null
  ( cd "$sb" && . "$LIB" && premium_hook_probe "search" "true" "true" "true" ); rc=$?

  if [ "$rc" -eq 2 ]; then
    mark_pass "premium_hook_probe: feature disabled -> NOT_APPLICABLE (2)"
  else
    mark_fail "probe not applicable when feature disabled" "rc=$rc"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 8 (#929): premium_hook_probe — feature enabled but presence check
# fails (component absent) -> NOT_APPLICABLE (2).
# ---------------------------------------------------------------------------
test_probe_not_applicable_when_component_absent() {
  local sb rc
  sb=$(mktemp -d)
  build_sandbox "$sb"

  # shellcheck source=/dev/null
  ( cd "$sb" && . "$LIB" && premium_hook_probe "search" "false" "true" "true" ); rc=$?

  if [ "$rc" -eq 2 ]; then
    mark_pass "premium_hook_probe: component absent -> NOT_APPLICABLE (2)"
  else
    mark_fail "probe not applicable when component absent" "rc=$rc"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 9 (#929): premium_hook_probe — gate passes AND probe_cmd exits 0 ->
# REACHABLE (0).
# ---------------------------------------------------------------------------
test_probe_reachable_returns_zero() {
  local sb rc
  sb=$(mktemp -d)
  build_sandbox "$sb"

  # shellcheck source=/dev/null
  ( cd "$sb" && . "$LIB" && premium_hook_probe "search" "true" "true" "true" ); rc=$?

  if [ "$rc" -eq 0 ]; then
    mark_pass "premium_hook_probe: gate passes + probe succeeds -> REACHABLE (0)"
  else
    mark_fail "probe reachable" "rc=$rc"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 10 (#929): premium_hook_probe — gate passes but probe_cmd exits
# non-zero -> UNREACHABLE (1), distinguishable from NOT_APPLICABLE (2).
# ---------------------------------------------------------------------------
test_probe_unreachable_on_failure() {
  local sb rc
  sb=$(mktemp -d)
  build_sandbox "$sb"

  # shellcheck source=/dev/null
  ( cd "$sb" && . "$LIB" && premium_hook_probe "search" "true" "exit 1" "true" ); rc=$?

  if [ "$rc" -eq 1 ]; then
    mark_pass "premium_hook_probe: probe_cmd exits 1 -> UNREACHABLE (1)"
  else
    mark_fail "probe unreachable on failure" "rc=$rc"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 11 (#929): premium_hook_probe — a hanging probe_cmd is killed by its
# OWN (shorter-by-default) timeout knob and treated as UNREACHABLE (1), not
# left to hang or fall back to the general payload timeout. Skips gracefully
# if neither `timeout` nor `gtimeout` exists.
# ---------------------------------------------------------------------------
test_probe_hanging_is_bounded_and_unreachable() {
  local sb start end elapsed rc
  sb=$(mktemp -d)
  build_sandbox "$sb"

  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    echo "  SKIP: neither timeout nor gtimeout is installed on this machine"
    rm -rf "$sb"
    return 0
  fi

  start=$(date +%s)
  # shellcheck source=/dev/null
  ( cd "$sb" && export PREMIUM_HOOK_PROBE_TIMEOUT_SECS=1 && . "$LIB" && premium_hook_probe "search" "true" "sleep 30" "true" )
  rc=$?
  end=$(date +%s)
  elapsed=$((end - start))

  if [ "$rc" -eq 1 ] && [ "$elapsed" -lt 10 ]; then
    mark_pass "premium_hook_probe: hanging probe killed within its own timeout -> UNREACHABLE (elapsed=${elapsed}s)"
  else
    mark_fail "probe hanging is bounded and unreachable" "rc=$rc elapsed=${elapsed}s"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 12 (#929): premium_hook_probe — missing feature_key or missing
# probe_cmd -> NOT_APPLICABLE (2), never a shell error.
# ---------------------------------------------------------------------------
test_probe_missing_required_args_not_applicable() {
  local sb rc1 rc2
  sb=$(mktemp -d)
  build_sandbox "$sb"

  # shellcheck source=/dev/null
  ( cd "$sb" && . "$LIB" && premium_hook_probe "" "true" "true" "true" ); rc1=$?
  # shellcheck source=/dev/null
  ( cd "$sb" && . "$LIB" && premium_hook_probe "search" "true" "" "true" ); rc2=$?

  if [ "$rc1" -eq 2 ] && [ "$rc2" -eq 2 ]; then
    mark_pass "premium_hook_probe: missing feature_key / probe_cmd -> NOT_APPLICABLE (2)"
  else
    mark_fail "probe missing required args" "rc1=$rc1 rc2=$rc2"
  fi
  rm -rf "$sb"
}

test_feature_absent_is_silent_noop
test_feature_absent_defaults_to_enabled_when_asked
test_feature_explicitly_false_overrides_default_true
test_enabled_and_present_runs_payload
test_enabled_but_component_absent_is_silent_noop
test_throwing_payload_is_swallowed
test_hanging_payload_is_killed_and_swallowed
test_missing_required_args_are_silent_noop
test_premium_feature_enabled_standalone
test_probe_not_applicable_when_feature_disabled
test_probe_not_applicable_when_component_absent
test_probe_reachable_returns_zero
test_probe_unreachable_on_failure
test_probe_hanging_is_bounded_and_unreachable
test_probe_missing_required_args_not_applicable

echo ""
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED_CASES" >&2
  exit 1
fi
exit 0
