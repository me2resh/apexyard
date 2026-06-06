---
name: report-apexyard-bug
description: Report a bug in the apexyard FRAMEWORK itself (hook misfire, skill gap, rule bug) — files a structured issue upstream to me2resh/apexyard. Distinct from /bug, which files into your own project.
argument-hint: "<short description of the framework bug>"
allowed-tools: Bash, Read, Write
---

# /report-apexyard-bug — Report a Framework Bug Upstream

Files a structured GitHub Issue **about the apexyard framework itself** to the
canonical upstream **`me2resh/apexyard`** — for when a hook misfires, a skill is
broken, a rule produces a wrong result, or the docs are wrong.

This is the framework-feedback sibling of `/bug`. The difference is the target:

| Skill | Reports a bug in… | Files to… |
|-------|-------------------|-----------|
| `/bug` | your managed project's code | your project's own GitHub repo |
| **`/report-apexyard-bug`** | the apexyard **framework** (hooks / skills / rules / agents / docs) | **`me2resh/apexyard`** (upstream) |

> **Leak protection (mandatory).** This skill writes to a PUBLIC framework repo.
> NEVER include a registered private project's name, repo slug, or workspace path
> in the issue. Per `.claude/rules/leak-protection.md`, describe the context
> generically ("a registered project", "one of the managed workspaces"). The
> `block-private-refs-in-public-repos.sh` hook is the mechanical backstop, but
> scrub at authoring time — the private name is right there in your context while
> you write, and not referencing it takes active suppression.

## Usage

```
/report-apexyard-bug detect-role-trigger.sh fires on the wrong path
/report-apexyard-bug /handover crashes when the repo has no README
/report-apexyard-bug require-active-ticket blocks an exempt docs edit
```

## Process

### 0. Write the active-issue-skill marker (REQUIRED — me2resh/apexyard#268)

Before any `gh issue create`, write this skill's name to the active-issue-skill
marker so `require-skill-for-issue-create.sh` lets the command through. At entry:

```bash
ops_root="$(r=$PWD;while [ ! -f \"$r/onboarding.yaml\" ] && [ \"$r\" != / ];do r=${r%/*};done;echo $r)"
mkdir -p "$ops_root/.claude/session"
echo "report-apexyard-bug" > "$ops_root/.claude/session/active-issue-skill"
```

Remove the marker on **every** exit path (success, cancel, error):

```bash
rm -f "$ops_root/.claude/session/active-issue-skill"
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

If `$UPSTREAM` doesn't look like `me2resh/apexyard` (a fork owner crept in via a
mis-set `upstream`), confirm with the user before filing, or default to the
canonical `me2resh/apexyard`.

### 2. Capture the framework version

So the maintainer knows which version the report is against, capture the version
from the fork (the SessionStart upstream-drift banner shows it; otherwise derive
it).

**Do NOT use `git describe --tags --abbrev=0`.** Under the release-cut branch
model, release tags (`vX.Y.Z`) are created on `main` and are NOT ancestors of
`dev`, so `git describe` from a `dev` checkout reports a stale version (observed:
`v1.1.0` when the line is actually `v2.2.0`) — every issue filed from `dev` would
be mislabeled (#503). Derive from `CHANGELOG.md` instead, which `/release-sync`
carries `main → dev`, so it is always current on `dev`:

```bash
# Primary: top-most `## [X.Y.Z]` heading in CHANGELOG.md (carried main→dev by
# /release-sync, so always the canonical current version on dev).
FW_VERSION=$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$ops_root/CHANGELOG.md" 2>/dev/null \
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

Ask conversationally — do NOT batch. Wait for each answer.

**a) What part of the framework?** (which hook / skill / rule / agent / doc — e.g. `detect-role-trigger.sh`, `/handover`, `.claude/rules/leak-protection.md`)

**b) Given / When / Then** — what was the state, what did you do, what happened vs what should have happened.

**c) Repro** — the minimal steps. Include the exact command / skill invocation if relevant. **Scrub private project names** — use `<project>` / "a registered project".

**d) Severity** — `blocker` (can't work) / `major` (wrong result, workaround exists) / `minor` (cosmetic / docs).

**e) Anything else** — error output, the banner text, related issue numbers (optional).

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

If the `bug` label doesn't exist on the upstream repo, drop `--label` and note it
(don't fail the whole filing over a missing label — per the create-labels-first
convention, but upstream label management isn't the adopter's job).

### 7. Return the URL

```
Filed upstream: <UPSTREAM>#{number} — {title}
{url}
```

## Rules

1. **One question at a time.** Never batch. Wait for each answer.
2. **Always confirm before filing.** Show the full issue, get explicit "yes".
3. **Scrub private project names** — this writes to a PUBLIC repo. Describe context generically. See `.claude/rules/leak-protection.md`. Use the `<!-- private-refs: allow -->` body marker ONLY on explicit user confirmation that a name must stay.
4. **Always file upstream** — `me2resh/apexyard`, not the adopter's fork or a managed project.
5. **Capture the framework version** so the report is actionable.
6. **Label `bug`.** Title prefix `[Bug]`.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
