# Product analysis — What to do & which choices

**Analyst:** Hanan (Product Analyst) · June 2026  
**Question:** Search and analyze what to do next, and **which** options to pick (waitlist model, markets, build order, positioning).

**Inputs:** Locked decisions in [`decisions.md`](./decisions.md) · Science deck · L&E + EllaOla references · Competitor scan.

---

## Executive recommendation (one screen)

| Decision | **Choose this** | Why |
|----------|-----------------|-----|
| Waitlist at checkout | **Configurable deposit (default on) → switch to $0 anytime in app** | Activity/volume first; enable deposits when POC warrants securing funds |
| Deposit amount | **~$5 USD / ~19 SAR** when enabled (credited at launch, instant refund) | Toggle without redeploying site |
| What to build first | **blendavit.com only** (Luna & Eve clone) | Portfolio hub without stock confuses waitlist signal; EllaOla shell = Phase 2 |
| Market **traffic** priority | **1 KSA → 2 USA** (UAE dropped) | SFDA registration strength in KSA; USA scale and EllaOla comp set |
| Market **checkout** day one | **KSA + USA only** (SAR + USD) | No UAE/CAN at launch |
| Success metric | **Paid reservations** (deposit or full pre-order), not email count | Only payment validates manufacturing MOQ |
| Shopify app | **Early Bird** or **PreProduct** (deposits + $0 + deferred charge + Markets) | Avoid fake “in stock”; supports >30 day lead time with disclosure |

---

## 1. What to do — sequenced plan

### Phase A — Demand test (weeks 1–4)

1. **Shopify store:** blendavit.com, Dawn-derived or L&E-style theme, 2 variants (Toddlers 1–3, Kids 4+).
2. **Pre-order flow:** “Reserve your box” → checkout → waitlist confirmation email (no ship date promise without range).
3. **Copy:** Pull from [`expert-evidence-copy.md`](./expert-evidence-copy.md) — Kutbi, iron/Lipofer, 0g sugar, SFDA registered.
4. **Analytics:** Meta Pixel + GA4 events: `AddToCart`, `Purchase` (reservation), `Deposit` vs `FreeReserve`, variant, country.
5. **Target:** **150–300 paid reservations** before committing first production MOQ (adjust after you set price; rule of thumb for ~$40–50 USD box ≈ $6k–15k committed demand).

### Phase B — Portfolio shell (weeks 3–6, parallel light)

6. **smartmomlabs.com:** Single-page EllaOla-style hero + 5 brand cards linking out; blendavit = only live “Reserve” CTA; others “Coming soon” notify.
7. **Do not** open 12-SKU checkout until each SKU has regulatory + inventory path.

### Phase C — After demand proof (weeks 6–14)

8. Set price per market (see §4).
9. Charge balance / ship first batch; turn off waitlist → standard buy + Subscribe & Save.
10. Add Arabic (KSA) and expert photos if advisors signed.

---

## 2. Which waitlist model — analysis

You want **real checkout UX** but **no manufacturing until demand is proven**. Three models:

| Model | Pros | Cons | Verdict |
|-------|------|------|---------|
| **A. Free email only** | Highest top-of-funnel | 1–5% convert to purchase; weak MOQ signal | **Do not use alone** |
| **B. $0 checkout reserve** (card vaulted, charge at ship) | Feels like L&E checkout; lower friction | 50–75% may not convert at charge time; Shopify policy risk if fulfillment >30 days without disclosure | **Use as secondary CTA** |
| **C. Refundable deposit** ($5–10, credited at launch) | Best demand signal; 15–40% warm list → purchase; funds micro-ads | Smaller volume than free | **Primary CTA** |
| **D. Full payment pre-order** | Maximum cash flow | High trust bar pre-brand; refund/legal load | **Only after** deposit cohort converts |

### Recommended UX (L&E-style PDP)

```
[ Reserve with $5 deposit — credited on launch ]  ← primary
[ Join free waitlist — pay when we ship ]         ← secondary link
```

- Deposit copy: *“Refundable anytime before launch. Fully credited to your first box.”*
- Fulfillment disclosure: *“First production run estimated [8–12 weeks]. We'll email before we charge the balance.”*
- Use app **fulfillment hold** so Shopify does not expect immediate ship.

