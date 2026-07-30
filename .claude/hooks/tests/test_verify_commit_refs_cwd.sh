#!/bin/bash
# Tests for verify-commit-refs.sh cwd-vs-worktree resolution (me2resh/apexyard#1050)
#
# Bug: the hook resolved the tracker repo from `git rev-parse --show-toplevel`
# / `git remote get-url origin` run with NO `-C`, which means both commands
# used the HOOK PROCESS'S OWN cwd — not the directory the `git commit` is
# actually executing in. In a split-portfolio / worktree-based sub-agent
# session, the harness's Bash cwd for that call (the payload `.cwd` field,
# same field `suggest-mcp-reindex-after-pull.sh` already reads) can be a
# managed project's worktree while the hook process itself is invoked from
# the ops fork. The hook then validates `Closes #N` against the OPS FORK's
# tracker instead of the PROJECT's tracker, false-blocking a legitimate
# reference.
#
# Coverage:
#   - payload .cwd points at a different repo than the hook's own cwd →
#     the referenced issue exists ONLY in the .cwd repo → must PASS
#     (pre-fix: BLOCKS, because it checks the hook's own cwd's repo instead)
#   - explicit `git -C <path> commit ...` in the command → must resolve
#     against <path>'s repo, regardless of .cwd or the hook's own cwd
#   - `cd <path> && git commit ...` compound prefix → must resolve against
#     <path>'s repo
#   - no .cwd, no -C, no cd-prefix → falls back to the hook's own process
#     cwd, UNCHANGED from before the fix (no-regression case)
#
# Each case builds two isolated one-commit git sandboxes with different
# `origin` remotes (simulating the ops fork vs. a managed project's
# worktree), installs the shared mock `gh`, and pipes a synthetic
# PreToolUse JSON blob at the hook while the hook's OWN process cwd is
# deliberately the "wrong" sandbox.

set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/verify-commit-refs.sh"
# shellcheck source=_lib-mock-gh.sh
source "$(cd "$(dirname "$0")" && pwd)/_lib-mock-gh.sh"
if [ ! -x "$HOOK_SRC" ]; then
  echo "FAIL: hook not found or not executable at $HOOK_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

# Build a one-commit git sandbox with the given origin remote. No upstream
# remote (keeps the upstream-fallback branch out of play for these cases).
make_repo() {
  local origin_slug="$1"
  local rp
  rp=$(mktemp -d)
  (
    cd "$rp" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git remote add origin "git@github.com:${origin_slug}.git"
    touch README.md
    git add README.md
    git commit -q -m "init"
  )
  echo "$rp"
}

# Build the `git commit -m "..."` command string. $1 uses literal `\n` for
# newlines (for readability in the case table below); converted to REAL
# newlines here, same as test_verify_commit_refs_upstream.sh does, so the
# hook's REFS regex sees an actual word boundary before "Closes" / "Refs"
# instead of a literal backslash-n glued directly onto the prior word.
# $2 is an optional prefix prepended verbatim in front of `git commit`
# (e.g. "git -C /path/to/repo " or "cd /path/to/repo && ").
build_command() {
  local msg_literal="$1" prefix="${2:-}"
  local msg; msg=$(printf '%b' "$msg_literal")
  printf '%sgit commit -m "%s"' "$prefix" "$msg"
}

# Run the hook with:
#   - process cwd = $hook_cwd_repo (simulates the ops fork the hook is
#     invoked from)
#   - synthetic PreToolUse payload with the given .cwd (may be empty) and
#     command
# Prints combined captured stderr; rc is returned via $?.
run_hook() {
  local hook_cwd_repo="$1" payload_cwd="$2" command="$3"
  local input result rc
  if [ -n "$payload_cwd" ]; then
    input=$(jq -nc --arg c "$command" --arg cwd "$payload_cwd" \
      '{cwd:$cwd, tool_input:{command:$c}}')
  else
    input=$(jq -nc --arg c "$command" '{tool_input:{command:$c}}')
  fi
  result=$(cd "$hook_cwd_repo" && echo "$input" | bash "$HOOK_SRC" 2>&1 >/dev/null)
  rc=$?
  echo "$result"
  return "$rc"
}

assert_case() {
  local label="$1" got_output="$2" got_rc="$3" want_rc="$4" want_stderr_regex="$5"
  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_output:0:400})" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_output" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_output" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# ---- Case 1: payload .cwd is the source of truth, not the hook's own cwd ----
