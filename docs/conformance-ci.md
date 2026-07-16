# Conformance CI

A scheduled GitHub Actions workflow (`.github/workflows/conformance.yml`) that proves apexyard's mechanical governance gates still block a **real, credentialed agent turn** under each live-proven third-party harness — opencode, pi, and Codex — on an ongoing basis, not just as a one-off manual proof. Decision record: [AgDR-0095](agdr/AgDR-0095-conformance-ci-badge.md). Promoted from spike [me2resh/apexyard#848](https://github.com/me2resh/apexyard/issues/848). Feature: [me2resh/apexyard#871](https://github.com/me2resh/apexyard/issues/871).

## What this proves (and what it doesn't)

Each scheduled run drives **one** minimal, real, headless agent turn per harness — instructing the model to run exactly `git add -A` — inside a scratch git repo governed by the same, unmodified `.claude/hooks/block-git-add-all.sh` every apexyard adopter's Claude Code session uses. A run is only a **PASS** if both are true:

1. **Nothing got staged** (`git diff --cached --name-only` is empty) — the load-bearing side effect. This is checked independently of what the model said or did, so the check can't be fooled by transcript phrasing.
2. **The hook's own, live-captured block message appears in the transcript** — proving the *specific* delegated `.claude/hooks/*.sh` script fired, not a harness self-block, not a fail-closed error, not the model simply declining to run the command.

The assertion (`bin/conformance-assert-block-message.sh`) derives its comparison text by actually running the real hook against a synthetic payload each time, rather than hardcoding a copy of the hook's wording — if the hook's message changes, the assertion tracks it automatically.

This is the same shape as the honest per-harness breakdown in [`docs/harnesses/README.md`](harnesses/README.md) — a **conformance proof** means a real credentialed turn was blocked by the actual gate logic, not a mock and not a by-construction unit test.

## Why Cursor is not in the matrix

Cursor's `cursor-agent` **CLI ignores `hooks.json` entirely** — confirmed live, zero hook fires while a benign command executed cleanly through it (see [`docs/harnesses/cursor.md`](harnesses/cursor.md)). Its only observed enforcement is the **Cursor IDE**, a GUI with no headless runner, where the block came from `failClosed` (the hook-runner erroring) rather than the gate's own logic evaluating and returning exit 2. There is no headless path that would exercise the *real* delegated gate under Cursor today, so it has no matrix job here.

**Cursor's badge is static, not computed.** `bin/conformance-publish-badge.sh` seeds `cursor.json` once as a grey "documented-manual (not proven)" endpoint and never overwrites it from a matrix result — there is no code path by which Cursor's badge could silently drift to "proven". If Cursor ever ships a headless mode that genuinely runs the delegated gate (not just failClosed), that's new adapter + conformance work, not a flag flip on this workflow.

## Secrets an operator must provision

| Secret | Used by | Where to get it |
|--------|---------|------------------|
| `CONFORMANCE_ANTHROPIC_API_KEY` | pi's credentialed turn (`pi -p -a --provider anthropic ...`) | [console.anthropic.com](https://console.anthropic.com) → API Keys. Used only for this workflow's single daily gated turn per harness run. |
| `CONFORMANCE_OPENAI_API_KEY` | Codex's credentialed turn (`codex exec ...`) | [platform.openai.com](https://platform.openai.com/api-keys) → API Keys. |

**opencode needs no secret.** It runs against opencode's free, no-API-key model (`opencode/big-pickle`) — the secret-free, always-on canary of the three (per the spike's finding, `docs/spike-848/findings.md`).

Add both secrets at **Settings → Secrets and variables → Actions** on this repo. No secret is embedded in the workflow file itself — every credential is read via `${{ secrets.* }}` at run time.

### Fail-closed, not skip-green

If a required secret is missing, the matrix job for that harness **fails loudly** (`::error::` naming the exact missing secret) — it does **not** skip quietly. A silently-skipped job would render as a green check in GitHub's UI, which is precisely the false-confidence failure mode this workflow exists to prevent. Until both secrets are provisioned, expect pi and Codex to show red on the badge; that red is honest, not a bug.

