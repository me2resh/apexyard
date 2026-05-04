---
name: split-portfolio
description: Migrate a single-fork apexyard adopter to split-portfolio mode (public framework + private sibling portfolio). Automates the destructive recovery flow — force-push history rewrite, GitHub Issue/PR body redaction, private repo creation, and config-block writing — with explicit operator-confirmation gates at every destructive step. ONLY invoke when the adopter has actively asked to migrate, OR is using `--verify` to inspect state without destructive ops. Refuses on a paid GitHub plan, a clean working tree, or an already-migrated fork.
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
argument-hint: "[--verify | --dry-run]"
effort: high
---

# /split-portfolio — Migrate to split-portfolio mode

Automates the recovery flow for ApexYard adopters who hit the **trip-wire** documented in `docs/multi-project.md` — pushed private project names to a public fork, then realized GitHub Free disallows fork-visibility changes.

The skill is destructive: it force-pushes the public fork's main branch after rewriting history, redacts GitHub Issue / PR body content, and creates a new private repo. Every destructive step has an explicit operator-confirmation gate. None of those gates are skip-able.

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`, `./projects/ideas-backlog.md`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir, ideas_backlog}` keys in `.claude/project-config.json`. Don't hardcode literal `apexyard.projects.yaml` or `projects/` paths in bash blocks — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

## Modes

| Invocation | Effect |
|------------|--------|
| `/split-portfolio` | Full migration — runs all 10 steps with operator-confirmation gates |
| `/split-portfolio --verify` | Read-only state report (registry/config drift, backup branch age, validate). No destructive ops. |
| `/split-portfolio --dry-run` | Walk through every step printing the commands that would run, but execute none. |

## Pre-flight refusals (before doing anything)

The skill refuses with a clear redirect when:

| Condition | Refusal message |
|-----------|----------------|
| Target fork's visibility is `PRIVATE` (`gh repo view --json visibility` returns `PRIVATE`) | "This fork is already private — split-portfolio mode is for public forks. If you meant something else, run `/split-portfolio --verify` for the state report." |
| Adopter is on a paid GitHub plan (Pro / Team / Enterprise) | "Paid GitHub plans support changing a fork's visibility in-place — that's a simpler path than this skill's destructive flow. Visit your fork's GitHub settings → Danger Zone → Change Visibility, and you're done. If you specifically want the public-framework + private-portfolio split anyway, re-run this skill with `--force` (not implemented in v1; ask first)." |
| Working tree has uncommitted changes | "Refusing to migrate with a dirty working tree — commit or stash first. Force-push + history rewrite would lose your in-flight work." |
| Already migrated (config-block mode OR symlink mode detected) | "Looks like this fork is already in split-portfolio mode (detected via config block / symlink). Run `/split-portfolio --verify` for the state report, or `/split-portfolio --dry-run` to see what a re-run would do." |

Refusal at any of these gates is silent on every other check — show only the relevant message.

## Process

### 0. Mark this session as bootstrap (REQUIRED for non-`--verify` modes)

`/split-portfolio` rewrites fork-root files (`.gitignore`, `.claude/project-config.json`, registry symlinks) which the `require-active-ticket.sh` PreToolUse hook would block — and the whole point of the migration is that the fork's existing private project names should no longer be referenced, so even filing a placeholder ticket is awkward. Write a marker so the hook exempts this skill (it's on the default `bootstrap_skills` list in `.claude/project-config.defaults.json`):

```bash
# Only on full / --dry-run modes. --verify is read-only and doesn't need the marker.
mkdir -p .claude/session && echo "split-portfolio" > .claude/session/active-bootstrap
```

Clear the marker at the end of the migration (or on a confirmed-abort). If the skill is interrupted mid-flow, the SessionStart hook `clear-bootstrap-marker.sh` clears it at the start of the next session. See AgDR-0011 + me2resh/apexyard#150.

### --verify mode (no destructive ops, safe to run anytime)

1. Source `_lib-read-config.sh` and `_lib-portfolio-paths.sh`.
2. Run `portfolio_validate`. Capture result.
3. Detect mode: config-block (presence of `portfolio:` block in `.claude/project-config.json`) vs symlink (`test -L apexyard.projects.yaml`) vs single-fork (neither).
4. List `backup-pre-rewrite` branch age, if present (`gh api repos/<fork>/branches/backup-pre-rewrite --jq .commit.commit.author.date`).
5. Detect drift (config-block AND symlink both present pointing at different things — broken state).
6. Print a structured report:

```
/split-portfolio --verify

Mode:                config-block (recommended) | symlink (legacy) | single-fork | mixed (DRIFT)
Registry resolves:   /abs/path/apexyard.projects.yaml
                     [exists | MISSING]
Projects dir:        /abs/path/projects
                     [exists | MISSING]
Ideas backlog:       /abs/path/projects/ideas-backlog.md
                     [exists | creatable | MISSING parent]
Validate:            OK | broken: <reason>

backup-pre-rewrite:  age=12d (consider deleting after 7-day soak)
                     OR not present

Drift:               none | YES — config and symlink point at different paths
```

