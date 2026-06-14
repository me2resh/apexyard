#!/usr/bin/env bash
# /extract-features --with-mockups smoke test
#
# Validates the static-analysis signatures the skill uses to infer ASCII
# wireframes per UI screen, plus the trust-contract guarantees: every
# wireframe carries the AI-inferred disclaimer header, and the `## Screens`
# section is absent when the flag is not set.
#
# The skill itself runs inside Claude Code with richer dispatch (LSP-aware
# walks, framework-specific signature matching, inference). This script
# verifies:
#
#   1. The grep-fallback signatures in SKILL.md § 4b match the four canonical
#      screen archetypes (form-heavy, table-heavy, modal, dashboard).
#   2. A reference inventory rendered with --with-mockups carries the
#      mandatory disclaimer on every wireframe and respects the 80-char
#      width cap.
#   3. A reference inventory rendered WITHOUT the flag has no `## Screens`
#      section (backward-compat).
#
# If the signature regexes in SKILL.md drift, or the disclaimer pattern
# changes, this script catches it.

set -euo pipefail

FIXTURE=$(mktemp -d -t extract-features-mockups-XXXXXX)
trap 'rm -rf "$FIXTURE"' EXIT

PASS=0
FAIL=0

assert_match() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — pattern '$pattern' not found in $file"
    FAIL=$((FAIL + 1))
  fi
}

assert_nomatch() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if ! grep -qE "$pattern" "$file" 2>/dev/null; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — pattern '$pattern' unexpectedly found in $file"
    FAIL=$((FAIL + 1))
  fi
}

