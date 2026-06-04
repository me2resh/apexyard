# blendavit website (MVP)

Luna & Eve–style marketing site for **blendavit** — static HTML ready to deploy or port into Shopify.

## Impeccable context

- `PRODUCT.md` — register, users, principles (brand)
- `DESIGN.md` — tokens, components, do/don't
- `.impeccable/live/config.json` — live mode (already configured)

## Preview locally

```bash
cd projects/smartmomlabs/website
python3 -m http.server 8080
```

Open http://localhost:8080

## Pages

| File | Purpose |
|------|---------|
| `index.html` | Home — hero, evidence, comparison, FAQ, reserve |
| `product.html` | PDP — Toddlers / Kids, KSA / USA, nutrient panels |

## Brand

- Mint `#D9E9E8`, brown `#4B3621`, green `#3B5340`
- Pack shots in `assets/images/`

## Shopify hookup (KSA + USA waitlist)

1. Create Shopify store + **Markets**: Saudi Arabia (SAR), United States (USD).
2. Two products or variants: **Toddlers 1–3**, **Kids 4+**.
3. Install **Early Bird** or **PreProduct** — enable deposit **or** $0 reserve (toggle anytime).
4. Paste checkout URLs into `assets/js/config.js`:

```javascript
window.BLENDAVIT_CONFIG = {
  shopifyStoreUrl: "https://your-store.myshopify.com",
  checkoutUrls: {
    toddlers_ksa: "https://...",
    toddlers_usa: "https://...",
    kids_ksa: "https://...",
    kids_usa: "https://...",
  },
};
```

5. Deploy static files to Netlify/Vercel **or** rebuild sections as Shopify theme sections.

## Deploy (Netlify)

Drag-drop `website/` folder or connect repo path `projects/smartmomlabs/website`.

## Next

- `smartmomlabs.com` hub (EllaOla-style) — Phase 2
- Arabic RTL for KSA
- Set prices when ready
