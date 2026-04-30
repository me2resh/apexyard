# Technical Design: Self-hosted WhatsApp API Wrapper

**Status**: Draft
**Author**: zeyad sleem (Tech Lead)
**Date**: 2026-04-30
**PRD**: [IDEA-001 WhatsApp API PRD](./IDEA-001-whatsapp-api-prd.md)

---

## Overview

### Summary

We are building a self-hosted WhatsApp API wrapper using Node.js and the Baileys library. It will provide a REST API and webhook receiver for internal systems (like POS and HR) to send automated, transactional text messages via a dedicated WhatsApp number, saving costs on the official API.

### Goals

- Deliver a zero-cost API wrapper for sending WhatsApp text messages.
- Ensure >98% delivery rate with <5 second latency.
- Provide a simple dashboard and robust rate limiting (to prevent bans).
- Containerize the application for easy self-hosted deployment.

### Non-Goals

- Receiving or handling incoming messages (beyond basic delivery receipts).
- Rich media (images/documents) support for the MVP.
- Multi-device or multi-number support.

---

## Domain Model

### Entities

```
Message
├── id: UUID
├── recipientPhone: String
├── content: String
├── status: Enum (PENDING, SENT, FAILED, DELIVERED)
├── retryCount: Integer
├── errorMessage: String (optional)
├── createdAt: Timestamp
└── updatedAt: Timestamp
    ├── updateStatus()
    └── incrementRetry()

ApiKey
├── id: UUID
├── keyHash: String
├── name: String
├── isActive: Boolean
└── createdAt: Timestamp
```

### Value Objects

| Value Object | Fields | Purpose |
|--------------|--------|---------|
| WebhookPayload | phone, text | Structure of incoming trigger payload |
| SendRequest | phone, message, template | Structure of API send request |

### Domain Events

| Event | Trigger | Data |
|-------|---------|------|
| MessageQueued | Webhook/API request received | Message ID, target phone |
| MessageSent | Baileys confirms dispatch | Message ID, WhatsApp message ID |
| MessageFailed | Baileys reports error or timeout | Message ID, Error reason |
| SessionDisconnected | WhatsApp session dropped | Reason, Action needed |

---

## Architecture

### Component Diagram

```
[External Systems] (POS, HR, etc.)
       │
       ▼ (HTTP POST / Webhooks)
┌───────────────────────────────────────┐
│           Node.js API Server          │
│                                       │
│  ┌────────────┐       ┌────────────┐  │
│  │ Auth/Rate  │       │ Dashboard  │  │
│  │ Middleware │       │ Controller │  │
│  └────────────┘       └────────────┘  │
│         │                    │        │
│  ┌────────────┐       ┌────────────┐  │
│  │ Message    │◀─────▶│ SQLite     │  │
│  │ Queue      │       │ Database   │  │
│  └────────────┘       └────────────┘  │
│         │                             │
│  ┌────────────┐                       │
│  │ Baileys    │                       │
│  │ Client     │                       │
│  └────────────┘                       │
└─────────│─────────────────────────────┘
          ▼ (WebSocket)
  [WhatsApp Servers]
```

### Data Flow

1. External system sends a POST request to `/api/send`.
2. Auth middleware verifies the API key.
3. Rate limiter checks if the target number or global queue is within limits.
4. Message is persisted to SQLite with status `PENDING`.
5. Background worker picks up the message and uses Baileys to send it.
6. Baileys callback updates the SQLite record to `SENT` or `FAILED`.
7. Dashboard queries SQLite to display the current state of messages and connection.

---

## API Design

### Endpoints

| Method | Path | Purpose | Auth |
|--------|------|---------|------|
| POST | `/api/v1/messages` | Queue a new message | API Key |
| GET | `/api/v1/messages` | List message history (for dashboard) | Admin/API Key |
| GET | `/api/v1/status` | Get WhatsApp connection status | Admin/API Key |
| POST | `/api/v1/auth/qr` | Get current QR code for linking | Admin |

### Request/Response Examples

**POST /api/v1/messages**

Request:

```json
{
  "phone": "1234567890",
  "message": "Your POS receipt: $42.50"
}
```

Response:

