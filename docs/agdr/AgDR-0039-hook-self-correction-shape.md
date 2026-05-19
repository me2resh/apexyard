# Standardised self-correction guidance shape for blocking hooks

> In the context of ApexYard's 17 blocking PreToolUse hooks, facing the failure mode that some hooks ship gold-standard "BLOCKED → context → numbered next-action list" error messages (e.g. `require-active-ticket.sh`, `validate-commit-format.sh`) while others ship a single-line `BLOCKED: <reason>` with no recovery path (e.g. `check-secrets.sh`, `block-git-add-all.sh`), I decided to standardise on the gold-standard heredoc shape with a canonical `To unblock:` numbered list, to achieve consistent agent self-correction across every block, accepting that retrofitting all 17 hooks is multi-PR work and is being staged.

## Context

Per Böckeler's [harness-engineering framing](https://martinfowler.com/articles/exploring-gen-ai/harness-engineering-for-coding-agent-users.html), the highest-leverage tactic for improving inferential agents' self-correction is to embed **structured next-action guidance directly in sensor error messages** — what she calls "a good kind of prompt injection." When an agent hits a blocking hook, the difference between `BLOCKED: secret detected. Use env vars instead.` and `BLOCKED: secret detected. To unblock: 1. Move the value to .env, 2. Add to gitignore, 3. Reference via process.env, 4. Re-stage, 5. Retry.` is the difference between the agent thrashing for two or three attempts and the agent recovering on the first try.

ApexYard's hooks are an uneven mix today:

| Gold-standard already | Underweight (this ticket's scope) |
|---|---|
| `require-active-ticket.sh` | `check-secrets.sh` |
| `require-migration-ticket.sh` | `block-git-add-all.sh` |
| `validate-commit-format.sh` | `block-main-push.sh` |
| `validate-pr-create.sh` | `validate-branch-name.sh` |
| `verify-commit-refs.sh` | (more in follow-up PRs) |
| `require-agdr-for-arch-pr.sh` | |
| `require-skill-for-issue-create.sh` | |
| `block-merge-on-red-ci.sh` | |
| `block-unreviewed-merge.sh` (main case) | |

The gold-standard ones already work well. The underweight ones leave the agent with no concrete recovery path beyond the one-line summary, which forces either an extra round-trip to the operator or a guess-and-retry loop. Both burn tokens and human attention.

The standardised shape also matters for **future hooks** — once the convention is documented, every new hook ships with the right error-message shape from day one, rather than re-litigating the question per PR.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| **A. Standardise on a heredoc shape with `To unblock:` numbered list** (chosen) | Matches the existing gold-standard hooks; canonical phrasing across all 17; explicit next-actions per Böckeler's design principle; one shape to learn for future hook authors | Multi-PR work to retrofit all 17; small risk of a hook author writing too-verbose guidance |
| **B. Keep per-hook variation, document a "minimum bar" instead** | Lighter touch — only specifies the floor, not the shape | Doesn't solve the variation problem; future hooks still freelance; no canonical phrase means inconsistent agent-side parsing |
| **C. Move all guidance out of the hook into a separate "recovery hint" file Rex reads on block** | Decouples hook code from prose; easier to update guidance without re-deploying hooks | Adds indirection at the worst possible moment (the agent has just been blocked and needs the recovery path NOW); two files to keep in sync; complicates testing |
| **D. Let the agent figure out recovery without explicit guidance** | Zero per-hook authoring cost | Token cost compounds — every block triggers an agent search instead of pointing at the answer; cf. the actual evidence from existing sessions |

## Decision

Chosen: **Option A — heredoc shape with `To unblock:` numbered list**.

### The standard shape

Every blocking hook's error message follows this template:

```
BLOCKED: <one-line summary of the violation>

<1-3 lines of context: which rule fired, where it lives, why this matters>

To unblock:
  1. <first concrete action — name a skill, a command, a file edit, or a marker>
  2. <second action if the first isn't sufficient>
  3. <retry the original operation>

<Optional: escape hatch / customisation pointer — 1-2 lines>
```

### The contract per section

- **BLOCKED line**: one sentence, present tense, names the violation. No emoji, no exclamation. Plain `BLOCKED:` prefix so log-grep stays trivial.
- **Context**: enough to identify which rule fired and (where applicable) where the rule lives in `.claude/rules/`. The agent uses this to decide whether the rule is genuinely the issue or whether something else is in play.
- **To unblock**: numbered list of **concrete actions**. Each entry names a skill (`/start-ticket`), a command (`git rebase main`), a file edit (`add path/to/file to .gitignore`), or a marker (`write .claude/session/reviews/<pr>-ceo.approved`). **Not** "fix the issue" or "address the violation" — those force the agent to guess.
- **Escape hatch**: when there's a legitimate-but-rare bypass (false-positive on `check-secrets.sh`, override of `protected_branches` in project-config), document the bypass at the end. Keep it short — the goal is to make the bypass visible, not to encourage it.

### Canonical phrasing

The phrase **`To unblock:`** is canonical. Prior hooks variously used `To proceed:`, `To self-correct:`, and `To unblock:` — picking one for grep-ability and operator habit-formation. `To unblock:` won because:

- "Proceed" sounds like the violation is optional; the gate is blocking, not advisory
- "Self-correct" anthropomorphises the agent in a way that's true but slightly off (the gate isn't asking the agent to correct itself; it's specifying actions to remove the block)
- "Unblock" is mechanically accurate and matches the operator's natural framing

## Consequences

### Positive

- Every block message gives the agent (and the operator) a concrete, actionable next step.
- Future hook authors have a canonical template; no debate per PR about message format.
- Inferential-agent token cost on blocks drops — the agent doesn't have to search for the recovery path.
- The framework dogfoods Böckeler's "good kind of prompt injection" principle.

### Negative

- Retrofitting all 17 blocking hooks is multi-PR work. This first PR ships the shape + 5 high-impact underweight hooks (`check-secrets.sh`, `block-git-add-all.sh`, `block-main-push.sh`, `validate-branch-name.sh`, `require-active-ticket.sh`'s phrasing tweak). The remaining underweight hooks are tracked as a follow-up.
- Slightly longer error messages — each block message grows from ~3 lines to ~12-15. Acceptable; the cost of an under-informed block is one agent-thrash cycle, far worse than the read cost of a richer message.

### Out of scope for this AgDR

- Programmatic enforcement of the shape (a meta-hook that lints hook error messages) — overkill for a 17-hook surface.
- Translating the shape into other formats (e.g. JSON for IDE integrations) — current consumers (Claude agent + human operator) both prefer prose.
- Changes to which hooks block vs which are advisory — orthogonal.

## Artifacts

- PR me2resh/apexyard#301 — the shape definition + 5 hook retrofits (this work)
- Ticket me2resh/apexyard#295 — feature/ticket spec
- Reference: Böckeler, ["Harness engineering for coding agent users"](https://martinfowler.com/articles/exploring-gen-ai/harness-engineering-for-coding-agent-users.html), 2026-04-02 (the "good kind of prompt injection" idea)
- Reference: Böckeler, ["Maintainability sensors for coding agents"](https://martinfowler.com/articles/exploring-gen-ai/maintainability-sensors.html), 2026-05-19 (the custom-formatter pattern for ESLint that inspired this)
