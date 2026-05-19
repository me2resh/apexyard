#!/usr/bin/env bash
# /feature-diagram smoke test
#
# Four fixtures:
#   1. Inventory with 3 features — assert 3 per-feature files emitted
#      and each contains its feature title + a Mermaid flowchart block
#   2. Each emitted file passes the shared _lib-mermaid-lint.sh
#      (graceful-skip when Node/npx isn't available, exit 3)
#   3. Feature with only routes + screens (no models, no jobs) emits a
#      valid sub-graph — empty subgraphs render with "(none)" placeholders
#   4. Missing feature slug → exit 2 with a message listing available slugs

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_LINT="$SKILL_DIR/../_lib-mermaid-lint.sh"

PASS=0
FAIL=0
FAILED_CASES=""

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label (expected=$expected, actual=$actual)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected=$expected, actual=$actual)"
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  $label"
  fi
}

assert_file_contains() {
  local label="$1"
  local file="$2"
  local needle="$3"
  if grep -qE "$needle" "$file" 2>/dev/null; then
    echo "  PASS: $label (matched: $needle)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected pattern: $needle, in: $file)"
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  $label"
    # Helpful debug
    echo "  --- file preview ---" >&2
    head -50 "$file" >&2 || true
    echo "  --- end preview ---" >&2
  fi
}

assert_exit_code() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label (exit $actual)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected exit $expected, got $actual)"
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  $label"
  fi
}

# ---------------------------------------------------------------------------
# Fixture setup
# ---------------------------------------------------------------------------

TMPROOT=$(mktemp -d -t feature-diagram-fixture-XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

INVENTORY="$TMPROOT/feature-inventory.md"

# Synthesise a feature inventory with three features whose source axes vary:
#   - "Create order" — route + test + UI + job → all four subgraphs populated
#   - "Reset password" — route + test + UI + job → all four subgraphs populated
#   - "View order detail" — route + UI only → no models, no jobs (covers the
#     "empty subgraph renders with (none) placeholder" case)
cat > "$INVENTORY" <<'INV'
# fixture-app — Feature Inventory

**Date**: 2026-05-19
**Scanner**: `/extract-features` (apexyard)
**Scope**: fixture
**Stack detected**: Node + Express + Prisma

## Coverage scope

**Walked**: `src/`, `prisma/`, `tests/`

**Axes that produced findings**: 5 of 6

## Consolidated feature matrix

| # | Feature | Surface | Status | Source | Notes |
|---|---------|---------|--------|--------|-------|
| 1 | Create order | API + UI | Active | route + model + test + UI + job | POST /api/orders; charges Stripe; sends confirmation email |
| 2 | Reset password | API + UI | Active | route + model + test + UI + job | one-time token expires in 1h |
| 3 | View order detail | API + UI | Active | route + UI | GET /api/orders/:id; read-only |

## Per-axis findings

### HTTP routes / entry points (5)

| Method | Path | Handler | File | Notes |
|--------|------|---------|------|-------|
| POST | /api/orders | createOrder | src/routes/orders.js | order creation, charges Stripe |
| GET | /api/orders/:id | getOrder | src/routes/orders.js | order detail view |
| POST | /api/auth/password-reset | requestReset | src/routes/auth.js | password reset request |
| POST | /api/auth/password-reset/confirm | confirmReset | src/routes/auth.js | password reset confirmation |
| POST | /api/auth/login | loginUser | src/routes/auth.js | login flow |

### Data models / DB schema (3)

| Model | Table | Fields | Relations | File |
|-------|-------|--------|-----------|------|
| Order | orders | id, userId, total, status | belongs_to User | prisma/schema.prisma |
| User | users | id, email, passwordHash | has_many Order | prisma/schema.prisma |
| PasswordResetToken | password_reset_tokens | id, userId, token, expiresAt | belongs_to User | prisma/schema.prisma |

### Async jobs / queue handlers (2)

| Job | Trigger | Handler | File |
|-----|---------|---------|------|
| order-confirmation-email | BullMQ queue: email | sendOrderConfirmation | src/workers/email.js |
| password-reset-email | BullMQ queue: email | sendPasswordReset | src/workers/email.js |

### UI screens / forms / interactions (4)

| Route | Component | Fields | File |
|-------|-----------|--------|------|
| /orders/new | OrderForm | items, currency | src/pages/OrderForm.jsx |
| /orders/:id | OrderDetail | (read-only) | src/pages/OrderDetail.jsx |
| /password-reset | PasswordResetForm | email | src/pages/PasswordResetForm.jsx |
| /password-reset/confirm | PasswordConfirmForm | token, newPassword | src/pages/PasswordConfirmForm.jsx |

## Coverage gaps

- Business rules embedded in code logic
INV

# ---------------------------------------------------------------------------
# Fixture 1: 3 features → 3 per-feature files emitted
# ---------------------------------------------------------------------------

echo ""
echo "================================================================"
echo "Fixture 1: 3 features in inventory → 3 per-feature files emitted"
echo "================================================================"

for slug in create-order reset-password view-order-detail; do
  out="$TMPROOT/${slug}.md"
  set +e
  bash "$SKILL_DIR/generate.sh" "$INVENTORY" "$slug" "fixture-app" > "$out" 2>"$TMPROOT/${slug}.err"
  rc=$?
  set -e
  assert_exit_code "Fixture 1: generate $slug exits 0" 0 "$rc"
  if [ -f "$out" ] && [ -s "$out" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: Fixture 1: $slug.md exists and is non-empty"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: Fixture 1: $slug.md missing or empty"
    FAILED_CASES="$FAILED_CASES\n  Fixture 1: $slug.md not produced"
    cat "$TMPROOT/${slug}.err" >&2 || true
  fi
done

# Shape checks on each emitted file
for slug in create-order reset-password view-order-detail; do
  out="$TMPROOT/${slug}.md"
  assert_file_contains "Fixture 1: $slug has feature title heading" \
    "$out" "^# [A-Z]"
  assert_file_contains "Fixture 1: $slug has Mermaid flowchart block" \
    "$out" '^```mermaid'
  assert_file_contains "Fixture 1: $slug uses flowchart LR" \
    "$out" 'flowchart LR'
  assert_file_contains "Fixture 1: $slug has four subgraphs" \
    "$out" 'subgraph (Screens|Routes|Models|Jobs)'
  assert_file_contains "Fixture 1: $slug has footer signature" \
    "$out" '_Generated by .*/feature-diagram.* on '
  assert_file_contains "Fixture 1: $slug links back to inventory" \
    "$out" 'feature-inventory.md'
  assert_file_contains "Fixture 1: $slug declares Participating elements" \
    "$out" '^## Participating elements'
done

# ---------------------------------------------------------------------------
# Fixture 2: each emitted file passes Mermaid lint
# ---------------------------------------------------------------------------

echo ""
echo "================================================================"
echo "Fixture 2: each per-feature file passes _lib-mermaid-lint.sh"
echo "================================================================"

if [ ! -f "$LIB_LINT" ]; then
  echo "  FAIL: Fixture 2: _lib-mermaid-lint.sh not found at $LIB_LINT"
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  Fixture 2: lint lib missing"
else
  for slug in create-order reset-password view-order-detail; do
    out="$TMPROOT/${slug}.md"
    set +e
    bash "$LIB_LINT" "$out" > "$TMPROOT/${slug}.lint.out" 2>&1
    rc=$?
    set -e
    case "$rc" in
      0)
        echo "  PASS: Fixture 2: $slug lints clean (mmdc parsed all blocks)"
        PASS=$((PASS + 1))
        ;;
      3)
        echo "  PASS: Fixture 2: $slug — lint graceful-skipped (Node/npx not available, exit 3)"
        PASS=$((PASS + 1))
        ;;
      *)
        echo "  FAIL: Fixture 2: $slug lint failed (exit $rc)"
        cat "$TMPROOT/${slug}.lint.out" >&2 || true
        FAIL=$((FAIL + 1))
        FAILED_CASES="$FAILED_CASES\n  Fixture 2: $slug lint failed"
        ;;
    esac
  done
