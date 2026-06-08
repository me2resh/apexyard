# Custom domains — blendavit + Smart Mom Labs

**Vercel project:** `website` (`prj_zeavAWmf2fiTk6ysbueoRW9RgqbO`)  
**Root directory:** `projects/smartmomlabs/website`

## Domains attached (2026-06-08)

| Domain | Serves |
|--------|--------|
| `blendavit.com` | blendavit home + PDP (site root) |
| `www.blendavit.com` | 301 → `blendavit.com` |
| `smartmomlabs.com` | Redirect `/` → `/hub/` |
| `www.smartmomlabs.com` | Redirect `/` → `/hub/` |

Until DNS propagates, production stays on `https://website-dun-zeta-85.vercel.app`.

## DNS records (at your registrar)

For each apex domain:

```
Type  Name  Value
A     @     76.76.21.21
```

For each `www` subdomain (or CNAME if your registrar prefers):

```
Type  Name  Value
A     www   76.76.21.21
```

Alternative: point nameservers to Vercel (`ns1.vercel-dns.com`, `ns2.vercel-dns.com`) and manage records in the Vercel dashboard.

## After DNS is live

1. Confirm domains show **Valid** in [Vercel → website → Domains](https://vercel.com/dr-kershos-projects/website/settings/domains).
2. Update absolute URLs in:
   - `assets/js/config.js` (`siteUrl`, `hubUrl`)
   - `robots.txt`, `sitemap.xml`, `llms.txt`
   - `<link rel="canonical">` and `og:url` in HTML heads
3. Redeploy production.

## Routing

Host-based redirects live in `vercel.json` at the site root.
