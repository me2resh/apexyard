# Site framework-counts drift prevention via CI workflow

> In the context of marketing-site copy that mentions specific framework counts ("53 skills, 29 hooks, 19 roles"), facing recurring drift every time a skill or hook is added or removed, I decided to add a CI workflow that asserts the count claims in `site/*.html` against the real `find`/`ls` counts on every PR, plus a smoke-test invariant under `.apexyard/hooks/tests/`, to achieve fail-fast detection at the moment drift is introduced, accepting one extra job in the CI matrix and the maintenance overhead of keeping the assertion list in sync with new site files.

## Context

`site/index.html`, `site/architecture.html`, and `site/skills.html` quote specific framework counts in marketing copy and structured data — phrases like "53 skills", "29 hooks", "19 roles", "53 slash commands". These counts are right at the moment they're written and wrong shortly after. Every PR that adds or removes a skill (or a hook, or a role) silently drifts the public site one step further from reality.

The drift was caught by the `/seo-audit` finding S13 + `/generative-engine-audit` follow-up: at audit time, site copy claimed 48 skills + 28 hooks while the framework was at 51/29 and climbing. The fix-once pattern doesn't work — within weeks of a manual refresh, the next PR re-introduces the drift. The decision is **how to make the drift self-healing**, not whether to refresh once.

Three viable mechanisms were proposed in the ticket body for `#325`:

1. Release-cut script (extends `.apexyard/skills/release/`)
2. CI workflow (per-PR assertion)
3. SessionStart advisory banner

Each has a different blast radius and feedback latency.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Release-cut script | Catches drift at the moment it would ship; concentrated owner (the release author); reuses an existing skill | Drift accumulates between releases; the release author becomes a bottleneck for fixing other people's miscounts; release skill grows responsibility scope |
| **CI workflow (chosen)** | Fail-loud per-PR; author who introduced drift fixes drift; no human-attention dependency; runs in seconds; trivially reproducible locally via the same `find`/`ls` commands; sibling pattern to existing `pr-title-check.yml` / `review-check.yml` | One more CI job to maintain; adds a new failure shape for PRs that legitimately add a skill but forget to refresh counts (mitigation: the failure message tells the author exactly which lines to update) |
| SessionStart banner | Zero CI cost; visible to every operator | Banner-blindness is real; an operator sees "site/ counts drift" 50 times before fixing it; counts stay wrong while the framework keeps shipping; advisory by definition |

The deciding factor is **feedback latency**. CI runs on every PR; the author sees the failure within minutes of pushing the commit that introduced the drift. Release-cut detection means drift can sit on `dev` for weeks before anyone notices. SessionStart is advisory and noisy. The CI shape closes the feedback loop tightest.

The smoke-test invariant (`.apexyard/hooks/tests/test_site_counts.sh`) is an additive backstop that runs the same assertions as the CI workflow but is invokable locally — operators can run it before pushing, and it's part of the framework's own test suite so it never silently breaks.

## Decision

Chosen: **CI workflow (`.github/workflows/site-counts-check.yml`) plus a smoke-test invariant (`.apexyard/hooks/tests/test_site_counts.sh`)**, because per-PR feedback is the only mechanism that catches drift at the moment it's introduced rather than after it has compounded.

The workflow runs on every PR that touches `.apexyard/skills/**`, `.apexyard/hooks/**`, `roles/**`, or `site/**`:

1. Count `find .apexyard/skills -name SKILL.md | wc -l` → `actual_skills`
2. Count `ls .apexyard/hooks/*.sh | grep -v "_lib\|/tests/" | wc -l` → `actual_hooks`
3. Count `find roles -name "*.md" -not -name "README*" -not -path "*/agdr/*" | wc -l` → `actual_roles`
4. Grep `site/*.html` for patterns like `>(\d+)< skills`, `>(\d+)< hooks`, `>(\d+)< roles`, `(\d+) slash commands`
5. Assert every match equals the corresponding actual count
6. On mismatch: fail the job with a one-line-per-drift report naming file + line + expected + actual

The smoke-test invariant is the same assertion library, invokable as `bash .apexyard/hooks/tests/test_site_counts.sh` for pre-push verification.

## Consequences

- Adding a new skill, hook, or role now requires updating `site/*.html` in the same PR, or the PR fails CI
- The failure message is self-explanatory (file + line + actual count), so the author can fix without consulting docs
- The assertion list is centralised in the workflow — if a new countable claim is added to the site, the workflow needs a new pattern. This is a known maintenance cost.
- The grep patterns are loose (`>\d+ skills`) on purpose to catch HTML, JSON-LD, and plain-text variants; this also means false matches (e.g. an unrelated `47 skills` in copy from another context) would need to be excluded by tightening the pattern or by adding a comment marker. v1 accepts that risk; if it bites, we tighten.
- AI-consumer artifacts (`site/llms.txt`, `site/llms-full.txt`, the markdown alternates from `#332`) are also scanned, so the drift fence covers every public-facing copy of the counts.
- SessionStart banner was considered as a secondary "you should know about this" surface and rejected — banners are advisory and accumulate noise without action. CI is the right shape.

## Artifacts

- `.github/workflows/site-counts-check.yml` — the CI workflow
- `.apexyard/hooks/tests/test_site_counts.sh` — the smoke-test invariant
- `site/index.html`, `site/architecture.html`, `site/skills.html` — count-refresh commit lands alongside this AgDR
- Closes: `me2resh/apexyard#325`
- Related findings: SEO-audit S13, GEO-audit (count claims appear in structured data)
