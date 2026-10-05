# AgDR-0217: Require a merged ORBIT slice before Feature and Task issues

> For issue #1565, I chose a project-scoped ticket creation gate so each ORBIT Feature or Task issue points to a durable slice record before work starts.

## Context

ORBIT planning orders work as goal, reconciliation, slice, issue, then PR.
Without a gate, an agent can file an issue before the slice record exists.
That breaks the link used by progress views and later reconciliations.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Skill instruction only | Small change. | Raw ticket creation can skip the record. |
| PreToolUse guard with default-branch read | Checks the durable record before filing. | Requires a local checkout and updated remote ref. |
| Working-tree file check | Allows immediate filing. | An unmerged record can disappear or change. |

## Decision

Chosen: **PreToolUse guard with a default-branch read**. When the target
project enables `orbit.default_planning`, Feature, Task, and ORBIT Slice issues must carry
`ORBIT slice: <id>` and the matching `docs/orbit/slices/<id>.json` must exist
on the project's local default-branch remote ref. The slice ID is restricted
to lowercase, hyphen-separated `slice-` identifiers before it enters a Git
object path. The record PR must merge before the issue is filed.

The explicit escape hatch is `ORBIT slice: none — <reason>`. The hook accepts
an ASCII dash or double dash too, requires a non-empty reason, and logs it to
stderr. This records why a ticket bypassed the normal planning order.

The gate fails closed with exit 2 when ORBIT is on and it cannot read the
ticket body, the default-branch ref, or the named record. It does not block
Bug or Spike issues or projects with ORBIT off. `/start-ticket` warns about
a missing slice line but still starts the ticket.

The ORBIT handoff requires the adapter preview to use a `[Slice]` title. The
default ticket prefix list accepts this title so the standard issue-structure
gate permits handoff.

Target repos are normalised to lowercase `owner/name` (scheme, `git@host:`,
`host/`, trailing `.git`, and trailing `/` stripped) before registry lookup.
Project resolution uses `registry_parse_entries` from
`_lib-registry-parser.sh` so inline `repos: […]` and commented block-list
items match the same shapes as leak protection. Wrapped
`result="$(tracker_create …)"` matching stays in this guard only; the skill
create gate keeps `dev`'s boundary list so `/tickets-batch`, `/roadmap`, and
the close-promote skills are not blocked for every adopter.

## Consequences

- `/orbit slice` saves a record named after its ID and files its issue after
  the record merges, using the existing GitHub adapter preview and preflight.
- A stale local default-branch ref can block a valid issue until it is updated.
- The command-text hook covers recognized creation calls. It is an agent
  workflow gate, not a server-side issue policy.

## Known limits

- **A-1 — `gh api` comment and label calls with ORBIT on.** Some
  `gh api repos/…` write shapes that are not issue creates can still match the
  create family when ORBIT is on. Operators should use direct issue-create
  forms for governed tickets. Not fixed in #1565 follow-up.
- **A-2 — Early fail-closed before ORBIT lookup.** Missing `jq`, an unreadable
  or invalid project-config JSON, and a missing config root exit 2 on
  create-shaped commands even when the target project would have ORBIT off
  (confirmed: global `orbit.default_planning: false` plus no per-project
  `orbit:` still blocks on bad config / hidden jq). Duplicate `--repo` also
  fails before the ORBIT enabled check. This is stricter than "does not block
  … projects with ORBIT off" for those parse failures; it matches fail-closed
  when the gate cannot evaluate. Left as documented, not narrowed, so ORBIT-on
  tickets cannot slip through a broken config path.
- **A-3 — Retitle after create.** Filing a `[Bug]` then editing the title to
  `[Feature]` bypasses the create-time gate. Server-side issue policy is out
  of scope.
- **A-4 — Stale default-branch ref.** An outdated
  `refs/remotes/origin/HEAD` (or the named default remote ref) yields a
  "slice not on default branch" message even when the remote already has the
  record. Fetch or update the ref, then retry.
- **A-5 — Multi-repo entry, one checkout.** A `repos:` list resolves to one
  `workspace:` checkout. Slice records are read from that tree only.

## Architecture evolution

### Before

The first #1565 land used a private registry awk that matched only singular
`repo:` and simple block-list `repos:` lines, compared the `--repo` flag
literally, and extended `require-skill-for-issue-create.sh` with a `$(pat…)`
boundary so ORBIT could see wrapped `tracker_create`. That skill-gate change
blocked `/tickets-batch`, `/roadmap`, `/spike-close --promote`, and
`/prototype-close --promote` for every adopter. The `jq_missing` test hid jq
with `PATH=/bin`, which is wrong on Ubuntu where `/bin` merges with `/usr/bin`.

### After

Repo targets normalise to lowercase `owner/name`. Registry identity comes from
`registry_parse_entries` (PAIR= name↔repo); workspace and
`orbit.default_planning` are read for that name only. The skill create gate
matches `dev` again; wrapped-create detection stays in the ORBIT guard.
`jq_missing` builds a temp PATH of symlinks to required tools without jq, so
Linux CI and macOS share one hide mechanism. Reasoning: keep ORBIT fail-closed
for governed creates, restore non-ORBIT skill workflows, and close the
fail-open spelling and registry gaps Rex named on PR #1571.

## Artifacts

- Issue #1565
- PR #1571
- `.claude/hooks/require-orbit-slice-for-ticket.sh`
- `.claude/hooks/require-skill-for-issue-create.sh`
- `.claude/skills/orbit/SKILL.md`
- `.claude/hooks/tests/test_require_orbit_slice_for_ticket.sh`
- `.claude/hooks/tests/test_require_skill_for_issue_create.sh`
