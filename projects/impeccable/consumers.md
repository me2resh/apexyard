# Impeccable consumer pattern

Impeccable is managed **once** at the portfolio level. Each site or app that uses it keeps **local sidecars** — design context and Live Mode state that belong to that product, not to the tooling repo.

## Two layers

| Layer | Where | Owns |
|-------|--------|------|
| **Tooling** | `workspace/impeccable/` + [Dr-kersho/impeccable](https://github.com/Dr-kersho/impeccable) | Skills, CLI, Live Mode server, `/impeccable *` commands |
| **Consumer** | Each site's repo root (or site subfolder) | `PRODUCT.md`, `DESIGN.md`, `.impeccable/live/config.json`, gitignored live sessions |

**Rule:** Never move a consumer's `PRODUCT.md`, `DESIGN.md`, or `.impeccable/live/` into the impeccable repo. Tool changes and site design context ship on different lifecycles.

## Sidecar files (per consumer)

| File / path | Committed? | Purpose |
|-------------|------------|---------|
| `PRODUCT.md` | Yes | Register, users, principles, anti-references — strategy only |
| `DESIGN.md` | Yes | Tokens, typography, components, do/don't — visual source of truth |
| `.impeccable/live/config.json` | Yes | Live Mode entry files, CSP, insert hook |
| `.impeccable/live/sessions/` | No | Recoverable live session journals |
| `.impeccable/live/previews/` | No | Variant previews |
| `.impeccable/hook.cache.json` | No | Local hook cache |

Runtime paths are gitignored via the `impeccable-live-ignore` block in the consumer's `.gitignore`.

## Wiring a new consumer

1. **Install skills** from the portfolio fork (pick one):

   ```bash
   # Per-project submodule (recommended for pinned version)
   git submodule add https://github.com/Dr-kersho/impeccable .impeccable
   npx impeccable skills link --source=.impeccable --providers=claude,cursor

   # Or harness-wide (uses latest npm build)
   npx impeccable skills install
   ```

2. **Run init once** in the consumer root:

   ```text
   /impeccable init
   ```

   Creates or refreshes `PRODUCT.md`, `DESIGN.md`, and `.impeccable/live/config.json`.

3. **Register the consumer** in `apexyard.projects.yaml` with tag `impeccable-consumer` if it is portfolio-managed.

4. **Add this row** to the table below.

## Registered consumers

| Project | Site root | Sidecars |
|---------|-----------|----------|
| **apexyard (ops)** | repo root | `PRODUCT.md`, `DESIGN.md`, `.impeccable/live/config.json` |
| [smartmomlabs](../smartmomlabs/) | `projects/smartmomlabs/website/` | `PRODUCT.md`, `DESIGN.md`, `.impeccable/live/config.json` |

## Where to open PRs

| Change | Target repo / path |
|--------|-------------------|
| New skill, CLI fix, Live Mode bug | `Dr-kersho/impeccable` |
| blendavit tokens, copy, layout | `projects/smartmomlabs/website/` (ops repo) |
| Portfolio registry or cross-project docs | apexyard ops repo (`projects/impeccable/`, `projects/smartmomlabs/`) |

## Preview + Live Mode

From a consumer site root:

```bash
./bin/preview          # static preview (8080)
./bin/preview 8766     # custom port for Impeccable Live
/impeccable live       # in Cursor / Claude Code
```

Live Mode reads the consumer's `.impeccable/live/config.json` and writes sessions under `.impeccable/live/sessions/` (gitignored).
