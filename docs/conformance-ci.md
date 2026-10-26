# Conformance CI

A scheduled GitHub Actions workflow (`.github/workflows/conformance.yml`) proves that apexyard's mechanical governance gates still block a **real, credentialed agent turn** under each live-proven third-party harness. The harnesses are opencode, pi, and Codex. The proof runs on an ongoing basis, not as a one-off manual proof. Decision record: [AgDR-0095](agdr/AgDR-0095-conformance-ci-badge.md). Promoted from spike [me2resh/apexyard#848](https://github.com/me2resh/apexyard/issues/848). Feature: [me2resh/apexyard#871](https://github.com/me2resh/apexyard/issues/871).

## What this proves (and what it does not)

Each scheduled run drives **one** minimal, real, headless agent turn per harness. The turn instructs the model to run exactly `git add -A`. The turn runs inside a scratch git repo governed by the same, unmodified `.claude/hooks/block-git-add-all.sh` every apexyard adopter's Claude Code session uses. A run is only a **PASS** if both are true:

1. **Nothing got staged** (`git diff --cached --name-only` is empty). This is the load-bearing side effect. The check runs independently of what the model said or did, so transcript phrasing cannot fool it.
2. **The hook's own, live-captured block message appears in the transcript.** That proves the *specific* delegated `.claude/hooks/*.sh` script fired. It was not a harness self-block, not a fail-closed error, and not the model declining to run the command.

The assertion (`bin/conformance-assert-block-message.sh`) derives its comparison text by running the real hook against a synthetic payload each time. It does not hardcode a copy of the hook's wording. If the hook's message changes, the assertion tracks it automatically.

This is the same shape as the honest per-harness breakdown in [`docs/harnesses/README.md`](harnesses/README.md). A **conformance proof** means the actual gate logic blocked a real credentialed turn, not a mock and not a by-construction unit test.

## Why Cursor is not in the matrix

A test on Cursor.app 3.10.20 (2026-09-16) observed native IDE exec of unmodified `.claude/hooks/*.sh`. The `cursor-agent` **CLI still ignores `hooks.json`**. There is no headless runner that would exercise the delegated gate in this workflow. Cursor stays out of the matrix.

**Cursor's badge is static, not computed.** `bin/conformance-publish-badge.sh` seeds `cursor.json` once as a grey "documented-manual" endpoint and never overwrites it from a matrix result. A headless Cursor path that runs the delegated gate would be new adapter plus conformance work, not a flag flip on this workflow.

## Secrets an operator must provision

| Secret | Used by | Where to get it |
|--------|---------|------------------|
| `CONFORMANCE_ANTHROPIC_API_KEY` | pi's credentialed turn (`pi -p -a --provider anthropic ...`) | [console.anthropic.com](https://console.anthropic.com) → API Keys. Used only for this workflow's single daily gated turn per harness run. |
| `CONFORMANCE_OPENAI_API_KEY` | Codex's credentialed turn (`codex exec ...`) | [platform.openai.com](https://platform.openai.com/api-keys) → API Keys. |

**opencode needs no secret.** It runs against opencode's free, no-API-key model (`opencode/big-pickle`). It is the secret-free, always-on canary of the three (per the spike's finding, `docs/spike-848/findings.md`).

Add both secrets at **Settings → Secrets and variables → Actions** on this repo. No secret sits in the workflow file itself. Every credential comes from `${{ secrets.* }}` at run time.

### Fail-closed, not skip-green

If a required secret is missing, the matrix job for that harness **fails loudly** (`::error::` naming the exact missing secret). It does **not** skip quietly. A silently-skipped job would render as a green check in GitHub's UI, which is precisely the false-confidence failure mode this workflow exists to prevent. Until the operator provisions both secrets, expect pi and Codex to show red on the badge; that red is honest, not a bug.

## The green-continuous rule

