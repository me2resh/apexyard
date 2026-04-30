# Technical Decisions — AgDR Required

**HARD STOP**: before making any technical decision, run `/decide` and create an Agent Decision Record (AgDR).

## Trigger Patterns — STOP if you catch yourself doing these

If you are about to:

- Say "I'll use X" or "Let's go with X" → STOP, run `/decide` first
- Compare "X vs Y" or "X or Y" → STOP, run `/decide` first
- Choose a library, framework, or tool → STOP, run `/decide` first
- Pick an implementation approach → STOP, run `/decide` first
- Make an architectural choice → STOP, run `/decide` first

## Real-Time Decision Detection

Before writing any code or config, scan your planned response for:

| Pattern in your response | Decision type | Action |
|--------------------------|---------------|--------|
| "I'll create a workflow that…"          | CI/CD design | `/decide` |
| "We'll use GitHub Actions / CircleCI…"  | CI platform | `/decide` |
| "The keystore will be stored in…"       | Security/infra | `/decide` |
| Adding dependencies to build files       | Library choice | `/decide` |
| Creating new architecture (modules, layers) | Architecture | `/decide` |
| "I'll implement the X pattern…"         | Design pattern | `/decide` |
| Setting up signing / release / deployment | Release strategy | `/decide` |

**Test yourself**: if someone asked "why did you choose X over Y?", would you need to explain trade-offs? If yes → `/decide` first.

## Self-Check Before the Build Phase

```
[ ] Did I make any technical decisions?     YES → AgDR exists for each?
[ ] Did I choose between options?           YES → AgDR exists?
[ ] No AgDR for a decision I made?          → Create it NOW before proceeding
```

## Self-Check During Implementation

```
[ ] Am I about to write code that introduces a new pattern?   → STOP, /decide
[ ] Am I adding new dependencies?                             → STOP, /decide
[ ] Am I creating CI/CD or infra config?                      → STOP, /decide
[ ] Am I designing something that has alternatives?           → STOP, /decide
```

## What `/decide` Does

Creates an **Agent Decision Record** (AgDR) that captures:

- What options were considered
- Why the chosen option was selected
- Context that influenced the decision

**AgDRs are stored at**: `{project}/docs/agdr/AgDR-NNNN-{slug}.md`. Each project has its own folder and its own ID sequence.

## Enforcement

1. **Real-time self-check** — scan every response for decision patterns before writing code
2. **Workflow gate** — AgDR required before the Build phase for new features
3. **Code Reviewer** — flags PRs with architecture changes that don't link an AgDR
4. **Pre-commit hook** — warns if architecture files changed without an AgDR reference
