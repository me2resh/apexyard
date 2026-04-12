---
name: seo-audit
description: Technical SEO audit — meta tags, Open Graph, sitemap, robots.txt, structured data, mobile-friendliness, Core Web Vitals readiness. Deep-dive companion to /launch-check's SEO dimension.
disable-model-invocation: false
argument-hint: "[project-path]"
effort: medium
---

# /seo-audit — Technical SEO Analysis

Deep-dive SEO audit against Google's best practices. Checks on-page SEO, technical SEO, and social sharing metadata. Invoke when `/launch-check`'s SEO row shows WARN or FAIL.

## Process

### Step 1: On-page SEO

Check each key page (index, about, pricing, blog, product pages) for:

- `<title>` tag (exists, unique per page, 50-60 chars)
- `<meta name="description">` (exists, unique, 150-160 chars)
- `<h1>` tag (exactly one per page, contains target keyword)
- Heading hierarchy (h1 → h2 → h3, no gaps)
- Internal linking between pages
- Image alt text containing relevant keywords (not keyword-stuffed)

### Step 2: Technical SEO

- `robots.txt` at root (exists, not blocking important pages)
- `sitemap.xml` at root (exists, lists all public pages, submitted to Search Console)
- Canonical URLs (`<link rel="canonical">` on each page)
- 404 page exists and returns HTTP 404 (not 200)
- Redirects: any redirect chains? (301 → 301 → page)
- URL structure: clean, readable, no query-string-based routing for content pages
- Mobile viewport meta tag: `<meta name="viewport" content="width=device-width, initial-scale=1">`

### Step 3: Social sharing (Open Graph + Twitter Cards)

- `og:title`, `og:description`, `og:image`, `og:url` on key pages
- `og:image` dimensions (1200x630 recommended)
- Twitter card meta tags (`twitter:card`, `twitter:title`, `twitter:description`, `twitter:image`)
- Favicon and apple-touch-icon

### Step 4: Structured data

- JSON-LD or Microdata for relevant schemas (Organization, Product, FAQ, BreadcrumbList, Article)
- Check validity: are required properties present?

### Step 5: Output

```
SEO AUDIT — <project> @ <sha>

| # | Area | Status | Finding |
|----|------|--------|---------|
| S1 | Title tags | PASS | All 5 pages have unique titles (52-58 chars) |
| S2 | Meta descriptions | WARN | /pricing missing meta description |
| S3 | robots.txt | PASS | Exists, allows crawling of public pages |
| S4 | sitemap.xml | FAIL | Not found at /sitemap.xml |
| S5 | Open Graph | WARN | og:image missing on /blog/* pages |
| S6 | Structured data | PASS | Organization + FAQ schema on homepage |
| S7 | Mobile | PASS | Viewport meta tag present |
| S8 | Canonical URLs | PASS | All pages have canonical links |

SEO readiness: GOOD (1 fail, 2 warnings — fix sitemap before launch)
```

## Rules

1. **Auto-PASS for non-web projects.** APIs, CLIs, libraries, backend-only services don't need SEO.
2. **Focus on technical SEO**, not content strategy. Don't audit keyword targeting or content quality — that's a marketing call, not a technical check.
3. **Check the built output** if available (`dist/`, `build/`, `.next/`), not just source — SSR frameworks may generate meta tags at build time.
4. **Prioritize by indexing impact.** Missing sitemap > missing og:image > missing structured data.
