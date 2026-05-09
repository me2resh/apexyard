#!/bin/bash
# Smoke tests for the /agdr skill's parsing + indexing logic.
#
# The skill itself is a markdown spec the model executes; this test
# exercises the parser the spec specifies (frontmatter extraction,
# category bucketing, search match) against a synthetic portfolio
# fixture so a regression in the spec — or in any future helper
# extracted from the spec — fails loudly.
#
# Each case:
#   - builds a sandbox portfolio with multiple synthetic AgDRs
#   - runs the parsing logic the skill specifies
#   - asserts the resulting index matches expectations
#
# Exit 0 means all cases passed. Exit 1 on first failure.

set -u

PASS=0
FAIL=0
FAILED_CASES=""

# ---------------------------------------------------------------------------
# parse_frontmatter <file>
# Mirrors the awk parser in .claude/skills/agdr/SKILL.md § "Parse frontmatter".
# Echoes only the lines between the leading --- / --- block.
# ---------------------------------------------------------------------------
parse_frontmatter() {
  local file="$1"
  awk '
    BEGIN { in_fm = 0; fm_done = 0 }
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && /^---[[:space:]]*$/ { in_fm = 0; fm_done = 1; next }
    in_fm { print }
    fm_done && /./ { exit }
  ' "$file"
}

# ---------------------------------------------------------------------------
# extract_category <file>
# Returns the literal category value, or "other" when missing.
# Mirrors the bucket-on-missing-frontmatter rule from the skill spec.
# ---------------------------------------------------------------------------
extract_category() {
  local file="$1"
  local fm cat
  fm=$(parse_frontmatter "$file")
  cat=$(printf '%s\n' "$fm" | awk -F': *' '/^category:/{print $2; exit}')
  if [ -z "$cat" ]; then
    echo "other"
  else
    # Strip surrounding quotes / whitespace / inline comments.
    echo "$cat" | sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'"'"']//' -e 's/["'"'"']$//'
  fi
}

# ---------------------------------------------------------------------------
# extract_id <file>
# Returns the AgDR-NNNN id, or empty if no id field found.
# ---------------------------------------------------------------------------
extract_id() {
  local file="$1"
  local fm
  fm=$(parse_frontmatter "$file")
  printf '%s\n' "$fm" | awk -F': *' '/^id:/{print $2; exit}'
}

# ---------------------------------------------------------------------------
# make_portfolio
# Builds a sandbox apexyard fork with three synthetic AgDRs:
#   - AgDR-0001: full frontmatter, category: architecture
#   - AgDR-0002: legacy (no frontmatter) — should bucket as `other`
#   - AgDR-0003: full frontmatter, category: security
# ---------------------------------------------------------------------------
make_portfolio() {
  local sb
  sb=$(mktemp -d)
  sb=$(cd "$sb" && pwd -P)

  mkdir -p "$sb/docs/agdr"

  cat > "$sb/docs/agdr/AgDR-0001-clean-architecture.md" <<'MD'
---
id: AgDR-0001
timestamp: 2026-05-01T10:00:00Z
agent: claude
status: executed
category: architecture
---

# Adopt clean architecture

> In the context of a growing API tier, facing creeping framework lock-in,
> I decided to adopt a hexagonal layout, accepting the upfront refactor cost.

## Decision

Chosen: **hexagonal**, because the rate-limit middleware can be swapped without
touching the domain layer.
MD

  cat > "$sb/docs/agdr/AgDR-0002-legacy-no-frontmatter.md" <<'MD'
# Legacy AgDR with no frontmatter

This file predates the `/agdr` skill and lacks any frontmatter at all.
It should still be indexable — bucketed as `other` by default.

## Decision

Chosen: **option X**, because reasons.
MD

  cat > "$sb/docs/agdr/AgDR-0003-mfa-required.md" <<'MD'
---
id: AgDR-0003
timestamp: 2026-05-02T10:00:00Z
agent: claude
status: executed
category: security
projects: [example-app, billing-api]
---

# Require MFA on admin login

> In the context of a portfolio-wide admin surface, facing credential-stuffing
> reports, I decided to require MFA on admin login, accepting the friction.

## Decision

Chosen: **TOTP MFA**, because hardware keys are over-engineering for this tier.
MD

  echo "$sb"
}

# ---------------------------------------------------------------------------
# run_case <name> <command...>
# Run a snippet, capture stdout+stderr, compare to expected via $assert_*.
# ---------------------------------------------------------------------------
assert_eq() {
  local name="$1"
  local got="$2"
  local expected="$3"
  if [ "$got" = "$expected" ]; then
    PASS=$((PASS + 1))
    echo "PASS: $name"
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  - $name (got=[$got] expected=[$expected])"
    echo "FAIL: $name"
    echo "  got:      [$got]"
    echo "  expected: [$expected]"
  fi
}

