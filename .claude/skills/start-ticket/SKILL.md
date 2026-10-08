---
name: start-ticket
description: Declare an active ticket so the ticket-first hook lets code edits through. Accepts `<N>` or `<owner>/<repo>#<N>`.
disable-model-invocation: false
argument-hint: "<issue-number> | <owner/repo>#<number>"
effort: low
---

## Writing rule

When this skill writes a durable artifact, read .claude/rules/writing-standard.md. Use the controlled technical writing profile.

# /start-ticket - Declare the Active Ticket

Writes the active-ticket marker for one working tree, so the `require-active-ticket.sh` PreToolUse hook permits Edit/Write on code paths in that tree. Without it, the hook blocks edits to anything outside `.claude/`, `docs/`, `projects/*/docs/`, and `*.md`.

Each working tree keeps its own marker in its own git dir (AgDR-0222):

| Working tree | Marker path |
|--------------|-------------|
| Main clone (the ops fork, or `workspace/<project>/`) | `<repo>/.git/apexyard-ticket` |
| Linked worktree (`git worktree add`) | `<repo>/.git/worktrees/<id>/apexyard-ticket` |

One tree holds one ticket. Parallel sessions on one project no longer overwrite each other, because each linked worktree has its own marker. `git worktree remove` deletes the marker with the worktree. The marker is never tracked, so it does not appear in `git status`.

The hook trusts a marker in a git dir only for the ops fork or a registered clone. A registered clone is `workspace/<project>/`, or the `workspace:` path of its registry entry. The marker is a process gate. Anyone with write access to the git dir can forge it. It is not an authorization boundary.

During the move to the new layout, the skill also writes the old-layout marker under `<ops_root>/.claude/session/`. It uses the place the old skill used: `tickets/<project>/<branch>`, `tickets/<project>` or `current-ticket`. The hooks still read old markers wherever they read them before. A hook from before the move, after a rollback or in a session that has not reloaded its hooks, sees the ticket too. See AgDR-0222, "Backward compatibility".

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
- `other-org/other-repo#128` — fully-qualified reference.
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
body=$(echo "$issue_json" | jq -r '.body // empty')
```

The lib emits normalised JSON: `{state, title, url, labels}`. Each tracker adapter parses the underlying CLI's JSON into this common shape, so the skill doesn't need to branch per-CLI.

If the lib exits non-zero with empty stdout, the issue does not exist (or the CLI isn't installed / authenticated). Stop and report the error — do not write the marker.

If `state` indicates the ticket is closed (gh: `CLOSED`; linear/jira/asana: `Done` / `Closed` / `Resolved` / `Cancelled`), warn the user and confirm before continuing (sometimes you do want to resume work on a re-opened issue).

When the resolved project has `orbit.default_planning: true`, check `body`
for an `ORBIT slice:` line, including the bold form
`**ORBIT slice:** \`<id>\``. If it has no such line, print:

```text
WARN: This ticket names no ORBIT slice. Run /orbit slice or record ORBIT slice: none — <reason> in the issue body.
```

Use the project's `orbit.default_planning` registry value when present; fall
back to `config_get '.orbit.default_planning'`. Make this check after step 4b
resolves the project. Continue to write the marker even when the line is
missing. A missing or unreadable issue body also produces the warning.

**`tracker.kind = none` adopters:** the lib returns no data. Skip the existence check entirely; trust the user's input. Re-verify the shape against `tracker_id_pattern` so obvious typos still block.

### 3. Derive a Branch Suggestion

From the issue title and number, generate: `<type>/<TICKET-ID>-<slug>` where:

- `<type>` guessed from title prefix: `[Feat]` → `feature`, `[Fix]` → `fix`, `[Docs]` → `docs`, `[Chore]` → `chore`, default `feature`
- `<TICKET-ID>` is `GH-<number>` for GitHub Issues, or matches the project's configured `ticket_prefix` from `apexyard.projects.yaml` if set
- `<slug>` = lowercase title, kebab-case, max 40 chars, stopwords trimmed from the edges

