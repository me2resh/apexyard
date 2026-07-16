# Conformance CI — Credentialed Multi-Runtime Gate Matrix + Live Badge

> In the context of proving apexyard's mechanical governance gates keep working under real, credentialed agent turns on opencode, pi, and Codex — not just the one-off manual proofs recorded 2026-07-09 — facing the choice of how to schedule the runs, gate them on secrets, transport a live status badge, and define when a "harness-agnostic, proven" claim is earned, I decided to run a **daily scheduled matrix job per harness with fail-closed secret gating, a shields.io-endpoint badge committed to an orphan `conformance-badge` branch, and a 3-consecutive-green-run threshold before any harness's badge claims "proven"**, accepting the ongoing cost of real per-turn API spend for pi and Codex and the residual risk that a harness CLI/model upgrade silently changes turn behaviour between scheduled runs.

## Context

Spike me2resh/apexyard#848 (promoted, `docs/spike-848/findings.md`) established the feasibility verdict this feature executes on: **3-green-continuous + Cursor documented-manual**. opencode, pi, and Codex can each be driven through a real credentialed agent turn headlessly in CI, with the delegated, unmodified `block-git-add-all.sh` firing; Cursor cannot — its `cursor-agent` CLI ignores `hooks.json` entirely, and its only observed enforcement (the IDE) blocks via `failClosed` (the hook-runner erroring), not the gate's own logic evaluating and returning exit 2. The spike's own glossary is explicit that a failClosed deny is **not** a conformance proof.

Feature ticket #871 named five acceptance criteria this AgDR's decisions had to satisfy: (1) a scheduled workflow driving all three green-lit harnesses through one real gated turn each with a verbatim-message assertion, (2) GitHub-secrets-only credentials, (3) a live-pulled per-harness badge, (4) Cursor staying documented-manual on that badge, and (5) an explicit, numeric definition of "green-continuous" gating any future harness-agnostic headline claim.

Four separate design questions had to be resolved to satisfy those five ACs, each with real trade-offs:

## Options Considered

### 1. Schedule cadence

| Option | Pros | Cons |
|--------|------|------|
| Per-PR (every push to dev) | Fastest drift detection | pi and Codex bill a real API call per turn; multiplies cost by PR volume on files the PR may not even touch |
| Weekly | Cheapest | A harness CLI/model regression could sit undetected for up to 7 days before the next scheduled run, widening the window a "proven" badge is silently stale |
| **Daily, + `workflow_dispatch` (CHOSEN)** | Catches drift within a day; keeps the 3-green-continuous window at 3 days, not 3 weeks; `workflow_dispatch` gives the operator an on-demand credentialed run without waiting for the clock | Still real, ongoing spend — 2 billed API turns/day (pi + Codex; opencode is free-model) plus whatever the operator triggers manually |

**Decision: daily (`cron: "17 6 * * *"`) + `workflow_dispatch` with an optional single-harness input.** The odd minute (`:17`) avoids the top-of-hour cron stampede GitHub Actions documents. `workflow_dispatch` accepting an optional `harness` input lets an operator re-run just the flaky harness after a fix, without re-billing the other two.

### 2. Secret-missing behaviour: skip vs fail-closed

| Option | Pros | Cons |
|--------|------|------|
| Skip the job (green check, "no secret configured" note) | Never blocks a PR/run on infra the operator hasn't set up yet | **A skipped job reads as a green check in GitHub's UI and in this workflow's own badge job (`needs.conform`)** — exactly the silent-drift failure mode this ticket exists to prevent. An operator who never provisions `CONFORMANCE_OPENAI_API_KEY` would see a permanently green Codex badge that has never actually run a credentialed turn. |
| **Fail-closed: missing secret = job FAILS loudly (CHOSEN)** | Un-provisioned credentials are visibly red, not invisibly green; matches the ticket's own explicit instruction ("fail-closed and honest — never skip-green") | The workflow is red-by-default for pi/Codex until the operator provisions two secrets — a real onboarding step, not a zero-config drop-in |

