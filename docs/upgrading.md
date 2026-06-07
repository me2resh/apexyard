# Upgrading Your ApexYard Fork

`/update` is the single entry point for pulling new framework releases into your fork. As of v1.4.0 it walks the **per-version migration chain** — so a fork that's three releases behind runs three migrations in order, not just the latest one.

This doc covers:

- The TL;DR flow
- The version anchor file (`.claude/framework-version`)
- What each migration does (table)
- Common scenarios (multi-hop, missing anchor, skip-migrations, dry-run)
- **When upgrading isn't enough — re-forking and keeping your data**
- Authoring a new migration (framework maintainers only)

For the daily-sync UX, see `.claude/skills/update/SKILL.md`. For the design rationale, see [`docs/agdr/AgDR-0032-update-chain-migrations.md`](agdr/AgDR-0032-update-chain-migrations.md).

---

## TL;DR

```bash
cd ~/ops/apexyard          # your fork
/update                    # interactive sync — walks intermediate-release migrations
```

That's it. On a fork that's three releases behind, `/update`:

1. Fetches `upstream/main`.
2. Detects your current framework version from `.claude/framework-version` (or prompts you once if the file is missing).
3. Builds the migration chain — e.g. v1.0.0 → v1.1.0 → v1.2.0 → v1.3.0.
4. Offers each migration with `[Y / n / show-diff / skip-all]`.
5. Stages all changes; you commit + push on a sync branch.
6. Advances `.claude/framework-version` to the new latest tag.

You're never more than one `/update` away from running every migration the framework needs you to run, even if you've been gone six months.

---

## The version anchor

```
.claude/framework-version    # one line, e.g. "v1.4.0"
```

This file records the framework version your fork was last synced against. `/update` reads it on entry, walks the chain to the new release tag, and writes the new value at the end. Forks created **before v1.4.0** don't have this file yet — `/update` will prompt you once to bootstrap it.

The anchor is intentionally a separate file (not derived from git tags or merged into `project-config.json`) because:

- Adopters rewrite history routinely (squash-merge, rebase, `/update --rebase`). A derived signal would silently drift.
- `project-config.json` mixes configured values with measured values; keeping the anchor separate lets each one have a single owner.
- It's one line, one job — easy to read, easy to write, easy to debug.

If you ever need to override it (rolled back a release, restored an older fork, accidentally deleted it):

```bash
/update --from-version v1.2.0
```

The override applies once. After a successful sync, the anchor is rewritten from the override.

---

## What each migration does

| Migration | Adds / changes | Affects |
|-----------|---------------|---------|
| `v1.2.0-to-v1.3.0.sh` | Moves `onboarding.yaml` and `workspace/<name>/` from the public fork to the private sibling repo (split-portfolio v2). Writes the `.apexyard-fork` anchor. Adds the `portfolio.{onboarding,workspace_dir}` keys to `.claude/project-config.json`. Updates `.gitignore`. | Split-portfolio adopters on the v1 layout. No-op for single-fork adopters. |
| `v1.3.0-to-v1.4.0.sh` | Currently a no-op placeholder. v1.4.0-cycle tickets that need per-adopter migrations (e.g. templates/tickets reorg) will populate the body before release-cut. | TBD when v1.4.0 ships. |

When a future release adds a migration, this table is the source of truth — the release PR template requires a row to be added here.

---

## Common scenarios

### Multi-hop sync (the original motivation)

You forked v1.0.0 six months ago, latest is v1.4.0:

```bash
/update
# → Detects v1.0.0 in the anchor (or prompts you to confirm)
# → Builds chain: v1.0.0→v1.1.0, v1.1.0→v1.2.0, v1.2.0→v1.3.0, v1.3.0→v1.4.0
# → Offers each migration with [Y/n/show-diff/skip-all]
# → Stages all changes
# → Hands you the commit
```

Approve all of them and the chain runs end-to-end. The fork lands on v1.4.0 with every migration applied.

