#!/bin/bash
# Unit tests for .claude/hooks/_lib-protected-branches.sh, specifically the
# fail-closed hardening added in me2resh/apexyard#1086 step 3 (AgDR-0114).
#
# No prior dedicated test file existed for this lib — it was previously
# exercised only indirectly through test_githooks_pre_push_protected_branch.sh.
# These tests call is_protected_branch() and protected_branch_regex()
# directly, in an isolated sandbox with its own project-config, so the two
# MEDIUM gaps found reviewing #1086 step 3 are pinned at the unit level
# rather than only proven end-to-end through a full git-hook round trip:
#
#   1. A malformed `.git.protected_branches[]` entry (e.g. an unbalanced-
#      paren fragment) must not make the composed regex fail to evaluate in
#      a way that reads as "not protected". grep -qE's exit codes: 0 =
#      match, 1 = no match, >1 = usage/regex error — only 1 is genuinely
#      "not protected".
#   2. A renamed/absent protected_branch_regex function (after the lib file
#      itself was successfully sourced) must not silently allow — it must
#      WARN and fail closed (treat the branch as protected).
#
# Both are DISCRIMINATING BY CONSTRUCTION: run this suite against the
# pre-#1086-step-3 lib (protected_branch_regex() only, no
# is_protected_branch()) and every case below fails with "command not
# found" — is_protected_branch did not exist. Cases 3 and 4 specifically
# are proven by first reproducing the OLD bug shape (a hand-rolled
# `command -v` guard + raw `grep -qE` exactly as the pre-#1086-step-3
# .githooks/pre-push did it) and showing IT silently allows, before showing
# is_protected_branch() does not.
#
# Cases:
#   1.  Well-formed config: is_protected_branch matches configured branches
#   2.  Well-formed config: is_protected_branch does NOT match a safe branch
#   3.  Malformed regex entry ("ma(in") -> main STILL protected (fail closed)
#   4.  Malformed regex entry -> a genuinely unrelated branch is also fail-closed
#       (the old bug: one bad entry silently unprotects EVERYTHING, not just
#       the malformed one — proven by reproducing the OLD behaviour first)
#   5.  protected_branch_regex renamed/removed -> WARN + fail closed (blocked),
#       contrasted against the OLD hand-rolled guard, which silently allowed
#   6.  Default fallback (no config at all) still protects main/master/dev/develop
#
# Exit 0 if all cases pass; 1 on any failure.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REAL_PROTECTED_LIB="$ROOT/.claude/hooks/_lib-protected-branches.sh"
REAL_READ_CONFIG_LIB="$ROOT/.claude/hooks/_lib-read-config.sh"
# me2resh/apexyard#1102 / AgDR-0118: protected_branch_regex's self-location
# now sources _lib-ops-root.sh (via the shared resolve_anchored_lib_dir
# guard) before it can locate _lib-read-config.sh — the sandbox must ship
# it too, or hook_dir never resolves and every case below silently falls
# back to the "main|master|dev|develop" default instead of exercising the
# configured `.git.protected_branches[]`.
REAL_OPS_ROOT_LIB="$ROOT/.claude/hooks/_lib-ops-root.sh"

PASS=0
FAIL=0
FAILED=""

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label] — expected '$expected', got '$actual'" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
  fi
}

assert_match() {
  local label="$1" pattern="$2" actual="$3"
  if printf '%s' "$actual" | grep -qE "$pattern"; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label] — expected to match /$pattern/, got: $actual" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
  fi
}

if [ ! -f "$REAL_PROTECTED_LIB" ]; then
  echo "FAIL: _lib-protected-branches.sh not found at $REAL_PROTECTED_LIB" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# build_sandbox DIR [PROTECTED_BRANCHES_JSON_ARRAY]
