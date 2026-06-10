# QPPV AI Assistant

**Repo:** [Dr-kersho/QPPV-Agent](https://github.com/Dr-kersho/QPPV-Agent)  
**Live app:** https://qppv-agent.vercel.app  
**Pitch (share with buyers):** https://qppv-agent.vercel.app/pitch/  
**Domain glossary:** `CONTEXT.md` in app repo  
**Roadmaps:** `docs/MVP-ROADMAP.md` (v1.0) · `docs/V1.5-ROADMAP.md` (platform + RA arm)

## Current phase

| Version | Focus | Status |
|---------|--------|--------|
| **v1.0** | PV cockpit, Arabic i18n, E2B, regulatory Q&A | Live on Vercel + Render |
| **v1.5** | Plan entitlements, RA arm MVP, team seats, Readiness Lite free tier | Roadmap approved — see `docs/V1.5-ROADMAP.md` |

## Demo

- URL: https://qppv-agent.vercel.app/login  
- Credentials: `demo@qppv.eg` / `demo1234`

## Stack

Next.js PWA · FastAPI · PostgreSQL · Qdrant · Claude / OpenAI / Perplexity

## Ports (local)

| Service | Port |
|---------|------|
| Frontend | 3010 |
| Backend | 8010 |
| Postgres | 5433 |
