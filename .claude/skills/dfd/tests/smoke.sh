#!/usr/bin/env bash
# /dfd smoke test
#
# Three fixtures:
#   1. Single-service repo (Express + Prisma + BullMQ + Stripe)
#      → assert all six discovery axes produce non-empty findings
#   2. Two synthetic services with a cross-service flow
#      → assert the trust boundary is placed between services
#   3. Code with @PII annotations + EMAIL_* env vars + user.email columns
#      → assert all three classification pathways fire
#
# This is the grep-fallback path. The skill itself dispatches richer
# logic via LSP when enabled; this test verifies the documented
# signatures actually match real code.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DFD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$(cd "$DFD_DIR/../../hooks" && pwd)"

# Sanity check the helper exists
if [ ! -f "$HOOKS_DIR/_lib-multi-repo-trace.sh" ]; then
  echo "FAIL: shared trace helper missing at $HOOKS_DIR/_lib-multi-repo-trace.sh" >&2
  exit 1
fi

TMPROOT=$(mktemp -d -t dfd-fixture-XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
FAILED_CASES=""

assert_yaml_has() {
  local label="$1"
  local file="$2"
  local needle="$3"
  if grep -qE "$needle" "$file" 2>/dev/null; then
    echo "  PASS: $label (matched: $needle)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected pattern: $needle)"
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  $label"
  fi
}

assert_count_ge() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  local min="$4"
  local count
  count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)
  if [ "$count" -ge "$min" ]; then
    echo "  PASS: $label found $count (>= $min)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label found $count (expected >= $min)"
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  $label"
  fi
}

# ---------------------------------------------------------------------------
# Fixture 1: single-service Express + Prisma + BullMQ + Stripe + Auth0
# ---------------------------------------------------------------------------

echo ""
echo "================================================================"
echo "Fixture 1: single-service repo, six-axis discovery"
echo "================================================================"

F1="$TMPROOT/billing-api"
mkdir -p "$F1/src/routes" "$F1/src/workers" "$F1/prisma"

cat > "$F1/package.json" <<'JSON'
{
  "name": "billing-api",
  "dependencies": {
    "express": "^4.19.0",
    "@prisma/client": "^5.0.0",
    "bullmq": "^5.0.0",
    "ioredis": "^5.0.0",
    "stripe": "^14.0.0",
    "@sendgrid/mail": "^8.0.0",
    "@auth0/auth0-spa-js": "^2.0.0"
  }
}
JSON

cat > "$F1/src/routes/charges.js" <<'JS'
const express = require('express');
const router = express.Router();

router.post('/api/charges', async (req, res) => {
  res.status(201).json({ id: 1 });
});

router.get('/api/charges/:id', async (req, res) => {
  res.json({});
});

// Admin route — triggers user_to_admin boundary
router.get('/admin/reconciliation', async (req, res) => {
  res.json([]);
});
JS

cat > "$F1/src/workers/email.js" <<'JS'
const { Queue, Worker } = require('bullmq');
const sg = require('@sendgrid/mail');

const emailQueue = new Queue('email');
const worker = new Worker('email', async (job) => {
  await sg.send({ to: job.data.email, subject: 'x', text: 'y' });
});
JS

cat > "$F1/src/workers/reconcile.js" <<'JS'
const cron = require('node-cron');
const Stripe = require('stripe');
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

cron.schedule('0 3 * * *', async () => {
  await stripe.charges.list({ limit: 100 });
});
JS

cat > "$F1/prisma/schema.prisma" <<'PRISMA'
datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

model User {
  id         Int    @id @default(autoincrement())
  email      String @unique
  passwordHash String
  phone_number String?
}

model Charge {
  id          Int    @id @default(autoincrement())
  userId      Int
  card_number String?
  cvv         String?
  exp_month   Int?
  amount      Int
}
PRISMA

cat > "$F1/.env.example" <<'ENV'
DATABASE_URL=postgresql://user:pass@localhost/db
STRIPE_SECRET_KEY=sk_test_xxx
SENDGRID_API_KEY=SG.xxx
JWT_SECRET=changeme
EMAIL_FROM=noreply@example.com
ENV