**Regulatory:** SFDA registered ≠ disease claims; deposit is commerce, not a health claim. Still need clear pre-order terms page (refund, timeline, region).

---

## 3. Which markets — analysis

| Market | Role in launch | Traffic | Ops notes |
|--------|------------------|---------|-----------|
| **UAE** | **Lead** | First paid tests (English, Instagram/TikTok parents, pharmacy trust) | ESMA/MOIAT; AED; WhatsApp support expected |
| **USA** | **Scale** | Largest comp (EllaOla, You+yours); USD; Meta scale | FDA structure/function copy; state sales tax via Shopify |
| **KSA** | **Grow** | High volume but needs **Arabic** for conversion | SAR; SFDA registration is your strength — feature it |
| **Canada** | **Attach** | Low incremental cost if US creative works | CAD; copy US legal pattern with CA footer |

**Do not** delay store availability in any country if Shopify Markets is configured — **delay ad spend** instead.

**GCC vs US messaging split:**

- **GCC:** Kutbi 89.8%, gummy sugar vs 0g, halal, SFDA, WhatsApp.
- **US/CA:** Picky eaters, allergen-free, no sugar gummies, third-party tested, pediatrician-developed framing (evidence cards, not fake endorsers).

---

## 4. Which competitors matter

| Competitor | Overlap | blendavit edge |
|------------|---------|----------------|
| [Luna & Eve](https://lunaandeve.com/) | Sachet, flavourless, 1–3 / 4+ | **Iron in sachet** (Lipofer); GCC evidence |
| [EllaOla](https://ellaola.com/) | Unflavored powder, iron as **separate SKU** | **All-in-one** 12 nutrients + iron; SFDA; less US-centric |
| [You+yours](https://youandyourshealth.com/) | Tasteless powder, 1+ | **12 vs 9** nutrients; iron; GCC positioning |
| NanoVM / clinical powders | Allergen-free, hospital channel | Consumer brand + sachet convenience |

**Positioning sentence (test in ads):**  
*“The unflavored multivitamin with iron — zero sugar, zero cooperation.”*

EllaOla splits iron because taste; blendavit’s deck claim is iron **inside** the tasteless matrix — that should be on every hero, not only ingredients.

---

## 5. Which site to mimic when

| Build | Reference | Not |
|-------|-----------|-----|
| blendavit pages | **Luna & Eve** section order | EllaOla’s multi-product homepage |
| smartmomlabs hub | **EllaOla** grid + expert row | L&E single-product simplicity |
| Trust | **Your evidence cards** | EllaOla-style fake MD names without contracts |

---

## 6. KPIs — what “enough demand” means

Track weekly:

| Metric | Target (8-week test) | Alarm |
|--------|----------------------|-------|
| Paid reservations (deposit) | 150+ total | <20 after 4 weeks paid ads |
| Deposit → paid box at launch | 30–50% | <15% |
| Free waitlist → paid box | 5–15% | Using free as primary metric |
| Variant mix | Track Toddlers vs Kids % | One variant <20% (MOQ risk) |
| Country mix | UAE+KSA ≥40% if GCC-first brand | 100% US with no GCC signal |
| CAC per **paid** reservation | TBD after price | >½ of deposit |

**Manufacturing go/no-go:** Green light if **≥150 deposits** AND **≥30%** say they’d accept stated ship window in post-checkout survey (add one question).

---

## 7. User confirmations (June 2026)

1. **Deposit:** OK — **operator can set to $0 anytime** in pre-order app (activity first; deposits when securing funds post-POC).  
2. **Markets:** **KSA + USA only** — UAE dropped.  
3. **Build:** blendavit first; Early Bird or PreProduct with **deposit + $0** modes.

---

## 8. Shopify build note — deposit toggle

Pick an app that supports **$0 deposit / pay-later reserve** and **fixed deposit** on the same product without theme redeploy (e.g. Early Bird partial/$0 deposits, PreProduct pay-later). Document in admin: *Mode A = $0 for volume · Mode B = SAR/USD deposit for fund capture.*

---

## Sources (external)

- Blazon Agency — deposit vs free waitlist conversion  
- Inventory Ready — supplement preorder strategy  
- LemonPage — waitlist vs payment validation  
- Shopify app docs: Early Bird, PreProduct, STOQ (deposits, Markets, deferred payment)
