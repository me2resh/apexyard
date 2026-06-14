#!/usr/bin/env bash
# /extract-features smoke test
#
# Builds a synthetic codebase fixture covering Express routes + Prisma models
# (plus test names, jobs, and docs for good measure), runs the discovery
# signatures from SKILL.md against it as plain grep, and asserts each axis
# produces non-empty findings.
#
# The skill itself runs inside Claude Code with richer dispatch (LSP-aware
# walks, framework-specific signature matching, dedup, matrix consolidation).
# This smoke test verifies the *grep-fallback* path the skill documents — if
# the regexes in SKILL.md drift from what they're supposed to match, this
# script catches it.

set -euo pipefail

FIXTURE=$(mktemp -d -t extract-features-fixture-XXXXXX)
trap 'rm -rf "$FIXTURE"' EXIT

PASS=0
FAIL=0

assert_nonempty() {
  local label="$1"
  local count="$2"
  local min="${3:-1}"
  if [[ "$count" -ge "$min" ]]; then
    echo "  PASS: $label found $count item(s) (>= $min)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label found $count item(s) (expected >= $min)"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Build the fixture: a tiny Express + Prisma + Jest app with a BullMQ worker,
# a React page, a README features section, and a CHANGELOG.
# ---------------------------------------------------------------------------

mkdir -p "$FIXTURE/src/routes" "$FIXTURE/src/workers" "$FIXTURE/src/pages" \
         "$FIXTURE/prisma" "$FIXTURE/tests" "$FIXTURE/docs/features"

cat > "$FIXTURE/package.json" <<'JSON'
{
  "name": "fixture-app",
  "version": "0.1.0",
  "dependencies": {
    "express": "^4.19.0",
    "@prisma/client": "^5.0.0",
    "bullmq": "^5.0.0",
    "react": "^18.2.0",
    "react-router-dom": "^6.20.0"
  },
  "devDependencies": {
    "jest": "^29.0.0",
    "prisma": "^5.0.0"
  }
}
JSON

# --- Axis 2a: HTTP routes (Express)
cat > "$FIXTURE/src/routes/orders.js" <<'JS'
const express = require('express');
const router = express.Router();

// List orders for the authenticated customer
router.get('/api/orders', async (req, res) => {
  res.json([]);
});

// Create a new order with line items + payment intent
router.post('/api/orders', async (req, res) => {
  res.status(201).json({ id: 1 });
});

// Cancel a pending order
router.delete('/api/orders/:id', async (req, res) => {
  res.status(204).send();
});

module.exports = router;
JS

cat > "$FIXTURE/src/routes/auth.js" <<'JS'
const express = require('express');
const app = express();

app.post('/api/auth/login', (req, res) => res.json({ token: 'x' }));
app.post('/api/auth/logout', (req, res) => res.status(204).send());
app.post('/api/auth/password-reset', (req, res) => res.status(202).send());

module.exports = app;
JS

# --- Axis 2b: Data models (Prisma)
cat > "$FIXTURE/prisma/schema.prisma" <<'PRISMA'
datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

generator client {
  provider = "prisma-client-js"
}

model User {
  id                Int       @id @default(autoincrement())
  email             String    @unique
  emailVerifiedAt   DateTime?
  passwordHash      String
  createdAt         DateTime  @default(now())
  orders            Order[]
}

model Order {
  id          Int      @id @default(autoincrement())
  userId      Int
  user        User     @relation(fields: [userId], references: [id])
  totalCents  Int
  currency    String
  status      String   @default("pending")
  createdAt   DateTime @default(now())
  items       OrderItem[]
}

model OrderItem {
  id        Int    @id @default(autoincrement())
  orderId   Int
  order     Order  @relation(fields: [orderId], references: [id])
  sku       String
  quantity  Int
}
PRISMA

# --- Axis 2c: Async jobs (BullMQ + cron)
cat > "$FIXTURE/src/workers/email.js" <<'JS'
const { Queue, Worker } = require('bullmq');

const emailQueue = new Queue('email');

const worker = new Worker('email', async (job) => {
  // Send transactional email
  console.log('sending', job.data);
});

module.exports = { emailQueue, worker };
JS

cat > "$FIXTURE/src/workers/cleanup.js" <<'JS'
const cron = require('node-cron');

// Nightly cleanup of expired password-reset tokens
cron.schedule('0 3 * * *', async () => {
  // delete expired tokens
});
JS

# --- Axis 2d: Test names (Jest)
cat > "$FIXTURE/tests/orders.test.js" <<'JS'
describe('Order creation', () => {
  it('creates order with valid payload', async () => {});
  it('rejects invalid currency', async () => {});
  it('sends confirmation email on success', async () => {});
});

describe('Order cancellation', () => {
  it('allows the owner to cancel a pending order', async () => {});
  it('rejects cancel by non-owner', async () => {});
});
JS

cat > "$FIXTURE/tests/auth.test.js" <<'JS'
describe('Authentication', () => {
  it('logs in with valid credentials', async () => {});
  it('rejects login with wrong password', async () => {});
  it('sends password-reset email on request', async () => {});
});
JS

# --- Axis 2e: UI screens (React Router)
cat > "$FIXTURE/src/pages/router.jsx" <<'JSX'
import { BrowserRouter, Route, Routes } from 'react-router-dom';

export function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Home />} />
        <Route path="/orders" element={<OrdersPage />} />
        <Route path="/orders/:id" element={<OrderDetail />} />
        <Route path="/login" element={<LoginPage />} />
      </Routes>
    </BrowserRouter>
  );
}
JSX

