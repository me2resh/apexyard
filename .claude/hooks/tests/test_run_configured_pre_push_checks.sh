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

# -------- CASE 8: session resolution cache is disabled, not trusted --------
# Hakim's A1 (PR #1428 review): config_get first checks a session-scoped
# cross-process cache file, keyed only by a (mtime, size) fingerprint with
# no path in it. A git hook shares its Claude Code session id with the
# session that invoked the push. This plants a cache entry with the
# fingerprint the sandbox's real config files carry, but a DIFFERENT
# command inside it, then proves the script never reads it.
#
# _sig mirrors _lib-resolution-cache.sh's _resolution_cache_file_sig: GNU
# `stat -c`, falling back to BSD/macOS `stat -f`.
_sig() {
  local f="$1" out
  out=$(stat -c '%Y:%s' "$f" 2>/dev/null)
  if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
  out=$(stat -f '%m:%z' "$f" 2>/dev/null)
  printf '%s' "$out"
}

case8() {
  local sb; sb=$(make_sandbox)
  # The resolution cache library must be present for this case — it is
  # what config_get consults before the disable-export takes effect.
  local src_root
  src_root=$(cd "$(dirname "$0")/../../.." && pwd)
  if [ -f "$src_root/.claude/hooks/_lib-resolution-cache.sh" ]; then
    cp "$src_root/.claude/hooks/_lib-resolution-cache.sh" "$sb/.claude/hooks/_lib-resolution-cache.sh"
  fi
  cat > "$sb/.claude/project-config.json" <<EOF
{"pre_push": {"commands": [{"name": "real", "run": "touch '$sb/REAL_RAN'"}]}}
EOF

  local pin_dir; pin_dir=$(mktemp -d)
  local sid="test-session-8"
  local fp
  fp="$(_sig "$sb/.claude/project-config.defaults.json")|$(_sig "$sb/.claude/project-config.json")"
  mkdir -p "$pin_dir"
  {
    printf '%s\n' "$fp"
    printf '%s\n' '{"pre_push": {"commands": [{"name": "poison", "run": "touch '"$sb"'/POISON_RAN"}]}}'
  } > "$pin_dir/resolve-cache-${sid}-config-json"

  # Fixed script (this PR's file, with the disable export): the poisoned
  # entry must be ignored. Only REAL_RAN may appear.
  (cd "$sb" && CLAUDE_CODE_SESSION_ID="$sid" APEXYARD_OPS_PIN_DIR="$pin_dir" \
    bash bin/run-configured-pre-push-checks.sh >/dev/null 2>&1)
  if [ -f "$sb/REAL_RAN" ] && [ ! -f "$sb/POISON_RAN" ]; then
    echo "PASS [A1-cache-poison-ignored-by-fixed-script]"
    PASS=$((PASS+1))
  else
    echo "FAIL [A1-cache-poison-ignored-by-fixed-script]: REAL_RAN=$([ -f "$sb/REAL_RAN" ] && echo yes || echo no) POISON_RAN=$([ -f "$sb/POISON_RAN" ] && echo yes || echo no)" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}A1-cache-poison-ignored-by-fixed-script "
  fi
  rm -f "$sb/REAL_RAN" "$sb/POISON_RAN"

  # Fail-before proof: strip the disable-export line from a scratch copy
  # of the SAME script and re-run against the SAME poisoned cache entry.
  # The unfixed copy must fall for the poison — proving the export is the
  # thing standing between the two outcomes, not something else in the
  # fixture.
  local unfixed="$sb/bin/run-configured-pre-push-checks-unfixed.sh"
  grep -v 'export APEXYARD_DISABLE_RESOLUTION_CACHE=1' \
    "$sb/bin/run-configured-pre-push-checks.sh" > "$unfixed"
  chmod +x "$unfixed"
  (cd "$sb" && CLAUDE_CODE_SESSION_ID="$sid" APEXYARD_OPS_PIN_DIR="$pin_dir" \
    bash bin/run-configured-pre-push-checks-unfixed.sh >/dev/null 2>&1)
  if [ -f "$sb/POISON_RAN" ]; then
    echo "PASS [A1-fail-before-unfixed-script-falls-for-poison]"
    PASS=$((PASS+1))
  else
    echo "FAIL [A1-fail-before-unfixed-script-falls-for-poison]: expected the unfixed copy to run the poisoned command" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}A1-fail-before-unfixed-script-falls-for-poison "
  fi

  rm -rf "$sb" "$pin_dir"
}

case1
case2
case3
case4
case5
case6
case7
case8

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
