---
name: start-ticket
description: Declare an active ticket for this session so the ticket-first hook lets code edits through. Accepts either a plain issue number (resolves against the current repo's origin) or a fully-qualified `<owner>/<repo>#<number>` reference. Run this at the start of any coding work.
disable-model-invocation: false
argument-hint: "<issue-number> | <owner/repo>#<number>"
effort: low
---

# /start-ticket - Declare the Active Ticket

Writes a session marker so the `require-active-ticket.sh` PreToolUse hook permits Edit/Write on code paths. Without it, the hook blocks edits to anything outside `.claude/`, `docs/`, `projects/*/docs/`, and `*.md`.

Marker layout (apexstack#41):

| Path | When the hook uses it |
|------|----------------------|
| `<ops_root>/.claude/session/tickets/<project>` | When the edit is under `<ops_root>/workspace/<project>/` AND this per-project marker exists |
| `<ops_root>/.claude/session/current-ticket` | Fallback. Always checked if the per-project marker is absent. This is also the marker used for ops-repo framework edits (where no `workspace/<name>/` prefix applies). |

Both markers live in the ops fork (gitignored). No more `.claude/session/` inside each managed-project clone.

This is the mechanical enforcement of the Pre-Build Gate in `.claude/rules/workflow-gates.md` — "do not start coding until the ticket exists".

## Process

### 1. Parse Arguments

Expected forms:

- `42` — plain number, resolves against the current repo. Read `git remote get-url origin` and extract `<owner>/<repo>`. If there's no origin, stop and ask for a fully-qualified reference.
- `me2resh/flat-mate#128` — fully-qualified reference.
- `apexstack#42` — owner defaults to the current org (parsed from the origin URL).

If `$ARGUMENTS` is empty, stop and ask the user which issue they're starting.

**Cross-repo note:** ApexStack governs a portfolio of repos. If the user is in the ops repo (the apexstack fork) but the ticket lives in a managed project's own repo, they should pass the fully-qualified form so the marker records the correct tracker. Each managed project's tickets live in that project's own GitHub repo — tickets do not cross project boundaries.

### 2. Verify the Issue Exists

Run:

```bash
gh issue view <number> --repo <owner/repo> --json number,title,state,url,labels
```

If `state` is not `OPEN`, warn the user and confirm before continuing (sometimes you do want to resume work on a re-opened issue).

If the issue does not exist, stop and report the error — do not write the marker.

### 3. Derive a Branch Suggestion

From the issue title and number, generate: `<type>/<TICKET-ID>-<slug>` where:

- `<type>` guessed from title prefix: `[Feat]` → `feature`, `[Fix]` → `fix`, `[Docs]` → `docs`, `[Chore]` → `chore`, default `feature`
- `<TICKET-ID>` is `GH-<number>` for GitHub Issues, or matches the project's configured `ticket_prefix` from `apexstack.projects.yaml` if set
- `<slug>` = lowercase title, kebab-case, max 40 chars, stopwords trimmed from the edges

Match the convention in `.claude/rules/git-conventions.md`.

### 4. Resolve the target marker

Per apexstack#41, the marker path depends on whether the ticket's tracker repo matches a registered managed project.

#### 4a. Locate the ops root

The ops root is the apexstack fork root — the directory containing BOTH `onboarding.yaml` and `apexstack.projects.yaml`. Walk up from CWD / the nearest git toplevel until you find it:

```bash
ops_root=""
r=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
while [ -n "$r" ] && [ "$r" != "/" ]; do
  if [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexstack.projects.yaml" ]; then
    ops_root="$r"
    break
  fi
  r=$(dirname "$r")
done
```

If not found (user is outside an apexstack fork), tell the user and stop. Starting a ticket without the fork doesn't make sense.

#### 4b. Look the tracker repo up in the registry

Given the ticket's `owner/repo` (from step 1), grep `apexstack.projects.yaml` for a project whose `repo:` field matches. One registry-safe way (uses `yq` when available, falls back to a greppy read):

```bash
if command -v yq >/dev/null 2>&1; then
  project=$(yq eval ".projects[] | select(.repo == \"${OWNER_REPO}\") | .name" "$ops_root/apexstack.projects.yaml")
else
  # Greppy fallback: find the `name:` whose sibling `repo:` matches.
  # Strips surrounding quotes from both `name:` and `repo:` values so the
  # comparison works whether the registry uses bare scalars
  # (`repo: me2resh/curios-dog`) or quoted scalars (`repo: "me2resh/…"`).
  project=$(awk -v r="$OWNER_REPO" '
    function unquote(s) { gsub(/^["\x27]|["\x27]$/, "", s); return s }
    /^[[:space:]]*- name:/ { name = unquote($3) }
    /^[[:space:]]*repo:/   { if (unquote($2) == r) { print name; exit } }
  ' "$ops_root/apexstack.projects.yaml")
fi
```

Notes on the fallback:

- Handles both `repo: me2resh/curios-dog` and `repo: "me2resh/curios-dog"` (and single-quoted).
- Assumes `- name:` is the FIRST key in each project entry — that matches the shape in `apexstack.projects.yaml.example` and every entry produced by `/handover`. If your registry reorders keys so `repo:` appears before `name:` in an entry, the lookup misses. Fix: move `name:` to the top, or install `yq` (the preferred path).
- Leading whitespace is tolerated via `^[[:space:]]*` — nested entries under `projects:` parse fine at any indent level, so long as the indent is consistent within the entry.

`$project` is now either a registered project name (e.g. `curios-dog`, `sharppick`) or empty (ticket's tracker repo isn't registered — typically because the ticket is on the ops fork itself, or a repo that's not under management).

#### 4c. Pick the marker path

```bash
if [ -n "$project" ]; then
  marker="$ops_root/.claude/session/tickets/$project"
  mkdir -p "$(dirname "$marker")"
else
  marker="$ops_root/.claude/session/current-ticket"
  mkdir -p "$(dirname "$marker")"
fi
```

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

### 6. Confirm to the User

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