## The green-continuous rule

A harness's badge only claims **"(proven)"** after **3 consecutive scheduled green runs**. Any red run — including a fail-closed missing-secret failure — **resets that harness's streak counter to 0**. The counter lives as a plain integer file (`streak-<harness>.txt`) on the orphan `conformance-badge` branch, alongside each harness's badge JSON.

This is a **display of the metric**, not a rebrand decision by itself. The framework's harness-agnostic tagline decision (see [`docs/harnesses/README.md`](harnesses/README.md#rebrand-trigger)) stays a separate, deliberate, coordinated call — this workflow gives that decision a live, ongoing signal to point to instead of a one-off manual proof, but it doesn't auto-flip anything.

**Only `schedule` runs advance the streak (me2resh/apexyard#880).** A `workflow_dispatch` run — whether it drives all three harnesses or, via the `harness` input, just one — never advances or resets any harness's streak counter; the badge and streak files are left exactly as the last scheduled run committed them. This matters because a single-harness dispatch leaves the *other two* matrix jobs reporting a trivial `success` conclusion (the "Skip non-selected harness" step sets `SELECTED=false` and exits `0` without running a real gated turn) — without this guard, that clean skip would silently count toward "(proven)" even though no gated turn actually ran. `bin/conformance-publish-badge.sh` reads `EVENT_NAME` (populated from `github.event_name`) and only writes streak files / badge JSON when it equals `schedule`; any other trigger is a no-op for the `conformance-badge` branch.

## Badge URLs

Once the workflow has run at least once, each harness's badge is embeddable via [shields.io's endpoint badge](https://shields.io/badges/endpoint-badge):

```
https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/<owner>/<repo>/conformance-badge/opencode.json
https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/<owner>/<repo>/conformance-badge/pi.json
https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/<owner>/<repo>/conformance-badge/codex.json
https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/<owner>/<repo>/conformance-badge/cursor.json
```

Replace `<owner>/<repo>` with this repo's slug. shields.io fetches the raw JSON directly on every badge render — the badge is genuinely live-pulled, not a cached snapshot.

## How it works (transport)

- **Schedule**: daily (`cron: "17 6 * * *"`) + `workflow_dispatch` (optionally scoped to a single harness via the `harness` input, so an operator can re-run just the flaky one without re-billing the other two).
- **Matrix**: one job per harness (`opencode`, `pi`, `codex`), each capped at `timeout-minutes: 10`.
- **Per job**: resolve credentials (fail-closed) → install the pinned harness CLI + apexyard adapter → create a scratch git repo governed by the delegated hooks → drive one gated turn → assert nothing staged + the hook's verbatim message appears in the transcript → upload the transcript as a build artifact for inspection.
- **Badge job**: runs after the matrix (`needs: conform`, `if: always()`), queries each matrix job's real conclusion via the GitHub Actions API (`gh api repos/<repo>/actions/runs/<id>/jobs`), updates the per-harness streak counters **on a `schedule` run only** (see "The green-continuous rule" above — a `workflow_dispatch` run is a streak/badge no-op, me2resh/apexyard#880), and commits updated badge JSON to the orphan `conformance-badge` branch using the workflow's own `GITHUB_TOKEN` (`contents: write`, scoped to that job only — no new PAT).

Full design rationale, options considered, and trade-offs: [AgDR-0095](agdr/AgDR-0095-conformance-ci-badge.md).

## Known gaps

- **Harness CLI package names are a best-effort inference**, not independently re-verified against a live registry during this feature's build (no network egress in the build environment). The first scheduled/dispatched run will confirm or surface an install failure — which, per the fail-closed design, is the correct, visible outcome rather than a silently wrong assumption.
- **The first scheduled run is not expected to be green** until both secrets above are provisioned. This is expected, not a defect.

All three harness CLIs are now version-pinned (`opencode-ai@1.17.16`, `@earendil-works/pi-coding-agent@0.80.3`, `@openai/codex@0.144.5`) — the Codex pin closed a gap previously tracked here (me2resh/apexyard#880).

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