**Decision: fail-closed.** `steps.creds` resolves readiness per harness and a following step exits 1 with a `::error::` naming the exact missing secret when not ready — this is deliberate: the operator must take an action (provision the secret) to turn the badge green, rather than the badge defaulting to a state that looks fine but proves nothing. opencode never fails on this axis — its free `opencode/big-pickle` model needs no key (per the spike's own finding), so it is CI's always-on, cost-free canary.

### 3. Badge transport

| Option | Pros | Cons |
|--------|------|------|
| Third-party badge service (e.g. a hosted status-badge SaaS) | Turnkey rendering | New external account + a new secret/API key to provision and rotate, for a purely cosmetic feature; against the ticket's "no credentials in the workflow file / minimal new secret surface" spirit |
| GitHub Gist + shields.io gist endpoint | No new repo | Needs a PAT with gist scope (broader than `contents:write` on this repo) — an unnecessary second secret |
| `gh-pages` branch + a rendered SVG generator | Human-browsable page | More moving parts (a static-site step) for what is fundamentally one JSON blob per harness; SVG generation duplicates what shields.io already does well |
| **shields.io endpoint badge, JSON committed to an orphan `conformance-badge` branch on this repo (CHOSEN)** | Zero new secrets — the default `GITHUB_TOKEN` already grants `contents: write` on this repo when the job requests it; shields.io fetches the raw JSON directly on every badge render, so the badge is genuinely live-pulled with no polling/webhook infra on apexyard's side; an orphan branch keeps the daily commit churn out of `dev`/`main` history | Badge consumers depend on shields.io's public endpoint-badge service being up; the orphan branch is a small amount of git-plumbing ceremony (`git checkout --orphan`) a simpler design wouldn't need |

**Decision: shields.io endpoint JSON on an orphan `conformance-badge` branch, pushed with the job's own `GITHUB_TOKEN` (`contents: write`, scoped to that job only per the repo's existing least-privilege convention — see `auto-tag-on-release-pr-merge.yml` for the precedent).** README / site badges embed:

```
https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/<owner>/<repo>/conformance-badge/<harness>.json
```

`bin/conformance-publish-badge.sh` (the durable, testable artifact — see `test_conformance_publish_badge.sh`) queries the run's own matrix-job conclusions via the Actions API (`gh api repos/<repo>/actions/runs/<id>/jobs`) rather than relying on `needs.<job>.result`, because GitHub Actions has no built-in per-matrix-branch output aggregation — `needs.conform.result` only reports the matrix's overall status, not each harness's individually. Cursor's badge is a static, hand-seeded grey "documented-manual" entry the script writes once and never overwrites — there is no Cursor matrix job to drive it, which is the mechanical guarantee behind AC4 ("Cursor stays documented-manual, never proven").

### 4. Defining "green-continuous"

| Option | Pros | Cons |
|--------|------|------|
| Any single green run flips the harness-agnostic headline | Fastest to "prove" | A single lucky run (model happened to comply, no flake) is exactly the one-off-manual-proof problem this ticket exists to move past |
| N=1 scheduled green run (i.e. "currently green") | Simple | Doesn't distinguish "green today" from "green reliably" — a flaky harness could ping-pong red/green and still read as momentarily proven on the day someone checks |
| **N=3 consecutive scheduled green runs, any red resets to 0 (CHOSEN)** | Requires sustained reliability, not a lucky day; a reset-on-red counter is simple to reason about and simple to implement as a single integer per harness | 3 days minimum before a fresh harness (or one recovering from a regression) can claim "proven" again — a deliberate cost, not a bug |