### Missing anchor file (pre-v1.4.0 fork)

If `.claude/framework-version` doesn't exist, `/update` prompts:

```
No .claude/framework-version anchor in this fork.
Which release was this fork last aligned with?

  [a] v1.0.0
  [b] v1.1.0
  [c] v1.2.0
  [d] v1.3.0  ← default (most recent before target)
  [e] skip migrations
  [f] abort

Choose [d]:
```

Pick the version you believe your fork is on. If you're not sure — when did you last run `/update`? Check `git log --grep='sync.*upstream' --oneline` for the date and match to a release tag.

If you genuinely don't know, picking `[e] skip migrations` advances the anchor without running any chain steps. That's safe — but you can replay any individual migration later with `bash .claude/migrations/<pair>.sh`.

### Skip migrations (files-only sync)

```bash
/update --skip-migrations
```

Syncs the framework files (merge / rebase as usual) but does NOT run any per-version migration. The anchor file IS still advanced to the new tag, so subsequent runs don't re-offer the same migrations.

Why this exists:

- You want to inspect the new files before running migrations.
- You're in a low-trust environment and don't want shell scripts running.
- You're cherry-picking specific framework files and don't want the wider migration footprint.

Replay later:

```bash
bash .claude/migrations/v1.2.0-to-v1.3.0.sh
```

Each migration is idempotent — safe to re-run any number of times.

### Dry-run (preview)

```bash
/update --dry-run
```

Prints the commit delta AND the planned migration chain. No fetch-after-preview, no migrations executed, no anchor advanced. Use to scope the work before committing.

### One step exits 1 (conflict)

If a migration script reports a conflict (exit code 1), the chain pauses. The anchor is NOT advanced. Resolve the conflict manually — usually by hand-editing the file the migration wanted to move/edit — then re-run `/update`. The chain picks up where it left off.

### `--from-dev` (pre-release sync)

When you use `--from-dev` to pull from `upstream/dev`, the migration chain is automatically skipped — pre-release work has no release tag to anchor against. The anchor file is NOT advanced; `--from-dev` is the only path that leaves the anchor untouched.

---

## When upgrading isn't enough — re-fork & keep your data

`/update` handles the common case. Two situations need more than a sync — and
both hinge on one mental model.

### Your data vs. the framework

Everything in a fork falls into one of two buckets:

| Bucket | Examples | Lifecycle |
|--------|----------|-----------|
| **The framework** | `.claude/hooks/`, `.claude/skills/`, `.claude/agents/`, `.claude/rules/`, `workflows/`, `templates/`, `docs/` | Owned by upstream — replaced on every upgrade |
| **Your portfolio data** | `apexyard.projects.yaml` (registry), `onboarding.yaml`, `projects/<name>/`, `workspace/<name>/`, `handbooks/`, custom skills | Owned by you — must survive every upgrade |

Upgrades replace the **framework** bucket. The whole game is keeping your **data**
bucket out of the line of fire. Split-portfolio mode does that structurally; the
manual approach does it by copy-out / copy-back.

### Re-fork (when the fork has drifted too far)

Sometimes a fork has been edited so heavily — or branched from such an old base —
that merging upstream is more painful than starting fresh. Symptoms:

- `/update` (or `/update --dry-run`) reports conflicts across most of `.claude/`.
- A PR opened from your fork against upstream shows a diff touching the *entire*
  framework tree.

Upgrade vs. re-fork — quick decision:

| Situation | Do this |
|-----------|---------|
| `/update --dry-run` shows a clean or small merge | **Upgrade** (`/update`) |
| A few conflicts in files you knowingly customised | **Upgrade**, resolve conflicts |
| Conflicts across most of `.claude/` | **Re-fork** |
| You don't know what diverged | **Re-fork** (cleanest reset) |

To re-fork safely:

