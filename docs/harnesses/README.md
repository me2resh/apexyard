# Harness support

An **agent harness** is the CLI or IDE that runs an ApexYard session. Examples
include Claude Code, Codex, pi, opencode, and Cursor.

ApexYard's initial development targeted Claude Code. Claude Code still provides the full
native experience. The enforcement layer uses portable Bash. Other harnesses
can reach the same gates through thin adapters.

This directory records what each harness supports today.

> **Positioning:** The primary tagline remains **"for Claude Code."** These
> pages document the current adapter support. The headline needs a separate product decision
> before it changes. See [Rebrand trigger](#rebrand-trigger).

## Support matrix

This page answers one question: **does ApexYard enforce my rules on this tool,
and how do I set it up?** A tool is **proven** only after the same
unmodified Bash rule stops a real, credentialed agent turn. Mocks do not qualify.

| Tool | Enforces your rules? | Setup | Good to know |
|------|----------------------|-------|--------------|
| **Claude Code** | ✅ **Yes: natively.** The rules fire on every tool call; no adapter. | Nothing to install: `/setup`; `.claude/` loads automatically. | The reference tool: `CLAUDE.md` auto-loads, and all rules, skills, and agents have full support. |
| **opencode** | ✅ **Yes: proven (2026-07-09).** The same rule blocked a real `opencode run --auto` turn's `git add -A`. | `bash bin/install-opencode-adapter.sh` → `.opencode/plugins/apexyard/` | Run with `--auto` so the command reaches the rule. The plugin reads its rule list straight from `.claude/settings.json`, so it cannot drift. Details: [opencode.md](opencode.md), [AgDR-0092](../agdr/AgDR-0092-opencode-gate-adapter.md). |
| **pi** (pi.dev) | ✅ **Yes: proven (2026-07-09).** The same rule stopped a real `pi -p -a` turn. | `bash bin/install-pi-adapter.sh` → `.pi/extensions/apexyard/` | Run headless with `-a` / `--approve`. pi ships deliberately bare-bones and leaves governance to you: ApexYard is that layer. An `AGENTS.md` + `SYSTEM.md` bridge carries the advisory rules. Details: [pi.md](pi.md), [AgDR-0082](../agdr/AgDR-0082-pi-gate-dispatcher-adapter.md). |
| **omp** (oh my pi) | tested with a local scripted model | `bash bin/install-pi-adapter.sh --target-dir <project>/.omp/extensions` | Tested version: omp 18.10.2. See [omp support and test limits](pi.md#omp-oh-my-pi). |
| **Codex** | ✅ **Yes: proven (2026-07-09).** A real `codex exec -m gpt-5.5` turn's `git add -A` fired the same rule (clean exit 2, nothing staged). | `bash bin/sync-codex-adapter.sh` → generates `.codex/hooks.json` | Codex has to trust the rules once: `/hooks` (interactive), `--dangerously-bypass-hook-trust` (one-off), or a user-level `~/.codex/hooks.json`. That is a trust step, not a missing capability. Details: [codex.md](codex.md), [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md). |
| **Cursor** | ✅ **Yes: native in the IDE (2026-09-16).** Cursor loads `.claude/settings.json` when third-party configs are on. `require-active-ticket.sh` refused a real Write call. | Enable third-party configs. Then `bash bin/install-cursor-adapter.sh` for the session-pin overlay. | IDE only. The `cursor-agent` CLI ignores hooks. A leftover full generated adapter can fail-closed-lock the session. Overlay does not copy gates. Details: [cursor.md](cursor.md). |

**The pattern underneath.** The rule is always the *same* unmodified bash. What changes per tool is one small setting that lets the agent's command reach it. That setting is an approve/trust flag (opencode `--auto`, pi `-a`, Codex trust), a config location, or Cursor's third-party-config toggle. Once that setting has a value, the delegated `.claude/hooks/*.sh` runs. Cursor's generated overlay is not a second gate list. It only maps the session id.

## Shared-core architecture

Everything above rests on four load-bearing decisions:

1. **Gates stay portable bash: no per-harness ports.** The `.claude/hooks/*.sh` scripts (merge gates, red-CI block, ticket-first, secrets/leak-protection) are the framework's security-critical trust chain. Rewriting them in a per-harness language would fork the gate logic and re-trigger a full security review per file. Instead, every harness reaches the *same* unmodified scripts. Rationale and the rejected language-port options: [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md).
2. **`.claude/` is the canonical authoring surface.** Skills, agents, hooks, settings, rules, and templates originate under `.claude/` first. Adapter surfaces include `.agents/`, `.codex/`, `harness-adapters/pi/`, and Cursor's thin `.cursor/` overlay. Each one is *generator output from*, or *shells out to*, `.claude/`. None is a second hand-maintained copy of gate logic. This is why adding a gate is a one-place change.
3. **Harnesses are transports, not forks.** An adapter carries a tool call from the harness's event model into the bash hook's stdin/exit-code contract and back. It carries no governance logic of its own. A bug in an adapter can fail to *invoke* a gate. It cannot silently *change* a gate's decision, because the decision lives in bash.
4. **Model tiers resolve through one matrix.** Framework agent frontmatter uses Claude model-tier labels (`opus` / `sonnet` / `haiku`). Each harness maps those to its own concrete models via a single file, [`.claude/harness-models.json`](../../.claude/harness-models.json). The Codex adapter reads the `codex` column. A pi/opencode adapter adds its own column rather than hardcoding a second mapping. Per [AgDR-0087](../agdr/AgDR-0087-reasoning-agents-require-frontier-model.md), each harness's `opus` row must stay on that harness's strongest available model. The reasoning-layer reviewers (Rex, Hakim, Tariq, Naqid) have a frontier-model floor. Adding a harness never downgrades them. See [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md) for how the Codex generator consumes the matrix.

The upshot: mechanical governance is model- and harness-agnostic and self-hostable, while review *depth* keeps a frontier-model floor. AgDR-0086/0087/0088 and 0082 decide those two facts. This page does not assert them.

## Per-harness pages

Each harness has a dedicated page with a consistent skeleton: status, enforcement vs advisory today, and how the transport works. The skeleton also covers how to install/generate, gaps + tracking, and related AgDRs.

- **[Claude Code](claude-code.md)**: Native, full experience. The reference harness: `CLAUDE.md` auto-load, hooks firing live, slash-command skills, sub-agents, session markers. Install pointer: [`docs/getting-started.md`](../getting-started.md).
- **[opencode](opencode.md)**: ✅ **Live-proven (2026-07-09)**. A TypeScript plugin over the unmodified bash hooks with `settings.json`-derived gates (drift-proof by construction); the delegated `block-git-add-all.sh` refused a real `opencode run --auto` turn's `git add -A`. Install: `bash bin/install-opencode-adapter.sh` (subdir shape, #845). Precondition: `--auto`.
- **[pi (pi.dev)](pi.md)**: ✅ **Live-proven (2026-07-09)**. A single dispatcher extension shells out to the bash hooks; the same hooks blocked a real `pi -p -a` turn. The `AGENTS.md`/`SYSTEM.md` advisory bridge works today. Install: `bash bin/install-pi-adapter.sh` (`.pi/extensions/apexyard/`, #845). Precondition: headless `-a`/`--approve`.
- **[Codex](codex.md)**: ✅ **Live-proven (2026-07-09)**. Generated from `.claude/`; a real `codex exec --dangerously-bypass-hook-trust -m gpt-5.5` turn's `git add -A` fired the delegated `block-git-add-all.sh` cleanly (exit 2, nothing staged). Model mapping (`opus`→`gpt-5.5`) is correct. Precondition: **hook-trust**: `/hooks` (interactive), `--dangerously-bypass-hook-trust` (headless one-off), or user-level `~/.codex/hooks.json`. Full workflow in [`docs/codex-adapter.md`](../codex-adapter.md) (linked, not moved).
- **[Cursor](cursor.md)**: ✅ **Native in the IDE (2026-09-16)**. Cursor loads `.claude/settings.json` when third-party configs are on. The generated overlay is session-pin only ([AgDR-0151](../agdr/AgDR-0151-native-first-cursor-overlay.md)). The `cursor-agent` CLI still ignores `hooks.json`. Full workflow in [`docs/cursor-adapter.md`](../cursor-adapter.md).

## Conformance CI: the ongoing, live proof

The manual proofs above date from 2026-07-09: a single, one-off run per harness. [**Conformance CI**](../conformance-ci.md) (`.github/workflows/conformance.yml`) turns that into an ongoing check: one real gated turn per harness. opencode runs daily on its free model. Pi and Codex run on manual dispatch and before each release (AgDR-0278). The check asserts against the delegated hook's own live output, with a per-harness status badge. It uses a **3-consecutive-green-run** definition of "green-continuous" before any harness's badge claims "(proven)". Cursor is deliberately not in the matrix because no headless path exists that would exercise the real gate. Its badge stays a static, hand-seeded "documented-manual" entry that no scheduled run can silently flip to proven. Decision record: [AgDR-0095](../agdr/AgDR-0095-conformance-ci-badge.md).

## Adapter-authoring pattern for future harnesses

Every adapter answers the same question: *how does this harness let a pre-tool gate block an action? How do I route that to the bash hooks without duplicating their logic?* Two shapes have emerged, chosen by how the target harness consumes hook configuration:

- **Declarative-generate**: for harnesses that read a static hook-config file (Codex's `.codex/hooks.json`). Write a generator that reads `.claude/settings.json` + `.claude/agents/*` and emits the harness's native config, with each `command` still exec'ing the unmodified `.claude/hooks/*.sh`. Compile any Claude-Code-specific handler metadata (e.g. handler-level `if` predicates) into a shell-side preflight in the generated command. Ship the *generator and its tests* as the durable contribution; treat the generated tree as regenerable output. Reference: the Codex generator (`bin/sync-codex-adapter.sh`, [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md)). Cursor used this shape until observations showed native `.claude/settings.json` loading. It now ships a thin session-pin overlay instead ([AgDR-0151](../agdr/AgDR-0151-native-first-cursor-overlay.md)).
- **Live extension**: for harnesses with an imperative plugin/extension API (pi's `tool_call` event; opencode's plugin hooks). Write one dispatcher extension driven by a gate table. On each tool call, reconstruct the exact stdin JSON the bash hook expects. Spawn the hook. Map its exit code (`2` = block, `0` = allow) to the harness's block/allow return contract. One dispatcher, N gates as data rows: adding a gate is a table entry, not a new file. Reference: the pi dispatcher (`harness-adapters/pi/src/gate-dispatcher.ts`, [AgDR-0082](../agdr/AgDR-0082-pi-gate-dispatcher-adapter.md)).

In both shapes the non-negotiable is the same: **bash owns every gate decision.** The adapter is the wire, never the judge. And both shapes carry the same last-mile obligation: a live, credentialed end-to-end run. This run proves the harness invokes the gate at the right moment during a real model turn. A by-construction test of the transport alone does not meet this obligation.

## Rebrand trigger

The headline stays **"for Claude Code"** until this condition is met, verbatim:

> The headline flips to harness-neutral only when **≥2 adapters have live end-to-end conformance proof** (then the site + channel positioning follow in a coordinated pass).

"Live end-to-end conformance proof" means the credentialed run described above: a gate blocks a real model turn under that harness. For example, the unmodified bash hook refuses a `git add -A`. A mock or a by-construction test does not qualify.

**As of 2026-07-09 the trigger condition is MET**: three adapters (**opencode**, **pi**, and **Codex**) have recorded that proof. Cursor IDE native exec was later observed (2026-09-16) but still has no headless conformance-CI path, so it does not add a fourth scheduled proof. That does **not** auto-flip the headline: the flip is a **separate, deliberate decision**. That decision moves the site (apexyard.ai) and channel positioning in one coordinated pass, and remains pending. Until then, the framework keeps the Claude-Code tagline and describes multi-harness support in the precise, per-harness terms above rather than as a blanket claim.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*

- [Portfolio adapter management](portfolio-adapters.md): registry-driven install and drift checks.
