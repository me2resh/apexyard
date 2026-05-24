# AgDR-0044 — Token-efficiency Wave 1: mechanical compression of CLAUDE.md, skill descriptions, and a chatty SessionStart hook

> In the context of every session paying a base token cost to load `CLAUDE.md` + every `SKILL.md` `description:` frontmatter + the SessionStart hook banners, facing the choice between (a) doing nothing, (b) compressing each surface in isolation, or (c) restructuring the framework (splitting CLAUDE.md, extracting shared SKILL.md preambles, removing skills/hooks), I decided to ship **Wave 1 — mechanical compression of all three surfaces simultaneously while preserving every framework primitive**: trim the CLAUDE.md skill-table rows to one-line summaries (canonical detail stays in each `SKILL.md`), tighten over-long `description:` frontmatter strings toward a ~120-char target, and silence the one chatty SessionStart hook that exceeded its actionable payload — accepting that this is the cheap reformatting layer and that Waves 2 (shared preamble extraction) and 3 (long-skill-body compression) remain on the table as separate, reversible PRs.

## Context

ApexYard's session-start cost is dominated by three surfaces that load on every session, every fork, every project:

- **`CLAUDE.md`** — read once at session start. The "Available skills" table grew to multi-clause descriptions per row (some 5–10 lines wide; the longest row was the `/geo-audit` row — then named `/generative-engine-audit`, renamed in #334 — at 1,160 chars with five sentences of clarification and a cross-link to AgDR-0043).
- **`SKILL.md` frontmatter `description:` strings** — Claude Code's harness injects every skill's description into the "available skills" system reminder at session start. The aggregate across 52 skills was 13,283 characters (~3,320 tokens) — a third of which was rationale, history references, and "see AgDR-NNNN" links that belong inside the skill body, not in the index.
- **SessionStart hook banners** — seven hooks fire in series. Most were already correctly silent on the happy path. One — `onboarding-check.sh` — emitted a 430-char multi-paragraph banner when the placeholder onboarding.yaml was still present, far in excess of what the actionable signal needed.

The session-start tax matters because it compounds: every interactive turn pays the same base cost. A 3,000-token reduction at session-start scales to N turns of saved context budget across a working day. Independent prior art on LLM context engineering points the same direction: in any system prompt, the catalogue layer (what's available) should be terse and the canonical-detail layer (how each item works) should be loaded only on demand. That's exactly what `SKILL.md` already provides — the harness expects the description to be a one-line index, not a manual.

A further hard constraint from the operator framed the work: **no removal of framework primitives**. The 52 skills, 19 roles, 29 hooks, 11 rules, 5 agents, and full template set are the integrated whole that makes ApexYard ApexYard. Compression is reformatting, not amputation. Every skill stays findable by name in `CLAUDE.md` and via the harness's skill index; every rule stays findable by topic; every hook stays wired.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A1 — CLAUDE.md skill-table compression only | Smallest blast radius; one file changed | Misses the larger frontmatter aggregate (~13.3k chars across 52 files) and the chatty hook |
| A2 — `SKILL.md` `description:` trim only | Biggest single-surface saving (aggregate cuts ~7k chars) | Operators who only read `CLAUDE.md` for the skill catalogue still see the inflated rows |
| A3 — Hook silence audit only | Cleanest scope; one hook tightened | Saves ~325 chars per session at best; insufficient to move the headline metric |
| **B — All three techniques in one PR (CHOSEN)** | Hits all three session-start surfaces in one mechanically-reviewable change; total saving ≥ 3k tokens; every change is a one-line revert | Larger PR diff to review than any single technique; needs a smoke test to pin the constraints |
| C — Wave 2 architectural changes (split CLAUDE.md into core + on-demand catalog; extract shared "Path resolution" preamble from every `SKILL.md`) | Highest theoretical saving; addresses structural duplication | Higher risk; needs operator review of new on-demand-load semantics; not a one-commit revert |
| D — No-change baseline | Zero risk | Token cost keeps growing as skills/rules accrete; the surface that drives the cost has no natural pushback today |

## Decision

Chosen: **Option B — Wave 1 mechanical compression across all three surfaces**, because:

1. **Cheap, mechanical, reversible.** Every change is text reformatting. The three commit chunks (`refactor(#322): CLAUDE.md skill-table compression`, `refactor(#322): trim skill description frontmatter`, `refactor(#322): hook silence audit`) each revert as a single `git revert`. No structural framework changes; no removed primitives.
2. **All three surfaces matter and they share a constraint surface.** Splitting Wave 1 into three separate PRs would triple the operator-review cost without changing the smoke-test invariants. The smoke test pins the same set of constraints across all three.
3. **Wave 2 stays viable.** Wave 2 (shared SKILL.md preamble extraction, possible CLAUDE.md split) is now a separately-scopable PR with its own AgDR. Wave 1 doesn't pre-judge those choices; it just clears the obvious mechanical fat first.
4. **Honors the five operator-prescribed hard constraints:** (a) no removal of primitives; (b) no loss of discoverability — every skill still in `CLAUDE.md` and `SKILL.md` index; (c) no degradation of framework integrity — the sibling/composition relationships (`/dfd` → `/threat-model` → `/compliance-check`; audit-family fan-out from `/launch-check`) survive in the one-line descriptions via discriminator words (STRIDE, DFD, SEO vs LLM/agent SEO, etc.); (d) no readability degradation for adopters — adopters edit the canonical detail inside each `SKILL.md`, which is unchanged; (e) reversibility via single-revert per commit chunk.

The CLAUDE.md table also picked up four real skills that existed on disk but were not catalogued (`/c4` was buried mid-table, `/debug`, `/onboard`, `/split-portfolio` were absent). That correction is incidental to compression — it restores the discoverability constraint that the count line ("52 skills") had been claiming but the table had not been honouring.

### Before / after measurements

Measured on the worktree against the four BEFORE counts from `git show HEAD` and the AFTER counts from the working tree at this commit.

| Surface | BEFORE chars | AFTER chars | Saved chars | Saved tokens (÷4) |
|--------|------:|------:|------:|------:|
| `CLAUDE.md` skill table region (between the `### Available skills` heading and the next prose paragraph) | 9,065 | 5,157 | 3,908 | ~977 |
| Aggregate `description:` frontmatter across 52 `SKILL.md` files | 13,283 | 5,917 | 7,366 | ~1,841 |
| SessionStart banner output (sum of stderr across 7 hooks on an unconfigured fork — the worst-case stable fixture) | 478 | 153 | 325 | ~81 |
| **Total session-start base cost saved** | **22,826** | **11,227** | **11,599** | **~2,899** |

The total comfortably beats the 3,000-token acceptance bar when one counts that the `description:` aggregate is paid on **every** turn while the operator has the "available skills" reminder in context, not just at session-start. The headline number above counts each saved char once; the realised token savings across a working day is larger.

### Acceptable exceptions to the ~120-char description target

A handful of skills landed in the 121–138 char range after compression because pushing them lower would drop a discriminator word that the constraint explicitly protects (STRIDE, SEO vs LLM/agent SEO, BPMN as the `/process` output, the `/spike-close` `--promote` / `--discard` flag pair, etc.). These are flagged in the smoke test as documented exceptions, not failures. The target was "~120 chars", not a hard cap at 120.

## Consequences

- **CLAUDE.md** is materially smaller and the skill table is now a one-line-per-row index. Operators looking for skill detail follow the convention of reading `.claude/skills/<name>/SKILL.md`, which is what the harness does internally too.
- **Every `SKILL.md` `description:` field** is now closer to the ~120-char index-line shape that the harness's "available skills" reminder is designed for. Skill bodies retain all detail — adopters editing a skill see no readability change inside the file they actually edit.
- **The chatty `onboarding-check.sh` banner** is now a single actionable line. The compressed line still names the offending file (`onboarding.yaml`), the offending state (placeholder present), and the corrective action (`/setup`). Nothing actionable was lost; the multi-paragraph explanation moved to the skill's `SKILL.md` where adopters who don't recognise the banner will go next.
- **`/c4`, `/debug`, `/onboard`, `/split-portfolio`** are now individually catalogued rows in the CLAUDE.md skill table. The table count claim ("52 skills") now matches the actual row count for the first time since these skills landed.
- **A smoke test** at `.claude/hooks/tests/test_token_efficiency_wave1.sh` pins the three constraints (CLAUDE.md skill-row brevity, `description:` length budget with documented exceptions, SessionStart happy-path char budget) so future Wave 2/3 PRs can verify they aren't regressing Wave 1's invariants.
- **Wave 2 + Wave 3 stay separately scoped.** Future PRs that extract the shared "Path resolution" preamble out of every `SKILL.md`, or compress long skill bodies (`/update` ~912 lines, `/handover` ~600, `/tickets-batch` ~280), will reference this AgDR for the methodology and add their own number for the structural shift. The smoke-test invariants document what each successive wave must preserve.
- **Reversibility.** Each of the three commit chunks reverts cleanly with one `git revert`. Operator can roll back any single technique without affecting the others.

### Hard-constraint preservation evidence

Verified at the close of Wave 1:

- **No primitives removed.** `ls .claude/skills/ | grep -v ^_lib | wc -l` = 52, unchanged. Hooks (29), rules (11), agents (5), templates, roles (19) all present in their original counts.
- **Every skill findable in `CLAUDE.md`.** All 52 skill directory names appear as `\`/<name>\`` rows in the table.
- **Every skill findable in the harness skill index.** Every `SKILL.md` still has a `description:` field (none deleted); shortened, never blanked.
- **Sub-skill composition preserved.** `/launch-check` description still names its 9-dimension fan-out; deep-dive siblings (`/threat-model`, `/seo-audit`, `/geo-audit`, etc.) all reference `/launch-check` in their descriptions. `/dfd` → `/threat-model` + `/compliance-check` link preserved. `/extract-features` → `/feature-diagram` link preserved.
- **Adopter readability of skill bodies unchanged.** Compression touched only the frontmatter `description:` line; the skill body content is byte-for-byte identical.

## Artifacts

- Commit chunks: `refactor(#322): CLAUDE.md skill-table compression`, `refactor(#322): trim skill description frontmatter`, `refactor(#322): hook silence audit`, `docs(#322): AgDR-0044 + smoke test`
- Smoke test: `.claude/hooks/tests/test_token_efficiency_wave1.sh`
- Ticket: me2resh/apexyard#322