Exit 0 if valid + no drift; exit 1 if validate fails or drift detected.

### Full migration (10 steps)

#### Step 1 — Pre-flight checklist

After the pre-flight refusals above pass, show the operator a checklist and ask for explicit confirmation:

```
About to migrate this fork to split-portfolio mode. Destructive operations will follow.

Changes you will see:
  - A new private repo created at <suggested-name>
  - This fork's git history rewritten to remove apexyard.projects.yaml + projects/
  - This fork's main branch force-pushed
  - GitHub Issue / PR bodies on this fork that named registered projects redacted
  - .claude/project-config.json updated with a `portfolio:` block pointing at the sibling

Reversibility:
  - A backup-pre-rewrite branch is pushed before any rewrite (recoverable for 7 days)
  - Force-push is irreversible at the GitHub level for anyone who cloned in the last hour
  - GitHub Issue/PR edit history (timeline API) survives — full purge requires repo deletion

Have you read docs/multi-project.md § "Migrating from single-fork to split-portfolio"? (y/n)
Are you running this during a low-traffic window so other clones won't be surprised? (y/n)

Continue? (yes / cancel)
```

#### Step 2 — Snapshot extraction

Copy the registry + `projects/` to a tmpdir. This is the data that will be pushed to the new private repo. Run BEFORE any destructive operation so a failure here doesn't cost the operator anything.

```bash
SNAPSHOT=$(mktemp -d)
cp "$(portfolio_registry)" "$SNAPSHOT/"
cp -r "$(portfolio_projects_dir)" "$SNAPSHOT/"
echo "Snapshot at: $SNAPSHOT"
```

Confirm to operator: snapshot exists, file count matches expectation. If not, refuse.

#### Step 3 — Create the private repo

The suggested default name is **`<account>/<fork>-portfolio`** — keeps the relationship to the public fork explicit on GitHub. Compute `<fork>` from the public-fork repo name (`gh repo view --json name -q .name`) so the suggestion is correct even when the fork was renamed (e.g. fork = `cos` → suggested portfolio = `cos-portfolio`).

```
Suggested name: <account>/<fork>-portfolio    (e.g. <account>/apexyard-portfolio)
Override? (Enter to accept default, or type a different name)
> _

Creating private repo... gh repo create <name> --private --description "ApexYard private portfolio: registry + per-project handover docs"
Continue? (yes / cancel)
```

If the repo name already exists in the operator's account, refuse and ask for a different name.

#### Step 4 — Push the snapshot to the private repo

```bash
cd "$SNAPSHOT"
git init -q
git checkout -b main
git add apexyard.projects.yaml projects/
git commit -q -m "chore: import portfolio snapshot from public fork"
gh repo set-default <name>
git remote add origin "https://github.com/<account>/<name>.git"
git push -u origin main
```

Print: `✓ Private portfolio repo populated at <name>`.

#### Step 5 — Backup branch on the public fork

Before any rewrite. Recoverable safety net.

```bash
cd /path/to/public/fork
git fetch origin
git push origin "origin/main:refs/heads/backup-pre-rewrite"
```

Print: `✓ backup-pre-rewrite pushed (will be auto-cleaned after 7-day soak in step 10)`.

#### Step 6 — History rewrite

Detect: was the registry + `projects/` added in a single commit? If yes, the cheap path:

```bash
PARENT=$(git log --format=%H --all -- apexyard.projects.yaml | tail -n 1)^
git reset --hard "$PARENT"
```

Otherwise, use `git filter-repo` (recommends installing if missing):

```bash
if ! command -v git-filter-repo >/dev/null 2>&1; then
  echo "git-filter-repo not installed. Install it (e.g. brew install git-filter-repo) and re-run."
  exit 1
fi
git filter-repo --path apexyard.projects.yaml --path projects --invert-paths
```

After rewrite, show the operator the diff: how many commits changed, sample of removed paths.

#### Step 7 — Force-push to fork's main

**This is the irreversible step.** Single explicit confirmation gate:

```
About to force-push the rewritten main to <account>/<fork>.

This is irreversible at GitHub for anyone who cloned in the last hour.
Continue? (yes / cancel)
```

```bash
git push --force-with-lease origin main
```

If the lease check fails (someone else pushed since the operator last fetched), refuse — operator should investigate before re-running.

#### Step 8 — Redact GitHub Issue / PR bodies

For each registered project name, search the public fork's issues + PRs for bodies that mention them:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
REGISTRY=$(portfolio_registry)

# Read names from snapshot (still has the registry)
names=$(yq eval '.projects[].name' "$SNAPSHOT/apexyard.projects.yaml")

for name in $names; do
  # Issues + PRs mentioning the name in body
  matching=$(gh issue list --repo <fork> --search "$name in:body" --json number,title,body --limit 100)
  matching_prs=$(gh pr list --repo <fork> --search "$name in:body" --json number,title,body --limit 100)

  for item in $matching $matching_prs; do
    # Show diff to operator: what was named, what redaction we'll apply
    # Confirm per item before writing
    # gh issue edit <n> --repo <fork> --body-file <redacted>
    # OR gh pr edit <n> --repo <fork> --body-file <redacted>
  done
