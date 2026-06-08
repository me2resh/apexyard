# Impeccable

**Repo:** [github.com/Dr-kersho/impeccable](https://github.com/Dr-kersho/impeccable) (fork of [pbakaus/impeccable](https://github.com/pbakaus/impeccable))  
**Workspace:** `workspace/impeccable/`  
**Status:** active  
**Tier:** P1

Design-language skills and Live Mode for AI coding harnesses (Cursor, Claude Code, Copilot, Codex, etc.). Gives agents a shared vocabulary for typography, color, motion, UX critique, and in-browser visual iteration.

## What it is

Impeccable is not an app — it is a **design tooling repo** installed into consumer projects via skills/submodules. It ships:

- Slash commands (`/impeccable init`, `craft`, `live`, `audit`, …)
- Live Mode: pick elements in a running dev server, iterate variants, write back to source

Consumers generate their own sidecars via `/impeccable init` — see [consumers.md](./consumers.md).

Upstream docs: [impeccable.style](https://impeccable.style/)

## Consumer pattern

**Tooling lives here; design context stays in each consumer site.**

- Portfolio tooling: this repo (`workspace/impeccable/`)
- Per-site sidecars: `PRODUCT.md`, `DESIGN.md`, `.impeccable/live/` in the consumer repo

Full contract: [consumers.md](./consumers.md)

## Registered consumers

| Project | Site root | Sidecars |
|---------|-----------|----------|
| [smartmomlabs](../smartmomlabs/) | `projects/smartmomlabs/website/` | `PRODUCT.md`, `DESIGN.md`, `.impeccable/live/config.json` |

Changes to Impeccable skills/CLI → **this repo**. Changes to blendavit design/copy → **consumer sidecars**, not here.

## Local clone

From the ops repo root:

```bash
git clone git@github.com:Dr-kersho/impeccable.git workspace/impeccable
```

Or symlink if you keep a canonical clone elsewhere:

```bash
ln -sf ~/Documents/impeccable workspace/impeccable
```

## Install into the ops repo (harness skills)

Skills must be **committed to git** — `npx impeccable skills install` alone leaves untracked copies that vanish on `git clean`, fresh clones, or branch resets.

```bash
# Install or verify (idempotent)
bin/install-impeccable-skills

# After install or upgrade, commit the harness copies + lock file:
git add skills-lock.json .claude/skills/impeccable .cursor/skills/impeccable .github/skills/impeccable
git commit -m "chore: pin impeccable skills v$(grep -m1 '^version:' .cursor/skills/impeccable/SKILL.md | sed 's/version: //')"
```

`skills-lock.json` at the ops-repo root records the pinned version. Re-run `bin/install-impeccable-skills --force` to pull a newer npm release, then recommit.

## Install into a consumer project

From the consumer repo (see upstream README for full options):

```bash
git submodule add https://github.com/Dr-kersho/impeccable .impeccable
npx impeccable skills link --source=.impeccable --providers=claude,cursor
```

Or harness-wide:

```bash
npx impeccable skills install
```

Consumer sidecars (`PRODUCT.md`, `DESIGN.md`, `.impeccable/live/config.json`) live in each site root — see [consumers.md](./consumers.md).

## Ticket prefix

GitHub Issues on `Dr-kersho/impeccable` — **GH** (shared default).

## Sync with upstream

This is a fork. Periodically merge from `pbakaus/impeccable`:

```bash
cd workspace/impeccable
git fetch upstream && git merge upstream/main
```

Add `upstream` once if missing:

```bash
git remote add upstream https://github.com/pbakaus/impeccable.git
```
