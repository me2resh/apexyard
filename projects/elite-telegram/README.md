# Elite Telegram

**Status:** Planning (new product)  
**Source PRD:** `Elite_Telegram_PRD.md` in this folder (sync from your Mac — see below)  
**Normalized PRD:** `prd.md` (ApexYard template; fill after source import)

Telegram-based product — separate from TCC, KoraID, XPORT, and QPPV. App repo **not created yet**.

## Sync PRD from your Mac (local)

From the **apexyard** repo root on your machine:

```bash
./scripts/sync-elite-prd-from-downloads.sh
```

Or manually:

```bash
cp ~/Downloads/Elite_Telegram_PRD.md projects/elite-telegram/Elite_Telegram_PRD.md
```

Then in **local** Cursor Agent:

```text
@projects/elite-telegram/Elite_Telegram_PRD.md
Normalize into projects/elite-telegram/prd.md (templates/prd.md). MVP cut P0/P1/Later.
```

## Repo (when ready)

1. Create `Dr-kersho/elite-telegram` on GitHub (private recommended).
2. Update `repo:` in `apexyard.projects.yaml`.
3. Run `/handover` on the new app repo.
4. Optional: `ln -sf ../elite-telegram workspace/elite-telegram`

## Ticket prefix

`GH` until a dedicated prefix is chosen in registry.

## Docs here vs app repo

| Location | Contents |
|----------|----------|
| `projects/elite-telegram/` (ops fork) | PRD, roadmap, portfolio notes |
| App repo (future) | `CONTEXT.md`, implementation, AgDRs |
