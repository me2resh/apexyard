# Favicons — design TODO

The site HTML references three favicon files via `<link rel="icon">` and `<link rel="apple-touch-icon">` tags in every page's `<head>`. The meta tags are in place now so they'll work as soon as the binary files deploy alongside the HTML.

## Required files

| File | Path | Size | Format | Linked from |
|------|------|------|--------|-------------|
| ICO favicon | `site/favicon.ico` | 16×16 / 32×32 multi-resolution | ICO (legacy browsers) | `<link rel="icon" href="/favicon.ico" sizes="any">` |
| SVG favicon | `site/favicon.svg` | scalable | SVG (modern browsers + dark-mode aware) | `<link rel="icon" href="/favicon.svg" type="image/svg+xml">` |
| Apple touch icon | `site/apple-touch-icon.png` | 180×180 | PNG (iOS home-screen) | `<link rel="apple-touch-icon" href="/apple-touch-icon.png">` |

## Design brief

- **Mark**: stylised "AY" monogram, OR the apexyard logo mark — sharp corners, no gradients, no shadows (matches the site's terminal-native brutalism aesthetic)
- **Palette**: monochrome on transparent background; the warning-red accent (`#C8321A`) is optional as a single accent stroke
- **Aesthetic match**: same visual language as the existing `og/*.png` social cards already shipped in `site/og/`
- **SVG specifics**: include a `@media (prefers-color-scheme: dark)` rule so the favicon adapts to the user's OS theme (same trick the site CSS uses for the cream → ink colour flip)

## Status

**TODO — design pending.** The three meta tags are wired into all three HTML pages (`index.html`, `architecture.html`, `skills.html`) so the moment the binaries land in `site/`, browser tabs and bookmark icons start working with zero further HTML changes. Same pattern as the `og:image` PNGs handled in PR #337 — meta tags reference the target paths; design follows.

## How to validate when the files land

1. Drop the three files at `site/favicon.ico`, `site/favicon.svg`, `site/apple-touch-icon.png`
2. Deploy and visit `https://yard.apexscript.com/` in a fresh browser tab; check the tab favicon renders
3. Run `curl -I https://yard.apexscript.com/favicon.ico` — expect `200 OK` with `Content-Type: image/x-icon` (or `image/vnd.microsoft.icon`)
4. Add the site to an iOS home screen — confirm the 180×180 apple-touch icon renders cleanly
5. Toggle OS dark mode and confirm the SVG variant flips appropriately (if the SVG includes the dark-mode media query)
