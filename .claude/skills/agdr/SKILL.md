---
name: agdr
description: Searchable, categorized library of Agent Decision Records (AgDRs) across the portfolio. Walks the registry, reads each project's docs/agdr/*.md (locally or via `gh api`), parses YAML frontmatter, and answers browse / search / show / stats queries. Use when you want to recall "have we decided this before?" without grepping every project.
argument-hint: "[browse|search <term>|show <id>|stats] [--project <name>] [--category <cat>] [--no-cache]"
allowed-tools: Bash, Read, Grep, Glob
---

# /agdr — AgDR Library across the portfolio

Walks `apexyard.projects.yaml`, collects every `docs/agdr/*.md` from every managed project (local clone if available, otherwise `gh api`), parses the optional YAML frontmatter for `category` + `projects`, and answers four queries:

| Subcommand | Purpose |
|------------|---------|
| `/agdr browse` | List every AgDR across the portfolio, grouped by category |
| `/agdr search <term>` | Full-text grep across all AgDR bodies; returns `<project>/AgDR-NNNN-<slug>.md` paths plus the matching paragraph |
| `/agdr show <id>` | Print a specific AgDR (`AgDR-0007` or `<project>/AgDR-0007`) regardless of which project it lives in |
| `/agdr stats` | Counts per category — the "AgDR Library" tile from the marketing slides, but real |

This is the data layer behind "AgDR Library" in the marketing slides. Before this skill, AgDRs were loose markdown files searchable only by `grep` per project. Now they're a portfolio-wide index with category metadata.

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`, `./projects/ideas-backlog.md`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir, ideas_backlog}` keys in `.claude/project-config.json`. Don't hardcode literal `apexyard.projects.yaml` or `projects/` paths in bash blocks — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

## Usage

```
/agdr browse                            # all projects, all categories
/agdr browse --category security        # only security AgDRs
/agdr browse --project example-app      # only one project's AgDRs
/agdr search "rate limit"               # full-text across all bodies
/agdr search rate --category patterns   # narrow by category
/agdr show AgDR-0007                    # disambiguates if id is unique
/agdr show example-app/AgDR-0007        # explicit when the id appears in two projects
/agdr stats                             # category counts (tabular)
/agdr stats --json                      # machine-readable counts
```

Add `--no-cache` to bypass the per-session cache (useful right after writing a new AgDR).

## Categories — the canonical 6

```
architecture     System / service shape, layering, bounded contexts
tech-stack       Language / framework / database / runtime choices
security         Auth, authz, secrets handling, threat-model outcomes
patterns         Design / implementation patterns adopted across the codebase
integrations     Third-party APIs, providers, vendors
other            Anything that doesn't fit; default for legacy AgDRs without frontmatter
```

These six are what `/agdr stats` aggregates and what the AgDR template's frontmatter offers as the choice set. Treat them as a stable taxonomy — operators occasionally want a seventh, but the cost of taxonomy drift across a portfolio is high; resist new categories without an AgDR justifying the addition.

## Frontmatter schema

The optional block at the top of each AgDR markdown file:

```yaml
---
id: AgDR-NNNN
timestamp: 2026-05-03T10:30:00Z
agent: claude
model: claude-opus-4-7
trigger: user-prompt
status: executed
category: architecture | tech-stack | security | patterns | integrations | other
projects: [example-app, billing-api]   # optional — defaults to the AgDR's containing project
---
```

The skill reads only `category` and `projects`. Everything else (id, timestamp, agent, etc.) is descriptive and not used for retrieval. Missing frontmatter or missing `category:` → categorise as `other`.

## Process

### 1. Resolve the portfolio

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
projects_dir=$(portfolio_projects_dir)

# Read project list. yq if available, otherwise a yaml-aware fallback.
if command -v yq >/dev/null 2>&1; then
  yq -r '.projects[] | .name + "|" + (.repo // "") + "|" + (.workspace // "")' "$registry"
else
  # Minimal fallback — good enough for the canonical example.yaml shape
  awk '/^  - name:/{name=$3} /^    repo:/{repo=$2} /^    workspace:/{ws=$2} \
       /^  - name:/ && name { if (prev) print prev; prev=name"|"repo"|"ws } \
       END{ if (prev) print prev }' "$registry"
