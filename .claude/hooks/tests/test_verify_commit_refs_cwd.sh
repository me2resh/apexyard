#!/bin/bash
# Tests for verify-commit-refs.sh cwd-vs-worktree resolution (me2resh/apexyard#1050)
# and its follow-up hijack fixes (PR #1073 review).
#
# Round 1 bug: the hook resolved the tracker repo from `git rev-parse
# --show-toplevel` / `git remote get-url origin` run with NO `-C`, which
# means both commands used the HOOK PROCESS'S OWN cwd — not the directory
# the `git commit` is actually executing in. In a split-portfolio /
# worktree-based sub-agent session, the harness's Bash cwd for that call
# (the payload `.cwd` field, same field suggest-mcp-reindex-after-pull.sh
# already reads) can be a managed project's worktree while the hook process
# itself is invoked from the ops fork. The hook then validated `Closes #N`
# against the OPS FORK's tracker instead of the PROJECT's, false-blocking a
# legitimate reference.
#
# Round 2 bug (caught in PR #1073 review, before merge): the round-1 fix
# passed the WHOLE raw command — including the commit MESSAGE — to the
# `-C`/`cd` scraper, and checked those scraped hints BEFORE the structured
# harness `.cwd` field. That combination is reachable in both directions:
#   - a commit MESSAGE containing the text `git -C <dir>` got scraped as
#     real shell syntax
#   - `git commit -m "..." && git -C /other log` — a `-C` belonging to a
#     LATER, unrelated git invocation bound to this commit
#   - `cd /real && git -C /other status && git commit` — same shape,
#     discarding the real governing `cd /real`
#   - a relative `cd ../sibling` resolved against the hook's own cwd — the
#     very cwd the round-1 fix exists to distrust
#   - a quoted path with spaces (`cd "/my path/repo"`) truncated at the
#     first space, silently reverting to pre-fix behavior
# The fix: strip the commit message out of the command before scanning
# (literal substring removal, not a regex), bind `-C` detection to THIS
# commit invocation only (immediately preceding the `commit` token, not
# anywhere else in the command), and check the harness `.cwd` FIRST —
# structured beats scraped — so the scraped fallback only matters when
# `.cwd` is genuinely absent.
#
# Coverage:
#   - payload .cwd points at a different repo than the hook's own cwd →
#     must resolve via .cwd (round-1 core case)
#   - payload .cwd wins outright even when the command ALSO carries a
#     competing, plausible-looking `-C` elsewhere (pins "structured beats
#     scraped" explicitly)
#   - explicit `git -C <path> commit ...`, .cwd ABSENT → resolves via the
#     command (round-1 fallback case, still covered)
#   - `cd <path> && git commit ...`, .cwd ABSENT → resolves via the command
#   - no .cwd, no -C, no cd-prefix → falls back to the hook's own process
#     cwd, UNCHANGED from before either fix (no-regression case)
#   - commit MESSAGE containing `git -C <dir>` text, .cwd ABSENT → must NOT
#     be scraped as real syntax (round-2 hijack, message-content direction)
#   - `git commit -m "..." && git -C <other> log`, .cwd ABSENT → the
#     trailing, unrelated `-C` must NOT bind to this commit (round-2 hijack)
#   - `cd <real> && git -C <other> status && git commit`, .cwd ABSENT → the
#     intervening, unrelated `-C` must NOT override the real governing `cd`
#   - `cd "<path with spaces>" && git commit ...`, .cwd ABSENT → a quoted,
#     spacey path must resolve correctly, not truncate at the first space
#   - a RELATIVE `cd ../sibling`, .cwd ABSENT → must NOT be trusted (only
#     absolute paths are accepted out of the scraped fallback); falls
#     through to the hook's own cwd rather than an ambiguous relative
#     resolution
#
# Each case builds one-or-two isolated one-commit git sandboxes with
# different `origin` remotes (simulating the ops fork vs. a managed
# project's worktree), installs the shared mock `gh`, and pipes a synthetic
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
# $2, if given, is a subdirectory name to create the repo inside (used to
# manufacture a path containing spaces).
make_repo() {
  local origin_slug="$1" subdir="${2:-}"
  local base rp
  base=$(mktemp -d)
  if [ -n "$subdir" ]; then
    rp="$base/$subdir"
    mkdir -p "$rp"
  else
    rp="$base"
  fi
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
# $2 is an optional prefix prepended verbatim BEFORE the `git` token (e.g.
# "cd /path/to/repo && "). $3 is optional FLAGS inserted BETWEEN `git` and
# `commit` (e.g. "-C /path/to/repo "). $4 is an optional SUFFIX appended
# after the closing quote of the -m value (e.g. ' && git -C /other log').
# Keeping prefix/flags/suffix as separate slots (rather than one combined
# string) avoids accidentally emitting a duplicated `git` token or losing
# track of exactly where the real commit invocation sits.
build_command() {
  local msg_literal="$1" prefix="${2:-}" flags="${3:-}" suffix="${4:-}"
  local msg; msg=$(printf '%b' "$msg_literal")
  printf '%sgit %scommit -m "%s"%s' "$prefix" "$flags" "$msg" "$suffix"
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

# ---- Case 1b: structured .cwd wins even when a competing -C is present ----
#
# Payload .cwd = proj (has the issue). The command ALSO carries a plausible
# `-C <decoy>` bound directly to this same commit invocation. Per the #1073
# review, structured beats scraped: .cwd must win outright and the `-C`
# must never even be considered. Set decoy's mock answer to "no" so a wrong
# resolution would BLOCK, making this a real discriminator.
{
  ops=$(make_repo "me2resh/apexyard")
  proj=$(make_repo "managed-org/example")
  decoy=$(make_repo "someone-else/decoy")
  mock_gh_install "$proj"
  mock_gh_set_repo_existence "$proj" 505 "managed-org/example" yes
  mock_gh_set_repo_existence "$proj" 505 "someone-else/decoy" no

  cmd=$(build_command 'fix: cwd beats a competing -C\n\nCloses #505' "" "-C ${decoy} ")
  out=$(run_hook "$ops" "$proj" "$cmd")
  rc=$?
  assert_case "payload .cwd wins outright over a competing in-command -C" \
    "$out" "$rc" 0 ""
  rm -rf "$ops" "$proj" "$decoy"
}

# ---- Case 2: explicit `git -C <path>` in the command, .cwd ABSENT ----
#
# No payload .cwd supplied. Hook process cwd = "ops" (issue 501 missing
# there). The command carries `-C <proj>` bound directly to this commit —
# with no structured .cwd to prefer, this scraped hint is what resolves it.
{
  ops=$(make_repo "me2resh/apexyard")
  proj=$(make_repo "managed-org/example")
  mock_gh_install "$proj"
  mock_gh_set_repo_existence "$proj" 501 "managed-org/example" yes
  mock_gh_set_repo_existence "$proj" 501 "me2resh/apexyard" no

  cmd=$(build_command 'fix: dash-C commit\n\nCloses #501' "" "-C ${proj} ")
  out=$(run_hook "$ops" "" "$cmd")
  rc=$?
  assert_case "explicit git -C <path> resolves against that path's repo (no .cwd)" \
    "$out" "$rc" 0 ""
  rm -rf "$ops" "$proj"
}

# ---- Case 3: `cd <path> && git commit ...` compound prefix, .cwd ABSENT ----
{
  ops=$(make_repo "me2resh/apexyard")
  proj=$(make_repo "managed-org/example")
  mock_gh_install "$proj"
  mock_gh_set_repo_existence "$proj" 502 "managed-org/example" yes
  mock_gh_set_repo_existence "$proj" 502 "me2resh/apexyard" no

  cmd=$(build_command 'fix: cd-prefix commit\n\nCloses #502' "cd ${proj} && ")
  out=$(run_hook "$ops" "" "$cmd")
  rc=$?
  assert_case "cd <path> && git commit prefix resolves against that path's repo (no .cwd)" \
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
# ---- shape from the round-1 bug report: referenced issue exists ONLY   ----
# ---- in the project repo; hook must resolve via .cwd, not block.       ----
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

# ---- Case 6: commit MESSAGE containing `git -C <dir>` text must not be ----
# ---- scraped as real shell syntax (round-2 hijack, message direction). ----
#
# No payload .cwd. Hook cwd = "real" (has the issue). The message's PROSE
# mentions a real, existing directory ("decoy", a different repo without
# the issue) via the literal text "git -C <decoy>". Pre-round-2-fix, the
# resolver scanned the WHOLE raw command (including this prose) and would
# have picked up "decoy" as though it were real command syntax, blocking a
# legitimate reference. Fixed: the message is stripped before scanning, so
# this text is never read as syntax; falls back to the hook's own cwd.
{
  real=$(make_repo "managed-org/real")
  decoy=$(make_repo "someone-else/decoy")
  mock_gh_install "$real"
  mock_gh_set_repo_existence "$real" 506 "managed-org/real" yes
  mock_gh_set_repo_existence "$real" 506 "someone-else/decoy" no

  cmd=$(build_command "fix: mentions git -C ${decoy} in prose\n\nSee git -C ${decoy} for the reproduction steps.\n\nCloses #506")
  out=$(run_hook "$real" "" "$cmd")
  rc=$?
  assert_case "commit message text 'git -C <dir>' is not scraped as real syntax" \
    "$out" "$rc" 0 ""
  rm -rf "$real" "$decoy"
}

# ---- Case 7: trailing, unrelated `git -C <dir> log` after the real ----
# ---- commit must not bind to it (round-2 hijack, row 3).             ----
#
# REGRESSION LOCK, not a discriminator: this shape happened to pass under
# BOTH the round-1 and round-2 implementations (verified — round-1's
# unscoped `tail -1` scrape didn't end up preferring the decoy here either),
# so it doesn't prove the round-2 fix by itself. Kept anyway to pin the
# behavior going forward, since the commit-boundary logic this depends on
# has since changed again (round 3, token-boundary fix below).
#
# No payload .cwd. Hook cwd = "real" (has the issue). The command has a
# real, separate `git -C <decoy> log` AFTER the actual commit invocation —
# a `-C` that belongs to a DIFFERENT git invocation, not this one.
{
  real=$(make_repo "managed-org/real")
  decoy=$(make_repo "someone-else/decoy")
  mock_gh_install "$real"
  mock_gh_set_repo_existence "$real" 507 "managed-org/real" yes
  mock_gh_set_repo_existence "$real" 507 "someone-else/decoy" no

  cmd=$(build_command 'fix: trailing unrelated -C\n\nCloses #507' "" "" " && git -C ${decoy} log")
  out=$(run_hook "$real" "" "$cmd")
  rc=$?
  assert_case "[regression lock] a trailing, unrelated 'git -C <dir> log' does not bind to this commit" \
    "$out" "$rc" 0 ""
  rm -rf "$real" "$decoy"
}

# ---- Case 8: governing `cd <real> &&` plus an INTERVENING unrelated  ----
# ---- `git -C <decoy> status &&` before the real commit (round-2      ----
# ---- hijack, row 4) — the intervening -C must not override the real  ----
# ---- governing cd.                                                    ----
{
  real=$(make_repo "managed-org/real")
  decoy=$(make_repo "someone-else/decoy")
  mock_gh_install "$real"
  mock_gh_set_repo_existence "$real" 508 "managed-org/real" yes
  mock_gh_set_repo_existence "$real" 508 "someone-else/decoy" no

  cmd=$(build_command 'fix: governing cd with intervening -C\n\nCloses #508' \
    "cd ${real} && git -C ${decoy} status && ")
  out=$(run_hook "$decoy" "" "$cmd")
  rc=$?
  assert_case "an intervening, unrelated 'git -C <dir> status' does not override the governing cd" \
    "$out" "$rc" 0 ""
  rm -rf "$real" "$decoy"
}

# ---- Case 9: quoted path with spaces must resolve correctly, not     ----
# ---- truncate at the first space (round-2 hijack, row 6).            ----
{
  base=$(mktemp -d)
  spacey=$(make_repo "managed-org/spacey" "my repo with spaces")
  ops=$(make_repo "me2resh/apexyard")
  mock_gh_install "$spacey"
  mock_gh_set_repo_existence "$spacey" 509 "managed-org/spacey" yes
  mock_gh_set_repo_existence "$spacey" 509 "me2resh/apexyard" no

  cmd=$(build_command 'fix: quoted spacey path\n\nCloses #509' "cd \"${spacey}\" && ")
  out=$(run_hook "$ops" "" "$cmd")
  rc=$?
  assert_case "a quoted cd path containing spaces resolves correctly, not truncated" \
    "$out" "$rc" 0 ""
  rm -rf "$base" "$spacey" "$ops"
}

# ---- Case 10: a RELATIVE cd path must not be trusted (round-2 hijack, ----
# ---- row 5) — only absolute scraped paths are honored; a relative one ----
# ---- falls through to the hook's own cwd rather than an ambiguous     ----
# ---- resolution against an unknown base.                              ----
{
  ops=$(make_repo "managed-org/example")
  mock_gh_install "$ops"
  mock_gh_set_repo_existence "$ops" 510 "managed-org/example" yes

  cmd=$(build_command 'fix: relative cd is not trusted\n\nCloses #510' "cd ../some-sibling && ")
  out=$(run_hook "$ops" "" "$cmd")
  rc=$?
  assert_case "a relative cd path is not trusted; falls back to the hook's own cwd" \
    "$out" "$rc" 0 ""
  rm -rf "$ops"
}

# ---- Cases 11-13: a directory whose NAME merely CONTAINS the substring ----
# ---- "commit" must not truncate the commit-boundary cut (round-3       ----
# ---- hijack — a real bug in the round-2 fix's own `${cmd%%commit*}`,   ----
# ---- caught end-to-end by the reviewer before merge).                  ----
#
# `${cmd%%commit*}` cuts at the first literal SUBSTRING "commit", not a
# token boundary — so a path component like "commitizen" or "commits-repo"
# truncates mid-directory. The truncated parent is usually not a git repo,
# so the (pre-fix) failure mode is FAIL-OPEN: TRACKER_REPO ends up empty,
# the hook hits the "could not resolve tracker repo — skipping" branch, and
# ref verification is silently disabled (same class as round-1's
# message-prose hijack, just a different trigger).
#
# Discriminator design: the referenced issue is set to NOT EXIST in the
# CORRECT (untruncated) repo's origin. If the fix correctly resolves the
# full path, the hook queries that origin, finds the ref missing, and
# BLOCKS (rc=2, "do not exist in <repo>"). If truncation still occurs, the
# truncated parent has no origin, TRACKER_REPO is empty, and the hook exits
# 0 via the skip branch instead — silently passing a fabricated ref. So
# rc=2 (not rc=0) is the proof that real verification happened against the
# right repo, and the stderr assertion additionally rules out the skip
# message appearing at all.

# Case 11: `cd <path>/commitizen && git commit` — reviewer's row 1 example.
{
  ops=$(make_repo "me2resh/apexyard")
  commitizen=$(make_repo "managed-org/tool" "commitizen")
  mock_gh_install "$commitizen"
  mock_gh_set_repo_existence "$commitizen" 511 "managed-org/tool" no

  cmd=$(build_command 'fix: cd into a dir named commitizen\n\nCloses #511' "cd ${commitizen} && ")
  out=$(run_hook "$ops" "" "$cmd")
  rc=$?
  assert_case "cd into .../commitizen resolves the FULL path, not truncated at 'commit'" \
    "$out" "$rc" 2 "do not exist"
  if echo "$out" | grep -qF "could not resolve tracker repo"; then
    echo "FAIL [cd .../commitizen]: silently skipped instead of verifying — output: ${out:0:300}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}cd-commitizen-silent-skip "
  fi
  rm -rf "$ops" "$commitizen"
}

# Case 12: `git -C <path>/commitizen commit` — reviewer's row 2 example.
{
  ops=$(make_repo "me2resh/apexyard")
  commitizen=$(make_repo "managed-org/tool2" "commitizen")
  mock_gh_install "$commitizen"
  mock_gh_set_repo_existence "$commitizen" 512 "managed-org/tool2" no

  cmd=$(build_command 'fix: -C into a dir named commitizen\n\nCloses #512' "" "-C ${commitizen} ")
  out=$(run_hook "$ops" "" "$cmd")
  rc=$?
  assert_case "git -C .../commitizen resolves the FULL path, not truncated at 'commit'" \
    "$out" "$rc" 2 "do not exist"
  if echo "$out" | grep -qF "could not resolve tracker repo"; then
    echo "FAIL [-C .../commitizen]: silently skipped instead of verifying — output: ${out:0:300}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}dash-C-commitizen-silent-skip "
  fi
  rm -rf "$ops" "$commitizen"
}

# Case 13: `cd <path>/commits-repo && git commit` — reviewer's row 3 example.
{
  ops=$(make_repo "me2resh/apexyard")
  commitsrepo=$(make_repo "managed-org/tool3" "commits-repo")
  mock_gh_install "$commitsrepo"
  mock_gh_set_repo_existence "$commitsrepo" 513 "managed-org/tool3" no

  cmd=$(build_command 'fix: cd into a dir named commits-repo\n\nCloses #513' "cd ${commitsrepo} && ")
  out=$(run_hook "$ops" "" "$cmd")
  rc=$?
  assert_case "cd into .../commits-repo resolves the FULL path, not truncated at 'commit'" \
    "$out" "$rc" 2 "do not exist"
  if echo "$out" | grep -qF "could not resolve tracker repo"; then
    echo "FAIL [cd .../commits-repo]: silently skipped instead of verifying — output: ${out:0:300}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}cd-commits-repo-silent-skip "
  fi
  rm -rf "$ops" "$commitsrepo"
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
