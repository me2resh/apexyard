---
name: decide
description: Make a technical decision with structured reasoning and create an Agent Decision Record (AgDR).
disable-model-invocation: false
argument-hint: "<what you're deciding>"
---

## Writing rule

When this skill writes a durable artifact, read .claude/rules/writing-standard.md. Use the controlled technical writing profile.

# /decide — Technical Decision Gate

Forces structured decision-making and creates an auditable Agent Decision Record (AgDR).

## Activated role

When `/decide` runs, activate the **[Tech Lead](../../../roles/engineering/tech-lead.md)** role — they own technical decisions within their domain. For decisions that cross the architecture-review threshold (new service, new tech stack, new external integration, major data model change), escalate to the **[Head of Engineering](../../../roles/engineering/head-of-engineering.md)** before creating the AgDR.

If the decision touches auth / crypto / secrets / PII, also involve the **[Security Auditor](../../../roles/security/security-auditor.md)** for sign-off on the security implications before finalising the choice.

See [`.claude/rules/role-triggers.md`](../../rules/role-triggers.md) for the full activation protocol.

## Process

### 1. Parse the Decision Topic

Extract the decision topic from `$ARGUMENTS`. If unclear, ask:

```
What technical decision do you need to make?
```

### 2. Gather Context

Identify decision-relevant context only:

- What problem are we solving?
- What constraints exist?
- What's already in the codebase?

### 3. List Options

Present 2–4 options in a table:

```markdown
| Option | Pros | Cons |
|--------|------|------|
| Option A | … | … |
| Option B | … | … |
```

### 4. Make the Decision

State the chosen option with justification.

### 5. Generate the AgDR

Create file at `{project-root}/docs/agdr/AgDR-{NNNN}-{slug}.md`.

**Important**: AgDRs live in the **current project's repository**, not centralised. Each project has its own `docs/agdr/` folder and its own ID sequence.

Resolve the AgDR template via the portfolio helper so adopter overrides win when present:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
template=$(portfolio_resolve_template agdr.md)   # → custom-templates/agdr.md if present, else templates/agdr.md
```

Single-fork adopters (no `portfolio` block) and adopters with no override fall straight through to `templates/agdr.md`. Adopters who want a customised AgDR shape drop their version at `<private_repo>/custom-templates/agdr.md`. See `templates/README.md` for the path-mirroring convention.

The skeleton:

```markdown
---
id: AgDR-{NNNN}
timestamp: {ISO-8601: YYYY-MM-DDTHH:MM:SSZ}
agent: {current-agent-name or "claude"}
model: {model-id from environment}
trigger: {user-prompt | hook | automation}
status: executed
---

# {short title}

> In the context of {context}, facing {concern}, I decided {decision} to achieve {goal}, accepting {tradeoff}.

## Context
{Decision-relevant context only — 2–4 bullets}

## Options Considered
| Option | Pros | Cons |
|--------|------|------|
| … | … | … |

## Decision
Chosen: **{option}**, because {justification}.

## Consequences
- {consequence 1}
- {consequence 2}

## Artifacts
- {commit / PR links when available}
```

### 6. Get the Next ID

Use a filesystem lock while scanning and reserving the next ID. This prevents
two concurrent `/decide` runs from selecting the same number.

```bash
# Use the main worktree's shared Git directory so linked worktrees serialize
# allocation together.
git_common_dir=$(git rev-parse --path-format=absolute --git-common-dir)
ops_root=$(dirname "$git_common_dir")
lock_dir="${APEXYARD_AGDR_LOCK_DIR:-$ops_root/.claude/session}/agdr-id.lock"
while ! mkdir "$lock_dir" 2>/dev/null; do sleep 1; done
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
reservation_dir="${APEXYARD_AGDR_RESERVATION_DIR:-$ops_root/.claude/session/agdr-reservations}"
mkdir -p "$reservation_dir"
last=$(find docs/agdr "$reservation_dir" -maxdepth 1 -type f \( \
    -name 'AgDR-[0-9][0-9][0-9][0-9]-*.md' -o -name 'AgDR-[0-9][0-9][0-9][0-9]' \) -print \
  | sed -E 's#^.*/AgDR-([0-9]{4})(-.*)?$#\1#' | sort -n | tail -1)
next=$(printf '%04d' $((10#${last:-0} + 1)))
# Reserve the ID before writing the record. The reservation is shared by all
# linked worktrees and remains after a worktree is removed.
while ! (set -C; : > "$reservation_dir/AgDR-${next}") 2>/dev/null; do
  next=$(printf '%04d' $((10#$next + 1)))
done
# Keep the reservation until the AgDR file is committed.
```

Keep the lock until the AgDR file is created. If the candidate exists after
the scan, increment and check again. Do not delete a reservation after the
AgDR is written; it prevents another branch from reusing the identifier.

### 7. Offer a Contrarian challenge (optional — opt-in, never forced)

A decision is a high-stakes moment. After drafting the AgDR, surface a **one-line
nudge** offering to stress-test the call before committing:

```
Recorded AgDR-{NNNN}. Want Naqid (The Contrarian) to challenge this first?
Run `/challenge {topic}` — he steelmans it, then attacks hidden assumptions,
failure modes, and cheaper alternatives. Advisory — it never blocks.
```

Rules for the offer:

- **Opt-in only.** Never auto-run `/challenge`; the operator decides.
- **Advisory only.** Its verdict informs; it never vetoes or gates the decision.
- **Fold the result back.** If the operator runs it and the verdict shifts the
  call, update the AgDR's Decision / Consequences to reflect the new reasoning and
  note the challenge under Artifacts.

This mirrors the advisory stance in [`.claude/rules/role-triggers.md`](../../rules/role-triggers.md)
§ "Optional advisory offer" — see `.claude/skills/challenge/SKILL.md` and AgDR-0078.

### 8. Return the Decision

```
Decision: {chosen option}
AgDR-{NNNN} created at docs/agdr/AgDR-{NNNN}-{slug}.md
Proceeding with: {brief action}
```

## Rules

1. **Always create an AgDR** — no decision without a record
2. **Y-statement required** — one-line summary at the top
3. **Options table required** — at least 2 options compared
4. **Justification required** — `because` clause is mandatory
5. **Timestamp precise** — full ISO-8601 with time
6. **Slug from title** — lowercase, hyphens, max 50 chars
7. **Offer a challenge** — after drafting the AgDR, offer `/challenge` (opt-in,
   advisory, never auto-run); update the AgDR if the verdict shifts the call

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
