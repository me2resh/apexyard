# Contributing to ApexYard

Thanks for wanting to make ApexYard better. It's plain markdown + shell with a thin Claude Code layer on top, so the barrier to contributing is low — and the framework's own hooks will guide you to a well-formed PR.

---

## TL;DR

```bash
# 1. Fork me2resh/apexyard on GitHub, then clone your fork
gh repo clone <you>/apexyard && cd apexyard
git remote add upstream https://github.com/me2resh/apexyard.git

# 2. Branch off dev (NOT main) using the naming convention
git checkout -b feature/GH-<issue>-short-slug upstream/dev

# 3. Make the change. Run the checks the CI gate runs:
bash bin/run-hook-tests.sh          # the hook test suite
# (+ markdownlint / shellcheck if you touched .md / .sh)

# 4. Open a PR targeting dev, with a Summary / Testing / Glossary body
gh pr create --base dev --fill
```

A maintainer + the Code Reviewer agent (Rex) review every PR before merge.

---

## The branch model (important)

ApexYard uses a **release-cut** model:

- **Contributor PRs target `dev`** — never `main`.
- `main` only ever receives **release PRs** from `dev` (tagged with semver). Maintainers cut those via `/release`.

So branch off `upstream/dev` and target `dev` in your PR. A PR opened against `main` will be redirected.

## Conventions the hooks enforce

These aren't style suggestions — `.claude/hooks/` blocks them mechanically, so following them up front saves a round-trip:

| Rule | Shape |
|------|-------|
| **Branch name** | `{type}/{TICKET-ID}-{slug}` — types: `feature, fix, refactor, chore, docs, test, spike, ci, build, perf`. e.g. `fix/GH-42-login-redirect` |
| **PR title** | `type(TICKET): description` — one ticket per title. e.g. `feat(#42): add session refresh` |
| **PR body** | Must include a `## Summary`, `## Testing`, and `## Glossary` section (see the PR template — it's pre-filled). |
| **Commits** | Conventional commits: `type: subject`. No `git add -A` / `.` — stage specific files. No direct pushes to `main`. |
| **Secrets / private config** | No hardcoded secrets; don't commit a filled-in `onboarding.yaml` (it's gitignored). The commit guards will stop you. |

Full detail lives in `.claude/rules/` (`git-conventions.md`, `pr-quality.md`, `pr-workflow.md`).

## Before you open a PR

Run what CI runs, locally:

```bash
bash bin/run-hook-tests.sh        # ~65 hook/behaviour tests — must be green
npx markdownlint-cli2 '**/*.md'   # if you touched markdown
shellcheck .claude/hooks/*.sh     # if you touched hooks
```

If you add or remove a skill / hook / role, update the counts the `site-counts-check` workflow verifies (see `.claude/hooks/tests/test_site_counts.sh` for what's checked).

## Making a technical decision?

If your change introduces a library, a pattern, or an architectural choice, add an **Agent Decision Record** under `docs/agdr/AgDR-NNNN-<slug>.md` (template: `templates/agdr.md`) and reference it in the PR. The AgDR-gate hook will ask for one on architecture-touching diffs.

## Review flow

1. You open the PR against `dev`.
2. **Rex** (the Code Reviewer agent) posts an automated review on the diff.
3. A maintainer reviews and merges. New commits after a review re-trigger it.
4. Your work ships to `main` in the next tagged release.

## Reporting bugs & requesting features

Open a GitHub issue (New issue → **Bug report** or **Feature request**). If you already run apexyard in Claude Code, use the framework-feedback skills instead — they file the issue here, on `me2resh/apexyard`, for you:

- **`/report-apexyard-bug`** — a bug in the framework itself (hook misfire, skill gap, rule bug)
- **`/request-apexyard-feature`** — a new skill / hook / rule / agent / workflow

These are distinct from `/bug` and `/feature`, which file into **your own** managed project, not upstream. For **security** issues, do **not** open a public issue — see [SECURITY.md](SECURITY.md).

## Questions

Open a [Discussion](https://github.com/me2resh/apexyard/discussions) or a question-labelled issue. We're happy to help you land your first PR.

---

*ApexYard is MIT-licensed. By contributing, you agree your contributions are licensed under the same terms.*
