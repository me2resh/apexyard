#!/bin/bash
# Tests for .githooks/pre-push's protected-branch enforcement — the git-
# native layer added in me2resh/apexyard#1086 step 2.
#
# WHY REAL GIT, NOT A STUBBED `git` ON PATH
# ------------------------------------------------------------------------
# The prior-review standard cited in the #1086 brief ("use a stubbed git on
# PATH so the push genuinely executes") was written for
# .claude/hooks/block-main-push.sh — a Claude-Code PreToolUse hook that
# decides allow/deny from a *simulated* tool_input.command, with the actual
# command never run by the test harness itself. There, a git stub is the
# only way to prove the DOWNSTREAM bash -c "$COMMAND" would really have
# reached (or not reached) git.
#
# .githooks/pre-push has no such simulated downstream step — it runs INSIDE
# the real git-push lifecycle, invoked by git itself with git's own
# resolved ref lines on stdin. A stub here would have to reimplement git's
# refspec/tag/HEAD/upstream-tracking resolution to hand the hook correct
# stdin — exactly the class of "reimplementation that has to be trusted to
# agree with the real thing" AgDR-0113 spent five review rounds arguing
# against. Running a REAL git binary against a REAL local bare "remote" and
# asserting on the remote's actual ref state after each push is a STRICTER
# proof of "the push genuinely executes or is genuinely rejected" than a
# stub could give, not a weaker one: there is nothing to reimplement, and
# nothing left to disagree with the real thing by construction.
#
# EACH "must block" CASE IS DISCRIMINATING BY CONSTRUCTION
# ------------------------------------------------------------------------
# Before #1086 step 2, .githooks/pre-push contained ZERO protected-branch
# logic — it only ever delegated to bin/run-pre-push-checks.sh (lint/format
# checks). Every "must block" case below therefore FAILS against the
# pre-change file (the push succeeds, the remote ref advances) and PASSES
# only once the new stdin-reading block exists. The "must NOT block" cases
# are regression controls, not novelty proofs — they already passed against
# the pre-change file (which blocked nothing) and exist here to catch
# OVER-narrowing introduced by this change, the mirror failure mode two
# prior predicates in block-main-push.sh were redesigned for.
#
# Cases:
#   1.  Feature-branch push                          -> NOT blocked
#   2.  Genuine tag push                              -> NOT blocked
#   3.  Two-remote tag push                           -> NOT blocked (both)
#   4.  Delete a NON-protected branch                 -> NOT blocked
#   5.  Bare `git push` while checked out on `main`   -> BLOCKED
#   6.  Explicit `git push origin main`               -> BLOCKED
#   7.  `--delete main` (deletion of protected branch) -> BLOCKED, remote main intact
#   8.  #1083 shape: redirect before the push          -> BLOCKED, remote main intact
#   9.  #1084 shape: decoy ref in unstripped heredoc,
#       then a bare (ref-less) push                    -> BLOCKED, remote main intact
#   10. #1085 shape: tag-push prefix + `git push origin HEAD` on main
#                                                        -> tags succeed, HEAD push BLOCKED
#   11. #1066 shape: heredoc prose merely discussing
#       `git push`, then a real push to main            -> BLOCKED, remote main intact
#
# Exit 0 if all cases pass; 1 on any failure.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REAL_PRE_PUSH="$ROOT/.githooks/pre-push"
REAL_PROTECTED_LIB="$ROOT/.claude/hooks/_lib-protected-branches.sh"
REAL_READ_CONFIG_LIB="$ROOT/.claude/hooks/_lib-read-config.sh"

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

assert_ne() {
  local label="$1" not_expected="$2" actual="$3"
  if [ "$not_expected" != "$actual" ]; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label] — expected NOT '$not_expected', got exactly that" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
  fi
}

