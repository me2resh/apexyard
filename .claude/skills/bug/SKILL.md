---
name: bug
description: Create a structured bug ticket (Given/When/Then scenario, repro steps, severity).
argument-hint: "<short description of the bug>"
allowed-tools: Bash, Read, Write
---

# /bug — Create a Bug Report Ticket

Creates a structured GitHub Issue for a bug with Given/When/Then scenario, repro steps, environment, and severity. Asks guided questions, shows the formatted ticket for confirmation, then creates the issue.

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`, `./projects/ideas-backlog.md`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir, ideas_backlog}` keys in `.claude/project-config.json`. Don't hardcode literal `apexyard.projects.yaml` or `projects/` paths in bash blocks — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

## Usage

```
/bug Profile picture upload fails
/bug RTL resets on navigation
/bug Follow button state not persisted
```

## Process

### 0. Write the active-issue-skill marker (REQUIRED — me2resh/apexyard#268)

Before any `gh issue create` (or other tracker CLI), write this skill's name to the active-issue-skill marker so `require-skill-for-issue-create.sh` lets the command through. At skill entry:

```bash
# Resolve the ops-fork root the SAME way the hooks do (_lib-ops-root.sh):
# anchor on the .apexyard-fork marker (split-portfolio v2 — onboarding.yaml
# lives in the sibling portfolio repo, NOT the ops fork), falling back to the
# onboarding.yaml + apexyard.projects.yaml pair (single-fork v1).
ops_root="$PWD"; r="$PWD"
while [ "$r" != / ]; do
  if [ -f "$r/.apexyard-fork" ] || { [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ]; }; then
    ops_root="$r"; break
  fi
  r=${r%/*}
done
mkdir -p "$ops_root/.claude/session"
echo "bug" > "$ops_root/.claude/session/active-issue-skill"
```

Remove the marker on **every** exit path (success, early-exit, user cancel, error):

```bash
rm -f "$ops_root/.claude/session/active-issue-skill"
```

The `clear-issue-skill-marker.sh` SessionStart hook sweeps stale markers from killed sessions, but a clean exit should never leave one behind. See AgDR-0030.

### 1. Resolve the target repo

Read `.claude/session/current-ticket` to determine which repo we're working in. If no active ticket, check `apexyard.projects.yaml` for managed projects. If only one project, use it. If multiple, ask:

```
Which project is this bug in?
```

If no projects are registered, ask for the repo in `owner/repo` format.

### 2. Parse or ask for the title

Take the title from `$ARGUMENTS`. If empty, ask:

```
What's the bug? Give me a short description.
```

### 3. Gather details (one question at a time)

Ask conversationally — do NOT batch all questions. Wait for each answer before asking the next.

**a) Bug Scenario**

```
Describe the bug scenario:
- Given: what's the starting state?
- When: what action triggers the bug?
- Then: what happens (the broken behavior)?
- Expected: what should happen instead?
```

If the user gives a casual description, restructure it into Given/When/Then/Expected format and confirm.

**b) Repro Steps**

```
What are the exact steps to reproduce?
```

**c) Severity**

```
How severe is this?
1. P0 — blocks a core feature, must fix immediately
2. P1 — important, fix soon
3. P2 — minor, fix when convenient
```

**d) Environment (optional)**

```
Any environment details? (browser, device, staging/prod, or Enter to skip)
```

**e) Investigation Notes (optional)**

```
Any initial investigation? (root cause hypothesis, relevant code paths, or Enter to skip)
```

### 4. Resolve the bug body template

Resolve the bug body template via the portfolio helper so adopter overrides win when present:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
template=$(portfolio_resolve_template tickets/bug.md)   # → custom-templates/tickets/bug.md if present, else templates/tickets/bug.md
```

Single-fork adopters (no `portfolio` block) and adopters with no override fall straight through to `templates/tickets/bug.md`. Adopters who want a customised bug-body shape drop their version at `<private_repo>/custom-templates/tickets/bug.md`. See `templates/README.md` for the path-mirroring convention.

**Backward-compat fallback**: if `portfolio_resolve_template` returns empty (template file missing — partial adopter setup), fall back to the inline heredoc body below and print a one-line WARN on stderr (`WARN: tickets/bug.md template missing — using inline fallback`). This preserves the pre-refactor behaviour for adopters whose installations don't yet have the new template files.

### 5. Show the formatted ticket for confirmation

Substitute the gathered inputs into the resolved template (or the inline heredoc fallback), then display the full ticket using the resolved shape (the default `templates/tickets/bug.md` shape is reproduced below):

```
Here's the ticket I'll create:

---
**[{P0|P1|P2}] {title}**

## Bug Scenario
**Given** {precondition}
**When** {action}
**Then** {unexpected result}
**Expected** {correct behavior}

## Repro Steps
1. {step 1}
2. {step 2}
3. ...

## Environment
{environment or "Not specified"}

## Severity
{P0-critical / P1-important / P2-later}

## Mitigation
{workaround or "—"}

## Investigation Notes
{notes or "—"}

## Glossary
| Term | Definition |
|------|------------|
| {term} | {definition} |
---

Labels: bug, {P0|P1|P2}
Repo: {owner/repo}

Create this ticket? (yes / edit / cancel)
```

### 6. Handle response

- **yes** / **looks good** / **go** → create the issue
- **edit** / **change X** → ask what to change, update, re-show
- **cancel** / **no** → abort

### 7. Create the issue (via the tracker abstraction)

Dispatch through `tracker_create` (#670 / AgDR-0072) so the issue lands in
**this project's** tracker (GitHub / GitLab / `custom`) per its `tracker:` block
in `apexyard.projects.yaml`. For a GitHub adopter this runs `gh issue create`
unchanged.

```bash
# Resolve + source the tracker lib (it lives in the ops fork's hooks dir).
tracker_lib="$(r="$PWD"; while [ -n "$r" ] && [ "$r" != / ]; do \
  [ -f "$r/.claude/hooks/_lib-tracker.sh" ] && { echo "$r/.claude/hooks/_lib-tracker.sh"; break; }; \
  r="${r%/*}"; done)"
# shellcheck source=/dev/null
. "$tracker_lib"

body_file="$(mktemp)"
cat > "$body_file" <<'BODY'
{formatted body}
BODY

# tracker_create <owner/repo> <title> <body_file> [<labels_csv>] → {"ref","url"}.
# Gated by require-skill-for-issue-create.sh; the step-0 marker keeps it allowed.
result="$(tracker_create "{owner/repo}" "[{P0|P1|P2}] {title}" "$body_file" "bug,{priority}")"
rc=$?
rm -f "$body_file"
if [ "$rc" -eq 3 ]; then
  # tracker.kind=none (shape-only): no tracker to create in. tracker_create
  # printed the rendered ticket body to stdout — surface it for manual /
  # external filing instead of a non-existent CLI/auth failure.
  echo "Tracker is 'none' (shape-only) — nothing was created in a tracker." >&2
  echo "File this in your external system (e.g. Jira/Linear via MCP):" >&2
  printf '%s\n' "$result"
  exit 0
elif [ "$rc" -ne 0 ] || [ -z "$result" ]; then
  echo "Issue creation failed — check the tracker CLI / auth. Nothing was created." >&2
  exit 1
fi
```

### 8. Return the result

```bash
ref="$(printf '%s' "$result" | jq -r '.ref')"
url="$(printf '%s' "$result" | jq -r '.url')"
echo "Created: {owner/repo}#${ref} — {title}"
echo "${url}"
```

## Rules

1. **One question at a time.** Never batch questions. Wait for each answer.
2. **Always confirm before creating.** Show the full ticket and get explicit "yes".
3. **Given/When/Then is required.** Restructure casual descriptions into the format.
4. **At least one repro step.** Don't create bugs without repro.
5. **Labels auto-applied.** `bug` always, plus the severity label. Severity label scheme reads from `.claude/project-config.*.json` → `.ticket.label_priority_scheme` (default `P0,P1,P2,P3`).
6. **Title prefix.** The accepted prefix list reads from `.claude/project-config.*.json` → `.ticket.prefix_whitelist`; `[Bug]` must be in that list. Some teams prefer `[Bug]` prefix with the severity as a label (the default); others embed severity in the title (`[P0]`, `[P1]`). Skill respects whichever is configured. See apexyard#109.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
