# ponytail — Handover Assessment

**Date**: 2026-06-19  
**Assessor**: apexyard handover  
**Status**: handover

## Origin

- **Where it came from**: open source (external author)
- **Original owner**: DietrichGebert (Max Felker II and contributors)
- **Repo location**: https://github.com/Dr-kersho/ponytail (fork of DietrichGebert/ponytail)
- **First commit date**: 2026 (young project; 103 commits in last 90 days)
- **Last commit date**: 2026-06-19 — Fix for #168: Don't write output on SessionStart for Copilot (#181)

## Current State

### Tech stack

- Language: JavaScript (Node.js), shell hooks, Markdown rules/skills
- Runtime: Node 22 (CI); `node` required for Claude/Codex lifecycle hooks
- Framework: none — agent harness tooling (skills, hooks, plugins)
- Database: none
- Test framework: Node built-in test runner (`node --test tests/*.test.js`) + pi-extension npm test
- CI: GitHub Actions `test.yml` on push/PR to `main`

### Build status

- `npm install`: ok (no install step required — zero runtime deps in root package.json)
- `npm run build`: n/a (no build script)
- `npm test`: **failed locally** — 1 failing test (`correctness.test.js` csv/pandas check; likely missing `pandas` locally; CI installs it)
- `npm run lint`: n/a (no lint script)

### Test coverage

- Estimated: unknown — tests exist (9 test files) but no coverage thresholds configured

### Repo activity

- Commits in last 90 days: 103
- Open issues: unknown (gh API unavailable in session)
- Open PRs: unknown
- Top contributors: DietrichGebert / Max Felker II (active maintenance)

## Harnessability assessment

**Overall verdict**: `low`

> ⚠ Harnessability: LOW
>
> Rex's architecture handbooks will fire advisory-only on this codebase. The blocking gate (`ENFORCEMENT: blocking`) will generate false positives. Recommended: adopt as advisory-only, plan a follow-up to add the missing scaffolding (typescript strict, lint baseline, etc.)

| Dimension | Score | Evidence |
|-----------|-------|----------|
| Type safety | `none` | Plain JavaScript throughout; no `tsconfig.json`, no JSDoc strict mode |
| Module boundaries | `flat` | Top-level `hooks/`, `skills/`, `scripts/`, `tests/` — no domain/application/infrastructure split |
| Framework opinionation | `weak` | Node scripts + agent adapter files; no HTTP/persistence framework |
| Test coverage signal | `absent` | `npm test` runs but no `coverageThreshold` or CI coverage step |
| Lint baseline | `absent` | No ESLint, RuboCop, or ruff config found |

See AgDR-0042 for the scoring rationale and v1 thresholds.

**Note:** Low harnessability is expected for agent-tooling repos (same class as impeccable). ApexYard governance applies to *how you manage* the adoption, not clean-architecture layers inside skill markdown.

## Quality Risks

### Security

- Hooks inject instructions into agent sessions — review upstream changes on upgrade (supply-chain surface)
- No secrets in repo; config is optional `~/.config/ponytail/config.json`

### Dependencies

- Root `package.json` has zero runtime dependencies (good)
- pi-extension subpackage has its own deps — run `/audit-deps` if forked
- Correctness benchmark tests require Python + pandas (dev/CI only)

### Technical debt

- Multiple agent adapter copies (`.cursor/`, `.windsurf/`, `.clinerules/`, etc.) — upstream maintains sync via `scripts/check-rule-copies.js`
- OpenClaw skills generated from `skills/` — must rerun build script after skill edits

### Operational

- CI present and active
- No deployment — distributed via plugin marketplaces and file copies

## Integration Plan

### Roles that apply

- tech-lead
- platform-engineer
- backend-engineer (hook/skill JS maintenance)

### Workflows that kick in

- [ ] PR workflow — if forked under org; upstream contributions via PR to DietrichGebert/ponytail
- [ ] AgDR for technical decisions — if customizing harness integration
- [ ] Code Reviewer agent on PRs to a fork
- [ ] Security Reviewer on hook/plugin changes
- [ ] `/audit-deps` if maintaining a fork with added dependencies

### Hooks to enable

Applies to **consumer projects** and **ops fork** once ponytail rules/plugins are installed — not intrinsic to the ponytail repo itself.

### CI templates to copy in

Only if forked: existing upstream CI is adequate for this repo shape.

### Registry entry

```yaml
- name: ponytail
  repo: Dr-kersho/ponytail
  workspace: workspace/ponytail
  docs: projects/ponytail
  status: handover
  roles:
    - tech-lead
    - platform-engineer
    - backend-engineer
  tags:
    - tool-only
    - ai-tools
    - dev-productivity
  ticket_prefix: GH
```

## Next Steps

1. Decide install scope: ops-repo rules only vs Claude Code plugin vs per-consumer project copies
2. Run `npm test` in `workspace/ponytail` with `pip install pandas` to confirm green baseline locally
3. If forking under `Dr-kersho/`, set upstream remote and document sync cadence (same pattern as impeccable)
4. `/code-review` or manual review of `hooks/ponytail-activate.js` before trusting lifecycle hooks org-wide

## Post-Handover Checklist

- [ ] Review this assessment — confirm adoption scope (portfolio tool vs fork)
- [ ] Install ponytail into target harness(s) — see `projects/ponytail/README.md`
- [ ] Confirm tests green with Python deps installed
- [ ] Add ponytail to weekly `/stakeholder-update` rollup if actively maintained as a fork
- [ ] Run `/audit-deps ponytail` if fork adds dependencies

## Open Questions

- ~~Fork under `Dr-kersho/` or track upstream directly?~~ **Resolved:** forked at Dr-kersho/ponytail; sync from DietrichGebert/ponytail via `upstream` remote
- Apply ponytail rules to the entire ops repo, or only to managed project workspaces?
- Relationship to existing minimal-code guidance in `AGENTS.md` / user rules — merge or keep separate?