done
```

After the loop, **explicitly print the timeline-API caveat**:

```
⚠ Edit history survives.

GitHub's timeline API still has the original body content. Full purge of
the original text requires deleting and recreating the repo (which loses
issue numbers + PR numbers + history). The redaction above hides the
content from casual viewers, search engines, and the GitHub UI default
view — that's it.
```

#### Step 9 — Write the `portfolio:` config block + .gitignore

```bash
# .gitignore additions in the public fork
cat >> .gitignore <<'EOF'

# Portfolio data lives in a separate private repo (split-portfolio mode).
# See docs/multi-project.md.
apexyard.projects.yaml
projects
EOF

# Untrack any framework projects/README.md from upstream (it'll be replaced by the private sibling's content)
git rm --cached -r projects 2>/dev/null || true

# Write portfolio: block to project-config
PRIVATE_REPO_REL="../<private-repo-name>"
cat > .claude/project-config.json <<JSON
{
  "portfolio": {
    "registry": "$PRIVATE_REPO_REL/apexyard.projects.yaml",
    "projects_dir": "$PRIVATE_REPO_REL/projects",
    "ideas_backlog": "$PRIVATE_REPO_REL/projects/ideas-backlog.md"
  }
}
JSON

git add .gitignore .claude/project-config.json
git commit -m "chore: configure split-portfolio mode (#143 / #145)"
```

If `.claude/project-config.json` already has a non-portfolio block, **merge** rather than overwrite — preserve existing keys.

If it has a `portfolio:` block already, refuse and ask the operator to manually reconcile.

#### Step 10 — Verify + cleanup

Verify migration:

```bash
source .claude/hooks/_lib-read-config.sh
source .claude/hooks/_lib-portfolio-paths.sh
if ! portfolio_validate; then
  echo "Migration produced a broken config — see error above. NOT proceeding to cleanup."
  exit 1
fi

# Confirm public fork's main no longer has the registry
git ls-tree --name-only HEAD apexyard.projects.yaml && {
  echo "ERROR: registry still in main. Force-push didn't take effect?"
  exit 1
}
```

Cleanup (opt-in, default-no):

```
backup-pre-rewrite branch holds your pre-migration history. Default: keep for 7-day soak.

Delete it now? (y/N)
```

If `y`: `gh api -X DELETE repos/<fork>/git/refs/heads/backup-pre-rewrite`.

Final report:

```
✓ Split-portfolio migration complete.

  Public fork:        <account>/<fork>      (registry removed, history rewritten)
  Private portfolio:  <account>/<private>   (registry + projects/ pushed)
  Config block:       .claude/project-config.json (portfolio.* set)
  Backup branch:      backup-pre-rewrite (kept for 7 days, run /split-portfolio --verify to monitor)

  Bodies redacted:    <N> issues, <M> PRs (timeline API survives — see warning above)

  Next step:          commit + push the new .gitignore + project-config.json:
                        git push origin main
```

## Idempotency

Re-running the skill on a partially-migrated fork picks up where it left off:

| Detected state | Action |
|----------------|--------|
| Private repo already exists, is empty | Skip step 3, do step 4 |
| Private repo already exists, has the snapshot | Skip steps 3 + 4 |
| `backup-pre-rewrite` branch exists | Skip step 5 |
| HEAD on main has no registry/projects | Skip steps 6 + 7 |
| `.claude/project-config.json` already has portfolio block matching new layout | Skip step 9 |
| All complete | Run --verify only and exit 0 |

The `--dry-run` flag walks through every step printing the commands but executes none. Useful for the operator to preview the destructive ops before running real.

## Cleanup (REQUIRED before exit)

```bash
rm -f .claude/session/active-bootstrap
```

Run on every exit path (successful migration, confirmed abort, refusal-in-flight). If the skill is interrupted before this step, `clear-bootstrap-marker.sh` clears the stale marker on the next session.

## Rules

1. **No destructive op without an explicit operator-typed `yes`.** Single-character `y` is acceptable; ambiguous `ok` / `sure` is not.
2. **No `--force`-by-default.** Force-push uses `--force-with-lease`; if the lease fails, refuse.
3. **Never delete `backup-pre-rewrite` automatically.** Even at step 10, deletion is opt-in. Default: keep for 7 days.
4. **Surface the timeline-API caveat verbatim** at step 8. Adopters must see it. No abstraction.
5. **Refuse on already-migrated.** Detection covers config-block mode, symlink mode, and mixed-drift. Re-run with `--verify` is fine; full re-run requires manual cleanup first.
6. **Resolve paths via the helper.** Step 8 + step 9 + step 10 all use `portfolio_registry`, `portfolio_projects_dir`, `portfolio_validate` from `_lib-portfolio-paths.sh`. No literal `apexyard.projects.yaml` references in bash blocks (the snapshot's path is passed as a separate variable).
