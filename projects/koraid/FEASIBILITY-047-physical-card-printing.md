# Feasibility — Physical Card Printing (TICKET-047)

**Author:** Omar (Head of Product)  
**Date:** 2026-06-01  
**Ticket:** [#47](https://github.com/Dr-kersho/koraid/issues/47) · PRD §2F  
**Status:** Conditional defer — validate demand before engineering

---

## Executive recommendation

| Verdict | **DEFER — conditional go** |
|---------|---------------------------|
| Build now? | **No** — do not promote #047 to Must or start eng until gates below pass |
| Why keep it? | Real **EGP revenue** on **earned Gold+** identity; complements viral card loop without selling stats |
| What to do instead | **Manual pilot** (10–20 orders) + in-app **waitlist**; full Paymob + self-serve flow only after pilot economics and ops are proven |

**One line:** Printing is a **monetization and pride** feature, not core product. Ship it when Gold+ users exist and ask for it — not because the PRD lists it.

---

## Problem & opportunity

### User problem (real but secondary)

Players and parents already share **digital** FIFA cards. Some want a **physical keepsake** — trial folders, bedroom wall, family WhatsApp — especially after reaching **Gold+** (merit gate in #047).

### Business opportunity

| Source | PRD assumption |
|--------|----------------|
| Price | 75 EGP standard · 150 EGP premium (foil) |
| Margin | 40–60% (needs vendor validation) |
| Payment | Paymob (already integrated for bookings) |
| Gate | Gold+ only |
| SLA | 5 business days courier |

This is one of few **direct consumer revenue** lines that does **not** violate merit-only stats (unlike pay-to-boost OVR).

### Strategic fit

| Dimension | Score | Notes |
|-----------|-------|-------|
| User value | Medium | Nice-to-have pride artifact; not blocking discovery or booking |
| Business value | Medium–High | Incremental margin; scales with Gold+ cohort |
| Effort (eng) | Low–Medium | PRD says 1 day; realistic **3–5 days** with order admin, PDF export, email/SMS |
| Effort (ops) | **High** | Print partner, QC, reprints, address errors, support |
| Strategic fit | Good | Reinforces “identity you earned” |
| Timing | **Early** | Phase 2 **Could**; #047 deferred until demand pilot (#045–#046 shipped) |

---

## Demand validation plan (before eng)

Run **before** any #047 implementation ticket.

### Step 1 — Waitlist (1 week, no eng beyond a link)

- Gold+ players on profile: *“Want a printed card? Join waitlist”* → Google Form or Typeform (name, uid, tier, phone, city, standard vs premium).
- Parent-managed minors: copy mentions parent phone for delivery.
- **Success gate:** ≥ **25 waitlist signups** from **≥ 15 unique Gold+ uids** in Alexandria beta.

### Step 2 — Manual pilot (2–4 weeks)

- Fulfill **10–20 orders** offline: export card PNG from existing renderer → local print shop (Alex) → courier (Bosta / Aramex / local).
- Charge via **Paymob link** or cash-on-delivery for pilot only.
- Track: cost per unit, defect rate, delivery time, support messages, repeat intent.

### Step 3 — Decision

| Outcome | Action |
|---------|--------|
| Waitlist &lt; 25 | **Kill or park** #047 for 2 quarters; revisit when Gold+ count grows |
| Pilot margin &lt; 25% net | Renegotiate print vendor or raise price; do not automate |
| Pilot NPS ≥ 8/10 and margin ≥ 30% | **Go** — spec #047 properly and schedule eng |

---

## Unit economics (model — validate with pilot)

Assumptions for **standard 75 EGP** (Alexandria, single-card mailer):

| Line item | Low | High |
|-----------|-----|------|
| Print (300gsm, laminate, A6/card die-cut) | 20 | 35 |
| Packaging + sleeve | 3 | 8 |
| Courier (last mile) | 12 | 22 |
| Paymob ~2.5% + fixed | 2 | 3 |
| Reprint / defect buffer (5%) | 2 | 4 |
| **Total COGS** | **39** | **72** |
| **Gross margin @ 75 EGP** | **48%** | **4%** |

**Premium 150 EGP** (foil / spot UV): add ~25–40 EGP print → margin healthier if conversion ≥ 50% of standard mix.

**Sensitivity:** At 75 EGP, **courier + print above ~55 EGP combined kills the PRD 40% target**. Premium tier is required for healthy blended margin unless print is batched.

| Gold+ users | Conv. 3% | Conv. 5% | Orders/mo @ 5% |
|-------------|----------|----------|----------------|
| 100 | 3 | 5 | 5 |
| 500 | 15 | 25 | 25 |
| 1,000 | 30 | 50 | 50 |

At **25 orders/mo × ~30 EGP net margin** ≈ **750 EGP/mo** — meaningful for early stage, not company-scale until Gold+ base is thousands.

---

## Product constraints (non-negotiable)

From PRD and positioning — any spec must enforce:

1. **Gold+ only** — server-side tier check at checkout (same pattern as platinum gates).
2. **Stats / tier / OVR never sold** — print is fulfillment of existing profile snapshot, not a stat SKU.
3. **Snapshot at order time** — card image frozen to order date (avoid “print then drill up” disputes).
4. **No G Coins for print** — real EGP via Paymob; keeps virtual economy cosmetic-only.
5. **Parent consent** for managed minors — delivery address + parent acknowledgment.

---

## Ops & fulfillment requirements

| Area | Requirement |
|------|-------------|
| Print partner | Card stock, color accuracy vs screen, batch SLA |
| QC | Sample approval of FIFA layout at print size |
| Data | Shipping address, phone, order id, card PNG/PDF artifact |
| Support | Reprint policy (defect vs user error), refund window |
| Legal | Consumer delivery terms; minor data handling |
| Inventory | None for MVP — print-on-demand |

**Risk:** Screen colors ≠ print; Arabic name truncation; photo resolution on card export.

---

## Engineering scope (if gates pass)

PRD #047 is **underscoped**. Real MVP:

| Piece | Estimate |
|-------|----------|
| Order flow `/print` or `/store/print` | 1d |
| Paymob checkout + webhook (reuse booking patterns) | 1d |
| High-res export / print-ready PDF | 1d |
| Order entity + admin queue (email or `/admin/print-orders`) | 1d |
| Gold+ gate + snapshot | 0.5d |
| **Total** | **~4–5 eng days** + ops runbook |

Defer: bulk discounts, gift orders, international ship, foil SKUs until pilot proves standard tier.

---

## Go / no-go gates (summary)

| Gate | Threshold | Status |
|------|-----------|--------|
| G1 — Gold+ cohort | ≥ 50 Gold+ active profiles in beta city | ☐ Measure |
| G2 — Waitlist | ≥ 25 signups / 15 uids | ☐ Run |
| G3 — Pilot economics | Net margin ≥ 30% on 10+ orders | ☐ Run |
| G4 — Ops readiness | Named print partner + courier SLA doc | ☐ Ops |
| G5 — Support load | &lt; 15 min avg handling per order | ☐ Pilot |

**Promote #047 to Must only when G1–G3 are green.** G4–G5 can run in parallel with eng spec.

---

## Roadmap placement

| Priority | Item | Rationale |
|----------|------|-----------|
| **Now** | #37 Goals of the Week | Engagement loop; feeds Reels content |
| **Now** | Scout / booking growth | Phase 1 metrics still matter |
| **Next** | #047 waitlist + manual pilot | Cheap validation |
| **Later** | #047 automated store | After pilot |
| **Not now** | #048+ AI stats | Research |

Update [roadmap.md](./roadmap.md) when G3 passes.

---

## Decision log

| Date | Decision |
|------|----------|
| 2026-06-01 | **Defer eng** on #047; approve demand pilot + waitlist; conditional go when gates pass |

---

## Next actions (owner)

| Action | Owner | When |
|--------|-------|------|
| Add waitlist CTA copy (AR) for Gold+ profile | PM / Design | This week |
| Identify 2 Alexandria print shops; quote A6 laminated card | Ops / Founder | This week |
| Track Gold+ count in beta | Data | Ongoing |
| File spike ticket *“Print pilot — manual fulfillment”* if waitlist hits 25 | PM | After G2 |

---

*KoraID — merit-only identity. Print is the trophy, not the stat pack.*
