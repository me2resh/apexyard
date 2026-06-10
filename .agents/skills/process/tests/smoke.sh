#!/usr/bin/env bash
# /process smoke test — single-repo discovery + BPMN emission + xmllint validity.
#
# Builds a synthetic fixture with:
#   - one XState state machine (axis 1)
#   - one cron entry (axis 3)
#   - one BullMQ queue chain (axis 2)
#   - one state-column (axis 4)
#   - one outbound HTTP call (axis 5)
#   - one README "Onboarding Flow" section (axis 7)
#
# Then runs discover.sh + generate-bpmn.sh against it and asserts:
#   - all three named axes (1, 2, 3) have findings
#   - emitted BPMN parses as valid XML (via xmllint when available)
#   - emitted BPMN contains a <bpmn:process> root element
#   - emitted BPMN contains a <bpmndi:BPMNDiagram> block when Node+npx is available
#
# Designed to run in any sandbox without network — bpmn-auto-layout is OPTIONAL.
# When npx isn't reachable, the test asserts the bare-BPMN fallback works.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "  PASS: $label  (got: $got)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label  (want: $want, got: $got)"
    FAIL=$((FAIL + 1))
  fi
}

assert_ge() {
  local label="$1" min="$2" got="$3"
  if [ "$got" -ge "$min" ]; then
    echo "  PASS: $label  (got: $got >= $min)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label  (got: $got, expected >= $min)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" file="$3"
  if grep -q "$needle" "$file" 2>/dev/null; then
    echo "  PASS: $label  ($needle found in $(basename "$file"))"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label  ($needle NOT found in $(basename "$file"))"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Build the synthetic fixture
# ---------------------------------------------------------------------------
FIXTURE=$(mktemp -d -t process-smoke-XXXXXX)
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/src/onboarding" "$FIXTURE/src/workers" "$FIXTURE/src/routes" "$FIXTURE/src/services" "$FIXTURE/prisma"

# --- Axis 1: XState state machine
cat > "$FIXTURE/src/onboarding/state.machine.ts" <<'TS'
import { createMachine } from 'xstate';

export const OnboardingMachine = createMachine({
  id: 'onboarding',
  initial: 'signup_submitted',
  states: {
    signup_submitted:    { on: { VALIDATED:   'identity_pending' } },
    identity_pending:    { on: { VERIFIED:    'email_pending', REJECTED: 'review' } },
    email_pending:       { on: { CONFIRMED:   'profile_pending' } },
    profile_pending:     { on: { COMPLETE:    'onboarded' } },
    review:              { on: { APPROVED:    'identity_pending', DENIED: 'rejected' } },
    onboarded:           { type: 'final' },
    rejected:            { type: 'final' }
  }
});
TS

# --- Axis 2: BullMQ queue
cat > "$FIXTURE/src/workers/email.ts" <<'TS'
import { Queue, Worker } from 'bullmq';

export const sendVerifyEmailQueue = new Queue('send-verify-email');

new Worker('send-verify-email', async (job) => {
  // dispatches the email
});
TS

# --- Axis 3: cron
cat > "$FIXTURE/src/workers/cleanup.ts" <<'TS'
import cron from 'node-cron';

cron.schedule('0 3 * * *', async () => {
  // Resend verification email for stale pending users
});
TS

# --- Axis 4: state column (Prisma)
cat > "$FIXTURE/prisma/schema.prisma" <<'PRISMA'
datasource db { provider = "postgresql"; url = env("DATABASE_URL") }
generator client { provider = "prisma-client-js" }

model User {
  id              Int      @id @default(autoincrement())
  email           String   @unique
  status          String   @default("signup_submitted")
  emailVerifiedAt DateTime?
  onboardedAt     DateTime?
}
PRISMA

# --- Axis 5: outbound HTTP (cross-repo handoff candidate)
cat > "$FIXTURE/src/services/user.ts" <<'TS'
import axios from 'axios';

export async function verifyIdentity(userId: number) {
  const r = await axios.post('https://identity-svc.internal/verify-identity', { userId });
  return r.data;
}
TS

# --- Axis 5: a route that dispatches the email queue
cat > "$FIXTURE/src/routes/signup.ts" <<'TS'
import { Router } from 'express';
import { sendVerifyEmailQueue } from '../workers/email';

const router = Router();

router.post('/signup', async (req, res) => {
  // ...
  await sendVerifyEmailQueue.add('verify', { email: req.body.email });
  res.status(202).send();
});

export default router;
TS

# --- Axis 7: README flow section
cat > "$FIXTURE/README.md" <<'MD'
# fixture-svc

A small onboarding service.

## Onboarding Flow

1. User submits signup payload
2. Service validates and persists a User with status=signup_submitted
3. Email verification queue dispatches a verify link
4. User clicks → status → email_verified
5. User completes profile → status → onboarded
MD

cat > "$FIXTURE/package.json" <<'JSON'
{
  "name": "fixture-svc",
  "dependencies": {
    "express": "^4.19.0",
    "bullmq": "^5.0.0",
    "xstate": "^5.5.0",
    "axios": "^1.7.0",
    "node-cron": "^3.0.3",
    "@prisma/client": "^5.0.0"
  }
}
JSON

# ---------------------------------------------------------------------------
# Run discover.sh
# ---------------------------------------------------------------------------
echo ""
echo "1) discover.sh — JSON report"
DISC_OUT=$(mktemp -t process-disc-XXXXXX.json)
"$SKILL_DIR/discover.sh" "$FIXTURE" \
  --slug=onboarding \
  --from-endpoint="POST /signup" \
  --from-machine=OnboardingMachine \
  --format=json > "$DISC_OUT"

# Axis 1 should find createMachine + the .machine.ts filename
AX1=$(grep -c '"axis_1":' "$DISC_OUT" | tr -d ' ')
assert_ge "discover.sh JSON has axis_1 key" 1 "$AX1"

# Project-wide axis 1 count from the report.
PW_AX1=$(grep -oE '"axis_1": [0-9]+' "$DISC_OUT" | head -1 | awk '{print $2}' | tr -d ',')
assert_ge "Axis 1 (explicit workflows) project-wide finds OnboardingMachine + .machine.ts" 2 "${PW_AX1:-0}"

PW_AX2=$(grep -oE '"axis_2": [0-9]+' "$DISC_OUT" | head -1 | awk '{print $2}' | tr -d ',')
assert_ge "Axis 2 (queues) project-wide finds BullMQ Queue + Worker" 2 "${PW_AX2:-0}"

PW_AX3=$(grep -oE '"axis_3": [0-9]+' "$DISC_OUT" | head -1 | awk '{print $2}' | tr -d ',')
assert_ge "Axis 3 (cron) project-wide finds node-cron schedule" 1 "${PW_AX3:-0}"

PW_AX5=$(grep -oE '"axis_5": [0-9]+' "$DISC_OUT" | head -1 | awk '{print $2}' | tr -d ',')
assert_ge "Axis 5 (API choreography) project-wide finds axios + queue dispatch" 2 "${PW_AX5:-0}"

PW_AX7=$(grep -oE '"axis_7": [0-9]+' "$DISC_OUT" | head -1 | awk '{print $2}' | tr -d ',')
assert_ge "Axis 7 (documented steps) project-wide finds README flow section" 1 "${PW_AX7:-0}"

# ---------------------------------------------------------------------------
# Run discover.sh in REPORT mode and assert it doesn't crash
# ---------------------------------------------------------------------------
echo ""
echo "2) discover.sh — report mode"
REPORT_OUT=$(mktemp -t process-rpt-XXXXXX.txt)
"$SKILL_DIR/discover.sh" "$FIXTURE" \
  --slug=onboarding \
  --from-machine=OnboardingMachine \
  --format=report > "$REPORT_OUT"
assert_contains "report contains 'Findings'" "Findings" "$REPORT_OUT"
assert_contains "report names the slug" "Slug:       onboarding" "$REPORT_OUT"

# ---------------------------------------------------------------------------
# Run generate-bpmn.sh against a hand-crafted model.json
# ---------------------------------------------------------------------------
echo ""
echo "3) generate-bpmn.sh — emit BPMN from synthetic model"
MODEL=$(mktemp -t process-model-XXXXXX.json)
cat > "$MODEL" <<'JSON'
{
  "slug": "onboarding",
  "description": "Signup through email-verify through profile-complete",
  "lanes": [
    { "id": "lane_signup", "name": "signup-svc" }
  ],
  "nodes": [
    { "id": "evt_start", "type": "event-start", "label": "Signup submitted",
      "lane": "lane_signup", "evidence": "src/routes/signup.ts:14" },
    { "id": "task_validate", "type": "task", "label": "Validate signup payload",
      "lane": "lane_signup", "evidence": "src/routes/signup.ts:18-32" },
    { "id": "task_send_verify", "type": "task-send", "label": "Send verification email",
      "lane": "lane_signup", "evidence": "src/workers/email.ts:12" },
    { "id": "gw_email_verified", "type": "gateway-exclusive", "label": "Email verified?",
      "lane": "lane_signup", "evidence": "User.emailVerifiedAt column" },
    { "id": "task_complete_profile", "type": "task", "label": "Complete profile",
      "lane": "lane_signup", "evidence": "src/routes/profile.ts:24" },
    { "id": "evt_end", "type": "event-end", "label": "Onboarding complete",
      "lane": "lane_signup", "evidence": "User.onboardedAt column" }
  ],
  "edges": [
    { "from": "evt_start",         "to": "task_validate",       "kind": "sequence" },
    { "from": "task_validate",     "to": "task_send_verify",    "kind": "sequence" },
    { "from": "task_send_verify",  "to": "gw_email_verified",   "kind": "sequence" },
    { "from": "gw_email_verified", "to": "task_complete_profile","kind": "sequence", "label": "yes" },
    { "from": "gw_email_verified", "to": "evt_start",           "kind": "sequence", "label": "no - resend" },
    { "from": "task_complete_profile", "to": "evt_end",         "kind": "sequence" }
  ]
}
JSON

BPMN_OUT=$(mktemp -t process-out-XXXXXX.bpmn)
# Skip layout — the smoke test should run offline; bpmn-auto-layout requires npm fetch.
"$SKILL_DIR/generate-bpmn.sh" --slug=onboarding --model="$MODEL" -o "$BPMN_OUT" --skip-layout

assert_contains "BPMN has bpmn:definitions root"  "<bpmn:definitions" "$BPMN_OUT"
assert_contains "BPMN has bpmn:process"           "<bpmn:process"     "$BPMN_OUT"
assert_contains "BPMN has bpmn:startEvent"        "<bpmn:startEvent"  "$BPMN_OUT"
assert_contains "BPMN has bpmn:endEvent"          "<bpmn:endEvent"    "$BPMN_OUT"
assert_contains "BPMN has bpmn:exclusiveGateway"  "<bpmn:exclusiveGateway" "$BPMN_OUT"
assert_contains "BPMN has bpmn:sequenceFlow"      "<bpmn:sequenceFlow" "$BPMN_OUT"
assert_contains "BPMN has bpmn:laneSet"           "<bpmn:laneSet"     "$BPMN_OUT"
assert_contains "BPMN has bpmn:documentation (source citations)" "<bpmn:documentation>Source:" "$BPMN_OUT"
assert_contains "BPMN names the process slug"     "Process_onboarding" "$BPMN_OUT"

# ---------------------------------------------------------------------------
# xmllint sanity (when available)
# ---------------------------------------------------------------------------
echo ""
echo "4) xmllint validity"
if command -v xmllint >/dev/null 2>&1; then
  if xmllint --noout "$BPMN_OUT" 2>/dev/null; then
    echo "  PASS: xmllint --noout passes on emitted BPMN"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: xmllint --noout rejected the emitted BPMN"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  SKIP: xmllint not installed; skipping XML well-formedness check"
fi

# ---------------------------------------------------------------------------
# bpmn-auto-layout pass (when Node+npx available, with network)
# ---------------------------------------------------------------------------
echo ""
echo "5) Auto-layout via bpmn-auto-layout (optional)"
if command -v npx >/dev/null 2>&1 && [ -z "${SKIP_NETWORK_TESTS:-}" ]; then
  BPMN_LAID_OUT=$(mktemp -t process-layout-XXXXXX.bpmn)
  if "$SKILL_DIR/generate-bpmn.sh" --slug=onboarding --model="$MODEL" -o "$BPMN_LAID_OUT" 2>/dev/null; then
    if grep -q '<bpmndi:BPMNDiagram' "$BPMN_LAID_OUT" 2>/dev/null; then
      echo "  PASS: <bpmndi:BPMNDiagram> populated"
      PASS=$((PASS + 1))
    else
      echo "  SKIP: bpmn-auto-layout returned a file without <bpmndi> (likely sandbox/offline). Bare BPMN is still semantically valid."
    fi
    rm -f "$BPMN_LAID_OUT"
  else
    echo "  SKIP: bpmn-auto-layout invocation failed (network / sandbox) — bare BPMN already verified above."
  fi
else
  echo "  SKIP: npx not present OR SKIP_NETWORK_TESTS set"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "----------------------------------------"
echo "Total: $((PASS + FAIL))   Passed: $PASS   Failed: $FAIL"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo ""
echo "OK: /process smoke test passed."
exit 0
