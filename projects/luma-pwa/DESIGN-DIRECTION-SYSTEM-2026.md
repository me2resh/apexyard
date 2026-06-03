# LUMA — System design direction (2026)

**Author:** Yasmin (Frontend) · **Inspiration:** [Mobbin](https://mobbin.com) (Fresha, wellness booking, ops dashboards)  
**Scope:** Patient PWA · Clinic admin · Platform operations  
**Status:** Direction preview — not implementation tickets

---

## 1. What you have today (honest audit)

| Surface | Visual language | Strength | Gap vs Mobbin leaders |
|---------|-----------------|----------|------------------------|
| **Patient PWA** | Quiet luxury — ivory, cherry selection, gold trust, Bodoni + Cormorant + Outfit | Distinct GCC concierge positioning; colorize hierarchy is intentional | Explore/book flows are dense; hero + card rhythm could be clearer (Fresha: photo-first cards, one primary CTA per screen) |
| **Clinic admin** | Same tokens, sidebar + tables | Functional parity | Feels like “patient UI shrunk to desktop” — needs **workbench** density (Stripe Dashboard / Linear-lite), not marketing chrome |
| **Ops** | `lib/opsUi.ts` inline styles, grouped nav (Monitor / Manage / Create) | Good information architecture after #81 | Visual system is **decoupled** from patient tokens — tables/inputs should share one `Luma UI` kit |

**Do not ship ApexYard brutalism PRD-001 as-is** — production is luxury serif + soft radius (10px ops inputs). Direction below **extends colorize**, not replaces with terminal mono.

---

## 2. Mobbin patterns to steal (and what to ignore)

### Patient — borrow from [Fresha booking flow](https://mobbin.com/explore/flows/0ae100c9-f9bb-4a81-8837-772fd8ac330c)

| Pattern | Apply to LUMA | Skip |
|---------|---------------|------|
| **Photo-first clinic cards** with rating + area + one CTA | Explore grid: larger image ratio, single “View clinic” | Generic pastel gradients |
| **Sticky date rail + slot list** on clinic detail | Already close — tighten chip active state (cherry wash) | Calendar month picker (overkill for MVP) |
| **Review & confirm** with deposit line item | Book step 4 + confirmed: show deposit / clinic balance split | Full payment method carousel |
| **Browse → detail → book** linear funnel | Keep 4-step wizard; reduce steps visible at once | Social feed discovery |

### Admin — borrow from Mobbin **B2B salon / business** apps (Fresha partner, Square Appointments)

| Pattern | Apply |
|---------|--------|
| **Left rail + content canvas** | Clinic: persistent nav (Bookings, Listing, Slots, Earnings) — collapse on tablet |
| **Status chips on rows** | Bookings table: confirmed / pending / refunded with color semantics from ops |
| **Empty states with one action** | “No bookings today → Share listing link” |

### Ops — borrow from **analytics / CRM** (Mobbin: Stripe, HubSpot mobile tables)

| Pattern | Apply |
|---------|--------|
| **Tabbed monitor** (Overview / Growth / Alerts) | Keep; add sparkline row height consistency |
| **Filter bar above table** | Search + month + clinic — one horizontal toolbar |
| **Danger actions isolated** | Refund / cancel in overflow menu, cherry outline |

---

## 3. Unified design system (one token sheet, three densities)

```
┌─────────────────────────────────────────────────────────────┐
│  Luma Design System v2 (extends globals.css)                │
├─────────────────┬─────────────────┬─────────────────────────┤
│  Marketing      │  Product        │  Workbench              │
│  (login, legal) │  (patient PWA)  │  (clinic + ops)         │
│  Serif hero     │  Cards + nav    │  Tables + forms         │
│  Full bleed     │  max 430px      │  fluid 960–1280px       │
└─────────────────┴─────────────────┴─────────────────────────┘
```

### Color (keep current — refine usage)

- **Cherry** `#8B1A1A` — selection, primary CTA, active nav (patient)
- **Gold** `#B8A47E` — verified, proof, secondary emphasis
- **Ivory / warm** — surfaces; never pure white `#FFF` on patient
- **Ink** `#1A1A1A` — headings; **secondary** `#5C5650` for meta

### Type

| Role | EN | AR |
|------|----|----|
| Display | Bodoni Moda | Aref Ruqaa |
| Accent serif | Cormorant (quotes, hero sub) | Scheherazade |
| UI | Outfit | Outfit + Scheherazade for body |

### Radius & elevation

- Patient cards: `12px` (soft luxury)
- Workbench controls: `10px` (match `opsUi`)
- **No drop shadows** on patient — border + wash only
- Ops tables: 1px border, zebra optional on wide screens

### Motion

- 150ms ease on chips/nav
- Book wizard: horizontal slide between steps (Mobbin-style continuity)
- Respect `prefers-reduced-motion`

---

## 4. Screen-by-screen direction

### Patient

1. **Login** — Split hero (keep); reduce duplicate headings; OTP boxes larger tap targets (48px)
2. **Explore** — Hero band (gold wash) → area chips (cherry active) → 2-col cards on tablet, 1-col phone
3. **Clinic** — Hero gallery carousel · sticky CTA “Book session” · availability rail (Arabic dates ✓)
4. **Book** — Step indicator (1–4) · running total footer · deposit highlighted in cherry
5. **Bookings / Profile** — List cells with left date column (Fresha-style), not full cards

### Clinic admin

- **Shell:** Navy sidebar `#1B2A3B` (existing `--luma-navy`) + ivory canvas
- **Dashboard:** Today’s bookings + earnings snapshot (2 KPI cards, not 6)
- **Bookings:** Table-first; mobile → card stack breakpoint

### Ops

- **Shell:** Same workbench as clinic but **top bar** with environment badge (Production)
- **Growth:** Funnel cards row + event table; handle missing `ProductEvent` gracefully (done in API)

---

## 5. Implementation phases (suggested)

| Phase | Work | Outcome |
|-------|------|---------|
| **A** | Extract `opsUi` → `@/components/luma-ui` (Button, Input, Table, Chip) | Clinic + ops visual parity |
| **B** | Explore + clinic card refresh (photo ratio, CTA) | Mobbin-level discovery |
| **C** | Book wizard footer + step chrome | Conversion clarity |
| **D** | Admin dashboard KPI simplification | Less noise |

---

## 6. Preview artifact

Open the standalone board (no server required):

**File:** [`design-preview/luma-system-direction.html`](design-preview/luma-system-direction.html)

Shows patient phone frames, clinic admin tablet, and ops desktop in one scrollable direction board.

**Live dev previews (already in repo):**

- `/en/design-preview` — Explore + book mock
- `/en/design-preview` (Colorize tab) — cherry/gold comparison
- `/en/admin/design-preview` — Admin chrome experiments

---

## 7. Mobbin links (bookmark set)

- [Fresha — Book appointment (web)](https://mobbin.com/explore/flows/0ae100c9-f9bb-4a81-8837-772fd8ac330c)
- [Fresha — Salon details](https://mobbin.com/explore/screens/daa7dd6f-8d5c-4ebe-b82c-a8838d417d80)
- [Fresha — Review & confirm](https://mobbin.com/explore/screens/f2d209cf-f76d-4efd-b50e-845928c1cf7e)
- [Fresha — Browse & discover](https://mobbin.com/explore/screens/4c936571-dda9-484c-8b58-07df650f3a73)

Search Mobbin for: `aesthetic`, `wellness`, `booking`, `dashboard`, `table` — filter **Web** for PWA parity.

---

*Next step: review `luma-system-direction.html` and pick Phase A vs B for first implementation ticket.*
