# Onboarding config: example-file pattern + commit-time guard

> In the context of adopters editing a tracked `onboarding.yaml` in a publicly-forked framework, facing real company config (name, internal URLs, tracker instance, named individuals) landing in public git history and upstream PR refs by default, I decided to adopt the `.env.example` convention (tracked `onboarding.example.yaml` + gitignored `onboarding.yaml`) plus a commit-time placeholder-diff guard, to achieve a safe-by-default config path with a mechanical backstop, accepting that single-fork clones must each run `/setup` once and that pre-existing committed history still needs a separate scrub.

## Context

`onboarding.yaml` was a **tracked** file that adopters filled with real values and committed. Because the framework is forked publicly and contributors open PRs upstream, private config reached public history by default. Split-portfolio v2 (#242) already solved this for v2 adopters (config moves to a private sibling repo), and `.gitignore` already kept a never-committed completion flag — but **single-fork mode (the default) still committed the config**, and nothing caught a filled-in file before it left the machine. This is the #517 gap, addressed in two layers.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Example-file + gitignore + commit guard (chosen) | Safe path is the default; mirrors the universally-understood `.env.example`/`.env` pattern; mechanical backstop catches force-adds; consistent with what v2 already does | Single-fork clones lose "config travels with the repo" — each clone runs `/setup` once |
| Gitignore only (no guard) | One-line change | A `git add -f` or a pre-existing tracked copy silently re-leaks; no defense-in-depth |
| Encrypt committed config (git-crypt / SOPS) | Config can stay committed | Key distribution + tooling burden; overkill for non-secret-but-private config; poor DX for a bootstrap file |
| Rely on split-portfolio v2 only | Already exists | Doesn't help the DEFAULT single-fork adopter — the majority |

## Decision

Chosen: **example-file + gitignore (Layer 1) + a commit-time placeholder-diff guard (Layer 2)**.

- **Layer 1:** ship `onboarding.example.yaml` (placeholders, tracked); gitignore `onboarding.yaml`; `git rm --cached onboarding.yaml`; `/setup` copies example→real and never stages the real file; `onboarding-check.sh` detects configured state from the local real file (or, in v2, the committed private copy) rather than a committed public file.
- **Layer 2:** `block-onboarding-in-git.sh` (PreToolUse on `git commit`) blocks a staged `onboarding.yaml` whose content differs from the example placeholders (the placeholder-diff signal), with an env-var (`APEXYARD_ALLOW_ONBOARDING_COMMIT=1`) and in-message (`<!-- onboarding: allow -->`) escape hatch. Sibling to `check-secrets.sh` and `block-private-refs-in-public-repos.sh`.

The placeholder-diff (compare staged config to the shipped `*.example`) gives a low-false-positive signal that the template was filled with real values — the same idea #518's release-artifact guard reuses on shipped output.

## Consequences

- Default single-fork forks no longer publish private config; the safe path is the default.
- Each fresh single-fork clone runs `/setup` once (copies the example, fills it in locally). v2 adopters are unaffected (private committed config carries across clones).
- A new commit-time gate exists; covered by `.claude/hooks/tests/test_block_onboarding_in_git.sh` (filled-in blocked, placeholder allowed, both escape hatches honored, non-config unaffected, non-commit ignored).
- **Already-committed history** still contains prior real values until a separate full-history scrub (tracked under the security-hardening work, #518). This PR untracks going forward; it does not rewrite history.

## Artifacts

- Issue: me2resh/apexyard#517
- Files: `onboarding.example.yaml`, `.gitignore`, `.claude/hooks/block-onboarding-in-git.sh`, `.claude/hooks/tests/test_block_onboarding_in_git.sh`, `.claude/hooks/onboarding-check.sh`, `.claude/settings.json`, `.claude/skills/setup/SKILL.md`, `docs/multi-project.md`, `.claude/hooks/README.md`
- Related: #518 (release-artifact guard reuses the placeholder-diff), #242 (split-portfolio v2)
