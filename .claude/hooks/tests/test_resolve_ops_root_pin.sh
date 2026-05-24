#!/bin/bash
# Smoke tests for the pin-first / walk-up-fallback behaviour added to
# .claude/hooks/_lib-ops-root.sh in apexyard#381, plus a tiny
# functional check on .claude/hooks/pin-ops-root.sh itself.
#
# Each case:
#   - builds an isolated sandbox under $TMPDIR with a synthetic
#     ops-fork layout (v1 or v2 anchors)
#   - optionally writes a pin file under a per-case APEXYARD_OPS_PIN_DIR
#   - sources the lib (or invokes the SessionStart hook)
#   - exports CLAUDE_CODE_SESSION_ID to drive the pin lookup
#   - asserts the returned path / pin-file contents
#
# Cases covered:
#   1. Pin hit (pin exists, cwd outside ops root) → returns pinned path
#   2. Stale pin (pin points at dir with no anchors) → falls back to walk-up
#   3. APEXYARD_OPS_DISABLE_PIN=1 → pin ignored, walk-up used
#   4. resolve_ops_root_walk direct call → ignores pin entirely
#   5. Spaced path in pin (/tmp/test space/ops) → read back intact
#   6. CLAUDE_CODE_SESSION_ID unset → falls back to walk-up
#   7. pin-ops-root.sh writes the pin file from launch cwd
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"
HOOK="$SRC_ROOT/.claude/hooks/pin-ops-root.sh"

if [ ! -f "$LIB" ]; then
  echo "FAIL: lib not found at $LIB" >&2
  exit 1
fi
if [ ! -f "$HOOK" ]; then
  echo "FAIL: hook not found at $HOOK" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

mark_pass() { echo "  ✓ $1"; return 0; }
mark_fail() { echo "  ✗ $1: $2" >&2; return 1; }

run_case() {
  local fn="$1"
  if "$fn"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES $fn"
  fi
}

# Legacy v1 sandbox: onboarding.yaml + apexyard.projects.yaml.
build_v1_sandbox() {
  local sb="$1"
  mkdir -p "$sb/workspace/demo/.git"
  : > "$sb/onboarding.yaml"
  : > "$sb/apexyard.projects.yaml"
}

# v2 sandbox: .apexyard-fork marker.
build_v2_sandbox() {
  local sb="$1"
  mkdir -p "$sb/workspace/demo/.git"
  : > "$sb/.apexyard-fork"
}

