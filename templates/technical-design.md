# Technical Design: [Feature Name]

**Status**: Draft | In Review | Approved
**Author**: [Tech Lead / Engineer]
**Date**: YYYY-MM-DD
**PRD**: [Link to PRD]

---

## Overview

### Summary

[1-2 sentences: What are we building and why?]

### Goals

- [Goal 1]
- [Goal 2]

### Non-Goals

- [What we're explicitly not doing]

---

## Domain Model

### Entities

```
[Entity Name]
├── id: EntityId
├── field1: Type
├── field2: Type
└── Methods:
    ├── create()
    └── businessMethod()
```

### Value Objects

| Value Object | Fields | Purpose |
|--------------|--------|---------|
| [Name] | [fields] | [purpose] |

### Domain Events

| Event | Trigger | Data |
|-------|---------|------|
| [EventName] | [When raised] | [What data] |

---

## Architecture

### Component Diagram

```
[Draw your architecture here using text/ASCII]
```

### Data Flow

[Describe how data flows through the system]

---

## API Design

### Endpoints

| Method | Path | Purpose | Auth |
|--------|------|---------|------|
| POST | /api/resource | Create resource | Required |
| GET | /api/resource/:id | Get resource | Required |
| PUT | /api/resource/:id | Update resource | Required |
| DELETE | /api/resource/:id | Delete resource | Required |

### Request/Response Examples

**POST /api/resource**

Request:

```json
{
  "field1": "value",
  "field2": 123
}
```

Response:

```json
{
  "id": "resource_123",
  "field1": "value",
  "field2": 123,
  "createdAt": "2026-01-21T00:00:00Z"
}
```

### Error Responses

| Status | Code | When |
|--------|------|------|
| 400 | INVALID_INPUT | Validation failed |
| 401 | UNAUTHORIZED | Not authenticated |
| 403 | FORBIDDEN | Not authorized |
| 404 | NOT_FOUND | Resource doesn't exist |
| 500 | INTERNAL_ERROR | Server error |

---

## Data Model

### Database Schema

| Field | Type | Key | Purpose |
|-------|------|-----|---------|
| id | UUID | Primary | Unique identifier |
| [field] | [type] | - | [purpose] |
| created_at | Timestamp | - | Record creation time |

### Access Patterns

| Access Pattern | Query |
|----------------|-------|
| Get by ID | Primary key lookup |
| List by user | Index on user_id |
| List by status | Index on status |

---

## Implementation Plan

### Tasks

| # | Task | Estimate | Dependencies |
|---|------|----------|--------------|
| 1 | Create domain entities | 2h | - |
| 2 | Implement use cases | 4h | 1 |
| 3 | Create API handlers | 2h | 2 |
| 4 | Set up database | 1h | - |
| 5 | Implement repository | 2h | 1, 4 |
| 6 | Write unit tests | 3h | 1, 2 |
| 7 | Write integration tests | 2h | all |

**Total Estimate**: X hours

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| [Risk 1] | Med | High | [How to mitigate] |
| [Risk 2] | Low | Med | [How to mitigate] |

---

## Security Considerations

- [ ] Authentication required on all endpoints
- [ ] Authorization checked for resource access
- [ ] Input validation at boundaries
- [ ] Sensitive data encrypted
- [ ] No PII in logs

---

## Testing Strategy

| Type | Coverage | Notes |
|------|----------|-------|
| Unit | Domain logic, 90%+ | All business rules |
| Integration | Use cases | Happy path + errors |
| E2E | Critical flows | If applicable |

---

## Open Questions

| Question | Owner | Status |
|----------|-------|--------|
| [Question 1] | [name] | Open |

---

## Approvals

| Role | Name | Date | Status |
|------|------|------|--------|
| Tech Lead | | | Author |
| Head of Engineering | | | Pending |
| Security (if needed) | | | Pending |