```json
{
  "id": "msg_123abc",
  "status": "PENDING",
  "createdAt": "2026-04-30T10:00:00Z"
}
```

### Error Responses

| Status | Code | When |
|--------|------|------|
| 400 | INVALID_INPUT | Missing phone or message |
| 401 | UNAUTHORIZED | Invalid or missing API key |
| 429 | RATE_LIMITED | Exceeded 60 msgs/min |
| 503 | SERVICE_UNAVAILABLE | WhatsApp session disconnected |

---

## Data Model

### Database Schema (SQLite)

**Table: `messages`**
| Field | Type | Key | Purpose |
|-------|------|-----|---------|
| id | TEXT | Primary | Unique message identifier |
| phone | TEXT | Index | Target WhatsApp number |
| content | TEXT | - | Message body |
| status | TEXT | Index | PENDING, SENT, FAILED, DELIVERED |
| retry_count | INTEGER | - | Number of retries attempted |
| error | TEXT | - | Failure reason if applicable |
| created_at | DATETIME | Index | When received by API |
| updated_at | DATETIME | - | Last status change |

**Table: `api_keys`**
| Field | Type | Key | Purpose |
|-------|------|-----|---------|
| id | TEXT | Primary | Key ID |
| hash | TEXT | - | Hashed secret for verification |
| name | TEXT | - | Identifier (e.g., "POS System") |
| is_active | BOOLEAN | - | Can be disabled |

### Access Patterns

| Access Pattern | Query |
|----------------|-------|
| Process queue | `SELECT * FROM messages WHERE status = 'PENDING' ORDER BY created_at ASC LIMIT 10` |
| View history | `SELECT * FROM messages ORDER BY created_at DESC LIMIT 50` |
| Rate limiting | `SELECT COUNT(*) FROM messages WHERE created_at > datetime('now', '-1 minute')` |

---

## Implementation Plan

### Tasks

| # | Task | Estimate | Dependencies |
|---|------|----------|--------------|
| 1 | Initialize Node.js + Fastify project | 1h | - |
| 2 | Setup SQLite database and schema | 2h | 1 |
| 3 | Integrate Baileys & Session Mgmt | 4h | 1 |
| 4 | Implement API endpoints & Auth | 3h | 2, 3 |
| 5 | Build Message Queue processing | 3h | 2, 3 |
| 6 | Add Rate Limiting middleware | 2h | 4 |
| 7 | Create basic Dashboard UI | 3h | 4 |
| 8 | Dockerize application (Dockerfile + compose) | 2h | all |

**Total Estimate**: 20 hours

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| WhatsApp bans the number | High | High | Strict rate limiting; warn users against marketing messages; warm up new numbers. |
| Baileys lib breaks on WhatsApp update | Med | High | Monitor repository issues; fail gracefully; alert admin via webhook/log. |
| Memory leaks in Baileys | Med | Med | Keep session state light; auto-restart container on OOM. |
| SQLite locking on high concurrency | Low | Med | Use WAL mode; queue writes sequentially in the Node.js event loop. |

---

## Security Considerations

- [x] Authentication required on all API endpoints via `x-api-key` header.
- [x] Dashboard protected by basic auth or separate admin key.
- [x] API keys stored as bcrypt/argon2 hashes, never in plaintext.
- [x] SQLite DB file mounted securely in Docker, not exposed publicly.
- [x] Inputs sanitized to prevent SQL injection.

---

## Testing Strategy

| Type | Coverage | Notes |
|------|----------|-------|
| Unit | 90%+ | Queue logic, rate limiter, auth hashing |
| Integration | API routes | Mock Baileys client, test SQLite read/writes |
| E2E | Manual | Link a test WhatsApp number and send real messages |

---

## Open Questions

| Question | Owner | Status |
|----------|-------|--------|
| Will we need an auto-reply for incoming messages to seem legitimate? | PM | Open |
| Do we want to support webhooks *out* (e.g. notify external system when delivered)? | PM | Open |

---

## Approvals

| Role | Name | Date | Status |
|------|------|------|--------|
| Tech Lead | zeyad sleem | 2026-04-30 | Author |
| Head of Engineering | | | Pending |
| Product Manager | | | Pending |
