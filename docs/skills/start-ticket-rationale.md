# Start-ticket rationale

One tree holds one ticket. Parallel sessions on one project no longer overwrite each other, because each linked worktree has its own marker. `git worktree remove` deletes the marker with the worktree. The marker is never tracked, so it does not appear in `git status`.

## Foreign overwrite (AgDR-0257 / #1533)

When `/start-ticket` would replace a marker that holds a **different** ticket
and a **different** `session_id` (empty or missing counts as different), ask
with `AskUserQuestion`:

| Option | Action |
|--------|--------|
| Stay in a worktree that already holds your ticket | Stop. Point at the concurrent-sessions runbook in #1534. |
| Take over | Write with `APEXYARD_START_TICKET_TAKEOVER=1`. |
| Cancel | Leave the marker byte-for-byte unchanged. |

Headless and `/fan-out` runs cancel. `active_ticket_write_from_file` also
refuses a foreign overwrite unless that flag is set. The guard checks the
per-tree marker when present. It checks the old-layout path only when the
tree fails validation. A valid linked worktree with no per-tree marker yet
writes its own marker and does not treat the shared old-layout session
marker as a foreign overwrite (Hakim A4). After a successful take-over write, the writer
prints one stderr audit line with control characters stripped from every
field (Hakim A2). The ticket gate warns once per session when `session_id`
or `branch` on the marker does not match the current session or tree
branch. The warning never blocks.

The hook trusts a marker in a git dir only for the ops fork or a registered clone. A registered clone is `workspace/<project>/`, or the `workspace:` path of its registry entry. The marker is a process gate. Anyone with write access to the git dir can forge it. It is not an authorization boundary.

During the move to the new layout, the skill also writes the old-layout marker under `<ops_root>/.claude/session/`. It uses the places the old skill used. The resolver in `_lib-active-ticket.sh` defines them. The hooks still read old markers wherever they read them before. A hook from before the move, after a rollback or in a session that has not reloaded its hooks, sees the ticket too. See AgDR-0222, "Backward compatibility".


**Cross-repo note:** ApexYard governs a portfolio of repos. If the user is in the ops repo (the apexyard fork) but the ticket lives in a managed project's own repo, they should pass the fully-qualified form so the marker records the correct tracker. Each managed project's tickets live in that project's own GitHub repo — tickets do not cross project boundaries.


The ops root is the apexyard fork root, anchored by EITHER the `.apexyard-fork` marker (split-portfolio v2, framework ≥ #242 — `onboarding.yaml` and `apexyard.projects.yaml` live in the sibling portfolio repo, not the fork) OR the legacy v1 pair (`onboarding.yaml` AND `apexyard.projects.yaml` both present in the same directory).

Locate `_lib-ops-root.sh` by walking up from `$PWD` — **not** via `git rev-parse --show-toplevel`. Inside a `workspace/<project>/` clone, `--show-toplevel` resolves to the *project* repo, and managed-project clones carry **no `.claude/hooks/` directory at all** (there is no framework mechanism that installs one there) — sourcing from that path silently fails, `resolve_ops_root` is never defined, and this step dead-ends exactly where split-portfolio v2 operators most often run `/start-ticket`. This is the same sibling walk-up pattern `bug`, `feature`, `task`, `migration`, `spike`, `prototype`, and 8 other ticket skills already use to locate `_lib-tracker.sh` — walk up until a directory containing the lib is found, then source it.

Keep two steps distinct: the walk-up below only finds a directory to **source the lib from** (the nearest fork-shaped root above cwd); `resolve_ops_root` then **decides the real ops root**, pin-first (apexyard#381) — the two can differ, e.g. a session pin can point at a different real ops fork than the nearest fork-shaped directory on the walk (say, cwd is inside an ops-fork-shaped `/tmp` build clone).


Notes on the fallback:

- Handles both `repo: me2resh/sample-app` and `repo: "me2resh/sample-app"` (and single-quoted).
- Assumes `- name:` is the FIRST key in each project entry — that matches the shape in `apexyard.projects.yaml.example` and every entry produced by `/handover`. If your registry reorders keys so `repo:` appears before `name:` in an entry, the lookup misses. Fix: move `name:` to the top, or install `yq` (the preferred path).
- Leading whitespace is tolerated via `^[[:space:]]*` — nested entries under `projects:` parse fine at any indent level, so long as the indent is consistent within the entry.