A harness's badge only claims **"(proven)"** after **3 consecutive scheduled green runs**. Any red run, including a fail-closed missing-secret failure, **resets that harness's streak counter to 0**. The counter lives as a plain integer file (`streak-<harness>.txt`) on the orphan `conformance-badge` branch, alongside each harness's badge JSON.

This is a **display of the metric**, not a rebrand decision by itself. The framework's harness-agnostic tagline decision (see [`docs/harnesses/README.md`](harnesses/README.md#rebrand-trigger)) stays a separate, deliberate, coordinated call. This workflow gives that decision a live, ongoing signal to point to instead of a one-off manual proof, but it does not auto-flip anything.

**Only `schedule` runs advance the streak (me2resh/apexyard#880).** A `workflow_dispatch` run never advances or resets any harness's streak counter, whether it drives all three harnesses or, via the `harness` input, only one. The badge and streak files stay exactly as the last scheduled run committed them. This matters because a single-harness dispatch leaves the *other two* matrix jobs reporting a trivial `success` conclusion. The "Skip non-selected harness" step sets `SELECTED=false` and exits `0` without running a real gated turn. Without this guard, that clean skip would silently count toward "(proven)" even though no gated turn ran. `bin/conformance-publish-badge.sh` reads `EVENT_NAME` (from `github.event_name`) and only writes streak files / badge JSON when it equals `schedule`. Any other trigger is a no-op for the `conformance-badge` branch.

## Badge URLs

Once the workflow has run at least once, each harness's badge is embeddable via [shields.io's endpoint badge](https://shields.io/badges/endpoint-badge):

```
https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/<owner>/<repo>/conformance-badge/opencode.json
https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/<owner>/<repo>/conformance-badge/pi.json
https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/<owner>/<repo>/conformance-badge/codex.json
https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/<owner>/<repo>/conformance-badge/cursor.json
```

Replace `<owner>/<repo>` with this repo's slug. shields.io fetches the raw JSON directly on every badge render. The badge is live-pulled, not a cached snapshot.

## How it works (transport)

- **Schedule**: daily (`cron: "17 6 * * *"`) plus `workflow_dispatch`. The dispatch may scope to a single harness via the `harness` input. An operator can re-run only the flaky one without re-billing the other two.
- **Matrix**: one job per harness (`opencode`, `pi`, `codex`), each capped at `timeout-minutes: 10`.
- **Per job**: Resolve credentials (fail-closed). Install the pinned harness CLI and apexyard adapter. Create a scratch git repo governed by the delegated hooks. Drive one gated turn. Assert nothing staged and that the hook's verbatim message appears in the transcript. Upload the transcript as a build artifact for inspection.
- **Badge job**: The job runs after the matrix (`needs: conform`, `if: always()`). It queries each matrix job's real conclusion via the GitHub Actions API (`gh api repos/<repo>/actions/runs/<id>/jobs`). It updates the per-harness streak counters **on a `schedule` run only** (see "The green-continuous rule" above). A `workflow_dispatch` run is a streak/badge no-op (me2resh/apexyard#880). It commits updated badge JSON to the orphan `conformance-badge` branch using the workflow's own `GITHUB_TOKEN` (`contents: write`, scoped to that job only, with no new PAT).

Full design rationale, options considered, and trade-offs: [AgDR-0095](agdr/AgDR-0095-conformance-ci-badge.md).

## Known gaps

- **Harness CLI package names are a best-effort inference.** The feature's build did not independently re-verify them against a live registry. The build environment had no network egress. The first scheduled or dispatched run will confirm or surface an install failure. Per the fail-closed design, that is the correct, visible outcome rather than a silently wrong assumption.
- **Do not expect the first scheduled run to be green** until the operator provisions both secrets above. Treat this as normal, not as a defect.

All three harness CLIs are now version-pinned (`opencode-ai@1.17.16`, `@earendil-works/pi-coding-agent@0.80.3`, `@openai/codex@0.144.5`). The Codex pin closed a gap previously tracked here (me2resh/apexyard#880).

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*
