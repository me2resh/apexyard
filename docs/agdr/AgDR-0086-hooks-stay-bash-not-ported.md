# AgDR-0086 — Keep `.claude/hooks` in bash; support other OSes via adapter-over-bash + Git Bash, not a language port

> In the context of bash being the runtime of the framework's entire hook layer with no native Windows execution outside Git Bash/WSL, facing spike #466's question of whether porting `.claude/hooks/**` to a cross-platform runtime (Node/Python/Go) is the highest-leverage move for Windows-native support, I decided **to keep bash as the single source of truth and reach other OSes/harnesses through thin adapters that shell out to the unmodified hooks, plus a documented Git Bash prerequisite on Windows**, to achieve cross-platform coverage without rewriting the security-critical trust chain, accepting that fully native Git-Bash/WSL-free Windows support remains unaddressed until (if ever) it becomes an explicit business requirement.

## Context

The `.claude/hooks/*.sh` scripts are the mechanical enforcement layer of the ApexYard SDLC — merge gates, red-CI blocking, ticket-first, secrets/leak-protection. They run natively on macOS/Linux; on Windows they need WSL or Git Bash. Spike #466 hypothesised that the bash hooks (not the git-fork/pipx distribution mechanism) were the real blocker to Windows-native support, and that porting them to a cross-platform language would be feasible without losing the PreToolUse/PostToolUse gating semantics.

The spike found a port is **technically viable but not worth doing now**. Decision-relevant facts it surfaced:

- The hooks directory is far larger than the ticket assumed: 58 files (44 hooks + 14 shared `_lib-*.sh` libraries), ~13,142 lines, plus a **19,019-line bash test suite** larger than the code it tests.
- The 14 `_lib-*.sh` files (4,201 lines, ~32% of the total) are the real cost — each encodes dozens of previously-debugged edge cases (multi-tracker dispatch, split-portfolio path resolution, the `gh api` vs `gh pr merge` bypass fix from #47) that a naive port would silently regress unless re-verified against the also-bash test suite.
- The hook **wiring** in `.claude/settings.json` is an inline bash bootstrap duplicated across ~40 hook registrations; porting the hook bodies alone doesn't remove it, so any real port also means rewriting ~40 `command` entries.
- Because `.claude/hooks/**` is the framework's explicit security-critical trust chain, every ported file re-triggers a mandatory Security Auditor review — dozens of security-reviewed PRs, not one refactor.
- The framework validated the **opposite** direction the same week: spike #804 (pi.dev) promoted to #815 and a matching opencode spike promoted to #821 — both prove a thin per-harness adapter shelling out to the *unmodified* bash hooks, keeping bash as the single source of truth. A language port would replace that source of truth and strand the in-flight adapter work.
- Windows-via-Git-Bash already works today: the one concrete blocker (an ancestor-directory-walk that never terminated on `C:`-drive paths) was fixed in #691.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| (a) Port hooks to **Node.js** | Matches the stack already used by premium/admin/pi-adapter tooling; enables native Windows | Multi-week (T-shirt L): ~4.2k lines of `_lib-*.sh`, the 19k-line parallel bash test suite, the `settings.json` ~40-entry rewrite, and per-file Security Auditor review; replaces and strands the adapter-over-bash direction #815/#821 depend on |
| (b) Port hooks to **Python** | Cross-platform; readable | Same multi-week cost as (a); additionally carries Python's flagged startup-latency cost (AgDR-0038) on hooks that fire on every tool call |
| (c) Port hooks to **Go** | Single static binary, fast | Largest effort (T-shirt XL); conflicts with the fork-and-clone distribution model (AgDR-0047); same strand-the-adapters problem |
| (d) **Stay bash** — single source of truth; reach other OSes/harnesses via adapter-over-bash (#815/#821) and document Git Bash/WSL as a stated Windows prerequisite | Zero change to the trust chain (no re-review churn); complements rather than replaces the live multi-harness adapter work; closes the actual Windows gap cheaply, same shape as the existing `jq` hard-dependency precedent (AgDR-0038); Windows already works via Git Bash after #691 | Does not deliver *native*, Git-Bash/WSL-free Windows execution — an adopter on Windows must install Git Bash |

## Decision

Chosen: **(d) — keep `.claude/hooks` in bash as the single source of truth**, do **not** port to a cross-platform runtime, and support other OSes/harnesses through the adapter-over-bash pattern (#815/#821) plus a documented Git Bash/WSL prerequisite on Windows.

The port is disqualified against spike #466's own kill criteria on cost (multi-week for the shared libs + parallel bash test suite + `settings.json` rewrite + per-file security review), and — more decisively — it would replace the exact source of truth the validated multi-harness direction shells out to. The cheap fix that closes the real gap (documenting Git Bash/WSL as a Windows prerequisite, mirroring the `jq` hard dependency in AgDR-0038) ships in the same PR as this decision, without touching the trust chain.

## Consequences

- Windows adopters run the hooks today via Git Bash/WSL (documented prerequisite, the `C:`-path hang fixed in #691); there is no native, Git-Bash-free Windows path, and that is an accepted, stated limitation — not a silent failure.
- Cross-OS and cross-harness coverage is delivered by thin adapters over the unmodified bash hooks (#815 pi.dev, #821 opencode), keeping one behavioural source of truth and avoiding a fork of the trust chain.
- If native, Git-Bash/WSL-free Windows support ever becomes an explicit business requirement (not just "works via a documented prerequisite"), **Node.js** is the best of the three language options — it matches existing tooling, avoids Python's startup-latency cost (AgDR-0038) and Go's distribution-model conflict (AgDR-0047). Revisiting is a dedicated multi-week initiative that must carry **its own AgDR**, not an add-on to this decision.

## Artifacts

- Spike disposition memo: [`docs/spike-memos/GH-466-cross-platform-hooks.md`](../spike-memos/GH-466-cross-platform-hooks.md)
- Spike ticket: me2resh/apexyard#466 (DISCARD); PR #823
- Multi-harness adapter direction this defers to: #804 → #815 (pi.dev gate adapter), opencode gate adapter spike → #821
- Precedent — explicit prerequisite beats silent failure: [AgDR-0038](AgDR-0038-jq-as-hard-dependency.md); Windows Git-Bash hang fix: #690/#691