# ---------------------------------------------------------------------------
# build_sandbox DIR
#
# Builds:
#   $DIR/remote.git  — a bare "remote" repo
#   $DIR/work        — a local working repo, `main` checked out, tracking
#                       origin/main, with the REAL .githooks/pre-push and its
#                       sourced libs installed via core.hooksPath.
#
# The remote's `main` is seeded via `git clone --bare` (not `git push`), so
# no push — and therefore no hook invocation — happens during setup. Only
# the pushes performed BY EACH TEST CASE go through the hook under test.
#
# bin/run-pre-push-checks.sh is stubbed to an immediate `exit 0` so cases
# aren't slowed down by (or made to depend on) markdownlint/shellcheck/npx
# being installed in the test environment — this suite tests the
# protected-branch block, not the lint check set, which has its own tests.
# ---------------------------------------------------------------------------
build_sandbox() {
  local dir="$1"
  local work="$dir/work"

  mkdir -p "$work"
  git -C "$work" init -q -b main
  git -C "$work" config user.name t
  git -C "$work" config user.email t@t.com

  mkdir -p "$work/.githooks"
  cp "$REAL_PRE_PUSH" "$work/.githooks/pre-push"
  chmod +x "$work/.githooks/pre-push"

  mkdir -p "$work/.claude/hooks"
  cp "$REAL_PROTECTED_LIB" "$work/.claude/hooks/_lib-protected-branches.sh"
  cp "$REAL_READ_CONFIG_LIB" "$work/.claude/hooks/_lib-read-config.sh"

  mkdir -p "$work/bin"
  printf '#!/bin/bash\nexit 0\n' > "$work/bin/run-pre-push-checks.sh"
  chmod +x "$work/bin/run-pre-push-checks.sh"

  git -C "$work" config core.hooksPath .githooks

  echo "seed" > "$work/README.md"
  git -C "$work" add README.md
  git -C "$work" commit -q -m "chore: init"

  git clone -q --bare "$work" "$dir/remote.git"
  git -C "$work" remote add origin "$dir/remote.git"
  git -C "$work" fetch -q origin
  git -C "$work" branch -q --set-upstream-to=origin/main main

  # Neutralise the bare remote's OWN denyDeleteCurrentBranch safety net
  # (git's server-side default refuses to delete whatever ref the bare
  # repo's HEAD points at — here, `main`). Without this, case 7's
  # "delete protected branch" assertions could pass for the WRONG reason —
  # the remote's own unrelated protection, not our LOCAL pre-push hook —
  # which would silently mask a broken hook. Disabling it here means the
  # only thing standing between a delete-main push and the remote is the
  # hook under test.
  git -C "$dir/remote.git" config receive.denyDeleteCurrent ignore
}

# A new, real commit on the currently checked-out branch — used so every
# "attempt to push main" case carries a genuine ref-update (local sha !=
# remote sha), not an accidental no-op that git might not even invoke the
# hook for.
new_commit() {
  local work="$1" msg="${2:-chore: advance}"
  date +%s%N >> "$work/README.md"
  git -C "$work" add README.md
  git -C "$work" commit -q -m "$msg" --allow-empty
}

remote_ref_sha() {
  local dir="$1" ref="$2"
  git -C "$dir/remote.git" rev-parse --verify "$ref" 2>/dev/null || echo "MISSING"
}

# ---------------------------------------------------------------------------
# CASE 1: feature-branch push -> NOT blocked
# ---------------------------------------------------------------------------
case_feature_branch_push_allowed() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"

  git -C "$work" checkout -q -b feature/GH-1-safe
  new_commit "$work"

  local out rc
  out=$(git -C "$work" push -u origin feature/GH-1-safe 2>&1); rc=$?
  assert_eq "feature branch push: exit code" "0" "$rc"
  assert_ne "feature branch push: remote ref created" "MISSING" "$(remote_ref_sha "$sandbox" refs/heads/feature/GH-1-safe)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 2: genuine tag push -> NOT blocked
# ---------------------------------------------------------------------------
case_genuine_tag_push_allowed() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"

  git -C "$work" tag v1.0.0-test

  local out rc
  out=$(git -C "$work" push origin v1.0.0-test 2>&1); rc=$?
  assert_eq "genuine tag push: exit code" "0" "$rc"
  assert_ne "genuine tag push: remote tag created" "MISSING" "$(remote_ref_sha "$sandbox" refs/tags/v1.0.0-test)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 3: two-remote tag push -> NOT blocked (both pushes succeed)
