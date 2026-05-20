# XPORT CRM — Roadmap

**Registry:** `xport-crm` | **Repo:** Dr-kersho/XPORT-CRM | **Branch:** `staging`

## Shipped (staging)

- [x] **#13** Auto-lead ingest, score, promote (mode A) — PR #19
- [x] **#14** Lead consent fields + `POST /api/outreach/whatsapp` gate — PR #20
- [x] **#15** Outreach task queue + First Contacts Due — PR #21

## Now (P0)

1. **#16** Meta WhatsApp Business API setup + AgDR
2. **#6 / #8 / #9** Staging deploy: Auth0, Vercel env, D2 smoke

## Next (P1)

3. **#17** Conditional auto-send WhatsApp (`opt_in` + approved template only)
4. **#18** Inbound webhook → stage + call log

## Later

- Legacy `/api/import` → delegate to scored ingest
- Lead detail UI to edit consent
- Backfill `consent_*` on pre-#14 leads
