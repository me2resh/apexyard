#!/bin/bash
# Regression tests for me2resh/apexyard#1104 — portfolio path-resolution
# treating case-only path differences as a split-portfolio / broken
# config, on a case-insensitive filesystem (macOS/APFS default, Windows).
#
# Root cause: `_lib-ops-root.sh`'s pin-first resolve_ops_root() can
# return a path string sourced from a raw, non-canonicalized cwd (or a
# stale pin file written before this fix), while
# `_lib-portfolio-paths.sh`'s functions always anchor on `git rev-parse
# --show-toplevel`, which resolves via the OS and always returns the
# on-disk canonical case regardless of the case used to invoke it —
# VERIFIED empirically (see _lib-portfolio-paths.sh's portfolio_path_eq
# header comment): bash's own `cd`/`pwd -P` do NOT re-case a path,
# unlike `git rev-parse`. Comparing a canonical-cased path against a
# raw-cased one with a plain `=`/`case` string match then misreads a
# case-only difference as "two distinct repositories" — a phantom
# split-portfolio-v2 banner (print-portfolio-primer.sh) on a plain
# single-fork setup.
#
# This file:
#   - detects whether the CURRENT filesystem is case-insensitive first,
#     and skips (exit 0, not a failure) when it is not — the bug and
#     its fix only mean anything where "Foo" and "foo" name the same
#     on-disk entry, which is false on Linux's default ext4/etc.
#   - unit-tests the new portfolio_path_eq / portfolio_path_under
#     helpers directly: case-only variants of the SAME real directory
#     compare equal/contained; a genuinely DIFFERENT directory does not
#     (negative control — the helpers must not degrade into "always
#     true").
#   - end-to-end: simulates a stale/case-divergent ops-root pin (the
#     exact mechanism print-portfolio-primer.sh consumes) against an
#     otherwise-plain single-fork sandbox, and asserts NO false
#     split-portfolio banner fires.
#   - negative control: a GENUINE split-portfolio v2 setup (a real
#     sibling directory, not just a case variant) still fires the
#     banner — the fix must not suppress a real split.
#
# Exit 0 if all cases pass (or the environment is case-sensitive and
# every case is skipped); 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/print-portfolio-primer.sh"
LIB_OPS="$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"
LIB_PORT="$SRC_ROOT/.claude/hooks/_lib-portfolio-paths.sh"
LIB_CFG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"

for f in "$HOOK_SRC" "$LIB_OPS" "$LIB_PORT" "$LIB_CFG" "$DEFAULTS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED=""

mark_pass() { echo "PASS [$1]"; PASS=$((PASS+1)); }
mark_fail() { echo "FAIL [$1] — $2" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}${1}; "; }

assert_silent() {
  local label="$1" output="$2"
  if [ -z "$output" ]; then
    mark_pass "$label"
  else
    mark_fail "$label" "expected silent, got: $output"
  fi
}

assert_contains() {
  local label="$1" output="$2" pattern="$3"
  if printf '%s' "$output" | grep -qF -- "$pattern"; then
    mark_pass "$label"
  else
    mark_fail "$label" "expected output to contain '$pattern', got: $output"
  fi
}

# ---------------------------------------------------------------------------
# Case-insensitive-filesystem probe. Creates Probe/probe under a fresh
# temp dir and checks whether the lower-case spelling names the SAME
# on-disk entry (device+inode identity via -ef). Skips the whole suite
# (exit 0) when the filesystem is case-sensitive — nothing here is
# meaningful there.
# ---------------------------------------------------------------------------
PROBE_BASE=$(mktemp -d)
mkdir -p "$PROBE_BASE/CaseProbeXYZ"
if [ ! "$PROBE_BASE/CaseProbeXYZ" -ef "$PROBE_BASE/caseprobexyz" ]; then
  echo "SKIP: filesystem at $PROBE_BASE is case-sensitive — me2resh/apexyard#1104 only reproduces on a case-insensitive filesystem (macOS/APFS default, Windows). Nothing to test here."
  rm -rf "$PROBE_BASE"
  exit 0
