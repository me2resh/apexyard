---
id: AgDR-0076
timestamp: 2026-06-21T00:00:00Z
agent: claude
model: claude-sonnet-4-6
trigger: user-prompt
status: executed
---

# Release automation — one-command bump + changelog + release PR + auto-tag

> In the context of the apexyard release-cut model (dev→main + semver tag), facing the gap between the well-documented `/release` skill and the mechanical steps still done by hand (changelog draft, CHANGELOG.md update, release-branch push, PR open, and post-merge tagging), I decided to automate the full preparation cycle — version bump, CHANGELOG generation from merged-PR history, PR creation — plus add a GH Actions workflow that tags the merge commit automatically when the release PR squash-merges to main, to achieve a single `/release` invocation that drives the operator from "nothing" to "PR open, ready for Rex + CEO", accepting that the PR body previews in Claude's output and the operator gets one confirmation moment before any file is written (via `--dry-run`).

## Context

The `/release` skill exists (`.claude/skills/release/SKILL.md`) and documents the process well, but as of v3.2.0 several mechanical steps remained manual:

1. **Changelog text** — operator had to draft `CHANGELOG.md` additions by hand, consulting `git log` themselves.
2. **CHANGELOG.md file update** — operator manually prepended the new section.
3. **Release branch creation + push** — operator ran `git checkout -b release/vX.Y.Z` + `git push`.
4. **Release PR open** — operator ran a `gh pr create` / `gh api` command with the drafted body.
5. **Post-merge tagging** — after squash-merge, operator had to fetch, tag `upstream/main`, run the ancestry guard, and push the tag. Easy to forget or mis-place (the v2.3.0 tag was placed on the release-branch HEAD rather than the squash commit).

The skill's SKILL.md described what to do but left the operator to execute every step. The result was that releases were slower than necessary and the post-merge tag step was documented with a warning about a known past mistake.

Additionally: apexyard-premium will cut its own releases on a version *matrix* (one version per component), where the changelog-from-commits approach is the same but the version source differs (a `versions.yaml` rather than the single apexyard `CHANGELOG.md` + the version tag). This AgDR captures the shared design so the premium adaptation inherits the right primitives.

**Note on site/ removal:** the marketing site (`site/`) was removed from the framework repo in #663 (moved to `me2resh/apexyard-site`). This implementation does NOT bump any site version strings — the site is now independently deployed. The atlas fork's earlier draft of this work included a Step 3.5 for `site/index.html` bumping; that step is intentionally omitted here since the file no longer exists in this repo.