**Decision: `GREEN_CONTINUOUS_THRESHOLD=3`, tracked as a plain integer counter per harness on the badge branch (`streak-<harness>.txt`), incremented on a `success` matrix-job conclusion and reset to `0` on anything else** (failure, including the fail-closed missing-secret case; cancelled; the job not running at all reads as `unknown`, also treated as non-success). At streak ≥ 3 the badge message appends `(proven)`; below 3 it reads `green` (or `red (<conclusion>)`) without that claim. This numeric badge state is a **display of the metric**, not itself the harness-agnostic headline-flip decision — `docs/harnesses/README.md`'s existing rebrand trigger (already ≥2-adapters-live-proven, still undecided as a deliberate, separate, coordinated call) stays the actual gate on the tagline; this AgDR's threshold is the mechanical precondition that decision can now point to, not a replacement for making it.

## Decision

Chosen, as a package: **daily schedule + `workflow_dispatch`, fail-closed secret gating (never skip-green), a shields.io-endpoint badge on an orphan `conformance-badge` branch driven by the Actions-API job-conclusion query, and a 3-consecutive-green-run definition of green-continuous with a reset-on-any-red counter** — because together they satisfy all five ACs on #871 without adding a new secret class, a new external account, or an ambiguous "proven" claim that could rest on a single lucky run.

Supporting implementation decisions:

- **The assertion helper extracts, not duplicates, the hook's message.** `bin/conformance-assert-block-message.sh` runs the real, unmodified `block-git-add-all.sh` against a synthetic stdin payload and derives its comparison anchor from that live output, rather than hardcoding a second copy of the block text in the workflow YAML. If the hook's wording changes, the assertion tracks it automatically — the alternative (a string literal baked into `conformance.yml`) would silently drift the day someone edited the hook's message for clarity, exactly the kind of duplication `docs/harnesses/README.md`'s shared-core architecture principle (`.claude/` stays canonical, everything else derives from it) already rejects for the harness adapters themselves.
- **The load-bearing assertion is the side effect, not the transcript, per the spike's own finding.** `git diff --cached --name-only` being empty after the turn is checked first and is fatal on its own; the transcript-anchor check is the second, corroborating signal that the *specific* delegated hook fired (vs. a harness self-block or a model that simply didn't attempt the command). This mirrors the spike's own three-assertion design (`docs/spike-848/findings.md` § "What 'run one gated turn and assert' looks like").
- **CLI versions are pinned in the workflow** (`opencode-ai@1.17.16`, `@earendil-works/pi-coding-agent@0.80.3`, matching the versions already recorded live-proven in `docs/harnesses/*.md`) except Codex, which is installed at `@latest` — no version-pinned Codex CLI precedent exists yet in this repo's docs to pin against; a follow-up should pin it once a specific tested version is recorded, tracked as a gap in `docs/conformance-ci.md` rather than guessed here.
- **Harness CLI package names are a best-effort inference**, not independently re-verified against a live npm registry lookup during this build (no network egress available in this build environment) — `opencode-ai`, `@earendil-works/pi-coding-agent` (already a real, installed dependency of `harness-adapters/pi/package.json`), and `@openai/codex`. This is flagged explicitly in the feature's PR body as a residual risk the first credentialed scheduled run will either confirm or surface as an install failure — which, per the fail-closed decision above, is itself the correct, visible outcome rather than a silent gap.

## Consequences