fi
rm -rf "$PROBE_BASE"

# ---------------------------------------------------------------------------
# make_single_fork_sandbox: a real git repo, single-fork layout (the
# .apexyard-fork marker + in-fork registry/projects_dir/onboarding — no
# portfolio.* override), at a MIXED-CASE directory name so there is a
# meaningful lower-case string variant to compare against. Mirrors
# test_print_portfolio_primer.sh's make_public_fork_base(), plus the
# case-mixing this file specifically needs.
# ---------------------------------------------------------------------------
make_single_fork_sandbox() {
  local base sb
  base=$(mktemp -d)
  sb="$base/CaseForkXYZ"
  mkdir -p "$sb/.claude/hooks" "$sb/projects"
  cp "$HOOK_SRC" "$sb/.claude/hooks/print-portfolio-primer.sh"
  cp "$LIB_OPS" "$sb/.claude/hooks/_lib-ops-root.sh"
  cp "$LIB_PORT" "$sb/.claude/hooks/_lib-portfolio-paths.sh"
  cp "$LIB_CFG" "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$DEFAULTS" "$sb/.claude/project-config.defaults.json"
  chmod +x "$sb/.claude/hooks/print-portfolio-primer.sh"
  (
    cd "$sb" || exit 1
    echo "# v2 marker, single-fork adopter" > .apexyard-fork
    cat > apexyard.projects.yaml <<'YAML'
version: 1
projects: []
YAML
    echo "# Ideas" > projects/ideas-backlog.md
    touch onboarding.yaml
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git add -A
    git commit -q -m "fixture: single-fork, mixed-case root"
  )
  echo "$sb"
}

# Runs print-portfolio-primer.sh from $1 with a PINNED ops-root of $2 —
# simulating pin-ops-root.sh having captured (or a stale pre-fix pin
# file already holding) a differently-cased path for the SAME
# directory. Session id + pin dir are test-scoped so this never touches
# a real operator's pin state.
run_hook_with_pin() {
  local dir="$1" pinned_root="$2"
  local pin_dir sess
  pin_dir=$(mktemp -d)
  sess="test-1104-$$-$RANDOM"
  printf '%s\n' "$pinned_root" > "$pin_dir/ops-root-$sess"
  (
    cd "$dir" || exit 1
    CLAUDE_CODE_SESSION_ID="$sess" APEXYARD_OPS_PIN_DIR="$pin_dir" \
      bash .claude/hooks/print-portfolio-primer.sh 2>&1
  )
  local rc=$?
  rm -rf "$pin_dir"
  return $rc
}

# ---------------------------------------------------------------------------
# Unit tests: portfolio_path_eq / portfolio_path_under directly.
# ---------------------------------------------------------------------------
# Sourced once, at top level (not inside a subshell) — mark_pass/mark_fail
# increment the script's global PASS/FAIL counters, and a subshell would
# isolate those increments from the parent. Safe to source directly here:
# portfolio_path_eq/portfolio_path_under are pure path-string + stat(2)
# helpers with no cwd/caching state (unlike _portfolio_root(), which IS
# cached per-process — not exercised by this case).
# shellcheck source=/dev/null
. "$LIB_CFG"
# shellcheck source=/dev/null
. "$LIB_PORT"

