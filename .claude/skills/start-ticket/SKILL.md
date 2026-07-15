---
name: start-ticket
description: Declare an active ticket so the ticket-first hook lets code edits through. Accepts `<N>` or `<owner>/<repo>#<N>`.
disable-model-invocation: false
argument-hint: "<issue-number> | <owner/repo>#<number>"
effort: low
---

# /start-ticket - Declare the Active Ticket

Writes a session marker so the `require-active-ticket.sh` PreToolUse hook permits Edit/Write on code paths. Without it, the hook blocks edits to anything outside `.claude/`, `docs/`, `projects/*/docs/`, and `*.md`.

Marker layout (apexyard#41 + #513):

| Path | When the hook uses it |
|------|----------------------|
| `<ops_root>/.claude/session/tickets/<project>/<safe-branch>` | **Tier 0 (#513).** Edit is under `<ops_root>/workspace/<project>/` AND the file's repo is on a git-worktree branch (or `CLAUDE_WORKTREE_BRANCH` is set). Lets parallel agents on the *same* project hold independent tickets. `safe-branch` = branch with `/`→`__`. |
| `<ops_root>/.claude/session/tickets/<project>` | **Tier 1.** Edit is under `<ops_root>/workspace/<project>/` AND this per-project marker exists (as a FILE). Single-agent default. |
| `<ops_root>/.claude/session/current-ticket` | **Tier 2.** Fallback. Checked if neither above matched. Also the marker for ops-repo framework edits (no `workspace/<name>/` prefix). |

All markers live in the ops fork (gitignored). No more `.claude/session/` inside each managed-project clone. `tickets/<project>` is a FILE (tier 1) or a DIRECTORY holding `<safe-branch>` markers (tier 0) — the hook's `-f` tests keep the two from colliding.

This is the mechanical enforcement of the Pre-Build Gate in `.claude/rules/workflow-gates.md` — "do not start coding until the ticket exists".

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`, `./projects/ideas-backlog.md`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir, ideas_backlog}` keys in `.claude/project-config.json`. Don't hardcode literal `apexyard.projects.yaml` or `projects/` paths in bash blocks — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

## Process

### 1. Parse Arguments

Expected forms:

- `42` — plain number, resolves against the current repo. Read `git remote get-url origin` and extract `<owner>/<repo>`. If there's no origin, stop and ask for a fully-qualified reference.
- `me2resh/flat-mate#128` — fully-qualified reference.
- `apexyard#42` — owner defaults to the current org (parsed from the origin URL).

If `$ARGUMENTS` is empty, stop and ask the user which issue they're starting.

**Cross-repo note:** ApexYard governs a portfolio of repos. If the user is in the ops repo (the apexyard fork) but the ticket lives in a managed project's own repo, they should pass the fully-qualified form so the marker records the correct tracker. Each managed project's tickets live in that project's own GitHub repo — tickets do not cross project boundaries.

### 2. Verify the Issue Exists

Source the tracker library and call `tracker_view`. The library dispatches the right CLI based on `.tracker.kind` in `.claude/project-config.{defaults,}.json` — `gh` (default), `linear`, `jira`, `asana`, `custom`, or `none`. See `.claude/hooks/_lib-tracker.sh` and AgDR-0033.

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-tracker.sh"

issue_json=$(tracker_view "<number>" "<owner/repo>")
state=$(echo "$issue_json" | jq -r '.state // empty')
title=$(echo "$issue_json" | jq -r '.title // empty')
url=$(echo "$issue_json" | jq -r '.url // empty')
```

The lib emits normalised JSON: `{state, title, url, labels}`. Each tracker adapter parses the underlying CLI's JSON into this common shape, so the skill doesn't need to branch per-CLI.

If the lib exits non-zero with empty stdout, the issue does not exist (or the CLI isn't installed / authenticated). Stop and report the error — do not write the marker.

If `state` indicates the ticket is closed (gh: `CLOSED`; linear/jira/asana: `Done` / `Closed` / `Resolved` / `Cancelled`), warn the user and confirm before continuing (sometimes you do want to resume work on a re-opened issue).

**`tracker.kind = none` adopters:** the lib returns no data. Skip the existence check entirely; trust the user's input. Re-verify the shape against `tracker_id_pattern` so obvious typos still block.

### 3. Derive a Branch Suggestion

From the issue title and number, generate: `<type>/<TICKET-ID>-<slug>` where:

- `<type>` guessed from title prefix: `[Feat]` → `feature`, `[Fix]` → `fix`, `[Docs]` → `docs`, `[Chore]` → `chore`, default `feature`
- `<TICKET-ID>` is `GH-<number>` for GitHub Issues, or matches the project's configured `ticket_prefix` from `apexyard.projects.yaml` if set
- `<slug>` = lowercase title, kebab-case, max 40 chars, stopwords trimmed from the edges

Match the convention in `.claude/rules/git-conventions.md`.

### 4. Resolve the target marker

Per apexyard#41, the marker path depends on whether the ticket's tracker repo matches a registered managed project.

#### 4a. Locate the ops root

The ops root is the apexyard fork root, anchored by EITHER the `.apexyard-fork` marker (split-portfolio v2, framework ≥ #242 — `onboarding.yaml` and `apexyard.projects.yaml` live in the sibling portfolio repo, not the fork) OR the legacy v1 pair (`onboarding.yaml` AND `apexyard.projects.yaml` both present in the same directory).

Locate `_lib-ops-root.sh` by walking up from `$PWD` — **not** via `git rev-parse --show-toplevel`. Inside a `workspace/<project>/` clone, `--show-toplevel` resolves to the *project* repo, and managed-project clones carry **no `.claude/hooks/` directory at all** (there is no framework mechanism that installs one there) — sourcing from that path silently fails, `resolve_ops_root` is never defined, and this step dead-ends exactly where split-portfolio v2 operators most often run `/start-ticket`. This is the same sibling walk-up pattern `bug`, `feature`, `task`, `migration`, `spike`, `prototype`, and 8 other ticket skills already use to locate `_lib-tracker.sh` — walk up until a directory containing the lib is found, then source it.

Keep two steps distinct: the walk-up below only finds a directory to **source the lib from** (the nearest fork-shaped root above cwd); `resolve_ops_root` then **decides the real ops root**, pin-first (apexyard#381) — the two can differ, e.g. a session pin can point at a different real ops fork than the nearest fork-shaped directory on the walk (say, cwd is inside an ops-fork-shaped `/tmp` build clone).

```bash
ops_lib="$(r="$PWD"; while [ -n "$r" ] && [ "$r" != / ]; do \
  [ -f "$r/.claude/hooks/_lib-ops-root.sh" ] && { echo "$r/.claude/hooks/_lib-ops-root.sh"; break; }; \
  r="${r%/*}"; done)"
if [ -z "$ops_lib" ]; then
  echo "Not inside an apexyard fork (no .claude/hooks/_lib-ops-root.sh found walking up from $PWD)." >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$ops_lib"
ops_root=$(resolve_ops_root)
```

If `$ops_root` is still empty after sourcing (no pin, and `resolve_ops_root`'s own internal walk also found no anchor above cwd), tell the user and stop. Starting a ticket without the fork doesn't make sense.

#### 4b. Look the tracker repo up in the registry

Given the ticket's `owner/repo` (from step 1), resolve the registry path via `portfolio_registry` (see "Path resolution" above — do NOT hardcode `$ops_root/apexyard.projects.yaml`; in split-portfolio v2 the registry lives in the sibling repo, not the ops fork) and grep it for a project whose `repo:` field matches. `$ops_root` is already resolved and guaranteed to carry a `.claude/hooks/` tree (step 4a only succeeds when it does), so source directly from it — no second walk-up needed. One registry-safe way (uses `yq` when available, falls back to a greppy read):

```bash
source "$ops_root/.claude/hooks/_lib-read-config.sh"
source "$ops_root/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)

if command -v yq >/dev/null 2>&1; then
  project=$(yq eval ".projects[] | select(.repo == \"${OWNER_REPO}\") | .name" "$registry")
else
  # Greppy fallback: find the `name:` whose sibling `repo:` matches.
  # Strips surrounding quotes from both `name:` and `repo:` values so the
  # comparison works whether the registry uses bare scalars
  # (`repo: me2resh/curios-dog`) or quoted scalars (`repo: "me2resh/…"`).
  project=$(awk -v r="$OWNER_REPO" '
    function unquote(s) { gsub(/^["\x27]|["\x27]$/, "", s); return s }
    /^[[:space:]]*- name:/ { name = unquote($3) }
    /^[[:space:]]*repo:/   { if (unquote($2) == r) { print name; exit } }
  ' "$registry")
fi
```

Notes on the fallback:

- Handles both `repo: me2resh/curios-dog` and `repo: "me2resh/curios-dog"` (and single-quoted).
- Assumes `- name:` is the FIRST key in each project entry — that matches the shape in `apexyard.projects.yaml.example` and every entry produced by `/handover`. If your registry reorders keys so `repo:` appears before `name:` in an entry, the lookup misses. Fix: move `name:` to the top, or install `yq` (the preferred path).
- Leading whitespace is tolerated via `^[[:space:]]*` — nested entries under `projects:` parse fine at any indent level, so long as the indent is consistent within the entry.

`$project` is now either a registered project name (e.g. `curios-dog`, `sharppick`) or empty (ticket's tracker repo isn't registered — typically because the ticket is on the ops fork itself, or a repo that's not under management).

#### 4c. Pick the marker path

Three tiers (apexyard#41 + #513). When the ticket maps to a registered project
AND this session is running inside a **git worktree** (parallel agents fanned
out on the same project), write a per-worktree marker so two agents on the same
project don't overwrite each other's ticket (last-writer-wins). Otherwise write
the per-project file (single-agent — unchanged), or the ops fallback.

```bash
if [ -n "$project" ]; then
  # Detect a worktree: prefer the harness-set env var, else check whether the
  # current checkout is a LINKED worktree (not the main working tree). Compare
  # the ABSOLUTE git-dir against the ABSOLUTE common-dir — they differ only in a
  # linked worktree. The absolute forms matter: a plain --git-dir vs
  # --git-common-dir comparison false-positives in the main checkout (one comes
  # back absolute, the other relative). This is the SAME detection the
  # require-active-ticket.sh / require-migration-ticket.sh read side uses.
  wt_branch="${CLAUDE_WORKTREE_BRANCH:-}"
  if [ -z "$wt_branch" ]; then
    gd=$(git rev-parse --absolute-git-dir 2>/dev/null)
    gcd=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    if [ -n "$gd" ] && [ "$gd" != "$gcd" ]; then
      wt_branch=$(git branch --show-current 2>/dev/null)
    fi
  fi

  if [ -n "$wt_branch" ]; then
    safe_branch="${wt_branch//\//__}"          # '/' → '__' filesystem-safe
    marker="$ops_root/.claude/session/tickets/$project/$safe_branch"
  else
    marker="$ops_root/.claude/session/tickets/$project"
  fi
  mkdir -p "$(dirname "$marker")"
else
  marker="$ops_root/.claude/session/current-ticket"
  mkdir -p "$(dirname "$marker")"
fi
```

Note: `tickets/$project` is a FILE in single-agent mode and a DIRECTORY in
worktree mode (it holds the per-branch markers). If you're switching a project
from single-agent to worktree mode and `tickets/$project` already exists as a
file, remove it first (`rm "$ops_root/.claude/session/tickets/$project"`) so the
directory can be created.

### 5. Write the marker

Write these key=value lines to the path resolved in step 4c:

```
repo=<owner/repo>
number=<number>
title=<title>
url=<url>
suggested_branch=<branch>
started_at=<ISO-8601>
```

### 6. Move the board card to "In progress" (opt-in)

After writing the marker, call `board_move_card` so the GitHub Projects board
reflects the ticket being picked up. This is a no-op unless `enable_auto_moves`
is `true` in the fork's `github_projects` config.

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-project-board.sh"
board_move_card "<number>" "in_progress"
```

`board_move_card` degrades gracefully: if the board is not configured, the item
is not on the board, or `gh project` scope is absent, it warns to stderr and
returns 0 — it never blocks the ticket start.

### 7. Confirm to the User

Output a two-line confirmation that names the marker path so the user sees which scope this ticket is active on:

```
Active ticket: <owner/repo>#<number> — <title>
Marker: <marker>  (per-project / ops fallback)
Suggested branch: <branch>
```

Do NOT create the branch automatically. The user may already be on a branch, or may want to confirm the branch name first.

## Notes

- `.claude/session/` (including `.claude/session/tickets/`) is gitignored — markers are per-machine, per-clone of the ops fork.
- Running `/start-ticket` again overwrites the marker at whichever path resolved in step 4c (per-project or fallback). That's how you switch tickets — including jumping between projects (each project's marker lives in its own file, so switching between `curios-dog` and `sharppick` doesn't lose either one's context).
- To clear a specific project's marker: `rm <ops_root>/.claude/session/tickets/<project>`.
- To clear the ops-level fallback: `rm <ops_root>/.claude/session/current-ticket`.
- Exempt paths (`.claude/`, `docs/`, `projects/*/docs/`, any `*.md`) don't need a ticket — the skill is only required before touching source / config / infra.
- **Migration from pre-#41 layout**: if your workflow still has a `.claude/session/current-ticket` inside a managed-project clone (`workspace/<name>/.claude/session/current-ticket`), it's harmless but no longer read by the hook. Delete it or re-run `/start-ticket` to have the new marker written under the ops fork's `.claude/session/tickets/<name>`.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
