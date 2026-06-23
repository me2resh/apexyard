# Sequence Diagram - Visit Checkout

> Time-ordered walkthrough for the core operational flow: Visit -> optional Usage Session -> Charges/Add-ons -> Checkout -> Invoice(s) -> Payment(s) -> Space state update.

## Diagram

```mermaid
sequenceDiagram
    autonumber
    actor Visitor
    actor Staff
    participant Web as Web App
    participant API as tRPC API
    participant Domain as Domain Services
    participant DB as PostgreSQL
    participant Channel as Manual Payment Channel

    Visitor->>Staff: Arrives / requests workspace use
    Staff->>Web: Search or quick-create person, choose visit type
    Web->>API: visit.create(input)
    API->>Domain: createVisit(actor, branch, person, type)
    Domain->>DB: INSERT visit + audit log
    DB-->>Domain: visit
    Domain-->>API: visit DTO
    API-->>Web: visit created

    alt Billable or covered space use
        Staff->>Web: Choose available space
        Web->>API: session.start(visitId, spaceId)
        API->>Domain: checkAvailability + startUsageSession
        Domain->>DB: INSERT usage_session; update space occupied; audit
        DB-->>Domain: active session
        Domain-->>API: session DTO
        API-->>Web: session started
    else Non-billable visitor
        Staff->>Web: Mark visit non-billable
        Web->>API: visit.markNonBillable(visitId, reason)
        API->>Domain: persist non-billable reason + audit
        Domain->>DB: UPDATE visit
    end

    Staff->>Web: Add contextual charge/add-on
    Web->>API: charge.add(target, item/manual, responsibility)
    API->>Domain: validate target, stock, permissions, approval rules

    alt Charge allowed
        Domain->>DB: INSERT charge + audit
        DB-->>Domain: charge
        Domain-->>API: charge DTO
        API-->>Web: charge added
    else Approval required or item unavailable
        Domain-->>API: PRECONDITION_FAILED or CONFLICT
        API-->>Web: show approval/out-of-stock state
    end

    Staff->>Web: Open checkout
    Web->>API: checkout.preview(visitId)
    API->>Domain: calculate usage, coverage, charges, taxes, responsibilities
    Domain->>DB: SELECT visit/session/charges/membership/shift
    DB-->>Domain: checkout inputs
    Domain-->>API: checkout preview
    API-->>Web: totals, split, required payments

    alt Immediate payment required
        Staff->>Channel: Take payment externally
        Channel-->>Staff: Payment result/reference
        Staff->>Web: Enter method/reference/amount
        Web->>API: checkout.finalize(paymentInputs)
        API->>Domain: finalize invoices + record payments + close visit/session
        Domain->>DB: INSERT invoices/items/payments; close visit/session; update space; audit
        DB-->>Domain: finalized checkout
        Domain-->>API: receipt/invoice DTOs
        API-->>Web: checkout complete
    else Pay later / host account / included / complimentary
        Staff->>Web: Confirm non-immediate responsibility
        Web->>API: checkout.finalize(nonImmediateResponsibility)
        API->>Domain: finalize invoice/receivable or zero-due records
        Domain->>DB: INSERT invoices/items; close visit/session; update space; audit
        DB-->>Domain: finalized checkout
        Domain-->>API: checkout DTO
        API-->>Web: checkout complete
    end
```

---

## When this flow runs

- A walk-in visitor checks in, uses a space, adds services/products, and pays at checkout.
- A member checks in and subscription coverage is applied before any overage/add-on charges.
- A booking customer arrives and a booking turns into a live Visit/Usage Session.
- A hosted guest or event attendee checks in with host/event/company responsibility.
- A non-billable visitor is logged and closed without a payable invoice.

---

## Failure modes

| # | Branch | Cause | Detection | Recovery |
|---|--------|-------|-----------|----------|
| 9 | Billable space start | Space is occupied, reserved, cleaning, maintenance, blocked, inactive, or stale | `session.start` returns `CONFLICT` | Staff chooses another space or resolves status. |
| 20 | Charge allowed | Tracked item out of stock | `charge.add` returns `CONFLICT` | Staff selects another item or manager adjusts inventory. |
| 20 | Approval required | Discount, manual override, void, or complimentary reason crosses policy | `charge.add` returns `PRECONDITION_FAILED` with approval requirement | Supervisor approves or staff cancels/modifies charge. |
| 32 | Immediate payment | Cash payment without open shift | `checkout.finalize` returns `PRECONDITION_FAILED` | Staff opens shift, changes method, or uses pay-later/host account if allowed. |
| 32 | Finalization | Invoice/session stale after preview | `checkout.finalize` detects version/state mismatch | Staff refreshes checkout preview and retries. |
| 32 | DB transaction | Partial checkout write fails | Transaction rollback and server error log | No invoice/payment is finalized; staff retries after issue is resolved. |
| 37 | Non-immediate responsibility | Host/account/event credit or policy disallows pay-later | Domain validation returns `FORBIDDEN` or `PRECONDITION_FAILED` | Staff changes responsibility or obtains approval. |

---

## Notes

- **Idempotency**: Checkout finalization should use a request id or version check before payment records are introduced to avoid duplicate invoice/payment creation on retry.
- **Retry semantics**: Preview is safe to retry. Finalize must be guarded by invoice/session state/version.
- **Observability hooks**: Each mutation should write audit logs and structured server logs with stable entity IDs, not raw PII.
- **Transaction boundary**: Invoice item creation, payment record creation, visit/session close, space-state update, and audit write should commit together where practical.

---

## References

- `projects/backspace/architecture/dfd.md`
- `projects/backspace/designs/workspace-operations-technical-design.md`
- `projects/backspace/prd.md`

---

_Generated from `architecture/sequence.md` on 2026-06-23. Re-run after the checkout implementation changes._