cat > "$FIXTURE/src/pages/LoginPage.jsx" <<'JSX'
export function LoginPage() {
  return (
    <form>
      <input name="email" type="email" />
      <input name="password" type="password" />
      <button type="submit">Log in</button>
    </form>
  );
}
JSX

# --- Axis 2f: Documented features
cat > "$FIXTURE/README.md" <<'MD'
# fixture-app

A tiny e-commerce backend.

## Features

- Customer accounts with email/password authentication
- Password reset via email with one-time token
- Place orders with line items and currency
- Cancel pending orders (owner only)
- Nightly cleanup of expired tokens
MD

cat > "$FIXTURE/CHANGELOG.md" <<'MD'
# Changelog

## [Unreleased]

### Added
- Bulk-cancel endpoint for admins
- Order export to CSV

## [0.1.0] - 2026-01-15

### Added
- Initial customer auth
- Order create / list / cancel endpoints
MD

cat > "$FIXTURE/docs/features/orders.md" <<'MD'
# Orders feature

Customers can place orders containing one or more line items. Each order
records the customer, total in cents, currency, and status.
MD

# ---------------------------------------------------------------------------
# Run discovery axes against the fixture using the SKILL.md grep signatures
# ---------------------------------------------------------------------------

echo "Smoke test: /extract-features against synthetic fixture at $FIXTURE"
echo ""
echo "Axis 2a — HTTP routes (Express):"
ROUTES=$(grep -RhEo '(app|router)\.(get|post|put|patch|delete|all)\s*\(' "$FIXTURE/src" 2>/dev/null | wc -l | tr -d ' ')
assert_nonempty "Express route handlers" "$ROUTES" 5

echo ""
echo "Axis 2b — Data models (Prisma):"
MODELS=$(grep -cE '^\s*model\s+\w+\s*\{' "$FIXTURE/prisma/schema.prisma" 2>/dev/null || echo 0)
assert_nonempty "Prisma models" "$MODELS" 3

echo ""
echo "Axis 2c — Async jobs (BullMQ + cron):"
QUEUES=$(grep -rEo 'new (Queue|Worker)\s*\(' "$FIXTURE/src/workers" 2>/dev/null | wc -l | tr -d ' ')
CRONS=$(grep -rEo 'cron\.schedule\s*\(' "$FIXTURE/src/workers" 2>/dev/null | wc -l | tr -d ' ')
JOBS=$((QUEUES + CRONS))
assert_nonempty "BullMQ + cron handlers" "$JOBS" 2

echo ""
echo "Axis 2d — Test names (Jest):"
DESCRIBES=$(grep -REo 'describe\s*\(\s*['"'"'"`][^'"'"'"`]+['"'"'"`]' "$FIXTURE/tests" 2>/dev/null | wc -l | tr -d ' ')
ITS=$(grep -REo '\bit\s*\(\s*['"'"'"`][^'"'"'"`]+['"'"'"`]' "$FIXTURE/tests" 2>/dev/null | wc -l | tr -d ' ')
TESTS=$((DESCRIBES + ITS))
assert_nonempty "Jest describe + it strings" "$TESTS" 8

echo ""
echo "Axis 2e — UI screens (React Router):"
SCREENS=$(grep -REo '<Route\s+path=' "$FIXTURE/src/pages" 2>/dev/null | wc -l | tr -d ' ')
assert_nonempty "React Router routes" "$SCREENS" 3

echo ""
echo "Axis 2f — Documented features:"
DOC_LINES=0
if grep -qE '^##[[:space:]]+Features?' "$FIXTURE/README.md"; then
  DOC_LINES=$(awk '/^##[[:space:]]+Features?/{flag=1; next} /^##/{flag=0} flag && /^- /' "$FIXTURE/README.md" | wc -l | tr -d ' ')
fi
ADDED_LINES=$(grep -cE '^### Added' "$FIXTURE/CHANGELOG.md" 2>/dev/null || echo 0)
DOCS=$((DOC_LINES + ADDED_LINES))
assert_nonempty "README features + CHANGELOG Added blocks" "$DOCS" 3

echo ""
echo "Vendored-dir pruning sanity check:"
mkdir -p "$FIXTURE/node_modules/express"
echo 'app.get("/leak", () => {})' > "$FIXTURE/node_modules/express/index.js"
ROUTES_AFTER_PRUNE=$(grep -RhEo '(app|router)\.(get|post|put|patch|delete|all)\s*\(' "$FIXTURE/src" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$ROUTES_AFTER_PRUNE" -eq "$ROUTES" ]]; then
  echo "  PASS: scoping to src/ (not the whole tree) excludes node_modules/"
  PASS=$((PASS + 1))
else
  echo "  FAIL: route count changed when node_modules added; scoping is wrong"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "----------------------------------------"
echo "Total: $((PASS + FAIL))   Passed: $PASS   Failed: $FAIL"
echo "----------------------------------------"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo ""
echo "OK: all 7 discovery checks passed against the synthetic fixture."
exit 0
