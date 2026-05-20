# XPORT CRM — Roadmap

**Registry:** `xport-crm` | **Repo:** Dr-kersho/XPORT-CRM | **Branch:** `staging`

## Shipped (staging)

- [x] **#13** Auto-lead ingest, score, promote (mode A) — PR #19
- [x] **#14** Lead consent fields + `POST /api/outreach/whatsapp` gate — PR #20
- [x] **#15** Outreach task queue + First Contacts Due — PR #21
- [x] **#16** Meta WhatsApp API setup — PR #22
- [x] **#17** Conditional auto-send — PR #23

## Now (P0)

1. **#26** Staging DynamoDB on real AWS (issue #7 closed prematurely; tunnel interim only)
2. **#6 / #8 / #9** Staging deploy — Vercel live; preflight requires `staging_ready` (#26 for green)

## Next (P1)

_(WhatsApp epic #16–#18 complete on `staging`)_

## Later

- Legacy `/api/import` → delegate to scored ingest
- Lead detail UI to edit consent
- Backfill `consent_*` on pre-#14 leads
