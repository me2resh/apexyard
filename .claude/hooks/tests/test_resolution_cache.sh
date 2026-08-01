#!/bin/bash
# Tests for .claude/hooks/_lib-resolution-cache.sh and its wiring into
# _lib-read-config.sh + _lib-portfolio-paths.sh (me2resh/apexyard#1013 /
# AgDR-0120).
#
# Each case builds an isolated sandbox apexyard-fork fixture under a fresh
# mktemp dir, with its own project-config + registry, and drives the libs
# with an explicit CLAUDE_CODE_SESSION_ID + APEXYARD_OPS_PIN_DIR scoped to
# that case — never the real session id / pin dir (see bin/run-hook-tests.sh's
# suite-level APEXYARD_DISABLE_RESOLUTION_CACHE=1 export, which this file's
# cases override per-case to actually exercise the cache).
#
# Cases:
#   1. Cold cache produces IDENTICAL results to the cache-disabled path
#   2. Cross-process reuse: a second process (same session) does not redo
#      _config_load's jq -s merge (proven via a logging jq shim)
#   3. Cross-process reuse: a second process does not redo a portfolio
#      resolver's _portfolio_get call (proven via a call-counting wrapper)
#   4. Staleness: editing project-config.json mid-session is picked up on
#      the very next read, never served stale (config value AND a
#      dependent portfolio path)
#   5. A cache file whose stored fingerprint is deliberately "UNKNOWN" is
#      NEVER treated as a hit, even if a (buggy) caller passed "UNKNOWN"
#      as the expected fingerprint
#   6. An ops-root mismatch is never trusted (fingerprint components are
#      compared as a whole; forging just the value half is rejected)
#   7. Unwritable cache directory degrades to current behaviour: correct
#      value still returned, no error text on stdout, no crash
#   8. APEXYARD_DISABLE_RESOLUTION_CACHE=1 -> zero cache files ever written
#   9. No CLAUDE_CODE_SESSION_ID -> zero cache files ever written
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOKS="$SRC_ROOT/.claude/hooks"
RC_LIB="$HOOKS/_lib-resolution-cache.sh"
CONFIG_LIB="$HOOKS/_lib-read-config.sh"
PORTFOLIO_LIB="$HOOKS/_lib-portfolio-paths.sh"
OPS_ROOT_LIB="$HOOKS/_lib-ops-root.sh"
DEFAULTS_SRC="$SRC_ROOT/.claude/project-config.defaults.json"

for f in "$RC_LIB" "$CONFIG_LIB" "$PORTFOLIO_LIB" "$OPS_ROOT_LIB" "$DEFAULTS_SRC"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file not found at $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

mark_pass() { echo "  PASS: $1"; }
mark_fail() { echo "  FAIL: $1: $2" >&2; }

run_case() {
  local fn="$1"
  if "$fn"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES $fn"
  fi
}

# ---------------------------------------------------------------------------
# make_fork: build an isolated apexyard-fork sandbox with the libs +
# defaults file + minimal registry/projects_dir. Optionally an overrides
# file (project-config.json) so the jq -s merge path is exercised.
# Echoes the sandbox path.
# ---------------------------------------------------------------------------
make_fork() {
  local sb
  sb=$(mktemp -d)
  sb=$(cd "$sb" && pwd -P)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    touch onboarding.yaml
    cat > apexyard.projects.yaml <<'YAML'
version: 1
projects:
  - name: example
    repo: example/example
YAML
    mkdir -p projects .claude/hooks
    echo "# Ideas" > projects/ideas-backlog.md
    cp "$PORTFOLIO_LIB" .claude/hooks/_lib-portfolio-paths.sh
    cp "$CONFIG_LIB" .claude/hooks/_lib-read-config.sh
    cp "$RC_LIB" .claude/hooks/_lib-resolution-cache.sh
    cp "$OPS_ROOT_LIB" .claude/hooks/_lib-ops-root.sh
    cp "$DEFAULTS_SRC" .claude/project-config.defaults.json
    git add -A
    git commit -q -m "test fixture" >/dev/null
  )
  echo "$sb"
}

