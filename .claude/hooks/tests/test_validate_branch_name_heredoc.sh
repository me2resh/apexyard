#!/bin/bash
# Hook-level regression test for me2resh/apexyard#1066.
#
# The bug: `extract_push_ref` returned the first "git push"-shaped text
# ANYWHERE in the raw command, including inside a heredoc body that merely
# *mentions* git push in prose (this repo's own commit messages routinely
# discuss git behaviour). validate-branch-name.sh then validated a word from
# the prose as if it were the real branch name, and blocked a legitimate,
# correctly-named push.
#
# Each case builds a sandbox whose LOCAL branch is intentionally
# non-conforming ("not-conforming-branch-name"), so a fallback-to-local-HEAD
# would ALSO fail — the only way a case passes is if the real push ref
# embedded after the heredoc is what actually gets validated.
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/validate-branch-name.sh"
LIB_SRC="$SRC_ROOT/.claude/hooks/_lib-extract-push-ref.sh"
LIB_STRIP_HEREDOC_SRC="$SRC_ROOT/.claude/hooks/_lib-strip-heredoc.sh"
LIB_CONFIG_SRC="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
LIB_PR_REPO_SRC="$SRC_ROOT/.claude/hooks/_lib-pr-repo.sh"
# me2resh/apexyard#1102 / AgDR-0118: _lib-extract-push-ref.sh's
# self-location now sources _lib-ops-root.sh (via the shared
# resolve_anchored_lib_dir guard) before it can reach _lib-strip-heredoc.sh
# — every sandbox that ships the push-ref lib must ship this too, or the
# heredoc stripper never gets loaded and heredoc bodies leak into parsing.
LIB_OPS_ROOT_SRC="$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"

for f in "$HOOK_SRC" "$LIB_SRC" "$LIB_STRIP_HEREDOC_SRC"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

make_sandbox_with_wrong_local_branch() {
  local sb local_branch="${1:-not-conforming-branch-name}"
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    : > onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
    git checkout -q -B "$local_branch"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/validate-branch-name.sh"
  cp "$LIB_SRC"  "$sb/.claude/hooks/_lib-extract-push-ref.sh"
  if [ -f "$LIB_OPS_ROOT_SRC" ]; then
    cp "$LIB_OPS_ROOT_SRC" "$sb/.claude/hooks/_lib-ops-root.sh"
  fi
  if [ -f "$LIB_STRIP_HEREDOC_SRC" ]; then
    cp "$LIB_STRIP_HEREDOC_SRC" "$sb/.claude/hooks/_lib-strip-heredoc.sh"
  fi
  if [ -f "$LIB_CONFIG_SRC" ]; then
    cp "$LIB_CONFIG_SRC" "$sb/.claude/hooks/_lib-read-config.sh"
  fi
  if [ -f "$LIB_PR_REPO_SRC" ]; then
    cp "$LIB_PR_REPO_SRC" "$sb/.claude/hooks/_lib-pr-repo.sh"
  fi
  if [ -f "$SRC_ROOT/.claude/project-config.defaults.json" ]; then
    cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  fi
  chmod +x "$sb/.claude/hooks/validate-branch-name.sh"
  echo "$sb"
}

run_case() {
  local label="$1" cmd="$2" want_rc="$3"
  local sb; sb=$(make_sandbox_with_wrong_local_branch)
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  local got_rc got_stderr
  got_stderr=$(cd "$sb" && echo "$input" | bash .claude/hooks/validate-branch-name.sh 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc" >&2
    echo "    cmd: $cmd" >&2
    echo "    stderr: ${got_stderr:0:300}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# ---- #1066: the ticket's exact deterministic repro -----------------------
# Local branch is "not-conforming-branch-name" (would fail if used as
# fallback). Only a correct extraction of the REAL push ref passes this.
run_case "#1066: heredoc prose mentions 'git push', real push ref still validated" \
"$(cat <<'CMD'
cat > /tmp/m.txt <<EOF
The previous commit claimed terminal `git push` still runs the checks because
bin/run-pre-push-checks.sh hardcodes them.
EOF
git commit -F /tmp/m.txt
git push upstream fix/GH-1031-untrack-project-config-json
CMD
)" 0

# Same shape, but the REAL push ref is non-conforming -- must still BLOCK.
# Proves the fix didn't just make the hook permissive.
run_case "#1066: heredoc prose + real push ref is non-conforming -> still blocks" \
"$(cat <<'CMD'
cat > /tmp/m.txt <<EOF
The previous commit claimed terminal `git push` still runs the checks because
bin/run-pre-push-checks.sh hardcodes them.
EOF
git commit -F /tmp/m.txt
git push upstream bogus-branch-no-ticket
CMD
)" 2

