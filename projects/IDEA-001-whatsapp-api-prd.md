# PRD: Self-hosted WhatsApp API Wrapper

**Status**: Approved
**Author**: zeyad sleem
**Created**: 2026-04-30
**Last Updated**: 2026-04-30

---

## Overview

### Problem Statement

The official WhatsApp Business API is expensive (charging per conversation), requires strict message template approvals, and involves a complex setup process. Third-party wrappers (like wawp.net) provide easier access but still charge subscription fees and limit total control over data.

Small to medium-sized businesses (SMBs) and internal IT/dev teams want to automate simple transactional messages (like sending an e-receipt from a POS or a late-arrival alert from a fingerprint scanner) without incurring recurring costs or dealing with Meta's official API bureaucracy.

### Target User

**Primary**: In-house software developers or IT administrators who need a simple, self-hosted webhook/API endpoint to plug into their existing local software (POS, ERP, or HR/Attendance systems).

**Secondary**: HR Managers / Business Owners who want real-time visibility into operations via WhatsApp. Employees / Customers who receive instant, convenient notifications on an app they already use daily.

### Goals

1. **Zero API costs** — Eliminate all per-message and subscription fees compared to official WhatsApp Business API or third-party wrappers like wawp.net.
2. **>98% delivery rate** — Ensure reliable message delivery for triggered notifications.
3. **<5 second latency** — Time from trigger event (fingerprint scan, POS sale) to WhatsApp message arrival.
4. **0% ban rate** — Maintain account safety by strictly controlling message volume and content (transactional only, no marketing).
5. **Self-hosting** — Full control over data, infrastructure, and customization without third-party dependencies.

### Non-Goals (Out of Scope)

- Official WhatsApp Business API integration or WhatsApp Business Manager submission
- Marketing or bulk messaging capabilities
- Rich media templates (images, videos, documents) — MVP is text-only
- Multi-device support beyond single WhatsApp number
- End-to-end encrypted chat handling (receive replies)
- Customer support chat functionality
- WhatsApp Communities or Group management

### Success Metrics

| Metric | Target | How Measured |
|--------|--------|--------------|
| API Cost | $0/month | Self-hosted infrastructure only |
| Delivery Rate | >98% | Logs/analytics dashboard |
| Message Latency | <5 seconds | Timestamp delta between trigger and delivery |
| Uptime | 99.5% | Server monitoring (uptime checks) |
| Ban Rate | 0% | Account status monitoring |
| Setup Time | <30 minutes | Time from server spin-up to first test message |

---

## User Stories

### US-1: POS E-Receipt Notification
> As a **retail store owner**, I want my **POS system to automatically send a WhatsApp receipt** to the customer after each purchase, so that they **receive instant proof of payment without requiring a printed receipt**.

**Acceptance Criteria**:

- [ ] POS sends a webhook to the API with customer phone and purchase details
- [ ] API formats and sends a text message with itemized receipt
- [ ] Message delivery status is logged and visible in dashboard
- [ ] Rate limiting prevents duplicate sends within 1 minute

---

### US-2: Attendance Alert
> As an **HR manager**, I want the **fingerprint/attendance system to trigger a WhatsApp notification** when an employee scans in late, so that **management gets real-time visibility into attendance issues**.

**Acceptance Criteria**:

- [ ] Attendance device sends webhook with employee ID and timestamp
- [ ] API looks up employee phone number from local database
- [ ] API sends "Late Arrival" alert to configured manager number
- [ ] Message includes employee name, time, and threshold status

---

### US-3: Inventory Low-Stock Alert
> As a **warehouse manager**, I want the **inventory system to alert me via WhatsApp** when stock falls below threshold, so that I can **reorder before items run out**.

**Acceptance Criteria**:

- [ ] Cron job or webhook triggers when stock < threshold
- [ ] API sends alert with item name, current qty, and reorder suggestion
- [ ] Multiple recipients can be configured per alert type

---

### US-4: Developer API Integration
> As a **software developer**, I want a **simple REST API endpoint** to send WhatsApp messages from my existing software, so that I **don't need to build custom WhatsApp integration from scratch**.

**Acceptance Criteria**:

- [ ] POST /send endpoint accepts JSON with phone, message, template
- [ ] API key authentication protects all endpoints
- [ ] Response includes message_id, status, and timestamp
- [ ] SDK/curl examples provided in documentation

---

## Edge Cases

| Scenario | Expected Behavior |
|----------|-------------------|
| WhatsApp Web session expires (phone disconnected) | API returns 503, sends alert to admin, provides QR code URL for re-auth |
| Message rate exceeds 50/minute | Queue messages, throttle to 1/second, log warning |
| Recipient phone number is invalid | Return 400 error with "invalid phone format" |
| Server restarts | Auto-reconnect WhatsApp session, resume queued messages |
| Network outage | Retry up to 3 times with exponential backoff, then mark as failed |
| Target phone has WhatsApp disabled | Log as "undelivered", don't retry |