# ---------------------------------------------------------------------------
# Case 1: cold cache == cache-disabled, byte for byte
# ---------------------------------------------------------------------------
case_1() {
  local name="cold cache produces identical results to the cache-disabled path"
  local sb pin_dir sess
  sb=$(make_fork)
  pin_dir=$(mktemp -d)
  sess="case1-$$"

  local enabled disabled
  enabled=$(
    cd "$sb" || exit 1
    export CLAUDE_CODE_SESSION_ID="$sess"
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    unset APEXYARD_OPS_DISABLE_PIN APEXYARD_DISABLE_RESOLUTION_CACHE
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-read-config.sh
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-portfolio-paths.sh
    printf 'kind=%s registry=%s ws=%s\n' \
      "$(config_get '.tracker.kind')" \
      "$(portfolio_registry)" \
      "$(portfolio_workspace_dir)"
  )
  disabled=$(
    cd "$sb" || exit 1
    export CLAUDE_CODE_SESSION_ID="$sess"
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    export APEXYARD_DISABLE_RESOLUTION_CACHE=1
    unset APEXYARD_OPS_DISABLE_PIN
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-read-config.sh
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-portfolio-paths.sh
    printf 'kind=%s registry=%s ws=%s\n' \
      "$(config_get '.tracker.kind')" \
      "$(portfolio_registry)" \
      "$(portfolio_workspace_dir)"
  )

  rm -rf "$sb" "$pin_dir"
  if [ "$enabled" = "$disabled" ] && [ -n "$enabled" ]; then
    mark_pass "$name"
    return 0
  fi
  mark_fail "$name" "enabled='$enabled' disabled='$disabled'"
  return 1
}

# ---------------------------------------------------------------------------
# Case 2: cross-process reuse avoids redoing _config_load's jq -s merge
# ---------------------------------------------------------------------------
case_2() {
  local name="second process (same session) does not redo the config jq -s merge"
  local sb pin_dir sess bindir real_jq log
  sb=$(make_fork)
  (cd "$sb" && echo '{}' > .claude/project-config.json)
  pin_dir=$(mktemp -d)
  sess="case2-$$"
  bindir=$(mktemp -d)
  real_jq=$(command -v jq)
  log="$pin_dir/jq.log"
  : > "$log"
  cat > "$bindir/jq" <<EOF
#!/bin/bash
echo "\$*" >> "$log"
exec "$real_jq" "\$@"
EOF
  chmod +x "$bindir/jq"

  run_once() {
    (
      cd "$sb" || exit 1
      export PATH="$bindir:$PATH"
      export CLAUDE_CODE_SESSION_ID="$sess"
      export APEXYARD_OPS_PIN_DIR="$pin_dir"
      unset APEXYARD_OPS_DISABLE_PIN APEXYARD_DISABLE_RESOLUTION_CACHE
      # shellcheck source=/dev/null
      . .claude/hooks/_lib-read-config.sh
      config_get '.tracker.kind' >/dev/null
    )
  }

  run_once
  : > "$log"
  run_once

  local had_merge
  had_merge="no"
  grep -q -- '-s' "$log" && had_merge="yes"

  rm -rf "$sb" "$pin_dir" "$bindir"
  if [ "$had_merge" = "no" ]; then
    mark_pass "$name"
    return 0
  fi
  mark_fail "$name" "second process re-ran the jq -s merge: $(cat "$log" 2>/dev/null)"
  return 1
}

