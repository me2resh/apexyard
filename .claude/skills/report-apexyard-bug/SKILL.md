---
name: report-apexyard-bug
description: Report a bug in the apexyard FRAMEWORK itself (hook misfire, skill gap, rule bug). Files a structured issue upstream to me2resh/apexyard. Distinct from /bug, which files into your own project.
argument-hint: "<short description of the framework bug>"
allowed-tools: Bash, Read, Write
---

# /report-apexyard-bug: Report a Framework Bug Upstream

Read `.claude/rules/writing-standard.md`. Use the **controlled technical writing profile** for the
upstream bug report: lead with the observed outcome and reproducible next action.

File a structured GitHub Issue **about the apexyard framework itself** to the canonical upstream **`me2resh/apexyard`**.
Use this skill when a hook misfires, a skill fails, a rule produces a wrong result, or the docs are wrong.

This is the framework-feedback sibling of `/bug`. The difference is the target:

| Skill | Reports a bug in… | Files to… |
|-------|-------------------|-----------|
| `/bug` | your managed project's code | your project's own GitHub repo |
| **`/report-apexyard-bug`** | the apexyard **framework** (hooks / skills / rules / agents / docs) | **`me2resh/apexyard`** (upstream) |

> **Leak protection (mandatory).** This skill writes to a PUBLIC framework repo.
> NEVER include a registered private project's name, repo slug, or workspace path
> in the issue. Per `.claude/rules/leak-protection.md`, describe the context
> generically ("a registered project", "one of the managed workspaces"). The
> `block-private-refs-in-public-repos.sh` hook provides mechanical enforcement.
> Scrub the report as you write it.
> The private name remains in your context, so you must actively exclude it.

## Usage

```
/report-apexyard-bug detect-role-trigger.sh fires on the wrong path
/report-apexyard-bug /handover crashes when the repo has no README
/report-apexyard-bug require-active-ticket blocks an exempt docs edit
```

## Process

### 0. Write the active-issue-skill marker (REQUIRED: me2resh/apexyard#268)

Before any `gh issue create`, write this skill's name to the active-issue-skill
marker so `require-skill-for-issue-create.sh` lets the command through. At entry:

```bash
# Ops root through the session pin (docs/skills/shared/ops-root.md).
ops_root=$(p="${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID:-}"; r=""; [ -z "${APEXYARD_OPS_DISABLE_PIN:-}" ] && [ -f "$p" ] && IFS= read -r r < "$p"; [ -f "$r/.claude/hooks/_lib-ops-root.sh" ] || { r="$PWD"; while [ -n "$r" ] && [ ! -f "$r/.claude/hooks/_lib-ops-root.sh" ]; do r=${r%/*}; done; }; [ -f "$r/.claude/hooks/_lib-ops-root.sh" ] && . "$r/.claude/hooks/_lib-ops-root.sh" && resolve_ops_root) && [ -n "$ops_root" ] || { echo "No ops root. See docs/skills/shared/ops-root.md." >&2; exit 1; }
mkdir -p "$ops_root/.claude/session"
marker_home="$ops_root"
. "$marker_home/.claude/hooks/_lib-session-markers.sh"
skill_marker=$(active_issue_skill_marker_path "$marker_home") || { echo "A session id is required. Restart through the harness adapter." >&2; exit 2; }
echo "report-apexyard-bug" > "$skill_marker"
```

Remove the marker on **every** exit path (success, cancel, error):

```bash
marker_home="$ops_root"
. "$marker_home/.claude/hooks/_lib-session-markers.sh"
skill_marker=$(active_issue_skill_marker_path "$marker_home") || { echo "A session id is required. Restart through the harness adapter." >&2; exit 2; }
rm -f "$skill_marker"
```

### 1. Resolve the upstream repo

This skill always files **upstream**, regardless of the adopter's fork origin.
Resolve it (prefer the configured `upstream` remote; fall back to the canonical
slug):

```bash
UPSTREAM=$(git remote get-url upstream 2>/dev/null \
  | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
UPSTREAM="${UPSTREAM:-me2resh/apexyard}"
```

A misconfigured `upstream` can select a fork owner.
If `$UPSTREAM` does not look like `me2resh/apexyard`, confirm with the user before filing.
Alternatively, default to the canonical `me2resh/apexyard`.

### 2. Capture the framework version