- **The first scheduled run is not expected to be green.** Per #871's own scope note ("the spike never executed a real credentialed CI run"), this feature ships the matrix, the assertion, and the badge machinery — it does not itself provision `CONFORMANCE_ANTHROPIC_API_KEY` / `CONFORMANCE_OPENAI_API_KEY` (repo secrets, operator action) or verify the pinned CLI install commands against a live network. The badge will show pi and Codex red (fail-closed, missing secret) until the operator provisions them, and any harness's install step may need a follow-up fix if a pinned package name or version is wrong. This is the intended, honest state — not a defect to hide.
- **Ongoing real spend**: pi and Codex bill a model API call once per scheduled day (plus any `workflow_dispatch` runs); opencode's free-model job is cost-free. This is a known, accepted ongoing cost, not a one-time build cost.
- **A harness CLI or model upgrade between scheduled runs is the main residual risk this design does not fully close** — e.g. opencode 1.18.x changing `tool.execute.before`'s contract, or `codex exec`'s trust-flag behaviour changing. The daily cadence bounds the detection window to ~24h rather than leaving it open indefinitely, which is the whole point of "scheduled" over "one-off manual".
- **The green-continuous counter is a simple, auditable integer per harness**, resettable by inspecting `streak-<harness>.txt` on the `conformance-badge` branch — no external state store, no database, consistent with the rest of apexyard's file-marker-based state (session markers, review markers) rather than introducing a new persistence mechanism.
- **Cursor's badge cannot silently drift to "proven"** by construction — the publisher script only ever writes `opencode.json`/`pi.json`/`codex.json` from real matrix-job conclusions; `cursor.json` has no code path that could set it to anything but the seeded manual state without a deliberate script change (and any such change, being a diff to `bin/conformance-publish-badge.sh`, is itself subject to the normal code-review + `docs/harnesses/**` role-trigger gate).

## Artifacts

- `.github/workflows/conformance.yml` — the scheduled matrix workflow
- `bin/conformance-assert-block-message.sh` — live-derived block-message assertion helper
- `bin/conformance-publish-badge.sh` — per-harness badge JSON + green-streak publisher
- `.claude/hooks/tests/test_conformance_assert_block_message.sh` — assertion-helper test
- `.claude/hooks/tests/test_conformance_publish_badge.sh` — hermetic badge-publisher test (bare-repo fixture, stubbed `gh`)
- `docs/conformance-ci.md` — operator-facing doc (secrets to provision, green-continuous rule, why Cursor is manual)
- Spike: me2resh/apexyard#848 (`docs/spike-848/findings.md`)
- Feature: me2resh/apexyard#871
- Precedent: [AgDR-0092](AgDR-0092-opencode-gate-adapter.md), [AgDR-0088](AgDR-0088-codex-adapter-generation.md), [AgDR-0082](AgDR-0082-pi-gate-dispatcher-adapter.md) (the adapters this workflow drives); [AgDR-0086](AgDR-0086-hooks-stay-bash-not-ported.md) (hooks stay bash — why the assertion delegates to the real hook instead of re-implementing its check)

## Addendum — me2resh/apexyard#880 (fast-follow)

Rex's review of the #871 PR approved with two nit-level fixes deferred to a fast-follow rather than blocking the merge (the workflow was inert until secrets were provisioned, so neither was a regression):

- **Dispatch-path streak guard.** The original implementation advanced/reset every harness's `streak-<harness>.txt` on *any* trigger. That silently over-counted: a single-harness `workflow_dispatch` leaves the other two matrix jobs reporting a trivial `success` (the "Skip non-selected harness" step exits `0` without a real gated turn), and the badge job was counting that clean skip toward "(proven)". Fixed by gating the entire per-harness streak/badge-JSON update in `bin/conformance-publish-badge.sh` on `EVENT_NAME == 'schedule'` — a `workflow_dispatch` run (single-harness or all three) is now a no-op for every harness's streak file and badge JSON. This sharpens, not changes, the "N=3 consecutive scheduled green runs" definition from the Decision above — that definition already said "scheduled"; the implementation had not enforced it.
- **Codex CLI pin + model correction.** `@openai/codex@latest` → `@openai/codex@0.144.5` (closing the gap flagged in the "Supporting implementation decisions" bullet above and in `docs/conformance-ci.md`'s former "Known gaps"), and `codex exec -m gpt-5.4` → `codex exec -m gpt-5.5` (matching the model actually recorded live-proven in `docs/harnesses/codex.md`; `gpt-5.4` was a stale value, not what was tested).

No new decision surface — these are corrections to the implementation of decisions already recorded above, not a new architectural choice.