OUT1="$TMPROOT/discover-f1.yaml"
bash "$DFD_DIR/discover.sh" "$F1" > "$OUT1" 2>/dev/null

assert_yaml_has "Fixture 1: external auth detected (auth0)" "$OUT1" "auth_provider|external_auth"
assert_yaml_has "Fixture 1: stripe detected as ext_service"     "$OUT1" "ext_stripe|stripe"
assert_yaml_has "Fixture 1: sendgrid detected as ext_service"   "$OUT1" "ext_sendgrid|sendgrid"
assert_yaml_has "Fixture 1: public user actor"                  "$OUT1" "public_user|type:[[:space:]]*human"
assert_yaml_has "Fixture 1: admin user actor (admin/* route)"   "$OUT1" "admin_user"
assert_yaml_has "Fixture 1: HTTP API process"                   "$OUT1" "id:[[:space:]]*http_api"
assert_yaml_has "Fixture 1: queue workers process"              "$OUT1" "id:[[:space:]]*queue_workers"
assert_yaml_has "Fixture 1: scheduled jobs process"             "$OUT1" "id:[[:space:]]*scheduled_jobs"
assert_yaml_has "Fixture 1: Prisma/Postgres data store"         "$OUT1" "rdbms_prisma|postgresql"
assert_yaml_has "Fixture 1: Redis cache"                        "$OUT1" "cache_redis"
assert_yaml_has "Fixture 1: public-to-backend boundary"         "$OUT1" "public_to_backend"
assert_yaml_has "Fixture 1: user-to-admin boundary"             "$OUT1" "user_to_admin"
assert_yaml_has "Fixture 1: backend-to-data boundary"           "$OUT1" "backend_to_data"
assert_yaml_has "Fixture 1: us-to-third-party boundary"         "$OUT1" "us_to_third_party"
assert_yaml_has "Fixture 1: at least one data flow"             "$OUT1" "^[[:space:]]*-[[:space:]]*source:"

# ---------------------------------------------------------------------------
# Fixture 2: two-service cross-repo trace
# ---------------------------------------------------------------------------

echo ""
echo "================================================================"
echo "Fixture 2: cross-service trust-boundary detection"
echo "================================================================"

# Build a tiny apexyard fork sandbox with two registered projects.
SB="$TMPROOT/sandbox"
mkdir -p "$SB/.claude/hooks" "$SB/projects" "$SB/workspace/billing-api/src" "$SB/workspace/notifications-svc/src"
(cd "$SB" && git init -q && git config user.email t@t.com && git config user.name t)
# Canonicalise after git-init (macOS /var/ → /private/var/)
SB=$(cd "$SB" && pwd -P)

# Copy the helper + portfolio paths lib + config lib + defaults
cp "$HOOKS_DIR/_lib-multi-repo-trace.sh" "$SB/.claude/hooks/"
cp "$HOOKS_DIR/_lib-portfolio-paths.sh"  "$SB/.claude/hooks/"
cp "$HOOKS_DIR/_lib-read-config.sh"      "$SB/.claude/hooks/"
DEFAULTS_SRC="$(cd "$DFD_DIR/../.." && pwd)/project-config.defaults.json"
cp "$DEFAULTS_SRC" "$SB/.claude/project-config.defaults.json" 2>/dev/null || true

# Minimal ops-fork anchors
touch "$SB/onboarding.yaml"
cat > "$SB/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: billing-api
    repo: example-org/billing-api
    workspace: workspace/billing-api
    hostnames: [billing.internal]
  - name: notifications-svc
    repo: example-org/notifications-svc
    workspace: workspace/notifications-svc
    hostnames: [notify.internal]
YAML

# billing-api calls out to the notifications-svc (cross-service flow)
cat > "$SB/workspace/billing-api/src/notify.js" <<'JS'
const axios = require('axios');
async function notifyUser(userId, msg) {
  await axios.post('http://notify.internal/api/send', { userId, msg });
}
module.exports = { notifyUser };
JS