# ---------------------------------------------------------------------------
# Case 3: cross-process reuse avoids redoing a portfolio resolver's
# _portfolio_get call.
# ---------------------------------------------------------------------------
case_3() {
  local name="second process (same session) does not redo portfolio_workspace_dir's compute path"
  local sb pin_dir sess counter
  sb=$(make_fork)
  pin_dir=$(mktemp -d)
  sess="case3-$$"
  counter="$pin_dir/portfolio_get.count"
  : > "$counter"

  run_once() {
    (
      cd "$sb" || exit 1
      export CLAUDE_CODE_SESSION_ID="$sess"
      export APEXYARD_OPS_PIN_DIR="$pin_dir"
      unset APEXYARD_OPS_DISABLE_PIN APEXYARD_DISABLE_RESOLUTION_CACHE
      # shellcheck source=/dev/null
      . .claude/hooks/_lib-read-config.sh
      # shellcheck source=/dev/null
      . .claude/hooks/_lib-portfolio-paths.sh
      # Wrap _portfolio_get AFTER sourcing, so the wrapper is what
      # _portfolio_resolve_with_session_cache actually calls on a miss.
      eval "
        _portfolio_get_orig() { $(declare -f _portfolio_get | tail -n +2); }
        _portfolio_get() { printf x >> '$counter'; _portfolio_get_orig \"\$@\"; }
      "
      portfolio_workspace_dir >/dev/null
    )
  }

  run_once
  local after_first
  after_first=$(wc -c < "$counter" | tr -d ' ')
  run_once
  local after_second
  after_second=$(wc -c < "$counter" | tr -d ' ')

  rm -rf "$sb" "$pin_dir"
  if [ "$after_first" -ge 1 ] && [ "$after_second" = "$after_first" ]; then
    mark_pass "$name"
    return 0
  fi
  mark_fail "$name" "after_first=$after_first after_second=$after_second (expected second call to add nothing)"
  return 1
}

# ---------------------------------------------------------------------------
# Case 4: staleness -- a project-config.json edit mid-session is picked up
# on the very next read (config value AND a dependent portfolio path).
# ---------------------------------------------------------------------------
case_4() {
  local name="config edit mid-session invalidates the cache on the next read"
  local sb pin_dir sess
  sb=$(make_fork)
  pin_dir=$(mktemp -d)
  sess="case4-$$"

  local before
  before=$(
    cd "$sb" || exit 1
    export CLAUDE_CODE_SESSION_ID="$sess"
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    unset APEXYARD_OPS_DISABLE_PIN APEXYARD_DISABLE_RESOLUTION_CACHE
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-read-config.sh
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-portfolio-paths.sh
    portfolio_workspace_dir
  )

  # Edit the override file -- bumps mtime and changes the resolved value.
  (
    cd "$sb" || exit 1
    cat > .claude/project-config.json <<'JSON'
{ "portfolio": { "workspace_dir": "./changed-workspace" } }
JSON
  )

  local after
  after=$(
    cd "$sb" || exit 1
    export CLAUDE_CODE_SESSION_ID="$sess"
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    unset APEXYARD_OPS_DISABLE_PIN APEXYARD_DISABLE_RESOLUTION_CACHE
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-read-config.sh
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-portfolio-paths.sh
    portfolio_workspace_dir
  )

  rm -rf "$sb" "$pin_dir"
  case "$after" in
    */changed-workspace)
      if [ "$before" != "$after" ]; then
        mark_pass "$name"
        return 0
      fi
      ;;
  esac
  mark_fail "$name" "before='$before' after='$after' (expected after to end in /changed-workspace and differ from before)"
  return 1
}

# ---------------------------------------------------------------------------
# Case 5: a cache file with fingerprint literally "UNKNOWN" is never a hit
# ---------------------------------------------------------------------------
case_5() {
  local name="fingerprint UNKNOWN is never treated as a valid cache key"
  local pin_dir sess
  pin_dir=$(mktemp -d)
  sess="case5-$$"

  local result
  result=$(
    export CLAUDE_CODE_SESSION_ID="$sess"
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    unset APEXYARD_OPS_DISABLE_PIN APEXYARD_DISABLE_RESOLUTION_CACHE
    # shellcheck source=/dev/null
    . "$RC_LIB"
    # A malicious/buggy write under fingerprint UNKNOWN should be refused...
    _resolution_cache_write "some-key" "UNKNOWN" "should-never-be-served" 2>/dev/null
    write_rc=$?
    # ...and even if a file with that content existed by some other means,
    # a read asking for expected_fp=UNKNOWN must also refuse.
    mkdir -p "$pin_dir"
    file="$pin_dir/resolve-cache-${sess}-some-key"
    { printf '%s\n' "UNKNOWN"; printf '%s\n' "should-never-be-served"; } > "$file"
    read_out=$(_resolution_cache_read "some-key" "UNKNOWN" 2>/dev/null)
    read_rc=$?
    printf 'write_rc=%s read_rc=%s read_out=%s' "$write_rc" "$read_rc" "$read_out"
  )

  rm -rf "$pin_dir"
  case "$result" in
    "write_rc=1 read_rc=1 read_out="*)
      mark_pass "$name"
      return 0
      ;;
  esac
  mark_fail "$name" "got: $result"
  return 1
}

