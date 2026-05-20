# Open Graph images — TODO

This directory holds the three PNG share-preview images referenced from
the `<meta property="og:image">` and `<meta name="twitter:image">` tags in
`site/{index,architecture,skills}.html`.

The HTML meta tags already point at the URLs that will resolve once these
PNGs are deployed at `https://yard.apexscript.com/og/<page>.png`. A share
preview generator (opengraph.xyz, LinkedIn Post Inspector, Twitter Card
Validator) will return a 200 with the correct dimensions as soon as the
PNGs land.

## Files needed

| Path | Page it backs | What it should show |
|------|---------------|---------------------|
| `og/index.png` | `index.html` | Logo + tagline "where projects get forged" — terminal-native brutalism (JetBrains Mono, warm cream paper, single warning-red accent — same design tokens as the live site CSS) |
| `og/architecture.png` | `architecture.html` | The 5-layer architecture diagram (governance → capability → defaults → customisation overlay → per-project data) or a stylised version of it — same colour palette as `index.png` |
| `og/skills.png` | `skills.html` | A small montage / wordcloud of slash-command names, OR the apexyard logo paired with "52 skills" — same design language |

## Requirements

- **Dimensions**: exactly **1200 × 630** pixels (the OG / Twitter `summary_large_image` standard)
- **File size**: under **200 KB** each (LinkedIn and Slack truncate large images)
- **Format**: PNG, 8-bit RGB (no transparency required — flat warm cream `#F4EFE6` background looks crisper in dark-mode previews than a transparent png)
- **Compression**: run through `pngquant --quality=70-90` or similar after export

## Generator prompt (for AI image tools)

```
A 1200x630 social-share preview image in a terminal-native brutalist
aesthetic. Background: warm cream paper (#F4EFE6). Single typeface:
JetBrains Mono (use a similar monospace fallback if unavailable).
Single accent colour: warning red (#C8321A) used as a stamp / underline
only, NEVER as a fill. No gradients. No shadows. Sharp corners.

The composition is one paragraph of monospaced text laid out like a
clean README. For the index page: "apexyard — where projects get forged"
as the headline; subhead "SDLC-as-code, 52 skills, MIT". For the
architecture page: a five-row stack diagram showing governance →
capability → defaults → customisation overlay → per-project data. For
the skills page: a tight montage of 12-16 slash-command names
(/setup, /handover, /launch-check, /decide, /code-review, etc.) in a
two-column monospaced grid.

NO photographs. NO stock illustration. NO decorative icons. The page is
one big README rendered with care.
```

## When this directory will close out the ticket

Once the three PNGs land at `site/og/index.png`, `site/og/architecture.png`,
and `site/og/skills.png`:

1. Smoke-test each URL in https://www.opengraph.xyz/ and confirm the
   preview renders with the image.
2. Repeat in LinkedIn Post Inspector and Twitter Card Validator.
3. Delete this README (or replace it with a one-line "PNGs landed YYYY-MM-DD").

Until then, this directory + README serves as the explicit follow-up
hand-off — the SEO meta-tag work in PR #329 is complete; only the
binary asset generation remains.
