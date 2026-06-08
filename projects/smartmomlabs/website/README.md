# blendavit website (MVP)

Luna & Eve–style marketing site for **blendavit** — static HTML, Arabic-first (RTL), KSA-only at launch.

## Context docs

| File | Purpose |
|------|---------|
| `PRODUCT.md` | Register, users, principles |
| `DESIGN.md` | Tokens, components, do/don't (source of truth for colors) |

These are **Impeccable consumer sidecars** — they stay in this folder. Portfolio tooling lives in [impeccable](../../impeccable/) (`workspace/impeccable/`). See [consumers.md](../../impeccable/consumers.md).

| Path | Purpose |
|------|---------|
| `.impeccable/live/config.json` | Live Mode entry files (committed) |
| `.impeccable/live/sessions/` | Live session state (gitignored) |

## Preview locally

From the repo root or this folder:

```bash
cd projects/smartmomlabs/website
chmod +x bin/preview   # once
./bin/preview          # http://127.0.0.1:8080/
./bin/preview 8766     # custom port (e.g. Impeccable live)
```

Or: `python3 -m http.server 8080`

## Pages

| File | Purpose |
|------|---------|
| `index.html` | Home — trust stamps, lifestyle hero, steps, FAQ, reserve |
| `product.html` | PDP — Toddlers / Kids, KSA, nutrient panel |
| `hub/index.html` | Smart Mom Labs portfolio hub — blendavit live, other brands soon |
| `404.html` | Branded not-found (Netlify/Vercel) |
| `previews/trust-stamps-preview.html` | Trust icon direction comparison |

## Assets (committed — do not swap without PR)

| File | Use |
|------|-----|
| `assets/images/posters/poster-lifestyle.png` | Meta trial B1 only — **do not ship** (Gemini watermark baked in; regenerate) |
| `assets/images/hero-stir-yoghurt.png` | Hero lifestyle (cropped, no watermark) |
| `assets/images/posters/poster-split-gummy.png` | Science section — gummy vs sachet (B2) |
| `assets/images/posters/poster-variants.png` | Products section + PDP OG (B3) |
| `assets/images/hero-stir-yoghurt.png` | Usage steps (stir yoghurt) |
| `assets/images/usage-stir-yoghurt.png` | Step 2 — mix into yoghurt |
| `assets/images/usage-oats-bowl.png` | Steps 1 & 3 — sachets / serve |
| `assets/icons/trust/stamp-*.svg` | Trust strip (direction B) |
| `assets/images/WhatsApp_*.png` | Pack shots (product cards + PDP) |

## Brand tokens (from `main.css` / `DESIGN.md`)

- Background mint `#e8f2f0`, accent green `#1a3d32`, gold `#c9a227`
- Fonts: Tajawal / El Messiri (AR), Albert Sans / Source Serif 4 (EN)

## Shopify hookup (KSA only)

1. Create Shopify store with **Saudi Arabia** market (SAR).
2. Two variants: **Toddlers 1–3**, **Kids 4+**.
3. Install **Early Bird** or **PreProduct** for deposit or $0 reserve.
4. Paste checkout URLs into `assets/js/config.js`:

```javascript
window.BLENDAVIT_CONFIG = {
  shopifyStoreUrl: "https://your-store.myshopify.com",
  market: "ksa",
  checkoutUrls: {
    toddlers_ksa: "https://...",
    kids_ksa: "https://...",
  },
};
```

5. Deploy `website/` to Netlify/Vercel (root = this folder) or port sections into a Shopify theme.

## SEO and legal

| File | Purpose |
|------|---------|
| `robots.txt` | Crawler rules + sitemap pointer |
| `sitemap.xml` | Index, PDP, privacy, terms |
| `privacy.html` / `terms.html` | DRAFT legal pages (AR/EN via i18n) — legal sign-off required |

Update `siteUrl` in `assets/js/config.js` and absolute URLs in `robots.txt`, `sitemap.xml`, and `<head>` canonical/OG tags when the custom domain goes live.

## Deploy

- **Vercel:** `vercel --prod` from this directory (`.vercel/` is gitignored).
- **Netlify:** publish directory = `projects/smartmomlabs/website`.

## Branch note

Hero, usage photos, and trust stamps ship in git on the smartmomlabs site branch. After pulling, run `./bin/preview` to verify images load — if you see generic icons or a kitchen JPG hero, your branch is behind.
