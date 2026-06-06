# Harden the framework repo's own security scanning

> In the context of a public framework that ships security tooling to adopters, facing several high-value, zero-cost protections going unused on our own repo, I decided to add CodeQL, OSSF Scorecard, Dependabot (GitHub Actions), a SECURITY.md, and a release-artifact content guard — and to document the GitHub-native settings toggles for the operator — to achieve an exemplary, dog-fooded posture, accepting that the native-settings half (secret scanning + push protection, code-scanning default setup, Dependabot alerts) can't be set from code and must be flipped in repo Settings.

## Context

The repo already runs `security-scan.yml` (gitleaks full-history + Semgrep `r/bash`), release-gated. Missing, and mostly **free for public repos**: CodeQL, OSSF Scorecard, Dependabot, native secret scanning + push protection, a `SECURITY.md`, and a guard on the *release artifact* (the extracted marketplace sub-packs) rather than just source. We ship security tooling to adopters; the framework repo should run the strongest version of it. (#518.)

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Add CodeQL + Scorecard + Dependabot + SECURITY.md + artifact guard; document the native-settings toggles (chosen) | Closes the gaps that are code-expressible now; the rest is a 4-line operator checklist; dog-foods the strongest posture | Two-part delivery (code now, settings toggles by the operator) |
| Code workflows only, ignore native settings | Single PR, no operator action | Leaves the highest-leverage freebies (push protection) off |
| Toggle native settings via `gh api` in this PR | One-stop | Externally-visible admin changes on the public repo from an agent — wrong actor; the operator explicitly chose a checklist |
| New parallel security pipeline | Clean separation | Duplicates the existing `security-scan.yml`; the ticket says extend, not fork |

## Decision

Chosen: **extend in place**.

- `codeql.yml` — `actions` + `javascript-typescript` (CodeQL doesn't analyse bash; that stays on Semgrep `r/bash`).
- `scorecard.yml` — OSSF Scorecard + README badge.
- `dependabot.yml` — `github-actions` ecosystem (the repo's only real dependency surface; no package manifests).
- `SECURITY.md` — private-reporting policy + supported versions.
- **Release-artifact content guard** — a step in `extract-subpacks-on-release.yml` that scans the *built* `marketplace/` bundle with gitleaks (filesystem mode) **and** placeholder-diffs any bundled `onboarding.yaml` against `onboarding.example.yaml` (#517's signal), failing the build before publish.
- Full-history secret sweep is already covered by the existing gitleaks job (`fetch-depth: 0`).
- Broadening Semgrep beyond `r/bash` is a **no-op** here — the only JS is a static `site/copy-for-ai.js` snippet; CodeQL `javascript-typescript` already covers it. Documented, not added as noise.

The **GitHub-native settings** — secret scanning + push protection, code-scanning default setup, Dependabot alerts — cannot be expressed in committed files. They are delivered as an operator checklist (the operator declined having the agent flip them via `gh api`, since they are externally-visible admin changes on the public repo).

## Consequences

- CodeQL + Scorecard results appear under Security › Code scanning; the README carries a live Scorecard badge.
- Dependabot keeps pinned GitHub Actions patched.
- Release artifacts are scanned for secrets + filled-in config before publish.
- The ticket (#518) stays partially open until the operator flips the native-settings toggles — called out in the PR.
- New workflows mean more Actions minutes; CodeQL/Scorecard run weekly + on push/PR, which is the conventional cadence.

## Artifacts

- Issue: me2resh/apexyard#518
- Files: `.github/workflows/codeql.yml`, `.github/workflows/scorecard.yml`, `.github/dependabot.yml`, `SECURITY.md`, `.github/workflows/extract-subpacks-on-release.yml` (artifact guard), `README.md` (badge)
- Related: #517 (placeholder-diff reused by the artifact guard), #487 (the existing release-gated scan), #511/AgDR-0063 (semgrep severity)
