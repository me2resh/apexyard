# Nomrate

**Brand:** Nomrate — *Know your market rate.*  
**Domains:** `nomrate.com`, `nomrate.app` (register ASAP — verified available via RDAP June 2026)  
**Status:** Planning → active build (repos scaffolded; app implementation not started)  
**Ticket prefix:** `NOM`  
**Source PRD:** `NOMRATE_PRD_v3.md` (normalized from OBSIDIAN PRD v3)  
**Grill decisions:** `DECISIONS.md`

Freelancer pricing intelligence — rate calculator, market overlay, platform fee comparison, documents, AI advisor, community rate board, template marketplace.

## Repos (three-repo model)

| Repo | Purpose |
|------|---------|
| [Dr-kersho/nomrate-mobile](https://github.com/Dr-kersho/nomrate-mobile) | Expo app (iOS first, Android fast-follow) |
| [Dr-kersho/nomrate-api](https://github.com/Dr-kersho/nomrate-api) | AWS CDK, Lambda, DynamoDB, AI proxy; publishes `@nomrate/rates-core` |
| [Dr-kersho/nomrate-web](https://github.com/Dr-kersho/nomrate-web) | GTM fee calculator, landing, privacy policy, `/admin` moderation |

Shared npm package **`@nomrate/rates-core`** lives in `nomrate-api/packages/rates-core`.

## Workspace clones

```bash
# From apexyard root (gitignored)
git clone git@github.com:Dr-kersho/nomrate-mobile.git workspace/nomrate-mobile
git clone git@github.com:Dr-kersho/nomrate-api.git workspace/nomrate-api
git clone git@github.com:Dr-kersho/nomrate-web.git workspace/nomrate-web
```

## Build sequence

See [`ISSUES.md`](./ISSUES.md) for GitHub issue links (NOM-1–NOM-30) or `ROADMAP.md` for phase grouping.

## Docs here vs app repos

| Location | Contents |
|----------|----------|
| `projects/nomrate/` (ops fork) | PRD, grill decisions, roadmap, portfolio notes |
| App repos | Implementation, AgDRs, CI, deployment config |
