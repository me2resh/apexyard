#!/bin/bash
# Smoke tests for bin/run-configured-pre-push-checks.sh (me2resh/apexyard#1366,
# AgDR-0173) — the git-native runner for a repository's own configured
# `.pre_push.commands`.
#
# This script replaces the command-execution half of the pre-#1366
# `.claude/hooks/pre-push-gate.sh`. It is invoked by `.githooks/pre-push`,
# so its working directory is always the repository git itself resolved
# for the push — there is no command text to parse, and therefore no
# target to get wrong.
#
# Each case sets up an isolated sandbox repo under $TMPDIR, seeds a
# project-config.json with a specific `.pre_push.commands` array, runs the
# script with $PWD inside the sandbox (mirroring how .githooks/pre-push
# invokes it), and asserts exit code + stderr contents.
#
# Exit 0 if all cases pass; exit 1 on first failure with a clear message.

set -u

SCRIPT_SRC="$(cd "$(dirname "$0")/../../.." && pwd)/bin/run-configured-pre-push-checks.sh"
if [ ! -x "$SCRIPT_SRC" ]; then
  echo "FAIL: script not found or not executable at $SCRIPT_SRC" >&2
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
  mkdir -p "$sb/.claude/hooks" "$sb/bin"
  cp "$SCRIPT_SRC" "$sb/bin/run-configured-pre-push-checks.sh"
  chmod +x "$sb/bin/run-configured-pre-push-checks.sh"

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

run_script() {
  local sb="$1"
  local want_rc="$2"
  local want_stderr_regex="$3"
  local label="$4"
  local got_rc got_stderr
  got_stderr=$(cd "$sb" && bash bin/run-configured-pre-push-checks.sh 2>&1 1>/dev/null)
  got_rc=$?

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

# -------------------- CASE 1: empty commands -> no-op --------------------
case1() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": []}}
EOF
  run_script "$sb" 0 "" "empty-commands-noop"
  rm -rf "$sb"
}

# -------------------- CASE 2: no config at all -> no-op --------------------
case2() {
  local sb; sb=$(make_sandbox)
  run_script "$sb" 0 "" "no-config-noop"
  rm -rf "$sb"
}

# -------------------- CASE 3: passing command --------------------
case3() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "echo-ok", "run": "true"}]}}
EOF
  run_script "$sb" 0 "" "passing-command"
  rm -rf "$sb"
}

# -------------------- CASE 4: failing command blocks --------------------
case4() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "deliberate-fail", "run": "echo oops; exit 1"}]}}
EOF
  run_script "$sb" 1 "BLOCKED: configured pre-push check failed: deliberate-fail" "failing-command-blocks"
  rm -rf "$sb"
}

# -------------------- CASE 5: skip marker bypasses --------------------
case5() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "should-skip", "run": "exit 1"}]}}
EOF
  (cd "$sb" && git commit --amend -q -m "init

<!-- pre-push: skip -->")
  run_script "$sb" 0 "bypassed by skip marker" "skip-marker-bypasses"
  rm -rf "$sb"
}

# -------------------- CASE 6: fail-fast on first red --------------------
case6() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [
  {"name": "lint", "run": "exit 1"},
  {"name": "test", "run": "true"}
]}}
EOF
  run_script "$sb" 1 "BLOCKED: configured pre-push check failed: lint" "fail-fast-on-first-red"
  rm -rf "$sb"
}

# -------------------- CASE 7: config read pins to $REPO_ROOT --------------
# me2resh/apexyard#1405 review, finding B1: `_config_repo_root`'s ops-fork
# walk-up would resolve to an ENCLOSING ops fork's config instead of a
# project nested under it (e.g. workspace/<name>/), because that fork also
# carries the .apexyard-fork anchor. This script pins _CONFIG_ROOT_CACHE
# to $REPO_ROOT before calling config_get, bypassing that walk-up. Build a
# fake ops fork enclosing the sandbox and prove the SANDBOX's own config —
# not the enclosing fork's — is what runs.
case7() {
  local outer; outer=$(mktemp -d)
  touch "$outer/.apexyard-fork"
  mkdir -p "$outer/.claude/hooks"
  local src_root
  src_root=$(cd "$(dirname "$0")/../../.." && pwd)
  cp "$src_root/.claude/hooks/_lib-read-config.sh" "$outer/.claude/hooks/_lib-read-config.sh"
  if [ -f "$src_root/.claude/hooks/_lib-ops-root.sh" ]; then
    cp "$src_root/.claude/hooks/_lib-ops-root.sh" "$outer/.claude/hooks/_lib-ops-root.sh"
  fi
  cat > "$outer/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "outer-fork-check", "run": "exit 1"}]}}
EOF

  local sb="$outer/workspace/proj"
  mkdir -p "$sb"
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    touch onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks" "$sb/bin"
  cp "$SCRIPT_SRC" "$sb/bin/run-configured-pre-push-checks.sh"
  chmod +x "$sb/bin/run-configured-pre-push-checks.sh"
  cp "$src_root/.claude/hooks/_lib-read-config.sh" "$sb/.claude/hooks/_lib-read-config.sh"
  if [ -f "$src_root/.claude/hooks/_lib-ops-root.sh" ]; then
    cp "$src_root/.claude/hooks/_lib-ops-root.sh" "$sb/.claude/hooks/_lib-ops-root.sh"
  fi
  if [ -f "$src_root/.claude/project-config.defaults.json" ]; then
    cp "$src_root/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  fi
  # The PROJECT's own config passes. If config resolution leaked up to the
  # outer fork's failing command, this would block instead.
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "project-own-check", "run": "true"}]}}
EOF
  run_script "$sb" 0 "" "workspace-nested-layout-uses-own-config-not-enclosing-fork"
  rm -rf "$outer"
}

case1
case2
case3
case4
case5
case6
case7

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
