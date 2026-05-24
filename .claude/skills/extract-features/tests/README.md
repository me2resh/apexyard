# /extract-features smoke test

Standalone bash script that builds a synthetic codebase fixture covering
Express routes + Prisma models (plus BullMQ + cron jobs, Jest test names,
React Router screens, and a README features section + CHANGELOG), then runs
the grep-fallback signatures from `../SKILL.md` against it and asserts each
of the six discovery axes produces non-empty findings.

Verifies on every change that:

- The grep regexes in SKILL.md still match what they're supposed to match
  (the `app.get(` / `model X {` / `describe(` / `<Route path=` patterns)
- Vendored-dir pruning (`node_modules/`) doesn't leak into the route count
- Each axis exceeds a minimum-findings threshold so a regression that drops
  a signature is caught

The skill itself runs inside Claude Code with richer dispatch — LSP-aware
walks where available, framework-specific signatures, dedup across axes,
matrix consolidation. This script exists so a human or CI job can confirm
the documented signatures haven't drifted.

## Run

From the apexyard fork root:

```bash
bash .claude/skills/extract-features/tests/smoke.sh
```

Builds the fixture in `$TMPDIR/extract-features-fixture-*`, runs the seven
checks, and removes the fixture on exit (success or failure).

Exit code: `0` on success, `1` if any axis produces fewer findings than its
minimum threshold.

## Fixture coverage

| File | Axis exercised |
|------|----------------|
| `src/routes/orders.js` + `src/routes/auth.js` | HTTP routes (Express) |
| `prisma/schema.prisma` | Data models (Prisma) |
| `src/workers/email.js` + `src/workers/cleanup.js` | Async jobs (BullMQ + node-cron) |
| `tests/orders.test.js` + `tests/auth.test.js` | Test names (Jest) |
| `src/pages/router.jsx` + `src/pages/LoginPage.jsx` | UI screens (React Router) |
| `README.md` + `CHANGELOG.md` + `docs/features/orders.md` | Documented features |

This satisfies the ticket AC ("at least 2 framework signatures, e.g. Express
routes + Prisma schema") with margin — all six axes have at least one signature.

## Adding a framework signature

Edit `../SKILL.md` to document the new signature, then either:

1. Extend `smoke.sh` with a new fixture file + assertion if it's high-priority
   (a major framework family like Django or Rails)
2. Leave it to the skill's runtime dispatch otherwise (the smoke test is
   sampling, not exhaustive — it covers two or three signatures per axis to
   catch regressions, not every signature in the matrix)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
