---
name: challenge
description: Invoke The Contrarian (Naqid) to steelman-then-challenge an idea, feature, decision, or plan — surfaces assumptions, failure modes, and alternatives. Advisory only; never blocks a gate.
argument-hint: "<idea | #N | path/to/doc | 'the plan'>"
---

# /challenge — Stress-test the premise with The Contrarian

`/challenge <target>` spawns the **Contrarian** agent (Naqid) to adversarially challenge an idea *before* you commit build effort to it. It is the premise-level analog of `/code-review` (Rex), `/security-review` (Hakim), and `/design-review` (Tariq) — but where those review **built artifacts** and gate a merge, the Contrarian challenges **whether the idea is right at all** and is **advisory-only**: it never writes a marker, never blocks a gate. The call stays yours.

This is the operational tool for the "play devil's advocate" reflex — made a first-class, repeatable move instead of an ad-hoc prompt.

## When to use it

- Before writing a spec or filing an epic — pressure-test the idea while it's cheap to change.
- Before a big technical decision (`/decide`) — surface the assumptions and the cheaper alternative.
- Before committing to a multi-step plan — find the load-bearing assumption that, if wrong, sinks the plan.
- Any time you catch yourself agreeing with an idea too easily — that's exactly when an adversary earns its keep.

## Usage

```
/challenge add a second database to handle reporting load
/challenge #345
/challenge projects/apexbrain/prd.md
/challenge the plan
```

The argument is free-form. Step 1 normalises it into a concrete target for the agent.

## Process

### 1. Resolve the target

Classify the argument:

| Argument shape | Target the agent receives |
|----------------|---------------------------|
| `#N` or `owner/repo#N` | The ticket — instruct the agent to `gh issue view <N>` and challenge it. |
| A path ending `.md` (or under `projects/`, `docs/`, `prds/`, `designs/`) that exists | The document — the agent reads it and challenges it. |
| `the plan` / `this plan` | The most recent multi-step plan presented in the conversation — pass it inline to the agent. |
| Anything else (free text) | An idea stated in the conversation — pass the idea text (plus relevant conversation context) inline to the agent. |

If the argument is empty, ask: `What should I challenge? An idea, a ticket #N, a doc path, or "the plan"?`

### 2. Spawn the Contrarian

Invoke the agent via the Agent tool with `subagent_type: contrarian`, handing it the resolved target plus enough context to ground itself (the idea text / ticket ref / doc path). Instruct it to follow its steelman-first method and return its structured output. The agent is read-only; it will not modify anything.

```
Agent(subagent_type: "contrarian", prompt: "Challenge the following <idea|ticket|doc|plan>: <resolved target + context>. Steelman it first, then work the full challenge lens, and return your structured verdict.")
```

### 3. Relay the verdict

Present the agent's structured output verbatim (Steelman · Hidden assumptions · Failure modes · Strongest objections · Cheaper alternatives · What would have to be true · Verdict). Do **not** soften or editorialise it — the value is the unfiltered adversarial read.

Then, in one line, note the next move the verdict implies — e.g. *"Verdict: reconsider — the cheaper alternative (a read replica) likely gets 80% of the value; want me to spec that instead?"* — and let the operator decide. Never auto-act on a `reconsider`; surface it and stop.

## Rules

1. **Advisory only.** This skill never writes an approval marker, never runs a merge, never blocks a gate. It produces an opinion, full stop.
2. **One target per invocation.** Challenging two unrelated things at once muddies the verdict — run it twice.
3. **Relay, don't dilute.** Present the Contrarian's objections as-is. If you disagree, say so as a separate note; don't edit the agent's verdict.
4. **The call stays human.** A `reconsider` verdict is input, not a stop order. Surface it and let the operator choose.
5. **Not a substitute for the gates.** The Contrarian challenges the premise; Rex / Hakim / Tariq still review the built artifact. Passing a challenge is not passing review.

## Glossary

| Term | Definition |
|------|------------|
| The Contrarian (Naqid) | The advisory agent that steelmans then adversarially challenges an idea/decision. |
| Steelman | Stating the strongest honest version of an argument before critiquing it. |
| Premise-level review | Challenging *whether/what* to build, as opposed to reviewing *how* it was built. |

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