#
# Builds $DIR/work as a real git repo (so git rev-parse --show-toplevel
# inside the lib resolves somewhere sane) with the REAL lib + read-config
# helper copied in, and an optional .claude/project-config.defaults.json
# setting .git.protected_branches to the given JSON array literal.
# ---------------------------------------------------------------------------
build_sandbox() {
  local dir="$1" branches_json="${2:-}"
  local work="$dir/work"
  mkdir -p "$work/.claude/hooks"
  git -C "$work" init -q -b main >/dev/null 2>&1
  cp "$REAL_PROTECTED_LIB" "$work/.claude/hooks/_lib-protected-branches.sh"
  cp "$REAL_READ_CONFIG_LIB" "$work/.claude/hooks/_lib-read-config.sh"
  cp "$REAL_OPS_ROOT_LIB" "$work/.claude/hooks/_lib-ops-root.sh"
  if [ -n "$branches_json" ]; then
    printf '{"git": {"protected_branches": %s}}\n' "$branches_json" > "$work/.claude/project-config.defaults.json"
  fi
  echo "$work"
}

# ---------------------------------------------------------------------------
# CASE 1 + 2: well-formed config — matches configured branches, not others
# ---------------------------------------------------------------------------
case_well_formed_config() {
  local sandbox; sandbox=$(mktemp -d)
  local work; work=$(build_sandbox "$sandbox" '["main","dev","release/.*"]')

  local out
  out=$(cd "$work" && . .claude/hooks/_lib-protected-branches.sh && \
    if is_protected_branch "main"; then echo "PROTECTED"; else echo "SAFE"; fi)
  assert_eq "well-formed config: main is protected" "PROTECTED" "$out"

  out=$(cd "$work" && . .claude/hooks/_lib-protected-branches.sh && \
    if is_protected_branch "release/v1"; then echo "PROTECTED"; else echo "SAFE"; fi)
  assert_eq "well-formed config: release/v1 is protected (regex entry)" "PROTECTED" "$out"

  out=$(cd "$work" && . .claude/hooks/_lib-protected-branches.sh && \
    if is_protected_branch "feature/GH-1-safe"; then echo "PROTECTED"; else echo "SAFE"; fi)
  assert_eq "well-formed config: feature branch is NOT protected" "SAFE" "$out"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 3 + 4: malformed regex entry -> fail CLOSED, not "not protected"
#
# `"ma(in"` is an unbalanced-paren fragment: joined into the alternation
# and evaluated as `^(main|ma(in|dev)$`, grep -qE errors out (exit 2, "brk
# ket expression"/"unmatched ( or \(" depending on grep flavour) instead of
# returning a clean no-match. First reproduce the OLD bug (a hand-rolled
# guard identical to what .githooks/pre-push did before #1086 step 3) to
# prove it silently allows — then show is_protected_branch() does not.
# ---------------------------------------------------------------------------
case_malformed_regex_fails_closed() {
  local sandbox; sandbox=$(mktemp -d)
  local work; work=$(build_sandbox "$sandbox" '["main","ma(in","dev"]')

  # First: reproduce the OLD (pre-#1086-step-3) caller shape directly —
  # `command -v` guard + raw `grep -qE` against protected_branch_regex()'s
  # output, no fail-closed handling. This is the exact bug is_protected_branch
  # exists to replace.
  local old_behaviour
  old_behaviour=$(cd "$work" && . .claude/hooks/_lib-protected-branches.sh && \
    REGEX=$(protected_branch_regex) && \
    if echo "main" | grep -qE "^(${REGEX})\$" 2>/dev/null; then echo "OLD:PROTECTED"; else echo "OLD:SAFE"; fi)
  assert_eq "malformed regex, OLD hand-rolled guard: silently reads main as SAFE (the bug)" "OLD:SAFE" "$old_behaviour"

  # Now: the hardened predicate. Same malformed config, same branch — must
  # fail CLOSED (treat as protected) instead of inheriting the OLD bug.
  local new_behaviour
  new_behaviour=$(cd "$work" && . .claude/hooks/_lib-protected-branches.sh && \
    if is_protected_branch "main"; then echo "NEW:PROTECTED"; else echo "NEW:SAFE"; fi)
  assert_eq "malformed regex, is_protected_branch: main STILL protected (fail closed)" "NEW:PROTECTED" "$new_behaviour"

  # A WARN must accompany the fail-closed decision — not a silent block.
  local warn_out
  warn_out=$(cd "$work" && . .claude/hooks/_lib-protected-branches.sh && is_protected_branch "main" 2>&1 >/dev/null)
  assert_match "malformed regex: WARN emitted" "WARN:.*protected-branch pattern evaluation failed" "$warn_out"

  # A genuinely unrelated branch is ALSO fail-closed — the malformed entry
  # breaks the WHOLE composed regex (it's one alternation), not just its
  # own alternative, so every branch name is affected, not only "main".
  local unrelated
  unrelated=$(cd "$work" && . .claude/hooks/_lib-protected-branches.sh && \
    if is_protected_branch "totally-unrelated-branch-xyz"; then echo "PROTECTED"; else echo "SAFE"; fi)
  assert_eq "malformed regex: unrelated branch also fails closed" "PROTECTED" "$unrelated"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 5: protected_branch_regex renamed/removed -> WARN + fail closed
#
# Simulates a corrupted/partial lib file: source a version of the lib with
# protected_branch_regex renamed away, contrasted against the OLD
# `command -v protected_branch_regex` guard shape, which silently skips
# the whole check (no warning, no block) when the function is missing.
# ---------------------------------------------------------------------------
case_missing_function_fails_closed() {
  local sandbox; sandbox=$(mktemp -d)
  local work; work=$(build_sandbox "$sandbox" '["main"]')

  # Corrupt the copied lib: rename protected_branch_regex -> renamed_fn so
  # `command -v protected_branch_regex` genuinely fails, exactly like a
  # future refactor that renames the function without updating every caller.
  sed -i.bak 's/protected_branch_regex()/renamed_fn()/' "$work/.claude/hooks/_lib-protected-branches.sh"
  rm -f "$work/.claude/hooks/_lib-protected-branches.sh.bak"

  # OLD shape: a caller doing its own `command -v` guard silently skips the
  # entire check when the function is gone — no warning, reads as "allow".
  local old_behaviour
  old_behaviour=$(cd "$work" && . .claude/hooks/_lib-protected-branches.sh && \
    if command -v protected_branch_regex >/dev/null 2>&1; then echo "OLD:CHECK-RAN"; else echo "OLD:SILENTLY-SKIPPED"; fi)
  assert_eq "missing function, OLD guard shape: silently skips (the bug)" "OLD:SILENTLY-SKIPPED" "$old_behaviour"

  # NEW shape: is_protected_branch fails closed with a visible WARN.
  local new_behaviour
  new_behaviour=$(cd "$work" && . .claude/hooks/_lib-protected-branches.sh && \
    if is_protected_branch "main"; then echo "NEW:PROTECTED"; else echo "NEW:SAFE"; fi)
  assert_eq "missing function, is_protected_branch: fails closed (protected)" "NEW:PROTECTED" "$new_behaviour"

  local warn_out
  warn_out=$(cd "$work" && . .claude/hooks/_lib-protected-branches.sh && is_protected_branch "main" 2>&1 >/dev/null)
  assert_match "missing function: WARN emitted" "WARN:.*protected_branch_regex is unavailable" "$warn_out"

  # Even a branch that would obviously be safe (were the function present)
  # is fail-closed the same way — there is no way to evaluate ANY branch
  # once the resolver function itself is gone.
  local unrelated
  unrelated=$(cd "$work" && . .claude/hooks/_lib-protected-branches.sh && \
    if is_protected_branch "feature/GH-9-obviously-safe"; then echo "PROTECTED"; else echo "SAFE"; fi)
  assert_eq "missing function: an obviously-safe branch is ALSO fail-closed" "PROTECTED" "$unrelated"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 6: default fallback (no config at all) still protects the defaults
# ---------------------------------------------------------------------------
case_default_fallback() {
  local sandbox; sandbox=$(mktemp -d)
  local work; work=$(build_sandbox "$sandbox" "")

  for b in main master dev develop; do
    local out
    out=$(cd "$work" && . .claude/hooks/_lib-protected-branches.sh && \
      if is_protected_branch "$b"; then echo "PROTECTED"; else echo "SAFE"; fi)
    assert_eq "default fallback: $b is protected" "PROTECTED" "$out"
  done

  local out
  out=$(cd "$work" && . .claude/hooks/_lib-protected-branches.sh && \
    if is_protected_branch "feature/GH-1-safe"; then echo "PROTECTED"; else echo "SAFE"; fi)
  assert_eq "default fallback: feature branch is NOT protected" "SAFE" "$out"

  rm -rf "$sandbox"
}

case_well_formed_config
case_malformed_regex_fails_closed
case_missing_function_fails_closed
case_default_fallback

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
