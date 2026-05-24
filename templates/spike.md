<!-- Source: ApexYard · templates/spike.md · github.com/me2resh/apexyard · MIT -->

**[Spike] {title}**

## Hypothesis

{The single specific question this spike answers. One sentence. If you
can't write it as "we believe X. We will know we're right when Y", the
spike isn't ready.}

## Budget

{Hard cap on time/effort. Examples:}

- 2 days of one engineer
- 1 sprint
- Until end of week

{The author commits: at the budget cap, the spike ENDS regardless of outcome.}

## Kill Criteria

{The specific conditions under which the spike STOPS early without
completing, either because the answer is in or because pursuing further is
wasted. Examples:}

- "Library X has no TypeScript types and we'd have to write them — kill,
  too much yak-shave for a spike"
- "Auth provider Y returns 401 on the first integration test — kill,
  prove it's solvable elsewhere first"

## Disposition

{What happens when the spike closes. Author commits to ONE in advance —
"decide later" is not allowed; that's how spike code rots into half-shipped
production:}

- **PROMOTE** — file a fresh `[Feature]` ticket with production-shaped
  delivery, port the relevant findings.
- **DISCARD** — delete the spike branch, file an AgDR-style memo with
  what we learned (so future-us doesn't re-explore the same ground).

## Approach (optional)

{Brief sketch of the exploration plan. NOT a tech design. NOT a PRD. A
few bullet points: what's the smallest test, what tools we'd need, what
boundary we'd cross to fail-fast.}