# The reviewer-prose variant from the ticket's investigation notes: an arrow
# character and a quoted `git commit -m` inside a heredoc, with NO real push
# anywhere in the command at all -> the gate has nothing to check -> no-op.
run_case "#1066: heredoc-only prose (arrow + quoted commit), no real push -> no-op" \
"$(cat <<'CMD'
cat > /tmp/rev.txt <<EOF
The branch validator matched a -> character in review prose, and a quoted
`git commit -m "wip"` inside a heredoc was treated as a real commit.
EOF
echo done
CMD
)" 0

# Single-quoted heredoc terminator variant.
run_case "#1066: single-quoted <<'EOF' heredoc prose stripped, real push validated" \
"$(cat <<'CMD'
cat > /tmp/n.txt <<'EOF'
prose says git push origin some-other-branch
EOF
git push origin feature/GH-1066-heredoc-fix
CMD
)" 0

# ---- me2resh/apexyard#1081: decoy tag-push evidence must not hide a real,
#      non-conforming push from validation --------------------------------
#
# The bug (fixed here the same way #1075 fixed it for block-main-push.sh):
# is_tag_push's TRUE verdict is a WHOLE-COMMAND signal, so decoy tag-push
# evidence sitting in prose the heredoc stripper correctly declines to
# strip (an unconfirmed delimiter) made this hook `exit 0` before ever
# validating the REAL push's destination in the same command. Both cases
# below are proven RED against the pre-fix code (git stash) before the fix,
# per this repo's own governance rule for this bug class.

# Shape 1 — the ticket's own repro: dotted-delimiter heredoc carries decoy
# "--tags" prose, immediately followed by a real, non-conforming push.
# Pre-fix: is_tag_push("--tags" in decoy) -> true -> exit 0 (ALLOWED, wrong).
# Post-fix: the real push has no tag evidence of its own and no OTHER
# occurrence to lean on -> untrusted -> validated -> BLOCKS.
run_case "#1081: decoy --tags in unconfirmed heredoc must not hide a non-conforming push" \
"$(cat <<'CMD'
cat > /tmp/m.txt <<END.OF
we always use git push --tags for releases
END.OF
git push origin bogus-branch
CMD
)" 2

# Shape 2 — same decoy shape, but the real push IS conforming. Must still
# pass (the fix must not over-block a legitimate push just because a decoy
# is present elsewhere in the command).
run_case "#1081: decoy --tags in unconfirmed heredoc, real push conforms -> still passes" \
"$(cat <<'CMD'
cat > /tmp/m.txt <<END.OF
we always use git push --tags for releases
END.OF
git push origin feature/GH-1081-decoy-fix
CMD
)" 0

# Control: a genuine tag push with NO decoy and no heredoc must remain
# exempt (the fix must not make is_tag_push untrustworthy in general).
run_case "#1081 control: genuine tag push, no decoy -> still a no-op" \
  "git push origin --tags" 0

# ---- Regression: plain (no heredoc) cases from #194/#547 must be intact --
run_case "regression: plain conforming push still passes" \
  "git push origin feature/GH-194-worktree-cwd-hooks" 0
run_case "regression: plain non-conforming push still blocks" \
  "git push origin bogus-branch" 2
run_case "regression: tag push still a no-op" \
  "git push origin --tags" 0

# ---- Summary ---------------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