fi

# ---------------------------------------------------------------------------
# Fixture 3: feature with only routes + screens emits valid sub-graph
# (empty Models + Jobs subgraphs render with (none) placeholders)
# ---------------------------------------------------------------------------

echo ""
echo "================================================================"
echo "Fixture 3: routes + screens only (empty Models/Jobs subgraphs)"
echo "================================================================"

view_out="$TMPROOT/view-order-detail.md"
assert_file_contains "Fixture 3: Models subgraph rendered (even when empty)" \
  "$view_out" 'subgraph Models'
assert_file_contains "Fixture 3: Jobs subgraph rendered (even when empty)" \
  "$view_out" 'subgraph Jobs'
# Empty subgraphs must contain the (none) placeholder so Mermaid is valid.
assert_file_contains "Fixture 3: Models empty placeholder present" \
  "$view_out" 'Models_empty\["\(none\)"\]'
assert_file_contains "Fixture 3: Jobs empty placeholder present" \
  "$view_out" 'Jobs_empty\["\(none\)"\]'
# And the populated axes have real nodes.
assert_file_contains "Fixture 3: Routes has at least one node" \
  "$view_out" 'route_'
assert_file_contains "Fixture 3: Screens has at least one node" \
  "$view_out" 'screen_'

# ---------------------------------------------------------------------------
# Fixture 4: missing feature slug → exit 2 with available slugs listed
# ---------------------------------------------------------------------------

echo ""
echo "================================================================"
echo "Fixture 4: unknown slug → exit 2 with helpful message"
echo "================================================================"

set +e
bash "$SKILL_DIR/generate.sh" "$INVENTORY" "nonexistent-feature" "fixture-app" \
  > "$TMPROOT/nonexistent.out" 2> "$TMPROOT/nonexistent.err"
rc=$?
set -e
assert_exit_code "Fixture 4: unknown slug exits 2" 2 "$rc"
assert_file_contains "Fixture 4: stderr names the missing slug" \
  "$TMPROOT/nonexistent.err" "nonexistent-feature"
assert_file_contains "Fixture 4: stderr lists 'Available slugs'" \
  "$TMPROOT/nonexistent.err" "Available slugs:"
assert_file_contains "Fixture 4: stderr lists at least one real slug" \
  "$TMPROOT/nonexistent.err" "create-order|reset-password|view-order-detail"

# ---------------------------------------------------------------------------
# Fixture 5: missing inventory → exit 2
# ---------------------------------------------------------------------------

echo ""
echo "================================================================"
echo "Fixture 5: missing inventory → exit 2"
echo "================================================================"

set +e
bash "$SKILL_DIR/generate.sh" "$TMPROOT/nope.md" "create-order" "fixture-app" \
  > /dev/null 2> "$TMPROOT/missing-inv.err"
rc=$?
set -e
assert_exit_code "Fixture 5: missing inventory exits 2" 2 "$rc"
assert_file_contains "Fixture 5: stderr names the missing file" \
  "$TMPROOT/missing-inv.err" "not found"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "================================================================"
echo "Total: $((PASS + FAIL))   Passed: $PASS   Failed: $FAIL"
echo "================================================================"

if [ "$FAIL" -gt 0 ]; then
  echo -e "Failures:$FAILED_CASES"
  exit 1
fi
echo "OK: all /feature-diagram smoke checks passed."
exit 0
