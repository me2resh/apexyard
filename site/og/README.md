# Open Graph images

Three 1200×630 share-preview PNGs referenced from the `<meta property="og:image">` and `<meta name="twitter:image">` tags in `site/{index,architecture,skills}.html`. Served at `https://yard.apexscript.com/og/<page>.png`.

| File | Page it backs | Size |
|------|---------------|------|
| `index.png` | `index.html` | 1200×630, ~52 KB |
| `architecture.png` | `architecture.html` | 1200×630, ~96 KB |
| `skills.png` | `skills.html` | 1200×630, ~75 KB |

## Design tokens (for future regeneration)

- **Dimensions**: exactly 1200 × 630 (OG / Twitter `summary_large_image` standard)
- **Background**: warm cream `#F4EFE6` (no transparency)
- **Accent**: warning red `#C8321A` (stamp / underline only, never a fill)
- **Typeface**: JetBrains Mono (or close monospaced fallback)
- **Aesthetic**: terminal-native brutalist — no gradients, no shadows, sharp corners
- **File size**: keep each under 200 KB (LinkedIn + Slack truncate large images); run through `pngquant --quality=70-90` after export

Binaries shipped via #341. Regenerate via Figma / Affinity / AI image tools using the tokens above, then `pngquant` and replace in place.