# ---------------------------------------------------------------------------
case_two_remote_tag_push_allowed() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"

  git clone -q --bare "$work" "$sandbox/upstream.git"
  git -C "$work" remote add upstream "$sandbox/upstream.git"
  git -C "$work" tag v2.0.0-test

  local out rc
  out=$(git -C "$work" push origin --tags 2>&1 && git -C "$work" push upstream --tags 2>&1); rc=$?
  assert_eq "two-remote tag push: exit code" "0" "$rc"
  assert_ne "two-remote tag push: origin has tag" "MISSING" "$(remote_ref_sha "$sandbox" refs/tags/v2.0.0-test)"
  assert_ne "two-remote tag push: upstream has tag" "MISSING" "$(git -C "$sandbox/upstream.git" rev-parse --verify refs/tags/v2.0.0-test 2>/dev/null || echo MISSING)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 4: delete a NON-protected branch -> NOT blocked
# ---------------------------------------------------------------------------
case_delete_nonprotected_allowed() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"

  git -C "$work" checkout -q -b feature/GH-2-doomed
  new_commit "$work"
  git -C "$work" push -q -u origin feature/GH-2-doomed
  git -C "$work" checkout -q main

  local out rc
  out=$(git -C "$work" push origin --delete feature/GH-2-doomed 2>&1); rc=$?
  assert_eq "delete non-protected: exit code" "0" "$rc"
  assert_eq "delete non-protected: remote ref gone" "MISSING" "$(remote_ref_sha "$sandbox" refs/heads/feature/GH-2-doomed)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 5: bare `git push` while checked out on `main` -> BLOCKED
# ---------------------------------------------------------------------------
case_bare_push_on_main_blocked() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"
  local before; before=$(remote_ref_sha "$sandbox" refs/heads/main)

  new_commit "$work"

  local out rc
  out=$(git -C "$work" push 2>&1); rc=$?
  assert_ne "bare push on main: exit code non-zero" "0" "$rc"
  assert_match "bare push on main: BLOCKED message" "BLOCKED.*protected branch 'main'" "$out"
  assert_eq "bare push on main: remote main unchanged" "$before" "$(remote_ref_sha "$sandbox" refs/heads/main)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 6: explicit `git push origin main` -> BLOCKED
# ---------------------------------------------------------------------------
case_explicit_push_main_blocked() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"
  local before; before=$(remote_ref_sha "$sandbox" refs/heads/main)

  new_commit "$work"

  local out rc
  out=$(git -C "$work" push origin main 2>&1); rc=$?
  assert_ne "explicit push origin main: exit code non-zero" "0" "$rc"
  assert_match "explicit push origin main: BLOCKED message" "BLOCKED.*protected branch 'main'" "$out"
  assert_eq "explicit push origin main: remote main unchanged" "$before" "$(remote_ref_sha "$sandbox" refs/heads/main)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 7: `git push origin --delete main` -> BLOCKED, remote main intact
#
# This is the deletion / all-zeroes-local-sha case. Also the exact shape
# .claude/hooks/block-main-push.sh does NOT catch when run from a feature-
# branch checkout (its extract_push_ref bails on --delete and falls back to
# validating the CURRENT branch instead of the one being deleted) — proving
# this blocks here demonstrates the git-native layer closes that gap too.
# ---------------------------------------------------------------------------
case_delete_protected_blocked() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"
  local before; before=$(remote_ref_sha "$sandbox" refs/heads/main)

  # Deliberately checked out on a DIFFERENT branch — the exact shape
  # block-main-push.sh's text-based fallback gets wrong.
  git -C "$work" checkout -q -b feature/GH-3-bystander

  local out rc
  out=$(git -C "$work" push origin --delete main 2>&1); rc=$?
  assert_ne "delete protected (main): exit code non-zero" "0" "$rc"
  assert_match "delete protected (main): BLOCKED message says delete" "BLOCKED: Deleting protected branch 'main'" "$out"
  assert_eq "delete protected (main): remote main intact" "$before" "$(remote_ref_sha "$sandbox" refs/heads/main)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 8 (#1083 shape): a redirect/pipe BEFORE the push -> still BLOCKED
# ---------------------------------------------------------------------------
case_1083_redirect_before_push_blocked() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"
  local before; before=$(remote_ref_sha "$sandbox" refs/heads/main)

  new_commit "$work"

  local out rc
  out=$(cd "$work" && echo x > "$sandbox/scratch.txt" && git push origin main 2>&1); rc=$?
  assert_ne "#1083 redirect-before-push: exit code non-zero" "0" "$rc"
  assert_match "#1083 redirect-before-push: BLOCKED message" "BLOCKED.*protected branch 'main'" "$out"
  assert_eq "#1083 redirect-before-push: remote main unchanged" "$before" "$(remote_ref_sha "$sandbox" refs/heads/main)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 9 (#1084 shape): decoy ref inside an unterminated/unconfirmed
