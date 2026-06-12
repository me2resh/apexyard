# QPPV AI Assistant

**Repo:** [Dr-kersho/QPPV-Agent](https://github.com/Dr-kersho/QPPV-Agent)  
**Domain glossary:** `CONTEXT.md` in app repo (101 grill decisions)  
**Build order:** `docs/MVP-ROADMAP.md` in app repo  

## Active slice

| Ticket | Title | State |
|--------|--------|--------|
| [#31](https://github.com/Dr-kersho/QPPV-Agent/issues/31) | App shell — sidebar, badges, meta, request ID | OPEN (implementation on branch) |
| [#33](https://github.com/Dr-kersho/QPPV-Agent/issues/33) | Dashboard widgets + compliance gauge | Blocked by #31 |
| [#32](https://github.com/Dr-kersho/QPPV-Agent/issues/32) | ICSR detail page | Blocked by #31 |

## Stack

Next.js 15 PWA · FastAPI · PostgreSQL · Qdrant · Claude / OpenAI / Perplexity

## Ports (local)

| Service | Port |
|---------|------|
| Frontend | 3010 |
| Backend | 8010 |
| Postgres | 5433 |
