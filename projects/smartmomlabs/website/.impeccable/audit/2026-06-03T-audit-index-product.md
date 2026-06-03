---
targets: index.html, product.html, assets/css/main.css, assets/js/main.js
total_score: 13
rating: Acceptable
timestamp: 2026-06-03
auditor: Salim (QA) + impeccable audit
---

# blendavit audit + QA report

**Scope:** `index.html`, `product.html`, `main.css`, `main.js`, `config.js`  
**Detector:** `[]` (clean on disk)  
**Method:** Static review, contrast math, code trace, browser snapshot (localhost:8765; may lag disk until hard refresh)

---

## Audit Health Score

| # | Dimension | Score | Key Finding |
|---|-----------|-------|-------------|
| 1 | Accessibility | 3 | Contrast passes; missing landmarks/skip link; mobile nav drops section links |
| 2 | Performance | 3 | Lean static site; Google Fonts blocking; `live.js` must not ship to production |
| 3 | Theming | 3 | CSS tokens solid; PDP uses unstyled classes + inline styles |
| 4 | Responsive Design | 2 | Single 900px breakpoint; variant tabs under 44px height; compare table overflow risk |
| 5 | Anti-Patterns | 2 | Mint supplement palette + dual stat proof blocks read template-adjacent |
| **Total** | | **13/20** | **Acceptable** |

**Rating band:** Acceptable (significant polish before launch)

---

## Anti-Patterns Verdict

**Borderline pass.** Automated detector is clean after copy fixes. Remaining tells:

- Mint-tinted body (`#e4f0ef`) is on-brand from pack art but still reads “supplement DTC” at category level.
- `#science` proof columns (`89.8%` / `0g sugar`) sit next to hero-metric template energy (not a full hero-metric band, but same family).
- Product duo cards are intentional EllaOla pattern, not an identical icon grid.

Not failing as “obvious AI slop,” but not yet distinctive vs Luna & Eve / generic mint wellness.

---

## Executive Summary

- **Issues:** P0: 0 · P1: 6 · P2: 9 · P3: 4
- **Top risks:** Mobile users lose Shop/Science/FAQ nav; production `live.js` 404; unverified “Pediatrician-reviewed” claim; PDP unstyled trust pills; market not preserved from home cards to PDP.
- **Working well:** Variant sync (hero ↔ reserve ↔ pack image), WCAG contrast on text/muted, comparison table semantics, FAQ coverage, SFDA disclaimer, waitlist honesty.

---

## Salim (QA) — Exploratory test results

| # | Scenario | Steps | Expected | Result |
|---|----------|-------|----------|--------|
| 1 | Hero variant sync | Home → Toddlers 1–3 in hero | Badge `1–3 TODDLERS`, toddlers pack image, reserve tabs match | **Pass** (code + logic verified) |
| 2 | Reserve market | Reserve → KSA · SAR | `data-currency` = SAR; checkout URL uses `kids_ksa` when configured | **Pass** (currency label); **Partial** (URL only if `config.js` filled) |
| 3 | Deep link PDP | `product.html?variant=toddlers` | Toddlers panel visible, age label Ages 1–3 | **Pass** |
| 4 | Product card CTA | Reserve Toddlers from grid | Lands on PDP with toddlers selected | **Pass** |
| 5 | Market persistence | Select KSA on home → Reserve Toddlers card | PDP opens with KSA pre-selected | **Fail** — cards only pass `variant`, not `market` |
| 6 | Continue to reserve | Default Kids + USA → Continue | `product.html?variant=kids&market=usa` until Shopify URLs set | **Pass** |
| 7 | Mobile nav | Viewport ≤900px | Reach Science / FAQ without hunting | **Fail** — `hide-mobile` removes nav anchors |
| 8 | Footer company link | Smart Mom Labs | Inert until hub exists | **Pass** (intentional) but **a11y concern** (`href="#"` pattern) |
| 9 | Placeholder reviews | Reviews section | Clearly waitlist, not fake verified buyers | **Pass** |
| 10 | Console on deploy | Load without live server | No failed script requests | **Fail** if `live.js` block left in HTML |

---

## Detailed Findings

### P1 — Major

**[P1] Mobile navigation drops primary IA**  
- **Location:** `index.html` nav `.hide-mobile`  
- **Category:** Responsive / UX  
- **Impact:** Mobile users only see logo + Reserve; cannot jump to products, science, or FAQ from header.  
- **Recommendation:** Mobile menu, sticky section links, or footer anchors above fold.  
- **Command:** `/impeccable adapt index.html`

**[P1] Impeccable `live.js` bundled in production HTML**  
- **Location:** `index.html`, `product.html` (lines before `</body>`)  
- **Category:** Performance  
- **Impact:** 404 + console noise on every visitor when port 8400 is not running.  
- **Recommendation:** Strip `impeccable-live-start/end` blocks before deploy; gate behind dev flag.  
- **Command:** `/impeccable harden` (deploy hygiene)

**[P1] PDP trust pills / eyebrow unstyled**  
- **Location:** `product.html` — `.trust-pill`, `.hero-eyebrow` (no rules in `main.css`)  
- **Category:** Theming / Anti-pattern  
- **Impact:** PDP looks broken vs polished home page.  
- **Recommendation:** Add styles or remove markup.  
- **Command:** `/impeccable polish product.html`