#
# Hook process cwd  = "ops" repo (origin: me2resh/apexyard)      — issue 500 MISSING
# Payload .cwd      = "proj" repo (origin: managed-org/example)  — issue 500 EXISTS
# A `git commit` with no -C and no cd-prefix, run with harness cwd = proj,
# must validate against proj's tracker (managed-org/example), not ops's.
{
  ops=$(make_repo "me2resh/apexyard")
  proj=$(make_repo "managed-org/example")
  mock_gh_install "$proj"
  mock_gh_set_repo_existence "$proj" 500 "managed-org/example" yes
  mock_gh_set_repo_existence "$proj" 500 "me2resh/apexyard" no

  cmd=$(build_command 'fix: worktree commit\n\nCloses #500')
  out=$(run_hook "$ops" "$proj" "$cmd")
  rc=$?
  assert_case "payload .cwd resolves to the project's own repo, not the hook's cwd" \
    "$out" "$rc" 0 ""
  rm -rf "$ops" "$proj"
}

# ---- Case 2: explicit `git -C <path>` in the command wins outright ----
#
# Hook process cwd AND payload .cwd both = "ops" repo (issue 501 missing there).
# The command itself carries `-C <proj>`, which must take priority over both.
{
  ops=$(make_repo "me2resh/apexyard")
  proj=$(make_repo "managed-org/example")
  mock_gh_install "$proj"
  mock_gh_set_repo_existence "$proj" 501 "managed-org/example" yes
  mock_gh_set_repo_existence "$proj" 501 "me2resh/apexyard" no

  cmd=$(build_command 'fix: dash-C commit\n\nCloses #501' "git -C ${proj} ")
  out=$(run_hook "$ops" "$ops" "$cmd")
  rc=$?
  assert_case "explicit git -C <path> resolves against that path's repo" \
    "$out" "$rc" 0 ""
  rm -rf "$ops" "$proj"
}

# ---- Case 3: `cd <path> && git commit ...` compound prefix ----
#
# Hook process cwd AND payload .cwd both = "ops" repo (issue 502 missing there).
# The command is a compound `cd <proj> && git commit ...` — the effective
# cwd for the git call is proj, even though nothing else says so.
{
  ops=$(make_repo "me2resh/apexyard")
  proj=$(make_repo "managed-org/example")
  mock_gh_install "$proj"
  mock_gh_set_repo_existence "$proj" 502 "managed-org/example" yes
  mock_gh_set_repo_existence "$proj" 502 "me2resh/apexyard" no

  cmd=$(build_command 'fix: cd-prefix commit\n\nCloses #502' "cd ${proj} && ")
  out=$(run_hook "$ops" "$ops" "$cmd")
  rc=$?
  assert_case "cd <path> && git commit prefix resolves against that path's repo" \
    "$out" "$rc" 0 ""
  rm -rf "$ops" "$proj"
}

# ---- Case 4: no-regression — no .cwd, no -C, no cd-prefix falls back to ----
# ---- the hook's own process cwd (today's exact behavior)                ----
{
  ops=$(make_repo "managed-org/example")
  mock_gh_install "$ops"
  mock_gh_set_repo_existence "$ops" 503 "managed-org/example" yes

  cmd=$(build_command 'fix: plain commit\n\nCloses #503')
  out=$(run_hook "$ops" "" "$cmd")
  rc=$?
  assert_case "no cwd/-C/cd-prefix hints → falls back to hook's own process cwd" \
    "$out" "$rc" 0 ""
  rm -rf "$ops"
}

# ---- Case 5: cwd mismatch producing a genuine block — the false-BLOCK ----
# ---- shape from the bug report: referenced issue exists ONLY in the    ----
# ---- project repo, hook (pre-fix) checks the wrong one and blocks.      ----
{
  ops=$(make_repo "me2resh/apexyard")
  proj=$(make_repo "managed-org/example")
  mock_gh_install "$proj"
  mock_gh_set_repo_existence "$proj" 504 "managed-org/example" yes
  mock_gh_set_repo_existence "$proj" 504 "me2resh/apexyard" no

  cmd=$(build_command 'fix: another worktree commit\n\nRefs #504')
  out=$(run_hook "$ops" "$proj" "$cmd")
  rc=$?
  assert_case "payload .cwd case again with Refs keyword → pass, not false-blocked" \
    "$out" "$rc" 0 ""
  rm -rf "$ops" "$proj"
}

# ---- Summary ------------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
