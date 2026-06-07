#!/bin/bash
# Smoke tests for .claude/hooks/pre-push-gate.sh
#
# Each case:
#   - sets up an isolated sandbox repo under $TMPDIR
#   - seeds a project-config.json with a specific `.pre_push.commands` array
#   - pipes a synthetic PreToolUse JSON blob into the hook
#   - asserts exit code + stderr contents
#
# Exit 0 if all cases pass; exit 1 on first failure with a clear message.

set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/pre-push-gate.sh"
if [ ! -x "$HOOK_SRC" ]; then
  echo "FAIL: hook not found or not executable at $HOOK_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

# -- sandbox builder -----------------------------------------------------
make_sandbox() {
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    touch onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session"
  cp "$HOOK_SRC" "$sb/.claude/hooks/pre-push-gate.sh"
  chmod +x "$sb/.claude/hooks/pre-push-gate.sh"

  # Copy the shared reader + shipped defaults so config lookups resolve
  # the same way they do in a real fork (same pattern as #115 test harness).
  local src_root
  src_root=$(cd "$(dirname "$0")/../../.." && pwd)
  if [ -f "$src_root/.claude/hooks/_lib-read-config.sh" ]; then
    cp "$src_root/.claude/hooks/_lib-read-config.sh" "$sb/.claude/hooks/_lib-read-config.sh"
  fi
  if [ -f "$src_root/.claude/project-config.defaults.json" ]; then
    cp "$src_root/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  fi
  echo "$sb"
}

push_json() {
  cat <<EOF
{"tool_input":{"command":"git push origin HEAD"}}
EOF
}

run_hook() {
  local sb="$1"
  local stdin_payload="$2"
  local want_rc="$3"
  local want_stderr_regex="$4"
  local label="$5"
  (
    cd "$sb" || exit 1
    echo "$stdin_payload" | bash .claude/hooks/pre-push-gate.sh 2>/tmp/pre-push-gate-stderr.$$
  )
  local got_rc=$?
  local got_stderr
  got_stderr=$(cat /tmp/pre-push-gate-stderr.$$ 2>/dev/null)
  rm -f /tmp/pre-push-gate-stderr.$$

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:200})" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# -------------------- CASE 1: non-git-push command --------------------
case1() {
  local sb; sb=$(make_sandbox)
  echo '{"tool_input":{"command":"ls -la"}}' | (cd "$sb" && bash .claude/hooks/pre-push-gate.sh 2>/dev/null)
  local rc=$?
  if [ "$rc" = "0" ]; then
    echo "PASS [non-git-push-silent]"
    PASS=$((PASS+1))
  else
    echo "FAIL [non-git-push-silent]: want rc=0, got $rc" >&2
    FAIL=$((FAIL+1))
  fi
  rm -rf "$sb"
}

# -------------------- CASE 2: empty commands → no-op --------------------
case2() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": []}}
EOF
  run_hook "$sb" "$(push_json)" 0 "" "empty-commands-noop"
  rm -rf "$sb"
}

# -------------------- CASE 3: passing command --------------------
case3() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "echo-ok", "run": "true"}]}}
EOF
  run_hook "$sb" "$(push_json)" 0 "" "passing-command"
  rm -rf "$sb"
}

# -------------------- CASE 4: failing command --------------------
case4() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "deliberate-fail", "run": "echo oops; exit 1"}]}}
EOF
  run_hook "$sb" "$(push_json)" 2 "deliberate-fail: FAILED" "failing-command-blocks"
  rm -rf "$sb"
}

# -------------------- CASE 5: skip marker in HEAD commit --------------------
case5() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "should-skip", "run": "exit 1"}]}}
EOF
  # Amend the HEAD commit message to include the skip marker.
  (cd "$sb" && git commit --amend -q -m "init

<!-- pre-push: skip -->")
  run_hook "$sb" "$(push_json)" 0 "pre-push gate bypassed by skip marker" "skip-marker-bypasses"
  rm -rf "$sb"
}