**[P1] “Pediatrician-reviewed” without substantiation on page**  
- **Location:** `index.html` hero `.social-proof`  
- **Category:** Trust / compliance  
- **Impact:** Regulatory/trust risk if no named review process on site.  
- **Recommendation:** Match `expert-evidence-copy.md` (citation-first) or remove.  
- **Command:** `/impeccable clarify index.html`

**[P1] Compare table lacks `<caption>`**  
- **Location:** `index.html` `.compare-table`  
- **Category:** Accessibility (WCAG 1.3.1)  
- **Impact:** Screen reader users lose table purpose in context.  
- **Recommendation:** Add visually hidden or visible caption.  
- **Command:** `/impeccable polish index.html`

**[P1] Index page missing `<main>` landmark**  
- **Location:** `index.html` (PDP has `<main>`, home does not)  
- **Category:** Accessibility  
- **Impact:** Screen reader landmark navigation skips primary content wrapper.  
- **Recommendation:** Wrap sections in `<main>`, keep header/footer outside.  
- **Command:** `/impeccable polish index.html`

### P2 — Minor

**[P2] Variant/market touch targets ~38–40px tall**  
- **Location:** `main.css` `.variant-tab, .market-btn` (`padding: 12px 10px`)  
- **Category:** Responsive (WCAG 2.5.5 target size)  
- **Impact:** Harder taps on phones for primary conversion controls.  
- **Recommendation:** `min-height: 44px` on tabs/buttons.  
- **Command:** `/impeccable adapt`

**[P2] Market not passed from product cards**  
- **Location:** `index.html` product card links (`?variant=` only)  
- **Category:** UX  
- **Impact:** User selects KSA in reserve, clicks “Reserve Toddlers” card, PDP defaults USA.  
- **Recommendation:** Append `&market=` from active reserve state or cookie.  
- **Command:** `/impeccable harden`

**[P2] Compare table may horizontal-scroll on narrow phones**  
- **Location:** `main.css` `.compare-table { width: 100% }`  
- **Category:** Responsive  
- **Impact:** Four-column table cramped at 320px.  
- **Recommendation:** Card stack pattern under 600px.  
- **Command:** `/impeccable adapt`

**[P2] Footer “Smart Mom Labs” uses `href="#"`**  
- **Location:** `index.html` footer  
- **Category:** Accessibility  
- **Impact:** Focusable dead link; confusing for keyboard users.  
- **Recommendation:** `<span>` or `role="link" aria-disabled="true"`.  
- **Command:** `/impeccable polish`

**[P2] Stat proof blocks (89.8% / 0g)**  
- **Location:** `#science` `.proof-columns`  
- **Category:** Anti-pattern  
- **Impact:** Reads as SaaS metric band on parent brand page.  
- **Recommendation:** Fold into prose or one asymmetric pull-quote.  
- **Command:** `/impeccable quieter` or `/impeccable layout`

**[P2] Hero lead repeats nutrients twice**  
- **Location:** `index.html` h1 + `.hero-lead`  
- **Category:** Copy  
- **Impact:** Redundant reading effort.  
- **Command:** `/impeccable clarify`

**[P2] No skip link**  
- **Location:** `index.html`, `product.html`  
- **Category:** Accessibility  
- **Command:** `/impeccable polish`

**[P2] Generic PDP image alt**  
- **Location:** `product.html` `#pdp-image` alt="blendavit product"  
- **Category:** Accessibility  
- **Command:** `/impeccable clarify product.html`

**[P2] Google Fonts render-blocking**  
- **Location:** both HTML heads  
- **Category:** Performance  
- **Command:** `/impeccable optimize`

### P3 — Polish

**[P3] Inline styles on reserve panel / PDP**  
- **Location:** `index.html` `#reserve`, `product.html`  
- **Command:** `/impeccable extract`

**[P3] Long WhatsApp image filenames**  
- **Location:** `assets/images/`  
- **Command:** `/impeccable optimize`

**[P3] `scroll-behavior: smooth` without reduced-motion guard**  
- **Location:** `main.css` `html`  
- **Command:** `/impeccable animate`

**[P3] Section heading “Unflavored. Mixable. Fuss-free.” (three fragments)**  
- **Location:** `#how-it-works`  
- **Command:** `/impeccable clarify`

---

## Positive Findings

- Muted text `#5c5348` on mint bg ≈ **6.46:1** (passes AA).
- Body text ≈ **11.19:1** on page background.
- Variant selection syncs hero pack, badge, and reserve panel (fixed regression).
- Comparison table uses `scope` on row/column headers.
- FAQ covers waitlist, markets, SFDA, halal, ages.
- Supplement disclaimer in footer.
- Detector reports zero antipatterns on current disk copy.

---

## Recommended Actions (priority order)

1. **[P1] `/impeccable adapt index.html`** — mobile nav + compare table narrow layout  
2. **[P1] `/impeccable harden`** — remove `live.js` for production; pass market in URLs  
3. **[P1] `/impeccable polish product.html`** — style PDP trust row; `<main>` on home  
4. **[P1] `/impeccable clarify index.html`** — social-proof claim + caption on compare table  
5. **[P2] `/impeccable layout`** — soften stat proof blocks  
6. **[P2] `/impeccable critique index.html`** — fresh UX score post-fixes  
7. **`/impeccable polish`** — final pass after the above  

Re-run `/impeccable audit` after fixes to track score movement.
