# Spike memo: Evaluate porting .claude/hooks off bash to a cross-platform runtime for Windows-native support

> **Disposition: DISCARD** — hypothesis rejected (viable, but not worth doing); not pursuing further.

- **Spike ticket**: me2resh/apexyard#466
- **Author**: me2resh
- **Closed**: 2026-07-08

## Hypothesis (from the spike ticket)

apexyard's `.claude/hooks/*.sh` bash scripts are the real blocker to Windows-native support — not the distribution mechanism (git fork / pipx both work cross-platform). On Windows the hooks need WSL or Git Bash; to be truly native they'd need a cross-platform runtime. Porting the hooks to a cross-platform language (Python or Node) was hypothesized to be feasible without losing the PreToolUse/PostToolUse gating semantics, and the highest-leverage move for Windows support.

## Findings

A port is technically **viable** — nothing in the hook logic resists translation to Node or Python — but it is not worth doing now. The hooks directory has grown well past the ticket's original estimate: 58 files (44 hooks + 14 shared `_lib-*.sh` libraries), 13,142 lines, plus a 19,019-line bash test suite that is itself larger than the code it tests. The 14 `_lib-*.sh` files (4,201 lines, ~32% of the total) are the real cost — not because the logic is conceptually bash-only, but because each one encodes dozens of previously-debugged edge cases (multi-tracker dispatch, split-portfolio path resolution, the `gh api` vs `gh pr merge` bypass fix from #47) that a naive port would silently regress unless re-verified against the also-bash test suite. A further wrinkle: the hook *wiring* itself, in `.claude/settings.json`, is an inline bash bootstrap duplicated across roughly 40 hook registrations — porting the hook bodies alone doesn't remove it, so any real port also means rewriting `settings.json`'s ~40 `command` entries. Because `.claude/hooks/**` is the framework's explicit security-critical trust chain, every ported file would also re-trigger a mandatory Security Auditor review — dozens of security-reviewed PRs, not one refactor PR.

## Why we're not pursuing

The port cost (multi-week — the shared libs plus the parallel bash test suite plus the settings.json rewrite plus per-file security review, T-shirt-sized L for Node/Python and XL for Go) is disqualifying against the spike's own kill criteria. More decisively, the framework validated the *opposite* direction the same week this spike ran: spike #804 (pi.dev support) closed VIABLE and promoted to #815, and a matching opencode spike promoted to #821 — both prove a thin per-harness adapter that shells out to the **unmodified** bash hooks, keeping bash as the single source of truth. A language port would replace that source of truth and strand the in-flight adapter work rather than complement it. On top of that, Windows-via-Git-Bash already works today: the one concrete blocker (an ancestor-directory-walk that never terminated on `C:`-drive paths) was fixed in #691. The cheap fix — document Git Bash/WSL as a stated Windows prerequisite, same shape as the existing `jq` hard dependency (AgDR-0038) — closes the actual gap without touching the trust chain at all, and has been made as part of this same PR.

## What would change the answer

If native, Git-Bash/WSL-free Windows support ever becomes an explicit business requirement (not just "it works via a documented prerequisite"), Node.js is the best of the three real language options — it matches the stack already used by the premium/admin/pi-adapter tooling, avoids Python's flagged startup-latency cost (AgDR-0038), and avoids Go's conflict with the fork-and-clone distribution model (AgDR-0047). That would need its own multi-week initiative and its own AgDR — not an add-on to this spike.

## Artefacts

- Decision record: [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md) — the "keep hooks in bash; adapter-over-bash + Git Bash" decision this memo records
- Original spike ticket: me2resh/apexyard#466
- Spike branch: `spike/GH-466-cross-platform-hooks` (delete after merge of this memo)
- Full findings: `docs/spike-reports/GH-466-cross-platform-hooks.md` on the spike branch
- Related: [AgDR-0038](../agdr/AgDR-0038-jq-as-hard-dependency.md) (explicit-prereq-beats-silent-failure precedent), #690/#691 (Windows Git-Bash hang bug + fix), #804 → #815 (pi.dev gate adapter), opencode gate adapter spike → #821 — the live multi-harness direction this memo defers to
