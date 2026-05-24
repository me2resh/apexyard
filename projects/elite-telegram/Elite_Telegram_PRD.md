# Elite Telegram — source PRD (placeholder)

This file should be replaced by your local document.

## On your Mac

```bash
cd /path/to/apexyard
./scripts/sync-elite-prd-from-downloads.sh
git add projects/elite-telegram/Elite_Telegram_PRD.md
git commit -m "docs(elite-telegram): import source PRD from Downloads"
```

Expected source paths (first match wins):

- `~/Downloads/Elite_Telegram_PRD.md`
- `~/Downloads/Elite_Telegram_PRD.docx` (converted to markdown if `pandoc` is installed)

After import, run local Agent on `@projects/elite-telegram/Elite_Telegram_PRD.md` to populate `prd.md`.

---

_Placeholder only — cloud agent cannot read `/Users/apple/Downloads/`._