assert_count_ge() {
  local label="$1"
  local count="$2"
  local min="$3"
  if [[ "$count" -ge "$min" ]]; then
    echo "  PASS: $label ($count >= $min)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label ($count < $min)"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Build the fixture: four screen archetypes the skill must handle.
# ---------------------------------------------------------------------------

mkdir -p "$FIXTURE/src/pages" "$FIXTURE/src/components" "$FIXTURE/prisma" \
         "$FIXTURE/inventory"

cat > "$FIXTURE/package.json" <<'JSON'
{
  "name": "mockup-fixture",
  "dependencies": {
    "react": "^18.2.0",
    "react-router-dom": "^6.20.0",
    "react-hook-form": "^7.50.0",
    "@prisma/client": "^5.0.0"
  }
}
JSON

# --- A: form-heavy screen — Sign-up form with text, password, email, checkbox
cat > "$FIXTURE/src/pages/SignupPage.jsx" <<'JSX'
import { TopNav } from '../components/TopNav';
import { Footer } from '../components/Footer';
import { useForm } from 'react-hook-form';

export function SignupPage() {
  const { register, handleSubmit } = useForm();
  return (
    <>
      <TopNav />
      <form onSubmit={handleSubmit(() => {})}>
        <input type="email" {...register('email')} />
        <input type="password" {...register('password')} />
        <input type="password" {...register('confirmPassword')} />
        <input type="checkbox" {...register('acceptTerms')} />
        <button type="submit">Create account</button>
        <button type="button">Cancel</button>
      </form>
      <Footer />
    </>
  );
}
JSX

# --- B: table-heavy screen — Orders list with DataGrid
cat > "$FIXTURE/src/pages/OrdersPage.jsx" <<'JSX'
import { TopNav } from '../components/TopNav';
import { DataGrid } from '../components/DataGrid';

export function OrdersPage() {
  return (
    <>
      <TopNav />
      <main>
        <h1>Orders</h1>
        <button>New order</button>
        <DataGrid model="Order" columns={['id', 'customer', 'total', 'status', 'createdAt']} />
      </main>
    </>
  );
}
JSX

# --- C: modal screen — Confirm-delete dialog
cat > "$FIXTURE/src/components/ConfirmDeleteModal.jsx" <<'JSX'
import { Modal } from './Modal';

export function ConfirmDeleteModal({ onCancel, onConfirm }) {
  return (
    <Modal title="Confirm deletion">
      <p>Are you sure you want to delete this order? This action cannot be undone.</p>
      <button onClick={onCancel}>Cancel</button>
      <button onClick={onConfirm}>Delete</button>
    </Modal>
  );
}
JSX

# --- D: dashboard screen — Sidebar + cards + chart placeholder
cat > "$FIXTURE/src/pages/DashboardPage.jsx" <<'JSX'
import { TopNav } from '../components/TopNav';
import { Sidebar } from '../components/Sidebar';
import { Card } from '../components/Card';
import { Chart } from '../components/Chart';

export function DashboardPage() {
  return (
    <>
      <TopNav />
      <div className="layout">
        <Sidebar />
        <main>
          <Card title="Orders today" value="142" />
          <Card title="Revenue (MTD)" value="$12,840" />
          <Card title="Active users" value="893" />
          <Chart series="orders" />
        </main>
      </div>
    </>
  );
}
JSX

# --- Supporting Prisma model for field-type inference
cat > "$FIXTURE/prisma/schema.prisma" <<'PRISMA'
model User {
  id              Int      @id @default(autoincrement())
  email           String   @unique
  password        String
  confirmPassword String
  acceptTerms     Boolean  @default(false)
}

model Order {
  id         Int      @id @default(autoincrement())
  customer   String
  total      Int
  status     String
  createdAt  DateTime @default(now())
}
PRISMA

# ---------------------------------------------------------------------------
# Validate static-analysis signatures (the inputs the inference rules use)
# ---------------------------------------------------------------------------

echo "Smoke test: /extract-features --with-mockups against fixture at $FIXTURE"
echo ""

echo "Form-heavy detection (SignupPage):"
FORM_FIELDS=$(grep -cE '<input\s+type="(text|email|password|number|checkbox)"' "$FIXTURE/src/pages/SignupPage.jsx" 2>/dev/null || echo 0)
assert_count_ge "input fields detected" "$FORM_FIELDS" 4

USEFORM=$(grep -cE 'useForm\s*\(' "$FIXTURE/src/pages/SignupPage.jsx" 2>/dev/null || echo 0)
assert_count_ge "useForm() hook detected" "$USEFORM" 1

CHECKBOX=$(grep -cE '<input\s+type="checkbox"' "$FIXTURE/src/pages/SignupPage.jsx" 2>/dev/null || echo 0)
assert_count_ge "checkbox field detected" "$CHECKBOX" 1

SUBMIT_BTN=$(grep -cE '<button\s+type="submit"' "$FIXTURE/src/pages/SignupPage.jsx" 2>/dev/null || echo 0)
assert_count_ge "submit button detected" "$SUBMIT_BTN" 1

echo ""
echo "Table-heavy detection (OrdersPage):"
DATAGRID=$(grep -cE '<DataGrid\b' "$FIXTURE/src/pages/OrdersPage.jsx" 2>/dev/null || echo 0)
assert_count_ge "DataGrid component detected" "$DATAGRID" 1

echo ""
echo "Modal detection (ConfirmDeleteModal):"
MODAL=$(grep -cE '<Modal\b' "$FIXTURE/src/components/ConfirmDeleteModal.jsx" 2>/dev/null || echo 0)
assert_count_ge "Modal root component detected" "$MODAL" 1

echo ""
echo "Dashboard detection (DashboardPage):"
SIDEBAR=$(grep -cE '<Sidebar\b|import\s+\{\s*Sidebar' "$FIXTURE/src/pages/DashboardPage.jsx" 2>/dev/null || echo 0)
assert_count_ge "Sidebar import detected" "$SIDEBAR" 1

CARDS=$(grep -cE '<Card\b' "$FIXTURE/src/pages/DashboardPage.jsx" 2>/dev/null || echo 0)
assert_count_ge "Card components detected" "$CARDS" 3

CHART=$(grep -cE '<Chart\b|import\s+\{\s*Chart' "$FIXTURE/src/pages/DashboardPage.jsx" 2>/dev/null || echo 0)
assert_count_ge "Chart component detected" "$CHART" 1

TOPNAV=$(grep -lE '<TopNav\s*/?>|import\s+\{\s*TopNav' "$FIXTURE/src/pages/"*.jsx 2>/dev/null | wc -l | tr -d ' ')
assert_count_ge "TopNav used across pages" "$TOPNAV" 3

# ---------------------------------------------------------------------------
# Validate field-type inference from the Prisma model
# ---------------------------------------------------------------------------

echo ""
echo "Field-type inference (Prisma model):"
STRING_FIELDS=$(grep -cE '^\s*\w+\s+String' "$FIXTURE/prisma/schema.prisma" 2>/dev/null || echo 0)
assert_count_ge "String fields detected" "$STRING_FIELDS" 4

BOOL_FIELDS=$(grep -cE '^\s*\w+\s+Boolean' "$FIXTURE/prisma/schema.prisma" 2>/dev/null || echo 0)
assert_count_ge "Boolean fields detected" "$BOOL_FIELDS" 1

INT_FIELDS=$(grep -cE '^\s*\w+\s+Int' "$FIXTURE/prisma/schema.prisma" 2>/dev/null || echo 0)
assert_count_ge "Int fields detected" "$INT_FIELDS" 1

# ---------------------------------------------------------------------------
# Build a *reference* inventory file that the skill should produce with
# --with-mockups, and validate the trust-contract guarantees on it.
#
# This is what the skill writes when it runs end-to-end. We assert the shape
# directly so SKILL.md drift on the contract (disclaimer, width, structure)
# fails CI.
# ---------------------------------------------------------------------------

INVENTORY_WITH="$FIXTURE/inventory/feature-inventory-with-mockups.md"
INVENTORY_WITHOUT="$FIXTURE/inventory/feature-inventory.md"

cat > "$INVENTORY_WITH" <<'INV'
# mockup-fixture — Feature Inventory

**Date**: 2026-05-19
**Scanner**: `/extract-features --with-mockups` (apexyard)
**Scope**: /tmp/mockup-fixture
**Stack detected**: TypeScript + React + Prisma

## Consolidated feature matrix

| # | Feature | Surface | Status | Source | Notes |
|---|---------|---------|--------|--------|-------|
| 1 | Sign up | UI | Active | UI + model | password confirm, accept-terms |
| 2 | List orders | UI | Active | UI + model | table view |

## Per-axis findings

### UI screens / forms / interactions (4)

| Route | Component | Fields | File |
|-------|-----------|--------|------|
| /signup | SignupPage | email, password, confirmPassword, acceptTerms | src/pages/SignupPage.jsx |
| /orders | OrdersPage | (table) | src/pages/OrdersPage.jsx |
| (modal) | ConfirmDeleteModal | — | src/components/ConfirmDeleteModal.jsx |
| /dashboard | DashboardPage | — | src/pages/DashboardPage.jsx |

## Screens

### 1. Sign up

> AI-inferred sketch — verify before relying on. Source: src/pages/SignupPage.jsx

```
+----------------------------------------------------------------------------+
| TopNav: [Logo]  Home  Orders  Account                          [Log out]  |
+----------------------------------------------------------------------------+
|                                                                            |
|   Sign up                                                                  |
|                                                                            |
|   Email:            [ _______________________________________________ ]    |
|   Password:         [ _______________________________________________ ]    |
|   Confirm password: [ _______________________________________________ ]    |
|   [ ] I accept the terms of service                                        |
|                                                                            |
|   [ Create account ]   [ Cancel ]                                          |
|                                                                            |
+----------------------------------------------------------------------------+
| Footer                                                                     |
+----------------------------------------------------------------------------+
```

### 2. Orders list

> AI-inferred sketch — verify before relying on. Source: src/pages/OrdersPage.jsx

```
+----------------------------------------------------------------------------+
| TopNav: [Logo]  Home  Orders  Account                          [Log out]  |
+----------------------------------------------------------------------------+
|                                                                            |
|   Orders                                            [ New order ]          |
|                                                                            |
|   +-------+-------------+----------+--------+----------+-----------+       |
|   | ID    | Customer    | Total    | Status | Created  |           |       |
|   +-------+-------------+----------+--------+----------+-----------+       |
|   | 1001  | ...         | ...      | ...    | ...      | [ View ]  |       |
|   | 1002  | ...         | ...      | ...    | ...      | [ View ]  |       |
|   | 1003  | ...         | ...      | ...    | ...      | [ View ]  |       |
|   +-------+-------------+----------+--------+----------+-----------+       |
|                                                                            |
+----------------------------------------------------------------------------+
```

### 3. Confirm-delete modal

> AI-inferred sketch — verify before relying on. Source: src/components/ConfirmDeleteModal.jsx

```
+----------------------------------------------------------------------------+
|  (dimmed background)                                                       |
|                                                                            |
|             +----------------------------------------------+               |
|             |  Confirm deletion                       [X]  |               |
|             +----------------------------------------------+               |
|             |                                              |               |
|             |  Are you sure you want to delete this        |               |
|             |  order? This action cannot be undone.        |               |
|             |                                              |               |
|             |              [ Cancel ]   [ Delete ]         |               |
|             +----------------------------------------------+               |
|                                                                            |
+----------------------------------------------------------------------------+
```

### 4. Dashboard

> AI-inferred sketch — verify before relying on. Source: src/pages/DashboardPage.jsx

```
+----------------------------------------------------------------------------+
| TopNav: [Logo]  Home  Orders  Account                          [Log out]  |
+--------------+-------------------------------------------------------------+
| Sidebar      |                                                             |
|  - Overview  |   Overview                                                  |
|  - Orders    |                                                             |
|  - Users     |   +----------------+ +----------------+ +----------------+  |
|              |   | Orders today   | | Revenue (MTD)  | | Active users   |  |
|              |   |   [   142   ]  | |  [  $12,840 ]  | |   [   893   ]  |  |
|              |   +----------------+ +----------------+ +----------------+  |
|              |                                                             |
|              |   Orders over time                                          |
|              |   [ chart placeholder ]                                     |
+--------------+-------------------------------------------------------------+
```

## Coverage gaps
INV

cat > "$INVENTORY_WITHOUT" <<'INV'
# mockup-fixture — Feature Inventory

**Date**: 2026-05-19
**Scanner**: `/extract-features` (apexyard)
**Scope**: /tmp/mockup-fixture
**Stack detected**: TypeScript + React + Prisma

## Consolidated feature matrix

| # | Feature | Surface | Status | Source | Notes |
|---|---------|---------|--------|--------|-------|
| 1 | Sign up | UI | Active | UI + model | password confirm, accept-terms |

## Per-axis findings

### UI screens / forms / interactions (4)

| Route | Component | Fields | File |
|-------|-----------|--------|------|
| /signup | SignupPage | ... | src/pages/SignupPage.jsx |

## Coverage gaps
INV

echo ""
echo "Trust-contract checks on the reference inventory (--with-mockups):"

# Every wireframe section must carry the disclaimer header
DISCLAIMERS=$(grep -cE '^> AI-inferred sketch — verify before relying on\. Source: ' "$INVENTORY_WITH" 2>/dev/null || echo 0)
SCREENS=$(grep -cE '^### [0-9]+\. ' "$INVENTORY_WITH" 2>/dev/null || echo 0)
if [[ "$DISCLAIMERS" -eq "$SCREENS" && "$DISCLAIMERS" -ge 4 ]]; then
  echo "  PASS: every screen ($SCREENS) has a disclaimer header ($DISCLAIMERS)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: $SCREENS screens, $DISCLAIMERS disclaimers (must be equal and >= 4)"
  FAIL=$((FAIL + 1))
fi

assert_match "## Screens section present with --with-mockups" '^## Screens$' "$INVENTORY_WITH"
assert_match "form wireframe has text input pattern" '\[ _+ \]' "$INVENTORY_WITH"
assert_match "form wireframe has checkbox pattern" '\[ \] I accept' "$INVENTORY_WITH"
assert_match "form wireframe has button pattern" '\[ Create account \]' "$INVENTORY_WITH"
assert_match "table wireframe has ASCII grid header separator" '^\|.*\+\-+\+' "$INVENTORY_WITH"
assert_match "modal wireframe references modal/dialog box" 'Confirm deletion' "$INVENTORY_WITH"
assert_match "dashboard wireframe has sidebar and cards" 'Sidebar' "$INVENTORY_WITH"
assert_match "dashboard wireframe has chart placeholder" 'chart' "$INVENTORY_WITH"

# 80-char width cap — applies only inside the wireframe code-blocks (the
# boxed ASCII). Disclaimer headers, surrounding markdown prose, and the
# inventory's tables are not part of the wireframe contract.
echo ""
echo "80-char width cap (inside wireframe code-blocks only):"
OVERLONG=$(awk '
  /^```/ { in_block = !in_block; next }
  in_block && length($0) > 80 { print NR": "length($0)" chars" }
' "$INVENTORY_WITH" | wc -l | tr -d ' ')
if [[ "$OVERLONG" -eq 0 ]]; then
  echo "  PASS: no wireframe lines exceed 80 chars"
  PASS=$((PASS + 1))
else
  echo "  FAIL: $OVERLONG wireframe line(s) exceed 80 chars"
  awk '
    /^```/ { in_block = !in_block; next }
    in_block && length($0) > 80 { print NR": "length($0)" chars: "$0 }
  ' "$INVENTORY_WITH"
  FAIL=$((FAIL + 1))
fi

# Backward-compat: WITHOUT --with-mockups, no ## Screens section
echo ""
echo "Backward-compat check (without --with-mockups):"
assert_nomatch "no ## Screens section in default inventory" '^## Screens$' "$INVENTORY_WITHOUT"
assert_nomatch "no AI-inferred disclaimer in default inventory" 'AI-inferred sketch' "$INVENTORY_WITHOUT"

echo ""
echo "----------------------------------------"
echo "Total: $((PASS + FAIL))   Passed: $PASS   Failed: $FAIL"
echo "----------------------------------------"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo ""
echo "OK: all --with-mockups smoke checks passed."
exit 0
