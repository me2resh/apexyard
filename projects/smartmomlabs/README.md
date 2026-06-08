# Smart Mom Labs / blendavit

Product and website strategy for **blendavit** (DTC microsite) and the **Smart Mom Labs** supplement portfolio (12 SKUs, 6 brands).

**Status:** active (ops-embedded MVP — no separate app repo yet)  
**Impeccable:** consumer — sidecars live under `website/`; tooling repo is [impeccable](../impeccable/)

| Doc | Purpose |
|-----|---------|
| [website-strategy-brief.md](./website-strategy-brief.md) | Full brief — L&E + EllaOla references, IA, page specs |
| [decisions.md](./decisions.md) | Locked launch decisions (markets, waitlist checkout, SKUs) |
| [expert-evidence-copy.md](./expert-evidence-copy.md) | Website trust copy from portfolio science (citation-first) |
| [product-analysis-waitlist-and-launch.md](./product-analysis-waitlist-and-launch.md) | Hanan — what to do, which waitlist/markets/build order |
| **[website/](./website/)** | **Live MVP** — `index.html` + `product.html` |
| **[website/hub/](./website/hub/)** | **Parent hub MVP** — Smart Mom Labs portfolio (`/hub/` on deploy) |

## Impeccable sidecars (local to this site)

Design context for blendavit stays in the **website folder**, not in the impeccable tooling repo:

| File | Purpose |
|------|---------|
| [website/PRODUCT.md](./website/PRODUCT.md) | Register, users, principles, anti-references |
| [website/DESIGN.md](./website/DESIGN.md) | Tokens, typography, components — visual source of truth |
| [website/.impeccable/live/config.json](./website/.impeccable/live/config.json) | Live Mode config (committed) |
| `website/.impeccable/live/sessions/` | Live sessions (gitignored) |

Portfolio tooling: [projects/impeccable/](../impeccable/) → `workspace/impeccable/`  
Consumer contract: [projects/impeccable/consumers.md](../impeccable/consumers.md)

**Source deck:** `Supplement_Portfolio_v2 (1).pptx` (user Downloads folder).

**Future app repo:** When `Dr-kersho/blendavit` (or similar) is created, move `website/` there, add `repo:` + `workspace:` to `apexyard.projects.yaml`, and **carry the sidecars with the site**.

**Packaging references:** copied under `assets/` from the June 2026 product photos.
