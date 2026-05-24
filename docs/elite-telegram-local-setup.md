# Elite Telegram — local Cursor setup

Use this flow when the PRD lives on your Mac (`~/Downloads/`) and you want Agent sessions on **your machine**, not the cloud VM.

## 1. Get the ops repo on your Mac

```bash
cd ~/path/to/apexyard   # your Dr-kersho/apexyard fork
git pull origin main    # after the elite-telegram scaffold PR merges
```

## 2. Import the PRD

```bash
./scripts/sync-elite-prd-from-downloads.sh
git add projects/elite-telegram/Elite_Telegram_PRD.md
git commit -m "docs(elite-telegram): import source PRD"
```

## 3. Open in Cursor (local)

- **File → Open Folder** → your `apexyard` directory
- New **Agent** chat (not Cloud Agent)
- Reference: `@projects/elite-telegram/Elite_Telegram_PRD.md`

## 4. PM prompt (paste)

```text
/pm — Elite Telegram (IDEA-001). Read the source PRD, update projects/elite-telegram/prd.md
per templates/prd.md, propose P0/P1/Later MVP cut and open questions.
```

## 5. When ready to build

1. Create `github.com/Dr-kersho/elite-telegram`
2. Confirm `repo:` in `apexyard.projects.yaml`
3. `/handover` on the app repo
