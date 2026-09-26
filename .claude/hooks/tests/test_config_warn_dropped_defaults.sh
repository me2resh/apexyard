#!/bin/bash
# Tests for _config_warn_dropped_defaults — the advisory WARN that fires when
# a .claude/project-config.json array override drops entries a shipped
# default array carries (me2resh/apexyard#1369).
#
# Cases:
#   1. Override array missing default entries -> WARN naming the key + the
#      dropped entries, merged config STILL uses the override (unchanged
#      replace semantics).
#   2. Override array is a superset (pure addition) -> no WARN.
#   3. Override touches an unrelated key -> the untouched array's WARN does
#      not fire, and its own value is unaffected.
#   4. No override file at all -> no WARN, no-op.
#   5. Override key has no matching default array (override-only key, e.g.
#      migration_paths) -> no WARN (out of this function's scope by design;
#      see the function's own header comment).
#   7. _lib-read-config.sh sources cleanly under a POSIX-mode shell
#      (`/bin/sh` and `bash` with `POSIXLY_CORRECT=1`), and `config_get`
#      is defined afterward (Hakim's LOW-A regression, #1403).

set -u

# Test isolation: this sandbox is NOT the real ops fork. Disable both the
# resolve_ops_root() pin (#381) and the cross-process resolution cache
# (#1013) so config_get reads THIS test's synthetic files, not a pinned real
# session's ops root or its cached merged JSON.
unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export APEXYARD_OPS_DISABLE_PIN=1
export APEXYARD_DISABLE_RESOLUTION_CACHE=1

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB_READ_CONFIG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"

if [ ! -f "$LIB_READ_CONFIG" ]; then
  echo "FAIL: required source missing: $LIB_READ_CONFIG" >&2
  exit 1
fi

PASS=0
FAIL=0
record_pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
record_fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && echo "  $2" >&2; }

make_sandbox() {
  local sb
  sb=$(mktemp -d)
  mkdir -p "$sb/.claude/hooks"
  touch "$sb/.apexyard-fork"
  cp "$LIB_READ_CONFIG" "$sb/.claude/hooks/_lib-read-config.sh"
  if [ -f "$SRC_ROOT/.claude/hooks/_lib-ops-root.sh" ]; then
    cp "$SRC_ROOT/.claude/hooks/_lib-ops-root.sh" "$sb/.claude/hooks/_lib-ops-root.sh"
  fi
  echo "$sb"
}

# run_config_get SB DEFAULTS_JSON OVERRIDES_JSON FILTER
# Writes the two config files (OVERRIDES_JSON may be empty string = no file),
# runs config_get "$FILTER" against them, and captures stdout/stderr
# separately so the WARN (stderr) and the merged value (stdout) can each be
# asserted independently.
run_config_get() {
  local sb="$1" defaults_json="$2" overrides_json="$3" filter="$4"
  printf '%s\n' "$defaults_json" > "$sb/.claude/project-config.defaults.json"
  if [ -n "$overrides_json" ]; then
    printf '%s\n' "$overrides_json" > "$sb/.claude/project-config.json"
  fi
  STDOUT_OUT=$(cd "$sb" && bash -c '. .claude/hooks/_lib-read-config.sh; config_get "$1"' _ "$filter" 2>"$sb/.stderr")
  STDERR_OUT=$(cat "$sb/.stderr")
}

DEFAULTS='{"branch":{"type_whitelist":["feature","fix","chore","sync"]},"ticket":{"prefix_whitelist":["Feature","Bug"]}}'

# ---------------------------------------------------------------------------
# 1. Dropped entries -> WARN names the key + the dropped entries; merged
#    value still uses the override (replace semantics unchanged).
# ---------------------------------------------------------------------------
sb=$(make_sandbox)
run_config_get "$sb" "$DEFAULTS" '{"branch":{"type_whitelist":["feat"]}}' '.branch.type_whitelist | join(" ")'
if [ "$STDOUT_OUT" = "feat" ]; then
  record_pass "1a: merged value still REPLACES with the override (unchanged semantics)"
else
  record_fail "1a: merged value still REPLACES with the override (unchanged semantics)" "got: $STDOUT_OUT"
fi
if echo "$STDERR_OUT" | grep -q 'WARN' \
  && echo "$STDERR_OUT" | grep -q 'branch.type_whitelist' \
  && echo "$STDERR_OUT" | grep -q 'feature' \
  && echo "$STDERR_OUT" | grep -q 'chore' \
  && echo "$STDERR_OUT" | grep -q 'sync'; then
  record_pass "1b: WARN names the key and every dropped entry"
else
  record_fail "1b: WARN names the key and every dropped entry" "stderr: $STDERR_OUT"
fi
rm -rf "$sb"

# ---------------------------------------------------------------------------
# 2. Pure addition (override is a superset) -> no WARN.
# ---------------------------------------------------------------------------
sb=$(make_sandbox)
run_config_get "$sb" "$DEFAULTS" '{"branch":{"type_whitelist":["feature","fix","chore","sync","hotfix"]}}' '.branch.type_whitelist | join(" ")'
if ! echo "$STDERR_OUT" | grep -q 'WARN'; then
  record_pass "2: pure-addition override does not WARN"
else
  record_fail "2: pure-addition override does not WARN" "stderr: $STDERR_OUT"
fi
rm -rf "$sb"

# ---------------------------------------------------------------------------
# 3. Override touches an unrelated key -> the untouched default array's own
#    entries are unaffected and no WARN fires for a key nobody overrode.
# ---------------------------------------------------------------------------
sb=$(make_sandbox)
run_config_get "$sb" "$DEFAULTS" '{"ticket":{"prefix_whitelist":["Feature"]}}' '.branch.type_whitelist | join(" ")'
if [ "$STDOUT_OUT" = "feature fix chore sync" ]; then
  record_pass "3a: untouched array keeps its default value"
