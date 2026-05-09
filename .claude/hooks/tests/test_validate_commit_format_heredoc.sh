#!/bin/bash
# Tests for validate-commit-format.sh's heredoc-substitution skip (#194).
#
# When a commit is invoked as
#   git commit -m "$(cat <<'EOF'
#   subject
#   body
#   EOF
#   )"
# the harness sees the literal `$(cat <<'EOF' ... EOF )` string, not the
# expanded message. The hook's regex over the `-m` value cannot validate
# that string — it would always fail. Pre-194 the hook blocked these
# commits as "malformed subject". Post-194 the hook detects the substitution
# pattern and exits 0 with an INFO message suggesting `git commit -F file`
# for full validation on multi-line messages.
#
# Each case:
#   - builds an isolated sandbox with the hook + helpers
#   - pipes a synthetic PreToolUse JSON for a `git commit ...` command
#   - asserts exit code + (when relevant) stderr content
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/validate-commit-format.sh"
LIB_CFG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"

if [ ! -x "$HOOK_SRC" ]; then
  echo "FAIL: hook not found or not executable at $HOOK_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

make_sandbox() {
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    : > onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/validate-commit-format.sh"
  if [ -f "$LIB_CFG" ]; then cp "$LIB_CFG" "$sb/.claude/hooks/_lib-read-config.sh"; fi
  if [ -f "$DEFAULTS" ]; then cp "$DEFAULTS" "$sb/.claude/project-config.defaults.json"; fi
  chmod +x "$sb/.claude/hooks/validate-commit-format.sh"
  echo "$sb"
}

run_case() {
  local label="$1" cmd="$2" want_rc="$3" want_stderr_regex="$4"
  local sb; sb=$(make_sandbox)
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  local got_stderr got_rc
  got_stderr=$(cd "$sb" && echo "$input" | bash .claude/hooks/validate-commit-format.sh 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc" >&2
    echo "    cmd: ${cmd:0:200}" >&2
    echo "    stderr: ${got_stderr:0:300}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# -- Cases ---------------------------------------------------------------

# Heredoc-substitution shape — pre-194 this blocked; post-194 it skips with INFO.
HEREDOC_CMD='git commit -m "$(cat <<'\''EOF'\''
feat(#194): subject line from heredoc

body line 1
body line 2
EOF
)"'
run_case "heredoc-substitution: skip with INFO" \
  "$HEREDOC_CMD" 0 "heredoc-substitution detected"

# Variation: unquoted heredoc delimiter.
HEREDOC_NOQ_CMD='git commit -m "$(cat <<EOF
feat: subject
EOF
)"'
run_case "heredoc-substitution unquoted delim: skip with INFO" \
  "$HEREDOC_NOQ_CMD" 0 "heredoc-substitution detected"

# Variation: <<- (tab-stripping heredoc).
HEREDOC_DASH_CMD='git commit -m "$(cat <<-'\''EOF'\''
	feat: subject
	EOF
)"'
run_case "heredoc-substitution <<-: skip with INFO" \
  "$HEREDOC_DASH_CMD" 0 "heredoc-substitution detected"

# Plain non-substitution -m → still validated as before.
run_case "plain -m valid subject: pass silently" \
  'git commit -m "feat(#194): valid subject"' 0 ""

run_case "plain -m bad subject: BLOCK" \
  'git commit -m "not a valid subject line"' 2 "BLOCKED: Commit subject"

run_case "plain -m '\''quoted'\'' valid subject: pass" \
  "git commit -m 'fix: a fix'" 0 ""

# -F file path → no heredoc substitution involved, full validation runs.
# The skip pattern is anchored on `-m \$(cat <<` literally, so -F is never
# affected.
run_case "git commit -F (no -m): no heredoc skip applied" \
  'git commit -F /nonexistent/path' 0 ""

# A literal "$(cat <<" in a non--m position must NOT trigger the skip
# (e.g. `git commit -m "feat: subject" --trailer '...'` with a comment
# elsewhere). In practice this is hard to trigger without -m; this case
# documents the negative.
run_case "no heredoc-substitution: bad subject still blocks" \
  'git commit -m "junk"' 2 "BLOCKED: Commit subject"

# Non-commit command → no-op.
run_case "non-commit command exits 0 silently" \
  "git status" 0 ""

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