1. **Get your data out of the line of fire first** (see below).
2. Re-fork `me2resh/apexyard` (a fresh fork, or a fresh clone you re-point
   `origin` at).
3. Re-attach your data (split-portfolio: nothing to do — it lives elsewhere;
   manual: copy your data bucket back in).
4. Re-add the `upstream` remote so future `/update`s work:

   ```bash
   git remote add upstream https://github.com/me2resh/apexyard.git
   ```

### Preserving your data

**Best — split-portfolio mode (makes the fork disposable).** Your portfolio data
lives in a **separate private repo**; the framework fork only holds framework code
plus a `.claude/project-config.json` pointing at the sibling. Once split,
upgrading or re-forking the framework **never touches your data**.

```bash
/split-portfolio            # gated, destructive migration — every step confirms
/split-portfolio --dry-run  # walk the steps without executing
/split-portfolio --verify   # read-only state report
```

**Fallback — manual copy-out / copy-back** around a re-fork:

1. Copy your **data bucket** out of the old fork: `apexyard.projects.yaml`,
   `onboarding.yaml`, `projects/`, `workspace/` (if used), `handbooks/`, custom
   skills.
2. Re-fork `me2resh/apexyard`.
3. Copy the data bucket back into the fresh fork.
4. Re-add the `upstream` remote (above).

This works but repeats on every re-fork. Split-portfolio is the one-time
investment that removes the chore.

### A common trap: project tickets filed against the framework repo

On older forks (before per-project tracker routing landed), `/feature`, `/bug`,
and `/task` could file tickets against the **framework** repo instead of your
own project's repo. If your project's tickets/PRs show up on `me2resh/apexyard`,
your fork is out of date — **upgrade (`/update`)**, which fixes the routing and
enables leak-protection so private project names don't leak into public trackers.

---

## Authoring a new migration (framework maintainers)

When cutting a release that introduces a per-adopter change:

1. Create `.claude/migrations/v<current>-to-v<next>.sh`. Use `v1.2.0-to-v1.3.0.sh` as a template — note the env knobs (`APEXYARD_MIGRATION_PROMPT`, `APEXYARD_MIGRATION_QUIET`), the four-exit-code contract, and the staging-not-committing stance.
2. `chmod +x` the script.
3. Add a row to the "What each migration does" table above.
4. Update `CHANGELOG.md` with a one-line callout that the migration exists.

**Every release ships a migration script — real OR no-op placeholder.** The chain walker refuses to traverse a gap; skipping the placeholder means a v<N-1> adopter can't reach v<N+1>. The `/release` skill PR template has a checkbox for this.

The contract a migration script honours:

| Requirement | Why |
|-------------|-----|
| Idempotent | Re-running is safe. Guard each mutation on "source present AND target absent". |
| Stages changes, doesn't commit | Operator owns the commit message. |
| Per-file-class confirmable when touching multiple file types | Matches `/split-portfolio` UX; lets adopters opt in/out at a fine grain. |
| Exit codes 0/1/2 | The chain walker reads them to decide continue / pause / abort. |
| Quiet mode via `APEXYARD_MIGRATION_QUIET=1` | Lets tests suppress chatter. |

What does NOT belong in a migration script:

- Anything needing human judgement on the diff (use the `_lib-detect-deprecated-config.sh` y/n/s offer instead).
- Anything crossing repo boundaries beyond the sibling private repo.
- Anything irreversible without an explicit operator-confirmation prompt.

---

## Related

- `.claude/skills/update/SKILL.md` — the `/update` skill spec.
- `.claude/hooks/_lib-migration-chain.sh` — the chain-walking helper library.
- `.claude/migrations/README.md` — convention reference for migration scripts.
- `docs/agdr/AgDR-0032-update-chain-migrations.md` — design rationale.
- `docs/agdr/AgDR-0007-release-cut-branch-model.md` — the release-cut model the chain depends on.
- `docs/multi-project.md` § "Upgrades — pulling from upstream" — the wider sync flow.