assert_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*)
      PASS=$((PASS + 1))
      echo "PASS: $name"
      ;;
    *)
      FAIL=$((FAIL + 1))
      FAILED_CASES="$FAILED_CASES\n  - $name (needle=[$needle] missing from haystack)"
      echo "FAIL: $name"
      echo "  needle:   [$needle]"
      echo "  haystack: [$haystack]"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Build fixture portfolio
# ---------------------------------------------------------------------------
SB=$(make_portfolio)
A1="$SB/docs/agdr/AgDR-0001-clean-architecture.md"
A2="$SB/docs/agdr/AgDR-0002-legacy-no-frontmatter.md"
A3="$SB/docs/agdr/AgDR-0003-mfa-required.md"

# ---------------------------------------------------------------------------
# Case 1: parse_frontmatter extracts only the leading --- block
# ---------------------------------------------------------------------------
fm=$(parse_frontmatter "$A1")
assert_contains "parse_frontmatter A1: contains category" "$fm" "category: architecture"
assert_contains "parse_frontmatter A1: contains id" "$fm" "id: AgDR-0001"

# Should NOT include body lines (everything after the closing ---).
case "$fm" in
  *"# Adopt clean"*)
    FAIL=$((FAIL + 1))
    echo "FAIL: parse_frontmatter A1 leaked body content"
    ;;
  *)
    PASS=$((PASS + 1))
    echo "PASS: parse_frontmatter A1: body excluded"
    ;;
esac

# ---------------------------------------------------------------------------
# Case 2: legacy AgDR with no frontmatter → empty parse output
# ---------------------------------------------------------------------------
fm2=$(parse_frontmatter "$A2")
assert_eq "parse_frontmatter A2 (legacy): empty output" "$fm2" ""

# ---------------------------------------------------------------------------
# Case 3: extract_category bucketing
# ---------------------------------------------------------------------------
assert_eq "extract_category A1: architecture" "$(extract_category "$A1")" "architecture"
assert_eq "extract_category A2: other (legacy default)" "$(extract_category "$A2")" "other"
assert_eq "extract_category A3: security" "$(extract_category "$A3")" "security"

# ---------------------------------------------------------------------------
# Case 4: extract_id reads from frontmatter
# ---------------------------------------------------------------------------
assert_eq "extract_id A1" "$(extract_id "$A1")" "AgDR-0001"
assert_eq "extract_id A3" "$(extract_id "$A3")" "AgDR-0003"
assert_eq "extract_id A2 (no frontmatter): empty" "$(extract_id "$A2")" ""

# ---------------------------------------------------------------------------
# Case 5: stats — count by category across the fixture
# Mirrors what /agdr stats does in aggregate.
# ---------------------------------------------------------------------------
# Use a flat counter file rather than associative arrays — keeps the test
# portable across bash versions (some macOS shells ship bash 3, no -A).
counts_file=$(mktemp)
total=0
for f in "$A1" "$A2" "$A3"; do
  c=$(extract_category "$f")
  echo "$c" >> "$counts_file"
  total=$((total + 1))
done

count_arch=$(grep -c '^architecture$' "$counts_file" || true)
count_sec=$(grep -c '^security$' "$counts_file" || true)
count_other=$(grep -c '^other$' "$counts_file" || true)
rm -f "$counts_file"

assert_eq "stats: architecture count" "$count_arch" "1"
assert_eq "stats: security count" "$count_sec" "1"
assert_eq "stats: other count (legacy bucket)" "$count_other" "1"
assert_eq "stats: total" "$total" "3"

# ---------------------------------------------------------------------------
# Case 6: search — case-insensitive grep across bodies finds matches
# Mirrors the /agdr search <term> path.
# ---------------------------------------------------------------------------
# grep -li returns matching filenames, one per line. Counting lines gives
# the file-match count directly. -i is case-insensitive (matches the skill
# spec); the term is treated as a fixed string via -F to avoid regex traps
# in the test inputs ("." in "rate.limit" was eating the space).
matches=$(grep -liF "rate-limit" "$A1" "$A2" "$A3" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "search 'rate-limit': 1 file matches" "$matches" "1"

mfa_matches=$(grep -liF "mfa" "$A1" "$A2" "$A3" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "search 'mfa': 1 file matches" "$mfa_matches" "1"

zero_matches=$(grep -liF "kubernetes" "$A1" "$A2" "$A3" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "search 'kubernetes': 0 file matches" "$zero_matches" "0"

# ---------------------------------------------------------------------------
# Case 7: an AgDR id appears in the filename even when frontmatter lacks it.
# Filename-derived id is the fallback show-resolver path.
# ---------------------------------------------------------------------------
fname_id=$(basename "$A2" | grep -oE '^AgDR-[0-9]+')
assert_eq "filename id fallback for legacy AgDR" "$fname_id" "AgDR-0002"

# ---------------------------------------------------------------------------
# Cleanup + summary
# ---------------------------------------------------------------------------
rm -rf "$SB"

echo
echo "----------------------------------------"
echo "Total: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
  printf "Failed cases:%b\n" "$FAILED_CASES"
  exit 1
fi
exit 0
