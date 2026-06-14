#!/bin/bash
# Smoke test for the /update intermediate-release migration chain.
#
# Exercises `_lib-migration-chain.sh` end-to-end:
#   - version-anchor read / write
#   - chain detection across N releases
#   - "unknown" anchor → caller branch
#   - skip-migrations → no scripts run (just files)
#   - existing v1.2.0→v1.3.0 migration executes idempotently when re-run
#
# Sandbox-based: builds synthetic ops-fork layouts under mktemp dirs, with
# stub migration scripts that count their own invocations. The real
# v1.2.0-to-v1.3.0.sh + v1.3.0-to-v1.4.0.sh ship in the framework root
# and are copied in for the "real scripts execute idempotently" case.
#
# Exit 0 if every case passes; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB_CHAIN="$SRC_ROOT/.apexyard/hooks/_lib-migration-chain.sh"
REAL_V1_V2="$SRC_ROOT/.apexyard/migrations/v1.2.0-to-v1.3.0.sh"
REAL_V2_V3="$SRC_ROOT/.apexyard/migrations/v1.3.0-to-v1.4.0.sh"
REAL_V3_V4="$SRC_ROOT/.apexyard/migrations/v3.1.4-to-v4.0.0.sh"

for f in "$LIB_CHAIN" "$REAL_V1_V2" "$REAL_V2_V3" "$REAL_V3_V4"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

PASS=0
FAIL=0
FAILED=""

mark_pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
mark_fail() { echo "  ✗ $1: $2" >&2; FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; }

# build_fork <root> <versions_csv>
#   Creates a synthetic ops-fork under <root> with:
#     - onboarding.yaml + apexyard.projects.yaml (legacy v1 anchor → ops-root walk works)
#     - .apexyard/ with stub migrations for each pair implied by <versions_csv>
# E.g. build_fork /tmp/x "v1.0.0,v1.1.0,v1.2.0" creates two stubs:
#   .apexyard/migrations/v1.0.0-to-v1.1.0.sh
#   .apexyard/migrations/v1.1.0-to-v1.2.0.sh
# Each stub increments a counter file in $root/.counters/<pair>.
build_fork() {
  local root="$1"
  local versions_csv="$2"
  mkdir -p "$root/.apexyard/hooks" "$root/.apexyard/migrations" "$root/.counters"

  # Legacy v1 anchor pair (so the ops-root walk in the lib finds this dir)
  : > "$root/onboarding.yaml"
  : > "$root/apexyard.projects.yaml"

  # Init git so git rev-parse --show-toplevel works.
  ( cd "$root" && git init -q && git config user.email t@t.t && git config user.name t \
      && git add -A && git commit -q -m "fixture" >/dev/null 2>&1 ) || return 1

  # Build stub pair scripts.
  local prev="" cur
  IFS=',' read -r -a vs <<< "$versions_csv"
  for cur in "${vs[@]}"; do
    if [ -n "$prev" ]; then
      local pair="${prev}-to-${cur}"
      local script="$root/.apexyard/migrations/${pair}.sh"
      cat > "$script" <<STUB
#!/bin/bash
# stub migration for ${pair}
COUNTER="${root}/.counters/${pair}"
mkdir -p "\$(dirname "\$COUNTER")"
n=\$(cat "\$COUNTER" 2>/dev/null || echo 0)
echo \$((n+1)) > "\$COUNTER"
exit 0
STUB
      chmod +x "$script"
    fi
    prev="$cur"
  done
}

# ---------------------------------------------------------------------------
# Case 1: chain detection from v1.0.0 to v1.4.0 produces a 4-step chain
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_fork "$SB" "v1.0.0,v1.1.0,v1.2.0,v1.3.0,v1.4.0"

(
  cd "$SB" || exit 99
  # shellcheck source=/dev/null
  . "$LIB_CHAIN"
  chain=$(migration_chain "v1.0.0" "v1.4.0")
  expected="v1.0.0-to-v1.1.0
v1.1.0-to-v1.2.0
v1.2.0-to-v1.3.0
v1.3.0-to-v1.4.0"
  if [ "$chain" = "$expected" ]; then
    exit 0
  else
    echo "GOT:" >&2; echo "$chain" >&2
    echo "EXPECTED:" >&2; echo "$expected" >&2
    exit 1
  fi
)
[ "$?" -eq 0 ] && mark_pass "chain v1.0.0→v1.4.0 builds 4 ordered steps" \
              || mark_fail "chain build 4 steps" "see output above"

rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 2: same fork (no anchor file) → migration_current_version returns "unknown"
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_fork "$SB" "v1.2.0,v1.3.0,v1.4.0"
# Make sure no anchor file
rm -f "$SB/.apexyard/framework-version"

(
  cd "$SB" || exit 99
  # shellcheck source=/dev/null
  . "$LIB_CHAIN"
  cur=$(migration_current_version)
  [ "$cur" = "unknown" ] || { echo "got '$cur'" >&2; exit 1; }
  # And the chain helper should also early-out on unknown.
  chain=$(migration_chain "unknown" "v1.4.0")
  [ -z "$chain" ] || { echo "expected empty chain on unknown, got '$chain'" >&2; exit 1; }
  exit 0
)
[ "$?" -eq 0 ] && mark_pass "unknown anchor → migration_current_version=unknown + empty chain" \
              || mark_fail "unknown anchor branch" "see output above"

rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 3: writing the anchor + round-trip + idempotent overwrite
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_fork "$SB" "v1.2.0,v1.3.0,v1.4.0"

(
  cd "$SB" || exit 99
  # shellcheck source=/dev/null
  . "$LIB_CHAIN"
  migration_write_anchor "v1.2.0" || exit 1
  one=$(migration_current_version)
  [ "$one" = "v1.2.0" ] || { echo "after first write got '$one'" >&2; exit 1; }
  # Re-write same — no-op semantically.
  migration_write_anchor "v1.2.0" || exit 1
  same=$(migration_current_version)
  [ "$same" = "v1.2.0" ] || { echo "after idempotent write got '$same'" >&2; exit 1; }
  # Overwrite.
  migration_write_anchor "v1.3.0" || exit 1
  bumped=$(migration_current_version)
  [ "$bumped" = "v1.3.0" ] || { echo "after bump got '$bumped'" >&2; exit 1; }
  # Reject malformed version.
  migration_write_anchor "broken" 2>/dev/null && { echo "should have rejected 'broken'" >&2; exit 1; }
  exit 0
)
[ "$?" -eq 0 ] && mark_pass "anchor write/read round-trip + idempotence + rejects malformed" \
              || mark_fail "anchor round-trip" "see output above"

rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 4: --skip-migrations equivalent — no migrations run, anchor still written
# (We model this by NOT calling migration_run; just write the anchor.)
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_fork "$SB" "v1.2.0,v1.3.0,v1.4.0"

(
  cd "$SB" || exit 99
  # shellcheck source=/dev/null
  . "$LIB_CHAIN"
  migration_write_anchor "v1.2.0"
  # User passes --skip-migrations → caller skips migration_run loop, writes
  # the new anchor anyway. Counters must stay at 0.
  migration_write_anchor "v1.4.0"
  exit 0
)
v12_v13_count=$(cat "$SB/.counters/v1.2.0-to-v1.3.0" 2>/dev/null || echo 0)
v13_v14_count=$(cat "$SB/.counters/v1.3.0-to-v1.4.0" 2>/dev/null || echo 0)
if [ "$v12_v13_count" -eq 0 ] && [ "$v13_v14_count" -eq 0 ]; then
  mark_pass "--skip-migrations path: no migration scripts executed"
else
  mark_fail "--skip-migrations no exec" "counters: v12_v13=$v12_v13_count v13_v14=$v13_v14_count"
fi

# Anchor still written.
ANCHOR=$(head -n 1 "$SB/.apexyard/framework-version" 2>/dev/null)
[ "$ANCHOR" = "v1.4.0" ] \
  && mark_pass "--skip-migrations path: anchor still advances to v1.4.0" \
  || mark_fail "--skip-migrations anchor advance" "anchor='$ANCHOR'"

rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 5: real v1.2.0→v1.3.0 migration runs idempotently on a single-fork
# adopter (no portfolio block → no-op exit 0 both runs).
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_fork "$SB" "v1.2.0,v1.3.0"
# Replace the stub v1.2.0-to-v1.3.0 with the real script
cp "$REAL_V1_V2" "$SB/.apexyard/migrations/v1.2.0-to-v1.3.0.sh"
chmod +x "$SB/.apexyard/migrations/v1.2.0-to-v1.3.0.sh"

# No project-config.json → single-fork adopter
(
  cd "$SB" || exit 99
  APEXYARD_MIGRATION_QUIET=1 bash .apexyard/migrations/v1.2.0-to-v1.3.0.sh
)
rc1=$?
(
  cd "$SB" || exit 99
  APEXYARD_MIGRATION_QUIET=1 bash .apexyard/migrations/v1.2.0-to-v1.3.0.sh
)
rc2=$?

if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]; then
  mark_pass "real v1.2.0→v1.3.0 idempotent no-op on single-fork adopter (rc1=$rc1 rc2=$rc2)"
else
  mark_fail "real v1.2.0→v1.3.0 single-fork" "rc1=$rc1 rc2=$rc2"
fi

rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 5b: real v3.1.4→v4.0.0 migration moves adopter config + session state
# and is idempotent on a single-fork adopter.
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_fork "$SB" "v3.1.4,v4.0.0"
# Replace the stub v3.1.4-to-v4.0.0 with the real script and copy the sync tool.
cp "$REAL_V3_V4" "$SB/.apexyard/migrations/v3.1.4-to-v4.0.0.sh"
chmod +x "$SB/.apexyard/migrations/v3.1.4-to-v4.0.0.sh"
mkdir -p "$SB/bin"
cp "$SRC_ROOT/bin/apexyard-sync-tool-dirs" "$SB/bin/apexyard-sync-tool-dirs"
chmod +x "$SB/bin/apexyard-sync-tool-dirs"

