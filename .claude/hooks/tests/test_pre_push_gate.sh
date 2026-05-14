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

case1; case2; case3; case4; case5; case6; case7

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
