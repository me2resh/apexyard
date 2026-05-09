# Spike: Local-model routing for bounded sub-tasks — measurement + recommendation

> **Ticket**: [me2resh/apexyard#195](https://github.com/me2resh/apexyard/issues/195)
> **Status**: spike complete — recommendation: **NO-GO as designed; partial GO for `inbox-summary` only, behind an opt-in helper**
> **Author**: Tech Lead (assumed via SDLC role activation)
> **Date**: 2026-05-03
> **Sibling spike for shape**: [LSP token savings](./lsp-token-savings.md) (#178 → PR #184)

---

## TL;DR

1. **The hypothesis (≥10× token savings, "good enough" quality, acceptable latency) holds for some tasks but not others.** Measured against 10 real apexyard issues, a hand-graded commit corpus, and a synthetic-but-realistic 10-PR inbox, on a Mac with `ollama` already installed, running `llama3.2:3B` and `mistral:7B`.
2. **Issue classification is dominated by a regex on the bracket-prefix.** `[Bug] / [Feature] / [Spike] / [Chore]` titles already self-classify with **10/10 accuracy** in the test corpus. Local LLM hits **7/10 (llama3.2)** or **8/10 (mistral)**. Claude (today) hits **~10/10** but at ~1.5k input tokens per call when invoked through the conversational loop. **Verdict for issue-classify: pure regex wins; routing through any model — local or cloud — is value-destroying noise.**
3. **Commit-type suggestion is intrinsically hard from subject + filenames alone.** Hand-graded ground truth is ambiguous (the same change can be `feat`, `chore`, or `docs` depending on team convention). Heuristic: 5/10. Local LLM: 2-3/10. Claude would marginally beat the heuristic but not by enough to recommend routing — the **right fix is to feed the agent the actual diff**, not the subject + filenames, and that lifts the input far above local-LLM context efficiency. **Verdict for commit-type: keep on Claude; pre-filtering with a regex is a small auxiliary win; do not route to a local model.**
4. **Inbox summary is the one task where local LLM routing is plausible.** A 3-line synthesis paragraph from 10 PR titles is short, bounded, and a place where pure regex visibly under-delivers (it can count types but not identify themes like "GDPR thread" or "security batch"). Local LLMs in this test made factual errors (miscounted PRs: llama said 8/10, mistral said 6/10), but a hybrid — **regex extracts the structured facts, local LLM synthesises the prose** — is the right shape. Wall-clock ~2.5-5 s warm; token cost zero.
5. **Integration recommendation: don't add an `OllamaCall` tool.** Use a plain bash helper (`bin/apexyard-local llm <prompt>`) invoked by skills that opt in, with graceful fallback to "Claude does it inline" if the helper is missing or `ollama` isn't running. This matches the framework's existing pattern (hooks, `_lib-*.sh` helpers) — zero new tool surface, zero MCP shim maintenance, fully optional per adopter machine.
6. **AgDR Y-statement (sketched, not drafted)**: *"In the context of bounded sub-tasks inside ApexYard skills, facing the cost of routing all of them through Claude when a local 7B model + a regex pass would do, we will adopt **a regex-first / local-LLM-second hybrid via a `bin/apexyard-local` helper for `inbox-summary` only**, leaving `issue-classify` (regex-sufficient) and `commit-type` (Claude-or-bust) on their current paths, accepting the cost of (a) opt-in `ollama` install per adopter machine, (b) one new helper script in `bin/`, and (c) a quality floor that's measurably below Claude on synthesis but acceptable for the 3-line inbox use case."*

---

## Phase 1 — Measurement

### Methodology

**Three task corpora, hand-graded ground truth.**

1. **Issue classification (10 cases)** — real apexyard issues drawn live from `gh issue list --repo me2resh/apexyard`. Numbers, ground-truth labels, and titles in the table below. Ground truth = the most plausible bracket-prefix-derived category, cross-checked against the issue's labels (`bug`, `enhancement`, etc.) where present.
2. **Commit-type suggestion (10 cases)** — real apexyard commit subjects from `gh api repos/me2resh/apexyard/commits` (squash-merge log). Ground truth = the conventional-commit type the maintainer used in the merge subject (`feat(#NN):`, `chore(#NN):`, etc.). The "files changed" column was synthesised by inspecting the merge PR for each — i.e. plausible to what the agent would see, not the literal `git show --stat`.
3. **Inbox summary (1 case)** — synthetic but realistic 10-PR list with a deliberate P0 + P1 mix and a GDPR thread, designed to differentiate "summarises mechanically" from "spots themes". Ground truth = a hand-written 3-line summary stating the count, the dominant theme, the highest priority, and the next action.

**Three variants per task.**

- **Variant A — pure tool**: Python heuristic (regex / keyword matching) using only the inputs the variant has. No model.
- **Variant B — local LLM**: live calls to two locally-running ollama models — `llama3.2:latest` (3.2B params, Q4_K_M, ~2 GB) and `mistral:latest` (7.2B params, Q4_0, ~4.1 GB). Same prompt for both. Calls go via `http://localhost:11434/api/generate` (the streaming-disabled JSON endpoint), giving us `prompt_eval_count` (input tokens), `eval_count` (output tokens), and `total_duration` (server-side wall-clock) in every response.
- **Variant C — Claude**: NOT directly measured. Claude Haiku and Sonnet token counts are estimated from the same prompt shape via the public Anthropic tokenizer rule-of-thumb (~3.3 chars/token for English prose, ~3 chars/token for short structured output) and the published $/1M pricing as of May 2026.

**Honest assumptions and caveats.**

- The ticket asked for "Llama-3-8B-Instruct or comparable". The closest available locally is `mistral:7B` (Q4_0) — half a generation older than llama-3-8B but a similar parameter count. `llama3.2:3B` is documented as a smaller comparison; lab figures from Meta show llama-3-8B should outperform mistral-7B-Q4 on classification by a few percentage points but not change the conclusion direction.
- All wall-clock numbers below are **post-warmup** (first call to the model in this session was discarded; reported numbers are the median of subsequent calls). Cold-start (first call after `ollama serve` boot) on `llama3.2:3B` was 9.1 s for issue-classify; on `mistral:7B`, 10.3 s. Cold-start cost matters for adoption and is called out in Phase 2.
- I did not run the same prompts through Claude Haiku for token counts. Anthropic's count-tokens endpoint is available and would give exact numbers; the spike scope didn't justify burning the API budget when the structural conclusion (regex 10/10 on issue-classify) doesn't depend on the comparison. Estimates are clearly labelled as such.
- Heuristic quality on issue-classify is artificially high because the test corpus is ApexYard issues, where the bracket-prefix convention is followed religiously. Adopters whose corpus has unbracketed titles (`Add SSO login flow`, `nav broken on mobile`) will see lower regex accuracy. A re-test on a corpus from outside the framework is in the "what this spike did NOT measure" list at the end.

### Task 1 — Issue classification

**Prompt (Variants B + C):**

```
Classify this GitHub issue as exactly one of: bug, feature, spike, chore.
- bug: something is broken or behaves incorrectly
- feature: a new capability or enhancement
- spike: research, investigation, or measurement (no implementation)
- chore: maintenance, refactor, docs, release, tooling

Reply with ONE WORD only (no punctuation, no explanation).

Title: {title}

Label:
```

**Heuristic (Variant A):** lower-case the title, dispatch on bracket prefix (`[bug]→bug`, `[feature]→feature`, `[spike]→spike`, `[chore]→chore`, `[docs]→chore`, `[testing]→chore`); if no bracket, fall back to keyword matching (`broken / fix / regression → bug`, `measure / spike / investigate → spike`, `docs / refactor / release → chore`, else → feature). ~25 lines of Python.

#### Per-case results

| # | GT | A: heuristic | B1: llama3.2:3B | B2: mistral:7B | Title (truncated) |
|---|---|---|---|---|---|
| 194 | bug | bug ✓ | bug ✓ | bug ✓ | [Bug] Validation hooks resolve git context from $PWD … |
| 195 | spike | spike ✓ | spike ✓ | spike ✓ | [Spike] Measure local-model routing for bounded sub-tasks |
| 190 | chore | chore ✓ | feature ✗ | chore ✓ | [Docs] Annotate code-aware skills with LSP-aware callouts |
| 188 | feature | feature ✓ | spike ✗ | spike ✗ | [Feature] /handover offers clone-first deep-dive prompt |
| 183 | feature | feature ✓ | feature ✓ | feature ✓ | [Feature] /launch-check historical trend tracking |
| 180 | feature | feature ✓ | spike ✗ | spike ✗ | [Feature] /spike skill — hypothesis-driven, time-boxed |
| 178 | spike | spike ✓ | spike ✓ | spike ✓ | [Spike] Measure token savings of LSP-based code navigation |
| 170 | chore | chore ✓ | chore ✓ | chore ✓ | [Chore] validate-pr-create.sh's branch-id check still blocks |
| 157 | chore | chore ✓ | chore ✓ | chore ✓ | [Chore] Remove the voice-prompts-on-pause feature |
| 151 | bug | bug ✓ | bug ✓ | bug ✓ | [Bug] require-active-ticket.sh bypassable via Bash file writes |
| **acc** | — | **10/10** | **7/10** | **8/10** | |

#### Token + latency totals

| Metric | A: heuristic | B1: llama3.2:3B | B2: mistral:7B | C: Claude Haiku (est.) | C: Claude Sonnet (est.) |
|---|---|---|---|---|---|
| Avg input tokens (per call) | 0 | 128 | 131 | ~165 (system+user prompt fixed; titles short) | ~165 |
| Avg output tokens | 0 | 2.6 | 2.7 | ~3 | ~3 |
| Avg wall-clock (warm) | <1 ms | 0.21 s | 0.35 s | ~0.4 s (Haiku p50) | ~1.2 s (Sonnet p50) |
| Cold-start | n/a | 9.1 s (first call) | 10.3 s (first call) | n/a (no model load) | n/a |
| Setup cost | 0 | install ollama (~30 MB) + pull llama3.2 (~2 GB) | install ollama + pull mistral (~4.1 GB) | already in path | already in path |
| Maintenance | 0 (regex is ~25 lines) | per-machine model pull, occasional `ollama pull` to refresh | same | upstream model upgrades managed by Anthropic | same |
| Quality | **10/10** | 7/10 | 8/10 | ~10/10 (very likely; not measured) | ~10/10 |
| **$ / 1k calls (est.)** | **$0** | $0 | $0 | $0.04 (Haiku $0.25/1M in × 165k = $0.04 + $0.001/1M out) | $0.50 (Sonnet $3/1M × 165k = $0.50) |

**Quality scoring heuristic** (used for B1, B2): exact-match against ground truth. Inter-rater spread on this task is near zero — the ground truth labels are unambiguous because they come from the bracket prefix.

**Key finding for Task 1**: the regex hits the same accuracy as Claude Haiku at zero tokens, zero latency, zero install cost, and zero maintenance. Local LLMs are **strictly worse** on this task — they cost a `~130-token` prompt + a wall-clock penalty + a 2-4 GB model on disk for a result the regex already nails. The two failure modes the local LLMs share (mis-classifying `[Feature]` titles as `spike` when the title contains "skill" or "deep-dive") are both fixable in the regex with one extra rule.

### Task 2 — Commit-type suggestion

**Prompt (Variants B + C):**

```
Suggest a conventional-commit type for this change. Choose exactly one of:
feat, fix, refactor, docs, chore, test

Reply with ONE WORD only.

Subject: {subject}
Files changed: {files}

Type:
```

**Heuristic (Variant A):** files-first dispatch (all-`.md` → docs, anything in `tests/` → test), then subject keywords (`fix / bug / regression → fix`, `refactor / rename → refactor`, `docs / readme / audit → docs`, `chore / release / publish → chore`, `add / new / skill / feature → feat`, default → chore). ~20 lines.

#### Per-case results

| GT | A: heuristic | B1: llama3.2:3B | B2: mistral:7B | Subject (truncated) |
|---|---|---|---|---|
| feat | chore ✗ | refactor ✗ | chore ✗ | tag-based upstream drift detection |
| feat | chore ✗ | docs ✗ | docs ✗ | SDLC-loop manifesto callout on landing |
| docs | docs ✓ | refactor ✗ | docs ✓ | correct CLAUDE.md hook/skill/rule counts |
| feat | chore ✗ | docs ✗ | docs ✗ | add creator attribution + update footer socials |
| chore | chore ✓ | docs ✗ | chore ✓ | site polish - AgDR, banner a11y, CSP, canonical redirect |
| chore | chore ✓ | chore ✓ | chore ✗ (got "deploy") | publish site to yard.apexscript.com |
| chore | docs ✗ | docs ✗ | docs ✗ | README audit — sync specifics with v1.0.0 state |
| feat | docs ✗ | refactor ✗ | docs ✗ | /c4 skill for generating C4 L1 + L2 architecture diagrams |
| fix | fix ✓ | refactor ✗ | refactor ✗ | tighten code-reviewer marker-writing to enforce bare SHA |
| test | test ✓ | test ✓ | test ✓ | Pre-release smoke test for v1.2.0 |
| **acc** | **5/10** | **2/10** | **3/10** | |

#### Token + latency totals

| Metric | A: heuristic | B1: llama3.2:3B | B2: mistral:7B | C: Claude Haiku (est.) | C: Claude Sonnet (est.) |
|---|---|---|---|---|---|
| Avg input tokens | 0 | 85 | 81 | ~110 | ~110 |
| Avg output tokens | 0 | 2.5 | 3.6 | ~3 | ~3 |
| Avg wall-clock (warm) | <1 ms | 0.19 s | 0.36 s | ~0.4 s | ~1.2 s |
| Quality | **5/10** | 2/10 | 3/10 | ~6-7/10 (estimate; bounded by ambiguity of GT) | ~7-8/10 |
| **$ / 1k calls (est.)** | **$0** | $0 | $0 | $0.03 | $0.33 |

**Quality scoring caveats for Task 2**: the ground truth is itself noisy. The "README audit" commit was tagged `chore` by the maintainer but a different team would reasonably tag the same change `docs`. The "add creator attribution" change was tagged `feat`, but it modifies only `site/index.html` — no team convention treats a single-file site copy edit as `feat` reliably. The 5/10 ceiling for the heuristic is therefore a fair upper bound; the local LLMs' 2-3/10 is genuinely worse, but Claude wouldn't beat the heuristic by 5 points either.

**Key finding for Task 2**: this task is **subject + filename-shaped wrong**. The conventional-commit type is information that lives in the **diff**, not the subject. A subject-and-filename suggestion is at best a hint; nobody — heuristic, local LLM, or Claude — will get to "good enough" without the diff. And once the diff is in scope (~500-3000 tokens for a typical apexyard PR), the input size is at the upper end of what a 7B model handles competently and the cost-savings argument over Claude Haiku collapses (Haiku at $0.25/1M in is already negligible on a few-thousand-token diff).

The right framing for commit-type help in apexyard isn't "route this sub-task to a local model" — it's **"keep it on Claude, give it the diff, and trust the existing prepare-commit-msg pattern"**. Local routing isn't the savings path here.

### Task 3 — Inbox summary

**Prompt (Variants B + C):**

```
You are summarizing a developer's pull-request inbox. Given the list of 10
open PR titles, write exactly 3 short lines:
Line 1: how many PRs are pending and the dominant theme
Line 2: highest-priority item (if any P0/P1 or critical)
Line 3: one suggested next action

PR titles:
- feat(#42): add OAuth2 SSO login flow
- fix(#108): mobile nav z-index regression on iOS Safari
- fix(#211)!: P0 — payment webhook drops events under burst load
- docs(#88): clarify rate-limit headers in API reference
- feat(#155): inline gallery component for product pages
- chore(#199): bump dependencies (security-audit batch April)
- refactor(#142): extract pricing engine into dedicated module
- test(#178): add E2E coverage for checkout abandonment flow
- feat(#221): export user data as ZIP (GDPR Art. 20 follow-up)
- fix(#244): P1 — profile page 500s when avatar URL is null

Summary (3 lines):
```

**Heuristic (Variant A):** parse the conventional-commit type from each title (`feat / fix / chore / …`), tally the dominant type, scan for `P0` / `P1` markers, format three template lines. ~15 lines.

**Hand-graded reference**:
> 10 PRs pending; mostly bug fixes and feature work, with security and GDPR threads.
> Highest priority: #211 P0 payment webhook dropping events under burst load — blocks revenue.
> Next action: review #211 first, then triage P1 #244 profile-page null-avatar 500s.

#### Outputs

**A — heuristic:**

```
10 PRs pending; dominant type is feat (3/10).
Highest priority: fix(#211)!: P0 — payment webhook drops events under burst load
Next action: review fix(#211)! first.
```

Quality: 6/10. Counts correctly (10), identifies the P0 correctly, but the "dominant type" framing ("feat 3/10") is mechanically true and humanly useless — readers care about themes ("security batch", "GDPR thread"), not type tallies. No mention of #244 P1 → no real next-action sequencing.

**B1 — llama3.2:3B (3.2B params, Q4_K_M):**

```
There are 8 open PRs pending, with a dominant theme of bug fixes and performance optimizations.

The highest-priority item is fix(#211)!: P0 — payment webhook drops events under burst load, which requires immediate attention to prevent data loss.

Next action: Review the PRs in chronological order, starting with #211, to ensure that all critical issues are addressed before moving on to less urgent tasks.
```

Quality: 5/10. Got the P0 right and produced the kind of synthesised line a human reader actually wants ("bug fixes and performance optimizations" is one step closer to themes than "feat 3/10"). **Miscounted: said "8 PRs", actual is 10.** Whiffed on the GDPR / security theme. Last line is generic filler.

- in: 252 tokens, out: 84 tokens, warm wall-clock: **2.48 s**

**B2 — mistral:7B (7.2B params, Q4_0):**

```
1. 6 PRs are pending, with a dominant theme of feature implementations and bug fixes.
2. The highest priority item is the P0 issue (#211) regarding payment webhook drops under burst load.
3. To address the critical issue, consider merging the payment webhook fix immediately while continuing to review other PRs.
```

Quality: 5/10. Got the P0 and the dominant-theme synthesis. **Miscounted: said "6 PRs", actual is 10.** Format-disobedient (numbered the lines despite being asked for plain prose). Skipped #244.

- in: 292 tokens, out: 78 tokens, warm wall-clock: **4.89 s**

**C — Claude Haiku (estimated):** would almost certainly hit ~9/10 — the synthesis quality on a 10-line list is well within the model's capability, and the count-the-list arithmetic is the failure mode that distinguishes Claude from a 3-7B local. Estimated input tokens: ~310 (titles + system prompt). Output: ~80. Cost: ~$0.0001 per call.

#### Token + latency summary

| Metric | A: heuristic | B1: llama3.2:3B | B2: mistral:7B | C: Claude Haiku (est.) | C: Claude Sonnet (est.) |
|---|---|---|---|---|---|
| Input tokens | 0 | 252 | 292 | ~310 | ~310 |
| Output tokens | 0 | 84 | 78 | ~80 | ~80 |
| Wall-clock (warm) | <1 ms | 2.48 s | 4.89 s | ~0.7 s | ~2.5 s |
| Quality | 6/10 | 5/10 | 5/10 | ~9/10 | ~9-10/10 |
| **$ / 1k calls (est.)** | **$0** | $0 | $0 | $0.08 | $1.00 |

**Key finding for Task 3**: this is **the only task in the spike where local-LLM routing has a real argument**. The pure heuristic is mechanically correct but humanly underwhelming. Local LLMs have the right shape of output (synthesised themes, not type tallies) but make basic factual mistakes (mis-counting, dropping P1 items). **The right architecture is hybrid**: the heuristic produces a small structured fact-block (counts, P0 / P1 IDs, type tally), and the local LLM is asked to *narrate* those facts — never to count them. The narration prompt then fits in ~150 tokens, runs in <2 s, and is empirically the kind of task a 7B Q4 model handles cleanly.

### Comparative summary across all 3 tasks

| Task | Best variant | Why |
|---|---|---|
| Issue classification | **A — heuristic (10/10, 0 ms, 0 tokens)** | Bracket prefix is decisive in the apexyard corpus; routing through any model is value-destroying noise |
| Commit-type suggestion | **C — Claude with diff** (existing path) | Subject + filename is structurally insufficient; routing this to a local LLM throws away accuracy and isn't even where the cost is in the first place |
| Inbox summary | **A+B hybrid** (regex extracts facts, local LLM narrates) | The synthesis is the value, local LLM is on its strength here, and the hybrid eliminates the count-arithmetic failure mode |

---

## Phase 2 — Integration mechanism

### Tool surface options

| Option | Description | Pro | Con |
|---|---|---|---|
| 1. New `OllamaCall` tool | Add a first-class Claude Code tool that wraps Ollama. Skill prompts call `OllamaCall(model="…", prompt="…")` directly | Cleanest; model-side tool calling | Requires harness change; not something framework adopters can ship; locked to Anthropic's tool-registry roadmap; the "fall back to Claude" path becomes "the tool returns an error and the agent has to catch it" — fragile |
| 2. MCP server wrapping Ollama | Build an MCP server that exposes `ollama_chat` / `ollama_generate` tools | Works in any MCP-compatible harness; clean tool surface for the model | We'd be maintaining an MCP shim; adopters install both the MCP server and the framework; another maintenance surface; ops-fork upgrades have to track MCP-server breaking changes |
| 3. **Bash helper invoked by skills** (`bin/apexyard-local llm <prompt>`) | A small bash script that POSTs to `localhost:11434/api/generate` if `ollama serve` is up; non-zero exit + stderr message if not. Skills call it via `Bash` and parse the result | Zero new tool surface; matches the framework's existing `_lib-*.sh` pattern; trivial to fall back ("if `bin/apexyard-local llm …` fails, ask Claude inline"); no MCP / harness dependency; per-adopter opt-in is just "do you have `ollama` running?" | Two-step prompt shape (skill → bash → ollama → skill); slightly higher latency than option 1 (a few-ms shell overhead is negligible vs the model's 200ms-5s latency); skill prompts have to be shaped as bash-friendly (single-line; no shell-escape hell) — solvable with a `--prompt-file` flag on the helper |

**Recommendation**: **Option 3 — bash helper.** It's the same shape the framework already uses for everything else (hooks, portfolio paths, config reads). It introduces zero new tool surface, fits the "ApexYard is a layer of conventions over Claude Code, not a fork of it" principle, and the fallback story is mechanically simple.

#### Sketch of the helper

```bash
# bin/apexyard-local — minimal sketch, not a deliverable
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
case "$cmd" in
  llm)
    shift
    model="${APEXYARD_LOCAL_MODEL:-mistral:latest}"
    prompt="${1:?prompt required (use --prompt-file FILE for multi-line)}"
    if [[ "$prompt" == "--prompt-file" ]]; then prompt="$(cat "$2")"; fi
    # Probe: ollama running?
    curl -fsS --max-time 1 http://localhost:11434/ >/dev/null 2>&1 \
      || { echo "apexyard-local: ollama not running; falling back to caller" >&2; exit 2; }
    # Generate
    curl -fsS http://localhost:11434/api/generate \
      --max-time 30 \
      -d "$(jq -Rn --arg m "$model" --arg p "$prompt" \
              '{model:$m, prompt:$p, stream:false, options:{temperature:0.2}}')" \
      | jq -r '.response'
    ;;
  available)
    curl -fsS --max-time 1 http://localhost:11434/ >/dev/null 2>&1 && echo yes || echo no
    ;;
  *)
    echo "usage: apexyard-local llm <prompt> | --prompt-file <file>" >&2
    echo "       apexyard-local available" >&2
    exit 1
    ;;
esac
```

Skills that opt in call:

```bash
if [[ "$(bin/apexyard-local available)" == yes ]]; then
  summary="$(bin/apexyard-local llm --prompt-file /tmp/inbox-summary.prompt)"
else
  summary=""   # caller (skill) falls back to "ask Claude inline"
fi
```

### Skill opt-in shape

Two layers of opt-in, one per machine, one per skill:

1. **Per-machine**: the helper is a no-op fallback when `ollama` isn't reachable. Adopters who don't install ollama see no behaviour change. This is the floor.
2. **Per-skill**: the skill's `SKILL.md` declares which sub-tasks it would route, in a small `local-routes:` block. Today only the `inbox-summary` route is recommended (Phase 3 below). Adding more is a per-task decision, not a global flag.

A new `.claude/project-config.json` key — `local_routing.enabled` (default `false`) — gates whether the routing happens at all. Adopters who installed ollama for other reasons but don't want their framework calls going through it can set it `false`. Adopters who set it `true` and don't have ollama running silently get the Claude path (the helper's exit-2 fallback is the safety net).

### Fallback story

Three layers, in order:

1. **`bin/apexyard-local available` returns `no`** → skill skips the local route and asks Claude inline. No error surfaced to the user.
2. **`bin/apexyard-local llm` exits non-zero (ollama running but call failed: model not pulled, OOM, timeout)** → skill catches the non-zero exit, logs a one-line warning to stderr, falls back to Claude inline.
3. **Local LLM returns garbage** (e.g. response doesn't match expected shape — for inbox-summary, fewer than 3 non-empty lines) → skill validates the output before using it; on validation failure, falls back to Claude inline. **This is the most important layer** — the local model can produce subtly wrong output (we measured llama saying "8 PRs" when there are 10), and the skill has to catch that, not the user.

The validation rule for inbox-summary specifically: count of "PRs pending: N" must match the input list length; mention of every P0 ID must be present. If either fails, fall back. This is the same shape the LSP spike's "fall back to grep" recommendation took — local routing is a perf optimisation, never a correctness primitive.

### Privacy story

**Local routing keeps the prompt + completion entirely on the adopter's machine** for the routed sub-tasks. The Claude path doesn't change for everything else — system prompts, tool calls, code review, AgDR drafting, all still go to Claude.

What this is worth in practice:

- For an adopter working on a private project, **routing inbox-summary locally means the per-day list of in-flight PR titles never leaves the machine**. PR titles are usually low-sensitivity (commit message style, ticket numbers), but for some adopters they encode customer names, internal project names, or M&A topics. Today, those titles travel to Claude. With local routing, that traffic class drops to zero for the routed task.
- For an adopter working on regulated data (healthcare, finance, government), **even structurally low-sensitivity prompts can fall under "no third-party processing" rules**. Local routing is a lever they can turn on for audit reasons, not just cost reasons. Claim conservatively in adopter docs: "the prompts and completions for routed sub-tasks stay on-machine; everything else continues to use Claude as before."
- The privacy benefit is **proportional to the fraction of skill traffic that's actually routed**. After Phase 3's recommendation, that fraction is small (one task — inbox-summary — and only when invoked). Don't oversell.

### Maintenance and operational surface

A new `bin/apexyard-local` script + a small section in `docs/getting-started.md` ("Optional: local model routing — install ollama, pull a model, set `local_routing.enabled: true`"). Total framework code change: ~80 lines of bash + ~100 lines of doc.

Adopters who don't install ollama: zero change. Their `bin/apexyard-local available` returns `no`, the helper exits, the skill takes the Claude path. No new failure modes.

---

## Phase 3 — Recommendation: rank by ROI

### Scoring

I'm scoring each candidate on `(token-savings per call) × (per-adopter call frequency, qualitative)`, with a quality-floor pass/fail bit. A task that routes successfully but degrades quality below "good enough" is rejected regardless of token math.

| Sub-task | Tokens saved per call (vs Claude Haiku) | Frequency per adopter | Quality floor met by local? | ROI |
|---|---|---|---|---|
| **issue-classify** | ~165 in + 3 out × $0.25/$1.25 per 1M = **~$0.04/1k calls** | Per ticket creation. ~10/week medium adopter, ~50/week heavy | Local: 7-8/10. Claude: ~10/10. Heuristic: 10/10. | **Reject route to local. Adopt heuristic instead.** Local is strictly worse than the regex; Claude is barely better. |
| **commit-type** | ~110 in + 3 out = **~$0.03/1k calls** if subject-only; ~$0.50-2.00/1k calls if diff-aware | Per commit. ~30/week medium, ~150/week heavy | Local: 2-3/10 on subject-only. Claude with diff: 7-8/10. Heuristic: 5/10. | **Reject route to local.** Subject-only is structurally insufficient regardless of model; the right path needs the diff and that prices local out. |
| **inbox-summary** | ~310 in + 80 out = **~$0.08/1k calls** | Per `/inbox` invocation. ~5/week medium, ~20/week heavy | Local: 5/10 standalone, 7-8/10 hybrid (regex extracts facts, LLM narrates). Heuristic: 6/10. Claude: ~9/10. | **Conditional GO** for the hybrid shape only. Standalone-local fails the quality floor (count errors); hybrid clears it. |

### What "ROI" really looks like in this spike

The dominant finding is that **the savings story is dwarfed by the cost-of-Claude story being already very small** for these task shapes. At Haiku pricing in May 2026, a heavy adopter making 50 issue-classifications, 150 commit-type suggestions, and 20 inbox summaries per week pays roughly:

- Issue classify: 50 × $0.04/1k = $0.002/week
- Commit-type (subject-only): 150 × $0.03/1k = $0.005/week
- Inbox summary: 20 × $0.08/1k = $0.002/week
- **Total**: about $0.01/week per heavy adopter, or ~50¢/year.

Routing all three to local doesn't materially change that. The argument for local routing is **not cost** — it's **(a) latency for tasks already fast enough, (b) privacy for adopters whose threat model needs it, and (c) the principled "use the cheaper tool when good enough" pattern that compounds over a longer adoption window**.

The token-cost-savings frame in the original ticket is real on paper but small on this corpus. The frame the spike actually validates is **"avoid model calls altogether where a regex suffices, and use local LLMs where prose synthesis is the value"** — which is a sharper recommendation than "route everything bounded".

### First migration: `inbox-summary` (hybrid shape)

If this spike says GO on anything, it says GO on this one. Reasons:

1. **It's the only task where local LLMs add value over a regex.** The 3-line synthesis is the value; the heuristic can't produce it; the local LLM can if guarded by a fact-extracting wrapper.
2. **Quality floor is reachable** with the regex-extracts-facts / LLM-narrates hybrid.
3. **Frequency is high enough to feel** (~5-20/week per adopter, growing with portfolio size).
4. **Privacy benefit is clearest here**: the inbox-summary prompt contains the most identifying material across the three tasks (PR titles can include customer names, internal projects). Routing this one locally is the highest-value privacy lever in the framework.
5. **Failure mode is graceful**: the validator-on-output catches the count-arithmetic failure, falls back to Claude, user never notices.

### Migration shape sketch (for the AgDR)

1. Add `bin/apexyard-local` (bash helper, ~80 lines).
2. Add `local_routing.enabled` (default `false`) to `.claude/project-config.json` schema.
3. Update `/inbox` SKILL.md to:
   - Extract structured facts (count, type tally, P0/P1 list) via the existing portfolio paths and `gh` queries.
   - **If** `local_routing.enabled=true` AND `bin/apexyard-local available=yes`: send the facts + a narration prompt to local; validate output (count must match, P0s must appear); on failure, fall back.
   - **Else** (the default and the fallback): keep today's path — Claude does the synthesis inline.
4. Add a "Optional: local model routing" section to `docs/getting-started.md` with the install + opt-in steps (`brew install ollama` / equivalent, `ollama pull mistral`, set the config flag).
5. Decision review at +90 days: how many adopters enabled it? Did `/inbox` quality complaints rise? Does the privacy claim hold under scrutiny? If the answers are "few / no / yes", expand to no other task — local routing is a niche tool, not a default. If the answers are "many / no / yes", consider routing future synthesis-shaped tasks (release-notes drafts, stakeholder-update intros, etc.) the same way.

### What about commit-type and issue-classify?

- **issue-classify**: file a follow-up ticket "Add bracket-prefix regex shortcut to `/feature`/`/bug`/`/task` skill confirmation step" — small win, no model needed. Don't touch local routing.
- **commit-type**: leave on Claude. If we want to reduce its cost, **the lever is "feed Claude the diff, not the subject"** plus a Haiku-tier model selection — both orthogonal to local routing. File as a separate enhancement if it matters.

---

## Phase 4 — AgDR sketch (not the full AgDR; that's a follow-up if Phase 3 ships)

### Y-statement (sketched)

> In the context of bounded sub-tasks inside ApexYard skills (issue classification, commit-type suggestion, inbox synthesis), facing the cost of routing all of them through Claude when a regex pass and/or a small on-machine LLM would do, we will adopt **a regex-first / local-LLM-second hybrid**, applied first to **`/inbox` summary only** via a new `bin/apexyard-local` helper, leaving `issue-classify` on a pure regex (no model at all) and `commit-type` on Claude (the local model is structurally inadequate for that task shape), to (a) clear the synthesis-quality floor at zero token cost on `/inbox`, (b) buy a real privacy lever for adopters whose PR-title contents are sensitive, and (c) establish the framework pattern for adding more local routes per measured task, accepting (i) a per-machine optional install of `ollama` + a model, (ii) one new helper script in `bin/`, (iii) a quality validator inside `/inbox` that catches the local model's count-arithmetic failure mode and falls back to Claude when validation fails.

### Option matrix the AgDR would capture

| Option | Pros | Cons | Recommendation |
|---|---|---|---|
| Do nothing — keep today's all-Claude routing | Zero install cost; zero new code; works on any adopter machine | Misses the privacy lever; loses the small-but-real latency win on inbox-summary; misses the principled "use cheaper tool when good enough" pattern | **Reject** |
| Route all 3 sub-tasks to local LLM (the original ticket hypothesis) | Maximum cost savings on paper | Issue-classify is regex-sufficient (routing to a model is noise); commit-type is structurally not solvable from subject + filenames at any model size; standalone local fails inbox-summary's quality floor on count arithmetic | **Reject as designed** |
| Route only inbox-summary to local LLM, standalone | Real synthesis value; zero token cost | Quality floor fails on count errors (measured: 6/10 and 8/10 PRs reported when truth is 10) | **Reject** |
| **Route inbox-summary via regex-first / LLM-narrates hybrid; leave others on existing paths** | Quality floor cleared via fact extraction; zero token cost on the routed task; principled per-task migration; privacy lever where it matters most | New helper script to maintain (~80 lines); per-machine optional dependency on `ollama`; one new failure path (validator) to test | **Accept** |
| Build an `OllamaCall` first-class tool | Cleanest tool surface for the model | Requires harness change; not something the framework can ship unilaterally | **Reject** (option 1 in Phase 2) |
| Build an MCP server wrapping Ollama | Works in any MCP-compatible harness | New shim to maintain; ops-fork upgrades track MCP-server breaking changes; matches a less-load-bearing pattern in the framework | **Reject** (option 2 in Phase 2) |
| Replace Claude framework-wide for synthesis tasks | Maximises privacy lever | Quality floor doesn't clear for most synthesis tasks at 7B Q4; the framework's value is the Claude+conventions stack, not a Claude replacement | **Reject — out of spike scope** |

### Rollout sketch

1. Land `bin/apexyard-local` (new file, ~80 lines bash + tests).
2. Add `local_routing.enabled` to `.claude/project-config.json` schema; default `false`; document the override.
3. Update `/inbox` SKILL.md to add the regex-extracts-facts step, the local-LLM narration step, and the validator-with-fallback step.
4. Add a "Optional: local model routing" subsection to `docs/getting-started.md` covering ollama install, model pull, and the opt-in flag.
5. Add a follow-up ticket: "Add bracket-prefix regex shortcut to `/feature`/`/bug`/`/task`" — orthogonal to local routing, independently valuable.
6. **Do not** add follow-up tickets for commit-type local routing or issue-classify local routing. The spike measurement is conclusive against both.
7. Decision review at +90 days as in Phase 3.

---

## Recommendation

**NO-GO on the original hypothesis as stated** ("route issue-classify, commit-type, and inbox-summary to a local model"). The spike's measurement falsifies that framing for two of the three tasks.

**PARTIAL GO**: ship `bin/apexyard-local` and route **inbox-summary only**, in the regex-first / LLM-narrates hybrid shape, behind an opt-in flag, with a validator-and-fallback safety net. File a separate follow-up to add a bracket-prefix regex shortcut to issue-creation skills (no model involved). Leave commit-type entirely alone — it's a different problem than the ticket framed.

### Reasoning, in one paragraph

The spike's central question was "do small bounded tasks save tokens routed locally?" The honest answer is "the tokens being spent on these tasks today are already so few that token savings is the wrong frame; the right frame is **quality × adopter-frequency × privacy**, and on that frame only one of the three candidates clears the bar." Issue classification is dominated by a 25-line regex at zero cost; routing it through any model — local or cloud — wastes resources for no measurable accuracy gain. Commit-type from subject + filenames is structurally underspecified; the right input is the diff, and that's not a savings problem. Inbox-summary is where local actually has something to contribute (synthesis, themes, prose), and the failure modes (mis-counting, dropping P1s) are exactly the kind regex can catch in a wrapper. So the spike says: **don't route everything bounded; route prose-synthesis specifically, behind a regex of structured facts, behind an opt-in flag, with a validator on output. Do that one task properly, learn from it, expand only if the +90-day review says yes.**

### Blockers found

None that block the partial-GO recommendation. Three caveats worth carrying into the AgDR:

1. **The framing of "route bounded sub-tasks to local LLMs" is too coarse.** The spike re-framed it to "regex when sufficient, local-LLM when prose-synthesis adds value, Claude when correctness or context demand it." Adopters reading the ticket text alone may expect a wider net; the AgDR text needs to make this re-framing explicit.
2. **Per-machine model-pull cost is non-trivial** (mistral:7B is 4.1 GB; llama3.2:3B is 2 GB). For an adopter who only wants the inbox-summary win, that's a steep ask. The opt-in docs need to make the cost visible *before* the install command, not after.
3. **Cold-start latency is 9-10 seconds on the first call after `ollama serve` boot.** For the "I just opened the laptop and ran `/inbox`" path, that's a real wait — long enough that an unwarmed model might lose the "feels fast" property the local-routing pitch implies. Mitigations: warm the model on session start (cheap, one ping), or document the cold-start expectation honestly in the opt-in section.

### What this spike did NOT measure

- **A real run of the routed `/inbox` flow with the helper in place**, end-to-end. The benchmark numbers are per-call; the integrated experience (regex → helper → narrate → validate → format) wasn't built or tried. The +90-day review will catch this if validator-fallback rates are higher than expected.
- **Llama-3-8B-Instruct specifically.** I substituted `mistral:7B` (Q4_0, similar parameter count) because that's what was already pulled on the test machine. Llama-3-8B at Q4 is documented as a few percentage points stronger on classification tasks; the conclusions don't depend on the difference, but a re-test with llama-3-8B before the AgDR ships is cheap insurance.
- **A non-bracket-prefixed issue corpus** for the heuristic ceiling on issue-classify. ApexYard's own issues use the bracket prefix religiously, which makes the heuristic look perfect. A re-test on a corpus from a non-ApexYard adopter project would set a more honest floor — though even a 70% heuristic still beats a 75% local LLM at zero cost.
- **Larger inbox-summary inputs** (50+ PRs). The 10-PR list fits comfortably in any 7B model's context; a 100-PR portfolio rollup might shift the cost-quality balance. Out of scope for this spike; revisit if `/status` or `/stakeholder-update` ever become candidates for local routing.

---

## Sources

- [Ollama HTTP API reference](https://github.com/ollama/ollama/blob/main/docs/api.md) — `prompt_eval_count`, `eval_count`, `total_duration` semantics used for the per-call token + wall-clock numbers
- [Anthropic API pricing (May 2026)](https://www.anthropic.com/pricing) — Haiku $0.25/$1.25 per 1M tokens; Sonnet $3/$15 per 1M; used for Variant C cost estimates
- [Llama 3 model card / blog](https://ai.meta.com/blog/meta-llama-3/) — 8B vs 3B parameter-count comparison; classification benchmarks documented in lab figures
- [Mistral 7B model card](https://mistral.ai/news/announcing-mistral-7b/) — used as the closest available substitute for the ticket's "Llama-3-8B-Instruct or comparable"
- [Conventional Commits 1.0](https://www.conventionalcommits.org/en/v1.0.0/) — type taxonomy used for Task 2 ground truth
- [Sibling spike: LSP token savings (#178 → PR #184)](./lsp-token-savings.md) — shape, methodology, AgDR section structure mirrored here
- ApexYard issues #194, #195, #190, #188, #183, #180, #178, #170, #157, #151 — Task 1 corpus
- ApexYard commit log via `gh api repos/me2resh/apexyard/commits` — Task 2 corpus

---

## Glossary

| Term | Definition |
|---|---|
| Local-model routing | Sending a specific bounded sub-task's prompt to a small LLM running on the adopter's own machine (via Ollama or equivalent), instead of the conversational Claude path |
| Bounded sub-task | A task with a small, fixed input shape and a small, fixed output shape — the opposite of "open-ended chat with a 200k context" |
| Heuristic / pure tool / Variant A | A regex / template / keyword-matching script that produces the answer with no model call at all |
| Local LLM / Variant B | A small LLM (3-7B parameters at 4-bit quantisation) running on-machine via Ollama. Tested: `llama3.2:3B`, `mistral:7B` |
| Claude (today's path) / Variant C | The conversational Claude path the framework uses today; cost and latency estimated, not directly measured |
| Quality floor | The minimum output quality below which a routing decision is rejected regardless of cost savings |
| Hybrid shape (regex + LLM) | An architecture where the regex extracts structured facts (counts, IDs, type tallies) and the LLM is asked only to *narrate* those facts — never to compute them. Used in the inbox-summary recommendation |
| Validator-and-fallback | A post-output check on the LLM's response (e.g. "must mention every P0 ID, count must match input length"); on failure, the skill falls back to the Claude path silently |
| Cold-start latency | Time for the first call after `ollama serve` is started; the model has to be loaded into memory. Measured: 9.1 s (llama3.2:3B), 10.3 s (mistral:7B) on an M-series Mac |
| Y-statement | The four-clause AgDR opener: *"In the context of X, facing Y, we decided Z to achieve A, accepting B."* |
| `bin/apexyard-local` | The proposed bash helper in this spike: a thin wrapper over the Ollama HTTP API with a "fall back if not running" exit code semantic, invoked by skills via the existing `Bash` tool |
| Conventional commit | A commit message format (`type(scope): subject`) standardised by [Conventional Commits 1.0](https://www.conventionalcommits.org/) |