# Simulate old .claude/ layout with adopter data.
mkdir -p "$SB/.claude/session/reviews"
echo '{"migration_label":"infra-migration"}' > "$SB/.claude/project-config.json"
echo '#42' > "$SB/.claude/session/current-ticket"
echo 'approved' > "$SB/.claude/session/reviews/42-rex.approved"

(
  cd "$SB" || exit 99
  APEXYARD_MIGRATION_QUIET=1 bash .apexyard/migrations/v3.1.4-to-v4.0.0.sh
)
rc1=$?
(
  cd "$SB" || exit 99
  APEXYARD_MIGRATION_QUIET=1 bash .apexyard/migrations/v3.1.4-to-v4.0.0.sh
)
rc2=$?

if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] \
   && [ -f "$SB/.apexyard/project-config.json" ] \
   && [ -f "$SB/.apexyard/session/current-ticket" ] \
   && [ -f "$SB/.apexyard/session/reviews/42-rex.approved" ] \
   && [ ! -d "$SB/.claude/session" ]; then
  mark_pass "real v3.1.4→v4.0.0 moves config + session and is idempotent (rc1=$rc1 rc2=$rc2)"
else
  mark_fail "real v3.1.4→v4.0.0 single-fork" "rc1=$rc1 rc2=$rc2; check .apexyard/project-config.json, .apexyard/session/, .claude/session/"
fi

rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 6: missing-link in chain → migration_chain emits empty (refuse silently)
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
# Build a fork with v1.0.0, v1.1.0, v1.2.0, but DELETE the v1.1.0→v1.2.0 link.
build_fork "$SB" "v1.0.0,v1.1.0,v1.2.0"
rm -f "$SB/.apexyard/migrations/v1.1.0-to-v1.2.0.sh"

(
  cd "$SB" || exit 99
  # shellcheck source=/dev/null
  . "$LIB_CHAIN"
  chain=$(migration_chain "v1.0.0" "v1.2.0")
  if [ -z "$chain" ]; then
    exit 0
  else
    echo "expected empty (missing link), got: $chain" >&2
    exit 1
  fi
)
[ "$?" -eq 0 ] && mark_pass "missing link in chain → migration_chain emits empty (refuse)" \
              || mark_fail "missing link refuse" "see output above"

rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 7: backwards (from > to) → empty chain (refuse going backwards)
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_fork "$SB" "v1.2.0,v1.3.0,v1.4.0"

(
  cd "$SB" || exit 99
  # shellcheck source=/dev/null
  . "$LIB_CHAIN"
  chain=$(migration_chain "v1.4.0" "v1.2.0")
  [ -z "$chain" ] && exit 0
  echo "expected empty (backwards), got: $chain" >&2
  exit 1
)
[ "$?" -eq 0 ] && mark_pass "backwards from>to → empty chain (refuse)" \
              || mark_fail "backwards refuse" "see output above"

rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 8: from == to → empty chain (already up to date)
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_fork "$SB" "v1.3.0,v1.4.0"

(
  cd "$SB" || exit 99
  # shellcheck source=/dev/null
  . "$LIB_CHAIN"
  chain=$(migration_chain "v1.3.0" "v1.3.0")
  [ -z "$chain" ] && exit 0
  echo "expected empty (from==to), got: $chain" >&2
  exit 1
)
[ "$?" -eq 0 ] && mark_pass "from==to → empty chain (up to date)" \
              || mark_fail "from==to" "see output above"

rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 9: migration_run executes the script and returns its exit code
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_fork "$SB" "v1.2.0,v1.3.0"
# Replace stub with one that exits 1
cat > "$SB/.apexyard/migrations/v1.2.0-to-v1.3.0.sh" <<'SCR'
#!/bin/bash
exit 1
SCR
chmod +x "$SB/.apexyard/migrations/v1.2.0-to-v1.3.0.sh"

(
  cd "$SB" || exit 99
  # shellcheck source=/dev/null
  . "$LIB_CHAIN"
  migration_run "v1.2.0-to-v1.3.0"
  rc=$?
  [ "$rc" -eq 1 ] && exit 0
  echo "expected rc=1 (conflict), got rc=$rc" >&2
  exit 1
)
[ "$?" -eq 0 ] && mark_pass "migration_run forwards exit code 1 (conflict)" \
              || mark_fail "migration_run conflict code" "see output above"

# migration_run on missing script returns 2 (hard error)
rm -f "$SB/.apexyard/migrations/v1.2.0-to-v1.3.0.sh"
(
  cd "$SB" || exit 99
  # shellcheck source=/dev/null
  . "$LIB_CHAIN"
  migration_run "v1.2.0-to-v1.3.0" 2>/dev/null
  rc=$?
  [ "$rc" -eq 2 ] && exit 0
  echo "expected rc=2 (hard error), got rc=$rc" >&2
  exit 1
)
[ "$?" -eq 0 ] && mark_pass "migration_run forwards exit code 2 on missing script" \
              || mark_fail "migration_run hard error" "see output above"

rm -rf "$SB"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "===== test_update_chain.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED"
  exit 1
fi
exit 0