Match the convention in `.claude/rules/git-conventions.md`.

### 4. Resolve the target marker

The marker lives in the git dir of the working tree you are in. A ticket on a managed project's repo is declared from that project's clone, or from one of its worktrees.

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
  # (`repo: me2resh/sample-app`) or quoted scalars (`repo: "me2resh/…"`).
  project=$(awk -v r="$OWNER_REPO" '
    function unquote(s) { gsub(/^["\x27]|["\x27]$/, "", s); return s }
    /^[[:space:]]*- name:/ { name = unquote($3) }
    /^[[:space:]]*repo:/   { if (unquote($2) == r) { print name; exit } }
  ' "$registry")
fi
```

Notes on the fallback:

- Handles both `repo: me2resh/sample-app` and `repo: "me2resh/sample-app"` (and single-quoted).
- Assumes `- name:` is the FIRST key in each project entry — that matches the shape in `apexyard.projects.yaml.example` and every entry produced by `/handover`. If your registry reorders keys so `repo:` appears before `name:` in an entry, the lookup misses. Fix: move `name:` to the top, or install `yq` (the preferred path).
- Leading whitespace is tolerated via `^[[:space:]]*` — nested entries under `projects:` parse fine at any indent level, so long as the indent is consistent within the entry.

`$project` is now either a registered project name (e.g. `sample-app`, `demo-svc`) or empty (ticket's tracker repo isn't registered — typically because the ticket is on the ops fork itself, or a repo that's not under management).

#### 4c. Pick the working tree

The marker goes into the tree that holds the code you will change.

- Run the skill from inside the tree. The tree is the git top level of the working directory, so a subdirectory of the tree also works.
- A ticket can map to a registered project (step 4b) while you run from the ops fork's main tree. Then use the project's clone as the tree. That is the `workspace:` path of its registry entry, or `<workspace dir>/<project>` when the entry has none.
- The workspace dir comes from the portfolio paths. A split-portfolio adopter keeps it outside the ops fork.
- A ticket on the ops fork itself uses the ops root, or the linked worktree of the ops fork you work in.
- Stop when the tree is not an existing directory. Clone the project first, or run the skill from inside its clone.

```bash
cwd_top=$(git rev-parse --show-toplevel 2>/dev/null || true)
ops_top=$(cd "$ops_root" && pwd -P)
if [ -n "$project" ] && [ "$cwd_top" = "$ops_top" ]
then
  tree=$(cd "$ops_root" && bash -c '. "$1/.claude/hooks/_lib-active-ticket.sh" && active_ticket_init "$1" && active_ticket_project_clone "$2" && printf "%s" "$REPLY"' _ "$ops_root" "$project")
else
  tree="${cwd_top:-$PWD}"
fi
if [ -z "$tree" ] || [ ! -d "$tree" ]
then
  echo "No clone of $project at ${tree:-an unknown path}. Clone it, or run /start-ticket from inside its clone." >&2
  exit 1
fi
```

The writer in step 5 also checks the tree. It writes the marker only when the ticket's repo belongs to the tree's registry entry. In the ops fork, it writes no ticket of a registered project. A refused write is not an error, because the old-layout marker still covers the ticket.

#### 4d. Old-layout markers

Do not delete an old-layout file. Step 5 writes the old-layout marker for this ticket where the old skill wrote it. So it replaces an older ticket there, as before.

### 5. Write the markers

Write the markers in three steps. The issue title never goes on a command line. A title can hold shell syntax such as `>`, `| tee` or `sed -i`, and the ticket gate reads such a command as a file write. A fresh tree has no ticket yet, so the gate would block `/start-ticket` itself.

1. Run this fixed command to get the path of the ticket fields file. Replace `$ops_root` with the path from step 4:

   ```bash
   bash -c '. "$1/.claude/hooks/_lib-active-ticket.sh" && active_ticket_pending_path "$1"' _ "$ops_root"
   ```

   The command prints one path, `<ops_root>/.claude/session/start-ticket-<id>.pending`. The `<id>` is the session id, so each session uses its own file. Two sessions that run `/start-ticket` at the same time cannot swap tickets. Without a session id, the command makes a new id on each run. Run it once and use the printed path in steps 2 and 3.

2. Use the Write tool to write the ticket fields to the path from step 1, one `key=value` line each:

   ```
   repo=<owner/repo>
   number=<number>
   title=<title>
   url=<url>
   suggested_branch=<branch>
   ```

   Put the title on one line. Replace any newline in it with a space.

3. Run this fixed command. Replace `$ops_root` and `$tree` with the paths from step 4, and `$pending` with the path from step 1. The command takes only paths:

   ```bash
   bash -c '. "$1/.claude/hooks/_lib-active-ticket.sh" && active_ticket_write_from_file "$2" "$3"' _ "$ops_root" "$tree" "$pending"
   ```

`active_ticket_write_from_file` in `.claude/hooks/_lib-active-ticket.sh` reads the fields and deletes the file. It refuses a file that is a symlink. It also refuses any path that is not a `start-ticket-<id>.pending` file in `.claude/session`, and leaves that path in place. It then runs the two writers. `active_ticket_write` writes the marker into the tree's git dir. `active_ticket_write_legacy` writes the old-layout marker.

When the tree fails validation, the command writes only the old-layout marker and prints a one-line note. That is not an error. The hooks read the old-layout marker for that tree as they did before.

`active_ticket_write` validates the tree, then writes these lines atomically into the tree's git dir. `active_ticket_write_legacy` writes the same lines to the old-layout path:

```
repo=<owner/repo>
number=<number>
title=<title>
url=<url>
suggested_branch=<branch>
started_at=<ISO-8601>
```

`active_ticket_write` refuses a tree that is not the ops fork or a registered clone. It also refuses a symlink in the path, a repo owned by another user, and a malformed `.git` file. It prints the reason to stderr. If it prints a hint about the sandbox, the session may not write into the git dir. Tell the user. The old-layout marker still covers the tree. See AgDR-0222 for the allowlist the user can add.

`active_ticket_write_legacy` prints a one-line note and writes nothing when the old-layout path is blocked. An example is a `tickets/<project>` file where the per-worktree marker needs a directory. Report the note to the user. Do not delete the file.

Do NOT write the marker with the Edit or Write tool. `.git` is a protected path for those tools.

### Read the active ticket

Other skills read the active ticket of the working tree through the same resolver. Run this from the tree you are in:

```bash
bash -c '. "$1/.claude/hooks/_lib-active-ticket.sh" && active_ticket_init "$PWD" && active_ticket_lookup "$PWD" && cat "$REPLY"' _ "$ops_root"
```

The command prints the marker (`repo=`, `number=`, `title=`, `url=`), or nothing when no marker covers the tree. It reads the marker in the tree's git dir first, then the old-layout marker.

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

Output a confirmation that names the marker path, so the user sees which working tree this ticket governs:

```
Active ticket: <owner/repo>#<number> — <title>
Marker: <tree git dir>/apexyard-ticket  (this working tree only)
Suggested branch: <branch>
```

Do NOT create the branch automatically. The user may already be on a branch, or may want to confirm the branch name first.

## Notes

- The marker lives in the git dir, so it is per machine and per working tree. It is never committed.
- Running `/start-ticket` again in the same tree overwrites that tree's marker. That is how you switch tickets. A linked worktree and its main clone hold separate markers.
- To clear a tree's marker, delete `<git dir>/apexyard-ticket`. `git worktree remove` does it for a linked worktree.
- A tree needs its own `/start-ticket`. A marker in the main clone does not govern a linked worktree.
- Exempt paths (`.claude/`, `docs/`, `projects/*/docs/`, any `*.md`) don't need a ticket. The skill is only required before touching source, config, or infra.
- **Migration from the old layout**: `current-ticket` and `tickets/<project>` files under the ops fork's `.claude/session/` still work wherever they worked before. This skill still writes them. A SessionStart notice lists them. An explicitly breaking release will stop reading and writing them.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
