#!/bin/bash
# Tests for bin/kb-freshness.
set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FRESH="$REPO_ROOT/bin/kb-freshness"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1 — $2"; }

FX=$(mktemp -d)
trap 'rm -rf "$FX"' EXIT

git -C "$FX" init -q
mkdir -p "$FX/handbooks/architecture" "$FX/docs/agdr"

cat > "$FX/handbooks/architecture/stale.md" <<'MD'
---
owner: S
verified_by: S
verified_on: 2023-01-01
stale_after: 2023-06-30
sources: []
version: 1
status: active
---

# Handbook: Stale

Body.
MD

cat > "$FX/handbooks/architecture/fresh.md" <<'MD'
---
owner: F
verified_by: F
verified_on: 2026-01-01
stale_after: 2026-12-31
sources: []
version: 1
status: active
---

# Handbook: Fresh

Body.
MD

cat > "$FX/handbooks/architecture/deprecated.md" <<'MD'
---
owner: D
verified_by: D
verified_on: 2020-01-01
stale_after: 2020-06-01
sources: []
version: 1
status: deprecated
---

# Handbook: Deprecated

Body.
MD

cat > "$FX/docs/agdr/AgDR-0009-x.md" <<'MD'
---
id: AgDR-0009
agent: platform-engineer
---

# AgDR-0009 — X

Body.
MD

git -C "$FX" add .
git -C "$FX" -c user.name='S' -c user.email='s@example.com' commit -q -m 'seed'

# Today after stale_after → stale listed
out=$("$FRESH" --root "$FX" --today 2024-01-01 2>&1)
echo "$out" | grep -q 'handbooks/architecture/stale' && pass "stale listed" || fail "stale listed" "$out"
echo "$out" | grep -q 'handbooks/architecture/fresh' && fail "fresh not listed" "$out" || pass "fresh not listed"
echo "$out" | grep -q 'handbooks/architecture/deprecated' && fail "deprecated not listed" "$out" || pass "deprecated not listed"
echo "$out" | grep -q 'docs/agdr/AgDR-0009' && fail "null stale_after not listed" "$out" || pass "null stale_after not listed"

# Today before stale_after → nothing
out2=$("$FRESH" --root "$FX" --today 2023-01-01 2>&1)
if [ -z "$out2" ]; then
  pass "nothing printed when none stale"
else
  fail "nothing printed when none stale" "$out2"
fi

# --out only when stale
out_file="$FX/report.md"
rm -f "$out_file"
"$FRESH" --root "$FX" --today 2023-01-01 --out "$out_file" >/dev/null
if [ -f "$out_file" ]; then
  fail "no out file when none stale" "exists"
else
  pass "no out file when none stale"
fi

"$FRESH" --root "$FX" --today 2024-01-01 --out "$out_file" >/dev/null
[ -f "$out_file" ] && pass "out file when stale" || fail "out file when stale" ""
grep -q 'days overdue' "$out_file" && pass "report has days overdue" || fail "report has days overdue" "$(cat "$out_file")"

echo
echo "Total: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