# heredoc, then a genuinely bare (ref-less) push -> still BLOCKED
# ---------------------------------------------------------------------------
case_1084_decoy_heredoc_then_bare_push_blocked() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"
  local before; before=$(remote_ref_sha "$sandbox" refs/heads/main)

  new_commit "$work"

  local out rc
  out=$(cd "$work" && cat > "$sandbox/m.txt" <<'END.OF'
see git push origin feature/GH-1-safe
END.OF
git push 2>&1); rc=$?
  assert_ne "#1084 decoy-heredoc-then-bare-push: exit code non-zero" "0" "$rc"
  assert_match "#1084 decoy-heredoc-then-bare-push: BLOCKED message" "BLOCKED.*protected branch 'main'" "$out"
  assert_eq "#1084 decoy-heredoc-then-bare-push: remote main unchanged" "$before" "$(remote_ref_sha "$sandbox" refs/heads/main)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 10 (#1085 shape): a genuine tag-push prefix, followed by
# `git push origin HEAD` on `main` -> tags succeed, HEAD push BLOCKED
# ---------------------------------------------------------------------------
case_1085_tag_prefix_then_head_push_blocked() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"
  local before; before=$(remote_ref_sha "$sandbox" refs/heads/main)

  git -C "$work" tag v3.0.0-test
  new_commit "$work"

  local out rc
  out=$(cd "$work" && git push origin --tags && git push origin HEAD 2>&1); rc=$?
  assert_ne "#1085 tag-prefix-then-HEAD-push: exit code non-zero" "0" "$rc"
  assert_ne "#1085 tag-prefix-then-HEAD-push: tag DID push" "MISSING" "$(remote_ref_sha "$sandbox" refs/tags/v3.0.0-test)"
  assert_eq "#1085 tag-prefix-then-HEAD-push: remote main unchanged" "$before" "$(remote_ref_sha "$sandbox" refs/heads/main)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 11 (#1066 shape): heredoc prose merely DISCUSSING `git push`, then a
# real push to `main` -> BLOCKED (the decoy prose changes nothing; the real
# push is what's evaluated, because nothing here ever parses command text)
# ---------------------------------------------------------------------------
case_1066_heredoc_prose_then_real_push_blocked() {
  local sandbox; sandbox=$(mktemp -d)
  build_sandbox "$sandbox"
  local work="$sandbox/work"
  local before; before=$(remote_ref_sha "$sandbox" refs/heads/main)

  new_commit "$work"

  local out rc
  out=$(cd "$work" && cat > "$sandbox/m2.txt" <<EOF
The previous commit claimed terminal git push still runs the checks because
bin/run-pre-push-checks.sh hardcodes them.
EOF
git push origin main 2>&1); rc=$?
  assert_ne "#1066 heredoc-prose-then-real-push: exit code non-zero" "0" "$rc"
  assert_match "#1066 heredoc-prose-then-real-push: BLOCKED message" "BLOCKED.*protected branch 'main'" "$out"
  assert_eq "#1066 heredoc-prose-then-real-push: remote main unchanged" "$before" "$(remote_ref_sha "$sandbox" refs/heads/main)"

  rm -rf "$sandbox"
}

if [ ! -f "$REAL_PRE_PUSH" ]; then
  echo "FAIL: .githooks/pre-push not found at $REAL_PRE_PUSH" >&2
  exit 1
fi
if [ ! -f "$REAL_PROTECTED_LIB" ]; then
  echo "FAIL: .claude/hooks/_lib-protected-branches.sh not found at $REAL_PROTECTED_LIB" >&2
  exit 1
fi

case_feature_branch_push_allowed
case_genuine_tag_push_allowed
case_two_remote_tag_push_allowed
case_delete_nonprotected_allowed
case_bare_push_on_main_blocked
case_explicit_push_main_blocked
case_delete_protected_blocked
case_1083_redirect_before_push_blocked
case_1084_decoy_heredoc_then_bare_push_blocked
case_1085_tag_prefix_then_head_push_blocked
case_1066_heredoc_prose_then_real_push_blocked

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