**Note on auto-tag creating the GitHub Release directly (apexyard-premium#326 lesson):** tags pushed via `GITHUB_TOKEN` do not trigger a separate `on: push: tags:` release workflow in the same repository — GitHub suppresses the secondary event to prevent workflow loops. The `auto-tag-on-release-pr-merge.yml` workflow therefore creates the GitHub Release entry itself (in the same job, after tagging), rather than relying on a separate tag-triggered workflow. This pattern was confirmed working in apexyard-premium#326.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. Status quo — SKILL.md is guidance, operator executes** | No new code | Error-prone; releases slow; post-merge tag still mis-placeable; repeated manual effort |
| **B. Fully autonomous release — skill runs every step including merge + tag** | Maximum automation | Defeats the CEO approval gate; auto-merges are explicitly banned by framework rules |
| **C. Automate prep + PR creation; auto-tag + create Release via GH Actions after merge (CHOSEN)** | One command from "nothing" to "PR open"; keeps CEO approval as the sole human gate; auto-tag fires AFTER merge so it always lands on the squash commit (never the branch HEAD); workflow creates the GitHub Release in the same job (not via a secondary tag-triggered workflow, per apexyard-premium#326 lesson); reusable GH Actions workflow in `golden-paths/pipelines/` for adopters who want the same pattern on managed projects | Adds a GH Actions workflow; requires `contents: write` permission (already granted by default `GITHUB_TOKEN` on all GH repos) |
| **D. Automate prep; leave tagging entirely manual** | No GH Actions dependency | Keeps the mis-place risk; the v2.3.0 incident can repeat |

## Decision

Chosen: **Option C** — automate the mechanical prep (changelog generation + CHANGELOG.md update + release-branch push + PR creation) in the `/release` skill, and add a GH Actions workflow that auto-tags the squash commit and creates a GitHub Release when the release PR merges to `main`. Keep the CEO approval gate as the only required human step.

### Version bump

The `/release` skill already specifies the conventional-commit bump algorithm. A new helper script (`bin/release-changelog.sh`) encapsulates:

- `git log <prev-tag>..upstream/dev --pretty=format:'%h %s'` to extract commits
- Grouping by conventional-commit type (feat / fix / refactor+docs+chore / breaking)
- PR-number extraction from merge-commit subjects (format: `Merge pull request #N`) or from commit subjects that include `(#N)`
- Emitting the CHANGELOG section in the format the skill already documents

The helper is a separate shell script (not inline skill prose) so it is:

1. **Testable** — unit tests under `.claude/hooks/tests/`
2. **Reusable** — the premium adaptation can call the same script with different version sources

### `--dry-run` mode

`/release --dry-run` (or `--dry-run vX.Y.Z`): runs all steps up to and including the CHANGELOG draft and shows what would be written, but does not:

- Write `CHANGELOG.md`
- Create the release branch
- Push the branch
- Open the PR

Output ends with: `Dry run — no changes made. Remove --dry-run to execute.`

### Auto-tag on release PR merge

A new GH Actions workflow (`.github/workflows/auto-tag-on-release-pr-merge.yml` for the framework fork, plus `golden-paths/pipelines/auto-tag-on-release-pr-merge.yml` as a reusable template) triggers on `pull_request` → `closed` + `merged` where the PR's `head.ref` matches `release/v*`. It:

1. Extracts the version from the branch name (`release/v1.2.3` → `v1.2.3`).
2. Uses `github.sha` (the merge commit SHA already available in the event context on `main`).
3. Runs the ancestry guard: `git merge-base --is-ancestor <sha> main`.
4. Creates an annotated tag and pushes it with `git push origin --tags` — NOT `git push origin <tag>`, to avoid the branch-name validator hook misfiring on tag-push commands (per apexyard memory note on `avoid-apexyard-branch-hook-on-tag-push`).
5. Creates a GitHub Release entry using the CHANGELOG section extracted from the PR body — in the **same job**, because a tag pushed via GITHUB_TOKEN does not trigger a secondary release workflow (apexyard-premium#326).

The workflow requires no new secrets — only the default `GITHUB_TOKEN` with `contents: write` permission.

### Version-source difference: framework vs premium

| Repo | Version source | Changelog source |
|------|---------------|-----------------|
| `me2resh/apexyard` (this AgDR) | Git tag; `CHANGELOG.md` heading reflects current version | `git log <prev-tag>..dev` merged-PR history |
| `me2resh/apexyard-premium` (future) | `versions.yaml` — a matrix of component versions | Per-component `git log` filtered by path; each component gets its own CHANGELOG section |

The `bin/release-changelog.sh` helper is designed around the apexyard single-version case. The premium adaptation will use a separate helper that calls the same `git log` + grouping primitives but loops over components. The GH Actions workflow shape is identical; only the version-extraction line changes (reads `versions.yaml` instead of the branch name).

## Consequences

**Added:**

- `bin/release-changelog.sh` — helper script that generates a CHANGELOG entry from `git log` between two refs; accepts `PREV_TAG`, `HEAD_REF`, `VERSION`, `DATE` env vars; emits markdown to stdout; non-destructive (never writes files).
- `.claude/hooks/tests/test_release_changelog.sh` — unit tests for the helper covering: empty log (patch with 0 commits), feat-only (minor), breaking (major), mixed groups, PR-number extraction.
- `.github/workflows/auto-tag-on-release-pr-merge.yml` — the fork's own auto-tag + GitHub Release workflow for apexyard releases.
- `golden-paths/pipelines/auto-tag-on-release-pr-merge.yml` — reusable template adopters can copy into managed projects that also use the release-cut model.
- Enhanced `.claude/skills/release/SKILL.md` — step-by-step skill prose updated to reflect fully-automated prep; `--dry-run` flag documented; step 6 rewritten to reference the auto-tag workflow rather than manual commands; step 9 updated to reference `/release-sync`.
- Updated `docs/release-process.md` — references the new helper script and auto-tag workflow; manual commands preserved as fallback.

**Unchanged:**

- CEO approval gate — the release PR still requires Rex + `/approve-merge`. Automation ends at "PR open."
- `/release-sync` — unchanged; step 9 of `/release` continues to reference it after the tag is pushed.
- Branch protection rules on `main` — the auto-tag workflow uses the default `GITHUB_TOKEN`; no new PAT or elevated permissions required.
- Managed project semantics — this skill and all its artifacts are explicitly framework-only.

**Non-consequences (explicitly):**

- No `site/index.html` bumping — the marketing site was removed from this repo in #663.
- No hotfix or multi-branch automation.
- No auto-merge of the release PR.
- No version-matrix support in this iteration — that is the premium adaptation.

## Artifacts

- Implementing ticket: `me2resh/apexyard#674`
- Helper script: `bin/release-changelog.sh`
- Tests: `.claude/hooks/tests/test_release_changelog.sh`
- Auto-tag workflow (fork): `.github/workflows/auto-tag-on-release-pr-merge.yml`
- Auto-tag workflow (golden path): `golden-paths/pipelines/auto-tag-on-release-pr-merge.yml`
- Updated skill: `.claude/skills/release/SKILL.md`
- Updated docs: `docs/release-process.md`