# Run the trace helper against the cross-service URL
RESULT=$(cd "$SB" && bash -c '
  source ./.claude/hooks/_lib-read-config.sh
  source ./.claude/hooks/_lib-portfolio-paths.sh
  source ./.claude/hooks/_lib-multi-repo-trace.sh
  mrt_resolve_target "http://notify.internal/api/send"
' 2>/dev/null)

if [ "$RESULT" = "notifications-svc" ]; then
  echo "  PASS: Fixture 2: cross-service hostname resolved to notifications-svc"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Fixture 2: cross-service hostname did not resolve (got: '$RESULT')"
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  Fixture 2: hostname resolution"
fi

# Third-party detection — Stripe URL should NOT resolve to a registered project
TP_RESULT=$(cd "$SB" && bash -c '
  source ./.claude/hooks/_lib-read-config.sh
  source ./.claude/hooks/_lib-portfolio-paths.sh
  source ./.claude/hooks/_lib-multi-repo-trace.sh
  mrt_resolve_target "https://api.stripe.com/v1/charges" 2>/dev/null
  echo "---"
  mrt_is_third_party "https://api.stripe.com/v1/charges"
' 2>/dev/null)

if echo "$TP_RESULT" | grep -q "^stripe$"; then
  echo "  PASS: Fixture 2: Stripe URL detected as known third-party"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Fixture 2: Stripe URL not detected (got: $TP_RESULT)"
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  Fixture 2: third-party detection"
fi

# Workspace path resolution — registered project, clone exists
WS_RESULT=$(cd "$SB" && bash -c '
  source ./.claude/hooks/_lib-read-config.sh
  source ./.claude/hooks/_lib-portfolio-paths.sh
  source ./.claude/hooks/_lib-multi-repo-trace.sh
  mrt_workspace_for "notifications-svc"
' 2>/dev/null)

if [ -n "$WS_RESULT" ] && [ -d "$WS_RESULT" ]; then
  echo "  PASS: Fixture 2: workspace resolved to $WS_RESULT"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Fixture 2: workspace for notifications-svc not resolved (got: $WS_RESULT)"
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  Fixture 2: workspace resolution"
fi

# ---------------------------------------------------------------------------
# Fixture 3: classification pathways — annotations + env vars + schema
# ---------------------------------------------------------------------------

echo ""
echo "================================================================"
echo "Fixture 3: data-classification three-pathway detection"
echo "================================================================"

F3="$TMPROOT/classified"
mkdir -p "$F3/src/models" "$F3/prisma"

cat > "$F3/package.json" <<'JSON'
{ "name": "classified-app", "dependencies": { "@prisma/client": "^5.0.0" } }
JSON

# Pathway 1: annotations
cat > "$F3/src/models/user.ts" <<'TS'
// User profile model.
export class User {
  id: number;
  // @PII — primary identifier and contact channel
  email: string;
  // CLASSIFIED: pii
  profileBio: string;
  // @Sensitive
  hashedPassword: string;
}
TS

# Pathway 2: env var heuristics
cat > "$F3/.env.example" <<'ENV'
DATABASE_URL=postgresql://localhost
STRIPE_SECRET_KEY=sk_test_xxx
JWT_SECRET=changeme
SENDGRID_API_KEY=SG.xxx
EMAIL_FROM=noreply@example.com
SMTP_HOST=smtp.example.com
TWILIO_AUTH_TOKEN=xxx
SOME_PUBLIC_FLAG=true
ENV

# Pathway 3: schema columns
cat > "$F3/prisma/schema.prisma" <<'PRISMA'
datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

model Customer {
  id            Int    @id @default(autoincrement())
  email         String @unique
  phone_number  String?
  ssn           String?
  card_number   String?
  cvv           String?
  first_name    String?
  last_name     String?
  ip_address    String?
}
PRISMA

OUT3="$TMPROOT/classify-f3.yaml"
bash "$DFD_DIR/classify.sh" "$F3" > "$OUT3" 2>/dev/null

assert_yaml_has "Fixture 3: annotation pathway @PII fires"        "$OUT3" "source:[[:space:]]*annotation"
assert_yaml_has "Fixture 3: annotation pathway label pii"         "$OUT3" 'label:[[:space:]]*"pii"'
assert_yaml_has "Fixture 3: annotation pathway @Sensitive fires"  "$OUT3" 'label:[[:space:]]*"sensitive"'

assert_yaml_has "Fixture 3: env-var pathway STRIPE_SECRET_KEY"    "$OUT3" "STRIPE_SECRET_KEY"
assert_yaml_has "Fixture 3: env-var pathway SENDGRID_API_KEY"     "$OUT3" "SENDGRID_API_KEY"
assert_yaml_has "Fixture 3: env-var pathway EMAIL_FROM (email-routing)" "$OUT3" "EMAIL_FROM"
assert_yaml_has "Fixture 3: env-var pathway secrets label"        "$OUT3" 'label:[[:space:]]*"secrets"'

assert_yaml_has "Fixture 3: schema pathway Prisma email column"   "$OUT3" "field:[[:space:]]*\"email\""
assert_yaml_has "Fixture 3: schema pathway Prisma phone_number"   "$OUT3" "field:[[:space:]]*\"phone_number\""
assert_yaml_has "Fixture 3: schema pathway Prisma ssn"            "$OUT3" "field:[[:space:]]*\"ssn\""
assert_yaml_has "Fixture 3: schema pathway Prisma card_number (PCI)" "$OUT3" "field:[[:space:]]*\"card_number\""
assert_yaml_has "Fixture 3: schema pathway PCI label"             "$OUT3" 'label:[[:space:]]*"pci"'

# Check that SOME_PUBLIC_FLAG is NOT classified (no heuristic pattern matches)
if grep -q "SOME_PUBLIC_FLAG" "$OUT3" 2>/dev/null; then
  echo "  FAIL: Fixture 3: SOME_PUBLIC_FLAG should NOT be classified (false positive)"
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  Fixture 3: false-positive guard"
else
  echo "  PASS: Fixture 3: SOME_PUBLIC_FLAG correctly NOT classified (no false positive)"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
# Fixture 4: Mermaid generator output shape (smoke — has key sections)
# ---------------------------------------------------------------------------

echo ""
echo "================================================================"
echo "Fixture 4: Mermaid generator output shape"
echo "================================================================"

MD_OUT="$TMPROOT/dfd-f1.md"
bash "$DFD_DIR/generate-mermaid.sh" "billing-api" "$OUT1" "$TMPROOT/classify-f1.yaml" > "$MD_OUT" 2>/dev/null

assert_yaml_has "Mermaid: has top-level heading"             "$MD_OUT" "^# billing-api — Data Flow Diagram"
assert_yaml_has "Mermaid: declares source-of-truth"          "$MD_OUT" "Source of truth"
assert_yaml_has "Mermaid: includes flowchart block"          "$MD_OUT" '^```mermaid'
assert_yaml_has "Mermaid: declares trust-boundary subgraphs" "$MD_OUT" "subgraph"
assert_yaml_has "Mermaid: trust-boundaries table"            "$MD_OUT" "^## Trust boundaries"
assert_yaml_has "Mermaid: data-classifications table"        "$MD_OUT" "^## Data classifications"
assert_yaml_has "Mermaid: provenance section"                "$MD_OUT" "Discovery provenance"
assert_yaml_has "Mermaid: footer signature"                  "$MD_OUT" "_Generated by .*/dfd.* on "

# ---------------------------------------------------------------------------
# Fixture 5: Threat Dragon JSON serialiser output shape
# ---------------------------------------------------------------------------

echo ""
echo "================================================================"
echo "Fixture 5: Threat Dragon JSON serialiser"
echo "================================================================"

if command -v jq >/dev/null 2>&1; then
  MODEL_JSON='{
    "project": "billing-api",
    "actors": [
      { "id": "public_user",  "name": "End user",  "type": "human" },
      { "id": "ext_stripe",   "name": "Stripe",    "type": "external_service" }
    ],
    "processes": [
      { "id": "http_api",     "name": "HTTP API",  "type": "http_handler" }
    ],
    "stores": [
      { "id": "rdbms_prisma", "name": "Postgres",  "type": "rdbms" }
    ],
    "flows": [
      { "source": "public_user", "target": "http_api",     "label": "auth token, request body" },
      { "source": "http_api",    "target": "rdbms_prisma", "label": "persistent records" },
      { "source": "http_api",    "target": "ext_stripe",   "label": "charge intent" }
    ],
    "boundaries": [
      { "id": "public_to_backend", "name": "Public Internet ↔ Backend",
        "rationale": "HTTP routes detected", "contains": ["http_api"] }
    ],
    "threats": [
      { "element": "http_api", "type": "S", "severity": "High",
        "description": "No rate limit on POST /api/charges",
        "mitigation": "Add per-IP rate limit (5/min)", "status": "Open" }
    ]
  }'

  DRAGON_OUT="$TMPROOT/dragon-f5.json"
  echo "$MODEL_JSON" | bash "$DFD_DIR/generate-dragon.sh" > "$DRAGON_OUT" 2>/dev/null

  # Validate it's parseable JSON
  if jq empty "$DRAGON_OUT" 2>/dev/null; then
    echo "  PASS: Dragon output is valid JSON"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: Dragon output is not valid JSON"
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  Fixture 5: JSON validity"
  fi

  # Required top-level v2 schema keys
  for key in version summary detail; do
    if jq -e ".$key" "$DRAGON_OUT" >/dev/null 2>&1; then
      echo "  PASS: Dragon output has top-level key '$key'"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: Dragon output missing top-level key '$key'"
      FAIL=$((FAIL + 1))
      FAILED_CASES="$FAILED_CASES\n  Fixture 5: missing key $key"
    fi
  done

  # Diagram has cells with the actor / process / store / boundary / flow types
  for shape in tm.actor tm.process tm.store tm.boundary tm.flow; do
    if jq -e ".detail.diagrams[0].cells[] | select(.type == \"$shape\")" "$DRAGON_OUT" >/dev/null 2>&1; then
      echo "  PASS: Dragon diagram has at least one '$shape' cell"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: Dragon diagram has no '$shape' cells"
      FAIL=$((FAIL + 1))
      FAILED_CASES="$FAILED_CASES\n  Fixture 5: missing shape $shape"
    fi
  done

  # Threats are attached to their parent element
  THREAT_COUNT=$(jq '[.detail.diagrams[0].cells[].data.threats // [] | length] | add' "$DRAGON_OUT")
  if [ "$THREAT_COUNT" -ge 1 ]; then
    echo "  PASS: Dragon output carries $THREAT_COUNT threat(s) attached to elements"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: Dragon output has no threats attached (expected >= 1)"
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  Fixture 5: threats not propagated"
  fi
else
  echo "  SKIP: jq not installed — skipping Threat Dragon JSON validation"
fi

# ---------------------------------------------------------------------------
# Fixture 6: /threat-model + /compliance-check consume the DFD file
# ---------------------------------------------------------------------------

echo ""
echo "================================================================"
echo "Fixture 6: downstream consumers reference dfd.md (no regeneration)"
echo "================================================================"

# Read the actual current SKILL.md for both consumers — assert they
# point at projects/<...>/architecture/dfd.md as the source.
TM_SKILL="$(cd "$DFD_DIR/.." && pwd)/threat-model/SKILL.md"
CC_SKILL="$(cd "$DFD_DIR/.." && pwd)/compliance-check/SKILL.md"

if grep -qE 'architecture/dfd\.md' "$TM_SKILL"; then
  echo "  PASS: /threat-model SKILL.md references projects/.../architecture/dfd.md"
  PASS=$((PASS + 1))
else
  echo "  FAIL: /threat-model SKILL.md does NOT reference dfd.md (refactor regressed)"
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  Fixture 6: /threat-model refactor"
fi

if grep -qE 'architecture/dfd\.md' "$CC_SKILL"; then
  echo "  PASS: /compliance-check SKILL.md references projects/.../architecture/dfd.md"
  PASS=$((PASS + 1))
else
  echo "  FAIL: /compliance-check SKILL.md does NOT reference dfd.md (refactor regressed)"
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  Fixture 6: /compliance-check refactor"
fi

# /threat-model should OFFER to run /dfd first if dfd.md is missing
if grep -qE '/dfd' "$TM_SKILL" && grep -qiE 'offer|fall back|run /dfd' "$TM_SKILL"; then
  echo "  PASS: /threat-model handles missing DFD (offer to run /dfd first OR fallback)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: /threat-model has no clear fallback for missing DFD"
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  Fixture 6: /threat-model missing-DFD handling"
fi

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
echo "OK: all /dfd smoke checks passed."
exit 0
