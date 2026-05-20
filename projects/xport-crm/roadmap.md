# XPORT CRM — Roadmap

**Registry:** `xport-crm` | **Repo:** Dr-kersho/XPORT-CRM | **Branch:** `staging`

## Shipped (staging)

- [x] **#13** Auto-lead ingest, score, promote (mode A) — PR #19
- [x] **#14** Lead consent fields + `POST /api/outreach/whatsapp` gate — PR #20
- [x] **#15** Outreach task queue + First Contacts Due — PR #21
- [x] **#16** Meta WhatsApp API setup — PR #22
- [x] **#17** Conditional auto-send — PR #23

## Now (P0)

1. **#30** Funnel automation epic — ingest → active
2. **#28 / #29** Stage rules + follow-up outreach (in PR)

## Shipped (funnel)

- [x] **#26** Real AWS staging
- [x] **#13–#18** Auto-leads + WhatsApp epic

## Next (P1)

- **#30** trial → active rules, scheduled Apollo ingest, deal/PO record
- Meta WhatsApp env on Vercel (`whatsapp_cloud`)

## Later

- Legacy `/api/import` → delegate to scored ingest
- Lead detail UI to edit consent
- Programmatic follow-up send (#17 extension)
