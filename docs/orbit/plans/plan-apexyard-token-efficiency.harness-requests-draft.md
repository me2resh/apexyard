# Harness requests draft — plan-apexyard-token-efficiency ac2-4

Owner approved all four on 2026-10-19. They are filed:

1. Skill-body dedupe: https://github.com/anthropics/claude-code/issues/103425
2. Fork from a compacted parent, or with a context budget: https://github.com/anthropics/claude-code/issues/88841#issuecomment-6265152676
3. Names-only re-injection after compaction: https://github.com/anthropics/claude-code/issues/82144#issuecomment-6265151741
4. No skill listing for agents without the Skill tool: https://github.com/anthropics/claude-code/issues/103426

Aggregate numbers only. Leak scrub completed per
`.claude/rules/leak-protection.md` (no private project name, no local path,
no username).

Baseline source: framework token-cost baseline dated 2026-10-10
(`docs/perf/token-cost-baseline-2026-10-10.md`). Subagent `skill_listing`
byte count measured once from a local Claude Code subagent transcript
(attachment `type=skill_listing`, UTF-8 byte length of the `content` field).

| Aggregate | Value |
|---|---|
| Main context per turn mean / p90 | 489,792 / 849,914 |
| Compactions (near the cap) | 18 (12) |
| skill-body share of context-turns | 24.86% |
| skill-reinjection share of context-turns | 10.35% |
| Fork subagents (n=2): first-turn median / max | 430,256 / 580,938 |
| Fork subagents total tokens | 160,479 |
| Subagent `skill_listing` content bytes (one sample) | 30,077 |

---

## 1. Skill-body dedupe inside one context window

**Title:** Deduplicate skill bodies already present in the current context window

**Problem:** When a skill is invoked more than once in the same context window,
or when a skill body is still resident after an earlier load, the harness can
inject the full body again. In the 2026-10-10 baseline, skill-body alone was
24.86% of context-turns. Re-injecting a body that is already in the window
adds tokens with no new information.

**Measured aggregate numbers:**

- skill-body share of context-turns: 24.86% (est. 2,025,697 tokens)
- Top skill by injection count: `/approve-merge` — 210 injections, mean body
  33,688 bytes
- Main context mean per turn: 489,792 tokens

**Proposed behaviour:** Before injecting a skill body, check whether that
skill's body (or an equivalent content hash) is already present in the current
context window. If it is, inject a short stub that names the skill and points
at the earlier load instead of the full body.

**Existing issue:** none found
(searched `anthropics/claude-code` for skill-body dedupe / duplicate skill
injection / skill already loaded in context; no matching open or closed issue).

---

## 2. Fork from a compacted parent, or a fork with a context budget

**Title:** Let a fork start from a compacted parent, or cap fork inherited context

**Problem:** A fork inherits the parent's full conversation. In the 2026-10-10
baseline, two fork subagents started at 430,256 median and 580,938 max
first-turn context and used 160,479 tokens in total. That is low-spend hygiene
relative to the main loop, but each fork still replays a large parent context
even when a written brief would suffice.

**Measured aggregate numbers:**

- Fork runs: 2
- First-turn context median / max: 430,256 / 580,938
- Total tokens across those forks: 160,479
- Main context mean for comparison: 489,792

**Proposed behaviour:** Either (a) allow a fork to start from the parent's
post-compaction summary rather than the full parent transcript, or (b) accept
an explicit context budget on the fork spawn so inherited history is truncated
to that budget. Fresh spawns with a written brief remain the default for work
that does not need parent-only facts.

**Existing issue:** comment on
https://github.com/anthropics/claude-code/issues/88841
(best match: token cost visibility and guardrails for subagent fork context
inheritance). Add the aggregate numbers above as a comment; do not open a
duplicate.

---

## 3. Re-injection of skills as names only after compaction

**Title:** After compaction, re-inject skill names only — not full bodies

**Problem:** After auto-compaction, the harness re-injects previously invoked
skills. In the 2026-10-10 baseline, skill-reinjection was 10.35% of
context-turns. Full-body re-injection rebuilds cost that compaction just
removed.

**Measured aggregate numbers:**

- skill-reinjection share of context-turns: 10.35% (est. 436,091 tokens)
- Compactions in the measured session: 18 (12 near the cap)
- Compaction mean pre / post tokens: 800,830 / 53,732
- `/approve-merge` alone: 18 compaction re-injections at mean body 33,688 bytes

**Proposed behaviour:** After compaction, re-inject a name-only listing of
skills invoked earlier in the session (name + one-line description). Load a
full body again only when the model invokes that skill.

**Existing issue:** comment on
https://github.com/anthropics/claude-code/issues/82144
(best match: post-compaction skill re-injection costs ~4× the compaction
summary; full bodies, byte-truncated, cumulative). Related correctness reports
exist (#83306, #85138, #25994); prefer the cost-focused issue for this ask.
Add the aggregate numbers above as a comment; do not open a duplicate.

---

## 4. No skill listing for agents that lack the Skill tool

**Title:** Omit the skill listing attachment for agents that have no Skill tool

**Problem:** Subagents receive a `skill_listing` attachment even when the agent
type has no Skill tool and cannot invoke skills. One measured subagent
transcript carried a `skill_listing` content field of 30,077 UTF-8 bytes
(~138 listed skill lines). That listing is dead weight for a reviewer or build
agent that cannot use it.

**Measured aggregate numbers:**

- One subagent `skill_listing` content field: 30,077 UTF-8 bytes
- Method: parse one local Claude Code subagent transcript JSONL line whose
  `attachment.type` is `skill_listing`; take `len(content.encode("utf-8"))`
- Attachment JSON (type + content) was 32,847 UTF-8 bytes for the same sample
- The 2026-10-10 o1 script classifies `skill_listing` only on the main loop
  (post-compaction harness); it has no per-category subagent view for this
  attachment

**Proposed behaviour:** When spawning an agent whose tool set does not include
Skill, omit the `skill_listing` attachment. Keep the listing for agents that
can invoke skills.

**Existing issue:** none found
(searched `anthropics/claude-code` for skill listing on subagents / agents
without the Skill tool / Available skills injected into subagents; no matching
issue).

---

## Leak scrub statement

Manual scrub completed against `.claude/rules/leak-protection.md` before this
file was written. This draft names no registered private project, no local
filesystem path, and no username. Aggregate measurements only.
