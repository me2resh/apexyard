---
name: request-apexyard-feature
description: Request a new feature or enhancement for the apexyard FRAMEWORK itself — files a structured issue upstream to me2resh/apexyard. Distinct from /feature, which files into your own project.
argument-hint: "<short description of the framework feature>"
allowed-tools: Bash, Read, Write
---

# /request-apexyard-feature — Request a Framework Feature Upstream

Files a structured GitHub Issue **proposing a feature or enhancement for the
apexyard framework itself** to the canonical upstream **`me2resh/apexyard`** —
for a new skill, a new hook, a rule improvement, a better workflow, etc.

This is the framework-feedback sibling of `/feature`. The difference is the target:

| Skill | Requests a feature for… | Files to… |
|-------|-------------------------|-----------|
| `/feature` | your managed project | your project's own GitHub repo |
| **`/request-apexyard-feature`** | the apexyard **framework** (skills / hooks / rules / agents / workflows) | **`me2resh/apexyard`** (upstream) |

> **Leak protection (mandatory).** This skill writes to a PUBLIC framework repo.
> NEVER include a registered private project's name, repo slug, or workspace path.
> Per `.claude/rules/leak-protection.md`, describe the motivating context
> generically ("while onboarding a project", "during bulk ticket filing"). The
> `block-private-refs-in-public-repos.sh` hook is the backstop; scrub at authoring
> time.

## Usage

```
/request-apexyard-feature a /reindex skill for manual MCP reindexing
/request-apexyard-feature let /handover pick which docs to generate
/request-apexyard-feature a hook that warns on stale review markers
```

## Process

### 0. Write the active-issue-skill marker (REQUIRED — me2resh/apexyard#268)

```bash
ops_root="$(r=$PWD;while [ ! -f \"$r/onboarding.yaml\" ] && [ \"$r\" != / ];do r=${r%/*};done;echo $r)"
mkdir -p "$ops_root/.claude/session"
echo "request-apexyard-feature" > "$ops_root/.claude/session/active-issue-skill"
```

Remove the marker on **every** exit path (success, cancel, error):

```bash
rm -f "$ops_root/.claude/session/active-issue-skill"
```

### 1. Resolve the upstream repo

Always files **upstream**, regardless of the adopter's fork origin:

```bash
UPSTREAM=$(git remote get-url upstream 2>/dev/null \
  | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
UPSTREAM="${UPSTREAM:-me2resh/apexyard}"
```

If `$UPSTREAM` doesn't resolve to `me2resh/apexyard`, confirm with the user or
default to the canonical slug before filing.

### 2. Capture the framework version

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

**a) The problem / friction** — what's awkward or missing in the framework today? (the *why*, not the solution)

**b) Proposed behaviour** — what should the framework do? (new skill / hook / rule / agent / workflow change — name it concretely)

**c) Why it helps adopters** — who benefits and how; what they do instead today.

**d) Scope hint** (optional) — anything explicitly out of scope, or a rough size.

**e) Related** (optional) — existing skills/hooks it touches, related issue numbers.

### 4. Show the formatted issue for confirmation

Substitute into this body and display for `yes / edit / cancel`. **Re-scan for any
private project name before showing it.**

```
Here's the framework feature request I'll file to <UPSTREAM>:

---
**[Feature] {title}**

## Problem
{the friction / gap in the framework today}

## Proposed behaviour
{what the framework should do — new skill / hook / rule / agent / workflow}

## Why it helps adopters
{who benefits + how; what they do today instead}

## Scope / out of scope
{scope hint or "—"}

## Framework version
{FW_VERSION}

## Related
{touched skills/hooks + related issues, or "—"}

## Glossary
| Term | Definition |
|------|------------|
| {term} | {definition} |
---

Labels: enhancement
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
  --title "[Feature] {title}" \
  --label "enhancement" \
  --body "{formatted body}"
```

If the `enhancement` label doesn't exist upstream, drop `--label` and note it.

### 7. Return the URL

```
Filed upstream: <UPSTREAM>#{number} — {title}
{url}
```

## Rules

1. **One question at a time.** Never batch. Wait for each answer.
2. **Always confirm before filing.** Show the full issue, get explicit "yes".
3. **Scrub private project names** — this writes to a PUBLIC repo. See `.claude/rules/leak-protection.md`. Use the `<!-- private-refs: allow -->` marker ONLY on explicit user confirmation.
4. **Always file upstream** — `me2resh/apexyard`.
5. **Lead with the problem, not the solution** — the "why" makes a feature request actionable.
6. **Label `enhancement`.** Title prefix `[Feature]`.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
