<!-- Source: ApexYard · templates/tickets/prototype.md · github.com/me2resh/apexyard · MIT -->

**[Prototype] {title}**

## Direction Question

{The single "what should this look and feel like?" question the prototype
answers. One sentence. A prototype explores a UX/demo direction, NOT
technical feasibility — if the question is "will this work?", file a
`/spike` instead.}

## Fidelity

{What kind of disposable artifact this is and how far it goes. Examples:}

- Clickable mockup (Figma export / static HTML, no real backend)
- Demo flow (wired screens, stubbed data, happy-path only)
- Interactive proof-of-concept UI (real framework, fake everything else)

{The author commits: this is a throwaway artifact for learning a
direction, not the start of production code.}

## Budget

{Hard cap on time/effort. Examples:}

- 1 day of one engineer
- 2 days, then we decide
- Until the stakeholder demo on Friday

{At the budget cap, the prototype ENDS regardless of polish.}

## Disposition

{What happens when the prototype closes. Author commits to ONE in advance —
"decide later" is not allowed; that's how a throwaway mockup gets
accidentally promoted into production:}

- **PROMOTE** — the direction is chosen; file a fresh `[Feature]` ticket
  for production-shaped delivery. The prototype artifact is NOT lifted into
  production — the feature re-implements based on the chosen direction.
- **DISCARD** — the direction is rejected (or "not now"); write a memo at
  `docs/prototype-memos/<slug>.md` so future-us doesn't re-explore the same
  ground.

## Approach (optional)

{Brief sketch of what you'll mock up. NOT a tech design. NOT a PRD. A few
bullet points: which screens / flows, what tools (Figma, static HTML,
v0, the real framework with stubs), what you're deliberately faking.}