Capture the version from the fork so the maintainer knows which version the report concerns.
Use the SessionStart upstream-drift banner, or derive the version if necessary.

**Do NOT use `git describe --tags --abbrev=0`.** The release-cut branch model creates release tags (`vX.Y.Z`) on `main`.
These tags are NOT ancestors of `dev`.
Thus, `git describe` from a `dev` checkout reports a stale version.
It reported `v1.1.0` when the current line was `v2.2.0`.
This would mislabel every issue from `dev` (#503).
Derive the version from `CHANGELOG.md` instead.
`/release-sync` carries this file `main → dev`, so it is always current on `dev`:

```bash
# Primary: top-most `## [X.Y.Z]` heading in CHANGELOG.md (carried main→dev by
# /release-sync, so always the canonical current version on dev).
FW_VERSION=$(grep -m1 -oE '^## \[v?[0-9]+\.[0-9]+\.[0-9]+\]' "$ops_root/CHANGELOG.md" 2>/dev/null \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
if [ -n "$FW_VERSION" ]; then
  FW_VERSION="v$FW_VERSION"          # keep the `v` prefix the field renders today
else
  # Fallbacks: highest semver tag across ALL refs (catches main-only release
  # tags via -v:refname sort) → short HEAD → literal "unknown".
  FW_VERSION=$(git -C "$ops_root" tag --sort=-v:refname 2>/dev/null | head -1)
  [ -z "$FW_VERSION" ] && FW_VERSION=$(git -C "$ops_root" rev-parse --short HEAD 2>/dev/null)
  [ -z "$FW_VERSION" ] && FW_VERSION="unknown"
fi
```

### 3. Gather details (one question at a time)

Ask conversationally. Do NOT batch questions. Wait for each answer.

**a) What part of the framework?** (which hook / skill / rule / agent / doc, e.g. `detect-role-trigger.sh`, `/handover`, `.claude/rules/leak-protection.md`)

**b) Given / When / Then**: what was the state, what did you do, what happened vs what should have happened.

**c) Repro**: the minimal steps. Include the exact command / skill invocation if relevant. **Scrub private project names**: use `<project>` / "a registered project".

**d) Severity**: `blocker` (cannot work) / `major` (wrong result, workaround exists) / `minor` (cosmetic / docs).

**e) Anything else**: error output, the banner text, related issue numbers (optional).

### 4. Show the formatted issue for confirmation

Substitute into this body and display it for `yes / edit / cancel`. **Re-scan the
rendered body for any private project name before showing it.**

```
Here's the framework bug I'll file to <UPSTREAM>:

---
**[Bug] {title}**

## Affected
{hook / skill / rule / agent / doc}

## Given / When / Then
**Given** {state}
**When** {action}
**Then** {observed} — expected {expected}

## Repro
1. {step 1}
2. {step 2}

## Framework version
{FW_VERSION}

## Severity
{blocker | major | minor}

## Notes
{error output / banner / related issues, or "—"}

## Glossary
| Term | Definition |
|------|------------|
| {term} | {definition} |
---

Labels: bug
Repo: <UPSTREAM>

File this upstream? (yes / edit / cancel)
```

### 5. Handle response

- **yes** → create the issue
- **edit** / **change X** → update, re-show
- **cancel** / **no** → abort (and remove the marker)

### 6. Create the GitHub Issue

```bash
gh issue create --repo "$UPSTREAM" \
  --title "[Bug] {title}" \
  --label "bug" \
  --body "{formatted body}"
```

If the `bug` label does not exist upstream, omit `--label`.
Note the missing label.
Do not fail the filing because of a missing label.
Follow the create-labels-first convention, but the adopter does not manage upstream labels.

### 7. Return the URL

```
Filed upstream: <UPSTREAM>#{number} — {title}
{url}
```

## Rules

1. **One question at a time.** Never batch. Wait for each answer.
2. **Always confirm before filing.** Show the full issue, get explicit "yes".
3. **Scrub private project names**: this writes to a PUBLIC repo. Describe context generically. See `.claude/rules/leak-protection.md`. Use the `<!-- private-refs: allow -->` body marker ONLY on explicit user confirmation that a name must stay.
4. **Always file upstream**: `me2resh/apexyard`, not the adopter's fork or a managed project.
5. **Capture the framework version** so the report is actionable.
6. **Label `bug`.** Title prefix `[Bug]`.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*