# ---------------------------------------------------------------------------
# Case 6: ops-root mismatch (embedded in the fingerprint) is never trusted
# ---------------------------------------------------------------------------
case_6() {
  local name="a fingerprint computed for a different ops root never matches the current one"
  local pin_dir sess
  pin_dir=$(mktemp -d)
  sess="case6-$$"

  local result
  result=$(
    export CLAUDE_CODE_SESSION_ID="$sess"
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    unset APEXYARD_OPS_DISABLE_PIN APEXYARD_DISABLE_RESOLUTION_CACHE
    # shellcheck source=/dev/null
    . "$RC_LIB"
    fp_root_a=$(_resolution_cache_config_fingerprint "/fork/a" "/nonexistent/defaults.json" "/nonexistent/overrides.json")
    fp_root_b=$(_resolution_cache_config_fingerprint "/fork/b" "/nonexistent/defaults.json" "/nonexistent/overrides.json")
    _resolution_cache_write "rootcheck" "$fp_root_a" "value-for-a"
    # Reading with root b's fingerprint must miss even though both files
    # are equally (non-)existent -- only the root component differs.
    out=$(_resolution_cache_read "rootcheck" "$fp_root_b" 2>/dev/null)
    rc=$?
    printf 'fp_differ=%s read_rc=%s out=%s' \
      "$([ "$fp_root_a" != "$fp_root_b" ] && echo yes || echo no)" "$rc" "$out"
  )

  rm -rf "$pin_dir"
  case "$result" in
    "fp_differ=yes read_rc=1 out=")
      mark_pass "$name"
      return 0
      ;;
  esac
  mark_fail "$name" "got: $result"
  return 1
}

# ---------------------------------------------------------------------------
# Case 7: unwritable cache dir degrades to current behaviour
# ---------------------------------------------------------------------------
case_7() {
  local name="unwritable cache directory degrades gracefully (correct value, no crash)"
  local sb pin_dir sess
  sb=$(make_fork)
  pin_dir=$(mktemp -d)
  chmod 555 "$pin_dir"
  sess="case7-$$"

  local out rc
  out=$(
    cd "$sb" || exit 1
    export CLAUDE_CODE_SESSION_ID="$sess"
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    unset APEXYARD_OPS_DISABLE_PIN APEXYARD_DISABLE_RESOLUTION_CACHE
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-read-config.sh
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-portfolio-paths.sh
    printf 'kind=%s ws=%s\n' "$(config_get '.tracker.kind')" "$(portfolio_workspace_dir)"
  )
  rc=$?

  chmod 755 "$pin_dir"
  rm -rf "$sb" "$pin_dir"

  case "$out" in
    kind=gh\ ws=*/workspace)
      if [ "$rc" -eq 0 ]; then
        mark_pass "$name"
        return 0
      fi
      ;;
  esac
  mark_fail "$name" "rc=$rc out='$out'"
  return 1
}

# ---------------------------------------------------------------------------
# Case 8: APEXYARD_DISABLE_RESOLUTION_CACHE=1 -> zero cache files written
# ---------------------------------------------------------------------------
case_8() {
  local name="APEXYARD_DISABLE_RESOLUTION_CACHE=1 writes zero cache files"
  local sb pin_dir sess
  sb=$(make_fork)
  pin_dir=$(mktemp -d)
  sess="case8-$$"

  (
    cd "$sb" || exit 1
    export CLAUDE_CODE_SESSION_ID="$sess"
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    export APEXYARD_DISABLE_RESOLUTION_CACHE=1
    unset APEXYARD_OPS_DISABLE_PIN
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-read-config.sh
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-portfolio-paths.sh
    config_get '.tracker.kind' >/dev/null
    portfolio_workspace_dir >/dev/null
    portfolio_registry >/dev/null
  )

  local count
  count=$(find "$pin_dir" -mindepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
  rm -rf "$sb" "$pin_dir"
  if [ "$count" -eq 0 ]; then
    mark_pass "$name"
    return 0
  fi
  mark_fail "$name" "expected 0 files, found $count"
  return 1
}

# ---------------------------------------------------------------------------
# Case 9: no CLAUDE_CODE_SESSION_ID -> zero cache files written
# ---------------------------------------------------------------------------
case_9() {
  local name="no CLAUDE_CODE_SESSION_ID writes zero cache files"
  local sb pin_dir
  sb=$(make_fork)
  pin_dir=$(mktemp -d)

  (
    cd "$sb" || exit 1
    unset CLAUDE_CODE_SESSION_ID
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    unset APEXYARD_OPS_DISABLE_PIN APEXYARD_DISABLE_RESOLUTION_CACHE
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-read-config.sh
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-portfolio-paths.sh
    config_get '.tracker.kind' >/dev/null
    portfolio_workspace_dir >/dev/null
  )

  local count
  count=$(find "$pin_dir" -mindepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
  rm -rf "$sb" "$pin_dir"
  if [ "$count" -eq 0 ]; then
    mark_pass "$name"
    return 0
  fi
  mark_fail "$name" "expected 0 files, found $count"
  return 1
}

echo "Running resolution-cache tests..."
for fn in case_1 case_2 case_3 case_4 case_5 case_6 case_7 case_8 case_9; do
  run_case "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0