case_path_eq_case_variants() {
  local sb
  sb=$(make_single_fork_sandbox)
  local lc
  lc=$(printf '%s' "$sb" | tr '[:upper:]' '[:lower:]')

  if portfolio_path_eq "$sb" "$lc"; then
    mark_pass "portfolio_path_eq: canonical vs lowercase string, same dir → equal"
  else
    mark_fail "portfolio_path_eq: canonical vs lowercase string, same dir → equal" "expected equal, got not-equal ($sb vs $lc)"
  fi

  if portfolio_path_under "$sb/apexyard.projects.yaml" "$lc"; then
    mark_pass "portfolio_path_under: file under canonical dir, compared against lowercase root → under"
  else
    mark_fail "portfolio_path_under: file under canonical dir, compared against lowercase root → under" "expected under, got not-under"
  fi

  # Negative control: a genuinely DIFFERENT directory (not a case
  # variant) must NOT compare equal / under — the helpers must not
  # degrade into "always true" once they fold case.
  local other
  other=$(mktemp -d)
  if portfolio_path_eq "$sb" "$other"; then
    mark_fail "portfolio_path_eq: genuinely different dir → NOT equal (negative control)" "incorrectly reported equal ($sb vs $other)"
  else
    mark_pass "portfolio_path_eq: genuinely different dir → NOT equal (negative control)"
  fi
  if portfolio_path_under "$sb/apexyard.projects.yaml" "$other"; then
    mark_fail "portfolio_path_under: file NOT under a genuinely different dir (negative control)" "incorrectly reported under ($other)"
  else
    mark_pass "portfolio_path_under: file NOT under a genuinely different dir (negative control)"
  fi
  rm -rf "$other"

  rm -rf "$(dirname "$sb")"
}

# ---------------------------------------------------------------------------
# End-to-end: a plain single-fork setup (no portfolio.* override at
# all — the registry/projects_dir/onboarding all resolve to their
# in-fork defaults) must stay SILENT even when the pinned ops-root
# string carries a different case than the canonical git-toplevel the
# portfolio_* resolvers use. This is the exact me2resh/apexyard#1104
# repro: "Ops-fork root" (pinned, lowercase) vs "Portfolio (sibling)"
# (canonical) differing only in case must NOT read as a split.
# ---------------------------------------------------------------------------
case_no_false_split_on_case_only_pin() {
  local sb lc out
  sb=$(make_single_fork_sandbox)
  lc=$(printf '%s' "$sb" | tr '[:upper:]' '[:lower:]')

  out=$(run_hook_with_pin "$sb" "$lc")
  assert_silent "no false split-portfolio banner: case-only pin vs canonical root" "$out"

  rm -rf "$(dirname "$sb")"
}

# ---------------------------------------------------------------------------
# Negative control: a REAL split (a genuine sibling directory, not a
# case variant of the fork root) must still fire the banner. The fix
# must not suppress a real split-portfolio v2 detection.
# ---------------------------------------------------------------------------
case_real_split_still_detected() {
  local sb priv
  sb=$(make_single_fork_sandbox)
  priv=$(mktemp -d)
  priv="$priv/acme-portfolio"
  mkdir -p "$priv/projects" "$priv/workspace"
  cat > "$priv/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: demo
    repo: example/demo
YAML
  echo "# Ideas" > "$priv/projects/ideas-backlog.md"
  echo "company: {name: Acme}" > "$priv/onboarding.yaml"

  (
    cd "$sb" || exit 1
    cat > .claude/project-config.json <<JSON
{
  "portfolio": {
    "registry": "$priv/apexyard.projects.yaml",
    "projects_dir": "$priv/projects",
    "ideas_backlog": "$priv/projects/ideas-backlog.md",
    "onboarding": "$priv/onboarding.yaml",
    "workspace_dir": "$priv/workspace"
  }
}
JSON
    git add -A
    git commit -q -m "fixture: real split-portfolio v2 config"
  )

  # Pin the (canonically-cased) fork root itself — no case games here,
  # this case only proves the fix didn't break genuine split detection.
  local out
  out=$(run_hook_with_pin "$sb" "$sb")
  assert_contains "real split-portfolio v2 (genuine sibling dir) still fires the banner" "$out" "split-portfolio v2 detected"

  rm -rf "$sb" "$(dirname "$priv")"
}

case_path_eq_case_variants
case_no_false_split_on_case_only_pin
case_real_split_still_detected

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
