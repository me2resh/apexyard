# Ponytail

**Repo**: [github.com/Dr-kersho/ponytail](https://github.com/Dr-kersho/ponytail) (fork of [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail))  
**Workspace**: `workspace/ponytail/`  
**Status**: handover  
**Tier**: P1

Agent harness skill that pushes AI coding agents toward minimal, necessary code — YAGNI ladder (stdlib → native → installed dep → one line → minimum that works) while keeping validation, security, and accessibility non-negotiable.

Benchmarks claim ~54% less LOC on real agentic tasks vs no-skill baseline. Works with Claude Code, Codex, Cursor, OpenCode, Gemini, pi, OpenClaw, and 14+ agent hosts.

## Why forked

Same pattern as [impeccable](../impeccable/): portfolio-owned fork under `Dr-kersho` for org control, GH issues under your tracker (`GH` prefix), and safe customization without depending on upstream release cadence. Upstream stays the source of truth for core skill logic — merge periodically.

## Local clone

From the ops repo root:

```bash
git clone git@github.com:Dr-kersho/ponytail.git workspace/ponytail
cd workspace/ponytail
git remote add upstream https://github.com/DietrichGebert/ponytail.git   # once
```

## Sync with upstream

```bash
cd workspace/ponytail
git fetch upstream
git checkout main
git merge upstream/main
git push origin main
```

Add `upstream` once if missing:

```bash
git remote add upstream https://github.com/DietrichGebert/ponytail.git
```

## Install into the ops repo (Cursor / harness)

**Option A — rules only (zero deps):**

```bash
mkdir -p .cursor/rules
cp workspace/ponytail/.cursor/rules/ponytail.mdc .cursor/rules/
```

**Option B — AGENTS.md merge:** merge the ladder + safety rules from `workspace/ponytail/AGENTS.md` into this repo's `AGENTS.md`.

**Option C — Claude Code plugin (full features):**

```
/plugin marketplace add Dr-kersho/ponytail
/plugin install ponytail@ponytail
```

Or keep upstream marketplace if you haven't customized the plugin manifest:

```
/plugin marketplace add DietrichGebert/ponytail
```

Provides lifecycle hooks, mode switching (`lite` / `full` / `ultra` / `off`), and slash commands (`/ponytail-review`, `/ponytail-audit`, etc.).

## Install into a consumer project

Per-agent adapters live in the fork — see [docs/agent-portability.md](https://github.com/Dr-kersho/ponytail/blob/main/docs/agent-portability.md).

| Agent | Install path |
|-------|--------------|
| Cursor | `.cursor/rules/ponytail.mdc` |
| Claude Code | plugin marketplace (see above) |
| Codex | `codex plugin marketplace add Dr-kersho/ponytail` |
| Generic | copy `AGENTS.md` to project root |

## Registered consumers

| Project | Path | Rule |
|---------|------|------|
| blendavit website | `projects/smartmomlabs/website/` | `.cursor/rules/ponytail.mdc` |
| qppv-agent | `workspace/qppv-agent/` | `.cursor/rules/ponytail.mdc` |

Update after sync:

```bash
cp workspace/ponytail/.cursor/rules/ponytail.mdc <consumer>/.cursor/rules/
```

## Development

```bash
cd workspace/ponytail
pip install pandas                              # required for correctness tests locally
npm test
node scripts/check-rule-copies.js
node scripts/build-openclaw-skills.js           # after skill edits
```

CI runs on push/PR to `main` (`.github/workflows/test.yml`) — Node 22, Python 3.12 + pandas.

## Ticket prefix

GitHub Issues on `Dr-kersho/ponytail` — **GH** (shared default).

## Related portfolio tooling

| Tool | Role |
|------|------|
| [impeccable](../impeccable/) | Design-language skills (typography, UX, Live Mode) |
| [graphify](../graphify/) | Codebase knowledge graphs (query before grep) |
| **ponytail** | Code minimalism / YAGNI enforcement |

These are complementary — not replacements for each other.