# -------------------- CASE 6: multiple commands, first fails --------------------
case6() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [
  {"name": "lint", "run": "exit 1"},
  {"name": "test", "run": "true"}
]}}
EOF
  run_hook "$sb" "$(push_json)" 2 "lint: FAILED" "fail-fast-on-first-red"
  rm -rf "$sb"
}

# -------------------- CASE 7: no config at all → no-op --------------------
case7() {
  local sb; sb=$(make_sandbox)
  # No project-config.json at all; defaults ship with empty commands.
  run_hook "$sb" "$(push_json)" 0 "" "no-config-noop"
  rm -rf "$sb"
}


# -------------------- CASE 8: untracked bad markdown → no failure --------------------
# Regression guard for #548: a markdownlint command driven by git ls-files must
# NOT lint untracked files, so a lint-dirty untracked .md must not block the push.
# The command string avoids \0 / null-delimiter JSON escapes (jq rejects \0);
# filenames in sandboxes are space-free so plain xargs (newline-split) is safe here.
case8() {
  local sb; sb=$(make_sandbox)
  # Configure markdownlint using git ls-files (the fixed command shape).
  # shellcheck disable=SC2016
  printf '%s\n' \
    '{"pre_push": {"commands": [{"name": "markdownlint", "run": "command -v npx >/dev/null 2>&1 || { echo INFO; exit 0; }; md_files=$(git ls-files '"'"'*.md'"'"' 2>/dev/null); [ -z \"$md_files\" ] && { echo INFO_SKIP; exit 0; }; echo \"$md_files\" | xargs npx --yes markdownlint-cli2 2>&1"}]}}' \
    > "$sb/.claude/project-config.json"
  # Drop a lint-dirty untracked markdown file.
  # Critically, this file is NOT `git add`-ed, so git ls-files will not see it.
  mkdir -p "$sb/.claude/skills/external-skill"
  printf '# Bad heading  \n- item without blank line\n' \
    > "$sb/.claude/skills/external-skill/DOCS.md"
  # Push must succeed: the untracked file must be invisible to markdownlint.
  run_hook "$sb" "$(push_json)" 0 "" "untracked-bad-md-ignored"
  rm -rf "$sb"
}

# -------------------- CASE 9: tracked bad markdown → failure --------------------
# Regression guard for #548: a lint error in a TRACKED markdown file must still
# block the push, so the fix does not weaken the gate for real content.
# Same command shape as case8 (space-safe xargs without -0, valid JSON).
case9() {
  local sb; sb=$(make_sandbox)
  # shellcheck disable=SC2016
  printf '%s\n' \
    '{"pre_push": {"commands": [{"name": "markdownlint", "run": "command -v npx >/dev/null 2>&1 || { echo INFO; exit 0; }; md_files=$(git ls-files '"'"'*.md'"'"' 2>/dev/null); [ -z \"$md_files\" ] && { echo INFO_SKIP; exit 0; }; echo \"$md_files\" | xargs npx --yes markdownlint-cli2 2>&1"}]}}' \
    > "$sb/.claude/project-config.json"
  # Create a lint-dirty markdown file and COMMIT it so git ls-files sees it.
  # MD047 (files-end-with-single-newline) is reliably detectable without a
  # markdownlint config: just omit the trailing newline.
  printf '# README\nno-trailing-newline' > "$sb/README.md"
  (cd "$sb" && git add README.md && git commit -q -m "chore: add bad README")
  # npx must be available for this case to be meaningful; skip gracefully if not.
  if ! command -v npx >/dev/null 2>&1; then
    echo "SKIP [tracked-bad-md-fails]: npx not available, case not executable"
    return
  fi
  run_hook "$sb" "$(push_json)" 2 "markdownlint: FAILED" "tracked-bad-md-fails"
  rm -rf "$sb"
}

case1; case2; case3; case4; case5; case6; case7; case8; case9

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