---

## Requirements

### Functional Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| FR-1 | Send text message to single phone number via REST API | Must | Core MVP functionality |
| FR-2 | Authenticate API requests via API key | Must | Prevent unauthorized access |
| FR-3 | Log all message attempts with status (sent/failed/pending) | Must | For debugging and analytics |
| FR-4 | Dashboard to view message history and delivery status | Should | Simple web UI |
| FR-5 | Webhook receiver for external triggers (POS, attendance) | Should | Accept POST from external systems |
| FR-6 | Rate limiting to prevent spam/ban | Must | Configurable, default 60/min |
| FR-7 | Auto-reconnect on session loss | Should | Keep service running |
| FR-8 | Support for multiple recipient numbers | Could | For group alerts |
| FR-9 | Message templates (predefined formats) | Could | Reuse common messages |
| FR-10 | Health check endpoint for monitoring | Could | /health returns status |

### Non-Functional Requirements

| Category | Requirement | Target |
|----------|-------------|--------|
| Performance | API response time | <500ms for request ack |
| Performance | Message processing throughput | 10 messages/second |
| Security | API key storage | Environment variables, no plain text |
| Security | HTTPS/TLS | Required for production |
| Reliability | Session persistence | Auto-reconnect within 30 seconds |
| Reliability | Message queue durability | SQLite/JSON file persistence |
| Scalability | Concurrent connections | 1 WhatsApp session per instance (MVP) |

---

## Design

### User Flow

```
[External System: POS/Attendance/Inventory]
    |
    | (Webhook/HTTP POST)
    v
[Self-hosted WhatsApp API]
    |
    | (Send via Baileys/whatsapp-web.js)
    v
[WhatsApp Web Connection]
    |
    | (Deliver message)
    v
[End User Phone]
```

### Architecture

- **Runtime**: Node.js (Express/Fastify) or Python (FastAPI)
- **WhatsApp Library**: Baileys (Node.js) or PyWaifu (Python)
- **Database**: SQLite (simple, file-based) for message logs
- **Deployment**: Docker container on VPS/DigitalOcean

---

## Technical Notes

### Dependencies

| Dependency | Type | Status | Owner |
|------------|------|--------|-------|
| Baileys (whatsapp-web.js) | External (npm) | Ready | Open source community |
| Node.js 18+ | Runtime | Ready | - |
| SQLite | Database | Ready | - |
| Docker | Containerization | Ready | - |

### Technical Constraints

- **Session Management**: Requires initial QR code scan; session must be periodically refreshed (typically every 2-4 weeks)
- **Protocol Risk**: Unofficial API may break when Meta updates WhatsApp Web — requires monitoring library updates
- **Phone Number Dedicated**: One phone number per instance; cannot use personal number concurrently
- **No Official Support**: Cannot escalate to Meta if account is banned

---

## Launch Plan

### Rollout Strategy

- [ ] MVP: Single server, single WhatsApp number
- [ ] Internal testing with real POS/attendance systems
- [ ] Document setup process for self-hosting
- [ ] Release on GitHub as open source

### Phases

| Phase | Description | Target |
|-------|-------------|--------|
| 1 | Core API (send text, auth, logging) | Week 1-2 |
| 2 | Dashboard + rate limiting | Week 3 |
| 3 | Webhook integration | Week 4 |
| 4 | Docker deployment + docs | Week 5 |

---

## Open Questions

| Question | Owner | Status | Resolution |
|----------|-------|--------|------------|
| Which programming language/framework? | Dev | Open | Node.js (Baileys) vs Python (PyWaifu) — lean towards Node.js for larger ecosystem |
| How to handle message queue during downtime? | Dev | Open | In-memory queue with SQLite persistence |
| Should we include a simple UI for sending test messages? | Dev | Open | Yes, helps with debugging |
| What's the fallback if Baileys breaks after WhatsApp update? | Dev | Open | Monitor, patch quickly, document workaround |

---

## Timeline

| Milestone | Target Date | Status |
|-----------|-------------|--------|
| PRD Approved | 2026-05-01 | Pending |
| Core API Complete | 2026-05-15 | - |
| Dashboard + Rate Limiting | 2026-05-22 | - |
| Docker + Documentation | 2026-05-29 | - |
| Internal Testing | 2026-06-05 | - |
| Beta Release | 2026-06-12 | - |

---

## Approvals

| Role | Name | Date | Status |
|------|------|------|--------|
| Product Manager | zeyad sleem | 2026-04-30 | Author |
| Head of Product | | | Pending |
| Tech Lead | | | Pending |
| Head of Design | N/A | | Not Required |

---

*Related: IDEA-001 (Ideas Backlog)*