# ---------------------------------------------------------------------------
# Case 1: pin hit — pin exists, cwd outside ops root, returns pinned path
# ---------------------------------------------------------------------------
case_1() {
  local case_name="pin hit: returns pinned path even when cwd is outside ops root"
  local sb pin_dir cwd_outside
  sb=$(mktemp -d)
  pin_dir=$(mktemp -d)
  cwd_outside=$(mktemp -d)
  build_v1_sandbox "$sb"

  # Write the pin.
  printf '%s\n' "$sb" > "$pin_dir/ops-root-testsess1"

  (
    export CLAUDE_CODE_SESSION_ID="testsess1"
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    unset APEXYARD_OPS_DISABLE_PIN
    # shellcheck source=/dev/null
    . "$LIB"
    out=$(cd "$cwd_outside" && resolve_ops_root)
    [ "$out" = "$sb" ] || { mark_fail "$case_name" "expected '$sb', got '$out'"; return; }
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 2: stale pin — pin points at dir with no anchors → walk-up fallback
# ---------------------------------------------------------------------------
case_2() {
  local case_name="stale pin: falls back to walk-up when pinned path has no anchors"
  local sb pin_dir stale_dir
  sb=$(mktemp -d)
  pin_dir=$(mktemp -d)
  stale_dir=$(mktemp -d)   # no anchors
  build_v1_sandbox "$sb"

  # Pin points at a dir that doesn't satisfy anchor conditions.
  printf '%s\n' "$stale_dir" > "$pin_dir/ops-root-testsess2"

  (
    export CLAUDE_CODE_SESSION_ID="testsess2"
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    unset APEXYARD_OPS_DISABLE_PIN
    # shellcheck source=/dev/null
    . "$LIB"
    # cwd inside the real ops fork — walk-up should find $sb.
    out=$(cd "$sb/workspace/demo" && resolve_ops_root)
    [ "$out" = "$sb" ] \
      || { mark_fail "$case_name" "expected walk-up to '$sb', got '$out'"; return; }
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 3: APEXYARD_OPS_DISABLE_PIN=1 → pin ignored, walk-up used
# ---------------------------------------------------------------------------
case_3() {
  local case_name="escape hatch: APEXYARD_OPS_DISABLE_PIN=1 forces walk-up"
  local sb1 sb2 pin_dir
  sb1=$(mktemp -d)
  sb2=$(mktemp -d)
  pin_dir=$(mktemp -d)
  build_v1_sandbox "$sb1"
  build_v1_sandbox "$sb2"

  # Pin points at sb1, cwd inside sb2 — without the escape hatch we'd
  # see sb1; WITH it we should see sb2 from the walk-up.
  printf '%s\n' "$sb1" > "$pin_dir/ops-root-testsess3"

  (
    export CLAUDE_CODE_SESSION_ID="testsess3"
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    export APEXYARD_OPS_DISABLE_PIN=1
    # shellcheck source=/dev/null
    . "$LIB"
    out=$(cd "$sb2/workspace/demo" && resolve_ops_root)
    [ "$out" = "$sb2" ] \
      || { mark_fail "$case_name" "expected walk-up to '$sb2' (escape hatch on), got '$out'"; return; }
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 4: resolve_ops_root_walk direct call → ignores pin entirely
# ---------------------------------------------------------------------------
case_4() {
  local case_name="resolve_ops_root_walk ignores pin even when set"
  local sb1 sb2 pin_dir
  sb1=$(mktemp -d)
  sb2=$(mktemp -d)
  pin_dir=$(mktemp -d)
  build_v1_sandbox "$sb1"
  build_v1_sandbox "$sb2"

  # Pin says sb1; walk from sb2 should still return sb2.
  printf '%s\n' "$sb1" > "$pin_dir/ops-root-testsess4"

  (
    export CLAUDE_CODE_SESSION_ID="testsess4"
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    unset APEXYARD_OPS_DISABLE_PIN
    # shellcheck source=/dev/null
    . "$LIB"
    out=$(cd "$sb2/workspace/demo" && resolve_ops_root_walk)
    [ "$out" = "$sb2" ] \
      || { mark_fail "$case_name" "expected walk-up to '$sb2', got '$out'"; return; }
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 5: spaced path in pin → read back intact
# ---------------------------------------------------------------------------
case_5() {
  local case_name="spaced path: pin file round-trips through IFS= read -r intact"
  local base pin_dir cwd_outside sb_name sb
  base=$(mktemp -d)
  sb_name="test space/ops fork"
  sb="$base/$sb_name"
  mkdir -p "$sb"
  build_v1_sandbox "$sb"
  pin_dir=$(mktemp -d)
  cwd_outside=$(mktemp -d)

  printf '%s\n' "$sb" > "$pin_dir/ops-root-testsess5"

  (
    export CLAUDE_CODE_SESSION_ID="testsess5"
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    unset APEXYARD_OPS_DISABLE_PIN
    # shellcheck source=/dev/null
    . "$LIB"
    out=$(cd "$cwd_outside" && resolve_ops_root)
    [ "$out" = "$sb" ] \
      || { mark_fail "$case_name" "expected '$sb' (with spaces), got '$out'"; return; }
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 6: CLAUDE_CODE_SESSION_ID unset → walk-up only (pin ignored)
# ---------------------------------------------------------------------------
case_6() {
  local case_name="no session id: pin lookup skipped, walk-up used"
  local sb1 sb2 pin_dir
  sb1=$(mktemp -d)
  sb2=$(mktemp -d)
  pin_dir=$(mktemp -d)
  build_v1_sandbox "$sb1"
  build_v1_sandbox "$sb2"

  # A "default" pin shape that could match if anything tried to read it
  # without the session id.
  printf '%s\n' "$sb1" > "$pin_dir/ops-root-"

  (
    unset CLAUDE_CODE_SESSION_ID
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    unset APEXYARD_OPS_DISABLE_PIN
    # shellcheck source=/dev/null
    . "$LIB"
    out=$(cd "$sb2/workspace/demo" && resolve_ops_root)
    [ "$out" = "$sb2" ] \
      || { mark_fail "$case_name" "expected walk-up to '$sb2' (no session id), got '$out'"; return; }
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 7: pin-ops-root.sh writes the pin file from launch cwd
# ---------------------------------------------------------------------------
case_7() {
  local case_name="pin-ops-root.sh: SessionStart hook writes pin file"
  local sb pin_dir
  sb=$(mktemp -d)
  pin_dir=$(mktemp -d)
  build_v2_sandbox "$sb"

  local sess="testsess7-$$"
  (
    export CLAUDE_CODE_SESSION_ID="$sess"
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    # Run the hook from inside the ops fork. The hook resolves $PWD via
    # walk-up and writes the pin.
    cd "$sb/workspace/demo" || exit 1
    bash "$HOOK" >/dev/null 2>&1
  )

  local pin_file="$pin_dir/ops-root-$sess"
  if [ ! -f "$pin_file" ]; then
    mark_fail "$case_name" "pin file not created at '$pin_file'"
    return
  fi

  local pinned=""
  IFS= read -r pinned < "$pin_file" || pinned=""
  [ "$pinned" = "$sb" ] \
    || { mark_fail "$case_name" "expected pin contents '$sb', got '$pinned'"; return; }
  mark_pass "$case_name"
}

# ---------------------------------------------------------------------------
# Case 8: pin-ops-root.sh is a silent no-op when CLAUDE_CODE_SESSION_ID unset
# ---------------------------------------------------------------------------
case_8() {
  local case_name="pin-ops-root.sh: no-op when CLAUDE_CODE_SESSION_ID is unset"
  local sb pin_dir
  sb=$(mktemp -d)
  pin_dir=$(mktemp -d)
  build_v2_sandbox "$sb"

  (
    unset CLAUDE_CODE_SESSION_ID
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    cd "$sb" || exit 1
    bash "$HOOK" >/dev/null 2>&1
  )

  # Pin dir should still be empty (no file created).
  local count
  count=$(find "$pin_dir" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l)
  [ "$count" -eq 0 ] \
    || { mark_fail "$case_name" "expected no pin files in '$pin_dir', found $count"; return; }
  mark_pass "$case_name"
}

echo "Running pin-first resolve_ops_root tests..."
for fn in case_1 case_2 case_3 case_4 case_5 case_6 case_7 case_8; do
  run_case "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0