fi
```

If the registry doesn't parse or contains no `projects:` key → print a friendly error pointing at `apexyard.projects.yaml.example` and stop.

### 2. Collect AgDRs per project

For each project entry, decide the read path:

| Source | When to use | Read command |
|--------|-------------|--------------|
| Local workspace | `workspace/<name>/docs/agdr/*.md` exists | `find workspace/<name>/docs/agdr -name 'AgDR-*.md' -type f` |
| Local fork docs | This is the apexyard fork itself (its own AgDRs in `docs/agdr/`) | `find docs/agdr -name 'AgDR-*.md' -type f` (only when iterating the fork's own decisions) |
| GitHub API | No local clone | `gh api repos/<owner>/<repo>/contents/docs/agdr --jq '.[].name'` then `gh api repos/<owner>/<repo>/contents/docs/agdr/<file> --jq '.content' \| base64 -d` |

The fork's own `docs/agdr/` is included as a synthetic project entry named `apexyard` (or whatever the fork is named) — it carries the framework's own decisions, not a managed-project's, and they belong in the index.

Cache results per-session at `.claude/session/agdr-index.cache.json` keyed by registry mtime. Subsequent invocations within the same session re-read from cache; `--no-cache` forces a refresh. The cache is small (~1 KB per AgDR — id, path, category, project, body-snippet) and rebuilt in well under a second for typical portfolios.

### 3. Parse frontmatter

Each AgDR file is read once, and the leading `---\n…\n---` block is parsed:

```bash
parse_frontmatter() {
  local file="$1"
  awk '
    BEGIN { in_fm = 0; fm_done = 0 }
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && /^---[[:space:]]*$/ { in_fm = 0; fm_done = 1; next }
    in_fm { print }
    fm_done && /./ { exit }       # short-circuit once frontmatter parsed
  ' "$file"
}
```

Extract `category:` and `projects:`. If either is absent:

- Missing `category:` → `category=other`
- Missing `projects:` → `projects=[<containing project>]`

Files with no frontmatter at all (legacy AgDRs predating this skill) are still indexed — they just land in the `other` bucket.

### 4. Build the in-memory index

```
{
  "AgDR-0001": {
    "id": "AgDR-0001",
    "title": "Rule mechanization via hooks",
    "path": "apexyard/docs/agdr/AgDR-0001-rule-mechanization-hooks.md",
    "project": "apexyard",
    "category": "patterns",
    "projects_field": ["apexyard"]
  },
  ...
}
```

The index is built fresh per invocation (or once per session with `--no-cache` to bust). For typical portfolio sizes (5-20 projects, 5-30 AgDRs each) this is well under a second.

### 5. Answer the query

#### `/agdr browse [--category C] [--project P]`

Group by category (or by project if `--project` is set), sorted within each group by id:

```
ARCHITECTURE (3)
  apexyard/AgDR-0007  Adopt release-cut branch model
  apexyard/AgDR-0010  Portfolio config and self-healing
  example-app/AgDR-0004 Hexagonal layout for the API tier

TECH-STACK (2)
  apexyard/AgDR-0003  Mermaid C4 over Structurizr DSL
  example-app/AgDR-0001 Postgres over MySQL for transactional data

…

OTHER (4)                      ← legacy AgDRs without category frontmatter
  apexyard/AgDR-0002  Warning-to-blocker upgrade
  apexyard/AgDR-0005  Tag-based upstream drift
  apexyard/AgDR-0006  Project-configurable ticket schema
  apexyard/AgDR-0008  CHANGELOG fallback for squash-merged forks

13 AgDRs across 3 projects · 6 categories
3 lack `category:` frontmatter — run `/agdr migrate` (TODO) or edit manually.
```

The trailing migration prompt only appears if at least one AgDR is in `other` due to missing frontmatter (not because operator chose `other` deliberately — those are detected by the literal `category: other` value being absent).

#### `/agdr search <term> [--category C] [--project P]`

Case-insensitive grep across the bodies (title + content, not just frontmatter). One result block per match:

```
example-app/AgDR-0004 — Hexagonal layout for the API tier
  category: architecture
  …adopt a hexagonal architecture so that the **rate limiting** middleware
  can be replaced without touching the domain layer…

apexyard/AgDR-0011 — Bootstrap-skill exemption
  category: patterns
  …bootstrap skills like /setup write before any **rate limiting** is wired
  up; they shouldn't trip the active-ticket gate…

2 matches across 2 projects.
```

Match snippets are the paragraph containing the hit, trimmed to ~3 lines. Multiple hits per file collapse to one result block (with one snippet — the first hit). If 0 matches: print "0 matches for `<term>`" and exit cleanly.

#### `/agdr show <id>`

Print the resolved AgDR file's full content. Disambiguation:

- `AgDR-0007` → resolves uniquely if exactly one project has it; otherwise prompt for `<project>/AgDR-0007`
- `<project>/AgDR-0007` → resolves directly; errors if the project or id doesn't exist
- Numeric-only inputs (`7`, `0007`) → expanded to `AgDR-0007` and resolved as above

Output is the raw markdown — frontmatter included so the reader sees the full record.

#### `/agdr stats [--json]`

```
| Category       | Count |
|----------------|-------|
| architecture   |    12 |
| tech-stack     |     8 |
| security       |     6 |
| patterns       |     7 |
| integrations   |     5 |
| other          |     4 |
| **Total**      |    42 |

Across 5 managed projects + the apexyard fork itself.
```

`--json` flips this to:

```json
{
  "categories": {
    "architecture": 12,
    "tech-stack": 8,
    "security": 6,
    "patterns": 7,
    "integrations": 5,
    "other": 4
  },
  "total": 42,
  "projects": 6,
  "uncategorised": 4
}
```

`uncategorised` counts AgDRs that landed in `other` because frontmatter was missing — distinct from operator-chosen `category: other`. Useful for a "migrate these" follow-up.

### 6. Caching

Per-session cache at `.claude/session/agdr-index.cache.json`:

```json
{
  "registry_mtime": 1714752000,
  "built_at": "2026-05-03T10:30:00Z",
  "entries": [ { "id": "AgDR-0007", "project": "apexyard", "category": "architecture", "title": "...", "path": "..." }, ... ]
}
```

Invalidation:

- `--no-cache` → ignore and rebuild
- Cache file's `registry_mtime` differs from the registry's actual mtime → rebuild (catches new project added)
- Cache file is older than 1 hour → rebuild (catches AgDRs added since the cache was built)

The cache stores enough metadata for browse/stats but not full bodies — search always reads bodies fresh because reading 30 small markdown files is cheaper than maintaining a body cache.

## Errors and edge cases

| Condition | Behaviour |
|-----------|-----------|
| `apexyard.projects.yaml` missing | Print friendly error pointing at `.example` + `docs/multi-project.md` |
| Registry parses but has 0 projects | Skill still indexes the apexyard fork's own `docs/agdr/`; prints a note that no managed projects are registered |
| A project has no `docs/agdr/` dir | Silently skip — not an error, just zero contribution |
| `gh api` fails for a non-cloned project | Print a one-line warning per project, continue with the rest; mark that project as `(unreachable)` in browse |
| AgDR file has malformed frontmatter (unclosed `---`) | Treat as no-frontmatter (category=other); print one-line warning to stderr |
| Two AgDRs share the same id within one project | Index both; flag in `/agdr browse` as a duplicate row |
| `<id>` passed to `/agdr show` doesn't exist | List the closest matches by Levenshtein-ish prefix; exit 1 |

## Performance notes

- Typical portfolio: 5–20 projects × 5–30 AgDRs = 25–600 files. ~1 ms per file to read + parse → 25–600 ms total.
- Network reads via `gh api` add ~100 ms per non-cloned project (one directory listing + N small file fetches). Cache aggressively.
- Cache hit path is ~10 ms (read JSON, filter, render). Cold-start without cache and without local clones is ~3–5 s for a 10-project portfolio.
- v2 (out of scope of this skill): a `projects/agdr-index.md` rebuilt by a post-commit hook would make even cold starts ~10 ms. Left for a follow-up if the cache-per-session approach proves too slow.

## Rules

1. **Read-only** — never modifies any AgDR, never writes to `docs/agdr/` of any project. Cache writes go to `.claude/session/` only.
2. **Tolerant of missing frontmatter** — legacy AgDRs are first-class citizens, just bucketed as `other`.
3. **No new categories without an AgDR** — the 6-category taxonomy is the contract. Operators wanting a 7th category should write an AgDR justifying it; this skill rejects unknown categories and reports them as `other` with a one-line stderr warning so drift is visible.
4. **Doesn't mutate the registry** — pure consumer of `apexyard.projects.yaml`.
5. **`gh api` is the cross-org fallback, not the primary** — local clones are read first when available, both for speed and because `gh api` has rate limits on busy days.
6. **Apexyard's own AgDRs are included** — the fork's `docs/agdr/` is treated as a synthetic project so the framework's decisions show up alongside the portfolio's.

## When to use this

| Trigger | Use `/agdr`? |
|---------|--------------|
| "Have we decided X before?" mid-design | Yes — `/agdr search X` |
| Onboarding a new engineer to the portfolio | Yes — `/agdr browse` is the orientation |
| Pre-PRD: "what's our auth pattern across projects?" | Yes — `/agdr browse --category security` |
| Producing a marketing/sales deck with category counts | Yes — `/agdr stats --json` feeds the slide |
| Recording a NEW decision | No — that's `/decide`, which writes the AgDR. `/agdr` only reads. |
| Tracking a single decision's lineage | Use `git log -p docs/agdr/AgDR-NNNN…` directly — `/agdr` is portfolio-level, not history-level |

## Related skills

- `/decide` — writes AgDRs (the producer; this skill is the consumer)
- `/projects` — same registry walk; project-level rather than AgDR-level view
- `/handover` — onboarding flow that may produce an early batch of AgDRs

## Out of scope (v1)

- **Persistent index file** (`projects/agdr-index.md` auto-regenerated on commit) — deferred until cache-per-session proves insufficient
- **Frontmatter migration helper** (`/agdr migrate`) — currently the skill prints "N AgDRs lack `category:`" and the operator edits manually; a guided migrator is a separate ticket
- **Cross-AgDR linking** — "AgDR-0007 supersedes AgDR-0003" relationships aren't surfaced; the schema doesn't carry them yet
- **Full-text relevance ranking** — current search is grep-style match presence, not BM25/TF-IDF; fine for portfolios in the hundreds, not thousands