else
  record_fail "3a: untouched array keeps its default value" "got: $STDOUT_OUT"
fi
if ! echo "$STDERR_OUT" | grep -q 'branch.type_whitelist'; then
  record_pass "3b: WARN does not fire for a key nobody overrode"
else
  record_fail "3b: WARN does not fire for a key nobody overrode" "stderr: $STDERR_OUT"
fi
rm -rf "$sb"

# ---------------------------------------------------------------------------
# 4. No override file at all -> no WARN, no-op.
# ---------------------------------------------------------------------------
sb=$(make_sandbox)
run_config_get "$sb" "$DEFAULTS" '' '.branch.type_whitelist | join(" ")'
if [ "$STDOUT_OUT" = "feature fix chore sync" ] && ! echo "$STDERR_OUT" | grep -q 'WARN'; then
  record_pass "4: no overrides file -> defaults used, no WARN"
else
  record_fail "4: no overrides file -> defaults used, no WARN" "stdout: $STDOUT_OUT stderr: $STDERR_OUT"
fi
rm -rf "$sb"

# ---------------------------------------------------------------------------
# 5. Override-only key (no matching default array at all, e.g.
#    migration_paths) -> out of scope for this generic JSON diff by design;
#    no WARN, and the override's own value is used untouched.
# ---------------------------------------------------------------------------
sb=$(make_sandbox)
run_config_get "$sb" "$DEFAULTS" '{"migration_paths":["custom/path/*.sql"]}' '.migration_paths | join(" ")'
if [ "$STDOUT_OUT" = "custom/path/*.sql" ] && ! echo "$STDERR_OUT" | grep -q 'WARN'; then
  record_pass "5: override-only key (no JSON default) -> no WARN, override value used"
else
  record_fail "5: override-only key (no JSON default) -> no WARN, override value used" "stdout: $STDOUT_OUT stderr: $STDERR_OUT"
fi
rm -rf "$sb"

# ---------------------------------------------------------------------------
# 6. An array nested inside a parent array's own elements (e.g.
#    skill_intent.map[0].phrases) must NOT be independently diffed once the
#    parent array itself is already reported as replaced — that path is only
#    reachable through a numeric array index, which the path filter excludes.
#    Also exercises non-string array elements (objects) in the WARN text: it
#    must render them (tojson), never silently produce an empty list.
# ---------------------------------------------------------------------------
sb=$(make_sandbox)
NESTED_DEFAULTS='{"skill_intent":{"map":[{"skill":"a","phrases":["x","y"]},{"skill":"b","phrases":["z"]}]}}'
run_config_get "$sb" "$NESTED_DEFAULTS" '{"skill_intent":{"map":[{"skill":"a","phrases":["x"]}]}}' '.skill_intent.map | length'
if [ "$STDOUT_OUT" = "1" ]; then
  record_pass "6a: merged value still REPLACES with the override array-of-objects"
else
  record_fail "6a: merged value still REPLACES with the override array-of-objects" "got: $STDOUT_OUT"
fi
if ! echo "$STDERR_OUT" | grep -q 'skill_intent.map.0.phrases'; then
  record_pass "6b: no spurious WARN for an array nested inside the parent array's own elements"
else
  record_fail "6b: no spurious WARN for an array nested inside the parent array's own elements" "stderr: $STDERR_OUT"
fi
if echo "$STDERR_OUT" | grep -q 'skill_intent.map' && echo "$STDERR_OUT" | grep -q '"skill":"b"'; then
  record_pass "6c: WARN for the top-level array-of-objects renders dropped objects (not empty)"
else
  record_fail "6c: WARN for the top-level array-of-objects renders dropped objects (not empty)" "stderr: $STDERR_OUT"
fi
rm -rf "$sb"

# ---------------------------------------------------------------------------
# 7. Sourcing under a POSIX-mode shell must not raise a syntax error, and
#    config_get must be defined afterward. `_config_warn_dropped_defaults`'s
#    loop used `done < <(...)` process substitution, a bash/ksh/zsh
#    extension no POSIX shell parses. `/bin/sh` and `bash POSIXLY_CORRECT=1`
#    both reject it, which aborts the whole `source` and leaves config_get
#    undefined for the rest of the process (Hakim's LOW-A, #1403).
# ---------------------------------------------------------------------------
posix_probe_script() {
  local lib_path="$1"
  cat <<PROBE
. '$lib_path'
if command -v config_get >/dev/null 2>&1; then
  echo config_get_defined
else
  echo config_get_missing
fi
PROBE
}

probe="$(posix_probe_script "$LIB_READ_CONFIG")"

out_sh=$(printf '%s\n' "$probe" | /bin/sh 2>&1)
if [ "$(printf '%s\n' "$out_sh" | tail -1)" = "config_get_defined" ]; then
  record_pass "7a: sources cleanly under /bin/sh, config_get defined"
else
  record_fail "7a: sources cleanly under /bin/sh, config_get defined" "output: $out_sh"
fi

out_posix=$(POSIXLY_CORRECT=1 bash -c "$probe" 2>&1)
if [ "$(printf '%s\n' "$out_posix" | tail -1)" = "config_get_defined" ]; then
  record_pass "7b: sources cleanly under bash POSIXLY_CORRECT=1, config_get defined"
else
  record_fail "7b: sources cleanly under bash POSIXLY_CORRECT=1, config_get defined" "output: $out_posix"
fi

echo
echo "===== test_config_warn_dropped_defaults.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
