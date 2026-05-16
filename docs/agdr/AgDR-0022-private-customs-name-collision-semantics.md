# Private Customs — Delivery Mechanism, Name-Collision Semantics, and Two-Layer Handbook Discovery

> In the context of split-portfolio v2 adopters wanting a private home for **company-specific** custom skills + cross-org handbooks, facing the question of *how* those private artefacts surface inside the public fork's runtime (`.claude/skills/`, Rex's handbook context), I decided to ship a SessionStart symlink hook plus a "custom wins, framework backed up to `.framework.bak`" name-collision rule plus a two-layer handbook discovery in Rex, to keep the public-fork tree authoritative-on-disk while letting the private repo override skills and append handbooks, accepting the trade-offs of relying on POSIX symlinks (Windows requires manual install) and a `.bak` artefact in `.claude/skills/`.

## Context

Adopters running split-portfolio v2 have a private sibling repo (`<fork>-portfolio`) that already houses the registry, per-project docs, `onboarding.yaml`, and `workspace/`. v2 closed the public-fork leak surface for those four file classes. The next gap is **adopter-authored skills + handbooks**:

- A CTO running ApexYard internally writes a `/file-internal-bug` skill that knows the company's bug-tracker conventions. That skill body names the tracker URL, internal project codes, perhaps even API tokens. It cannot ship in the public fork.
- The same CTO wants Rex to read a `company-coding-standards.md` handbook on every PR review. That handbook describes their internal naming conventions, sometimes referencing private repos. Also cannot ship in the public fork.

Today the only way to wire these in is to commit them directly to the public fork (leaks) OR maintain them out-of-band and remember to re-apply on every machine (lossy). The framework needs a first-class home for both, and it has to:

1. **Surface custom skills as if they were native** — `/file-internal-bug` must work at the user's prompt without ceremony
2. **Surface custom handbooks to Rex** — Rex's code review must read them on diffs that match their language/architecture path conventions, same as framework handbooks
3. **Never store either in the public fork's tree**

Three sub-decisions had to be made together because they interact.

## Decision A — Skill delivery mechanism: symlink vs plugin install vs config-block-only resolution

### Options considered

| Option | Pros | Cons |
|--------|------|------|
| **A1. Plugin install** — package each adopter custom skill as a Claude Code plugin and install via `/plugin install <local-path>` | First-class surface; matches the official plugin mechanism we use for LSP | Plugin-install plumbing is heavyweight per-skill; adopter has to repackage on every skill edit; no native symlink-like "edit in private repo, see in fork" iteration loop |
| **A2. Direct copy on SessionStart** — copy `<sibling>/custom-skills/<name>/` → `<fork>/.claude/skills/<name>/` on every session start | Simple; no symlinks (works on Windows out of the box) | Writes into the public fork's tree, which means dirty working copy on every session, gitignored or not. Friction with `git status` review. Also: per-edit re-copy required, which silently overwrites in-progress edits |
| **A3. Symlink on SessionStart** — `ln -sf <sibling>/custom-skills/<name> <fork>/.claude/skills/<name>` | Adopter edits in private repo, fork picks up immediately, no working-copy churn (the symlink itself is gitignored). Idempotent re-runs are cheap. | POSIX-only (Windows ln equivalent is fragile); leaves `.claude/skills/` with mixed real-dir + symlink-dir entries (operator has to remember which is which); requires gitignore discipline (already covered for v2) |
| **A4. Runtime config-block resolution only** — extend Claude Code skill loader to consult `portfolio.custom_skills_dir`, no on-disk linking | Cleanest semantics; nothing lands in `.claude/skills/`; matches how onboarding.yaml resolution already works | Requires changes inside Claude Code itself (the loader, the slash-command resolver, the autocomplete index) — outside the framework's reach. Not viable in framework-only territory. |

### Choice — **A3 (symlink on SessionStart)**

The framework lives at the "everything outside Claude Code internals" boundary. A4 is the cleanest design but requires loader cooperation we don't have. A3 gets us 90% of A4's behaviour using existing primitives (symlinks + the SessionStart hook chain). A1 has the right semantics but the per-edit packaging tax is too high for the "I just want a skill" use case. A2 turns every session into a dirty tree.

A3's failure mode (Windows) is contained: the `link-custom-skills.sh` hook detects `uname` reporting MSYS/MINGW/Cygwin and prints a one-line "manual-install pointer" instead of attempting `ln`. Adopters on Windows can copy by hand or run the hook under WSL where symlinks work. This is the same shape as the existing LSP optional-plugin behaviour — feature available on POSIX, graceful decline on Windows.

## Decision B — Name-collision semantics: framework vs custom

### Options considered

| Option | Pros | Cons |
|--------|------|------|
| **B1. Framework wins** — refuse to link custom `/handover` over framework `/handover`, print warning | Conservative; framework behaviour stays predictable; CEO never gets a custom skill they forgot they wrote shadowing the canonical one | Defeats the use case: adopters who want a customised `/handover` (their org has a different onboarding checklist) cannot override. They'd have to fork the skill upstream, which means going public again. |
| **B2. Custom wins, no backup** — symlink overwrites the framework skill dir; on uninstall there's nothing to restore | Adopter intent is honoured | Destructive — if the operator removes their custom skill, the framework version is gone too; recovery requires `git checkout .claude/skills/handover` which is a chore + footgun |
| **B3. Custom wins, framework moved to `.framework.bak`** — `mv .claude/skills/handover .claude/skills/handover.framework.bak; ln -sf <sibling>/custom-skills/handover .claude/skills/handover` | Adopter intent honoured AND the framework version is recoverable in one `mv` back. Visible in `ls`, so the operator sees what's happening. | Leaves a `.bak` artefact in `.claude/skills/`. Gitignored via `*.framework.bak` to avoid noise. Marginal cognitive overhead. |
| **B4. Prompt operator on collision** — interactive ask: "framework `/handover` exists, override?" | Most explicit | Hook runs at SessionStart — there's no operator to prompt yet. Defers the decision to a place no operator can answer it. |

### Choice — **B3 (custom wins, framework moved to `.framework.bak`)**

The CTO writing a custom `/handover` is making a deliberate override decision. The framework should honour it (B1 fails the use case) but not destructively (B2 is a footgun). B4 doesn't work at SessionStart. B3 is the only option that both honours intent and leaves a recovery path. The `.framework.bak` artefact is the cost; gitignoring `*.framework.bak` keeps it out of `git status`.

The hook prints a one-line warning on every collision so the operator sees `which command they overrode`:

```
link-custom-skills: /handover overridden by custom; framework moved to .claude/skills/handover.framework.bak
```

## Decision C — SessionStart timing for the link operation

### Options considered

| Option | Pros | Cons |
|--------|------|------|
| **C1. SessionStart hook (chosen)** | Runs once per session before any skill is invoked; idempotent re-link refreshes if adopter added/renamed/deleted a custom skill between sessions; aligns with `clear-bootstrap-marker.sh`, `check-upstream-drift.sh`, `portfolio_validate` | Adds one more hook to the SessionStart chain. Latency contribution: < 50ms (single `find` + symlink calls). |
| **C2. Trigger-on-skill-invoke** — link the specific skill the first time the operator types `/file-internal-bug` | Lazy; no startup cost | Plumbing intrusive; would require Claude Code to call the framework on skill-not-found, which it doesn't do. Same A4-shaped problem. |
| **C3. One-shot install at `/setup` time** | Zero per-session cost | Adopters who add a new custom skill after running `/setup` have to remember to re-run a separate install command. High forgetfulness tax. |

### Choice — **C1 (SessionStart hook)**

SessionStart is already the framework's main "ensure invariants on every session" surface. Adding `link-custom-skills.sh` there matches the existing pattern, and the per-session latency cost (<50ms) is invisible against the rest of the SessionStart chain. C3 fails on the iteration loop — adopters edit custom skills frequently in early days, and "remember to re-install" is the exact ceremony the framework should absorb.

The hook is silent on success (zero new custom skills, or N skills linked with no collisions) and prints **only one line per collision OR a summary like `linked 2 custom skills`** otherwise. Banner shape mirrors `check-upstream-drift.sh`.

## Decision D — Rex handbook discovery: two-layer (framework + custom) vs single-layer

### Options considered

| Option | Pros | Cons |
|--------|------|------|
| **D1. Single-layer, symlink custom handbooks into `handbooks/`** (same shape as the skills choice) | Symmetric with custom skills; one mechanism | Adopters editing handbooks would see them mixed with framework handbooks in `ls handbooks/`; collisions get the same `.framework.bak` treatment, which is overkill for the "additive notes" use case where adopters usually want to *add* a handbook rather than override one |
| **D2. Two-layer: Rex reads both `handbooks/` (framework, in the fork) AND `<sibling>/custom-handbooks/` (resolved via the portfolio config block)** | Adopter handbooks are additive by default — they sit alongside framework ones in Rex's context without shadowing; symbolic override is still possible (same `architecture/` / `general/` / `language/<lang>/` path convention applies to both layers, so a custom file at `custom-handbooks/general/security.md` adds to whatever framework ships under `handbooks/general/`) | Two discovery roots; Rex's agent prompt has to enumerate both; slightly more complex to reason about |
| **D3. Single-layer, all handbooks live in private repo** (move framework handbooks out of the public fork entirely) | Maximally clean separation | Loses the framework's shipped handbooks (the architecture/general/language/ examples Rex ships with). Adopters who don't write any handbooks get zero. |

### Choice — **D2 (two-layer discovery in Rex)**

Custom handbooks are typically **additive** — *"add our company's TypeScript naming convention on top of what apexyard already ships"*. The skills-style "custom wins, framework backed up" semantics are wrong for the additive case; they force every custom handbook to override a framework one. D1 reuses the skills mechanism but fights the actual use case.

D3 is the cleanest design but loses the shipped handbooks, which are the demo content for the feature. D2 gets the best of both — Rex reads framework `handbooks/` plus `<sibling>/custom-handbooks/` (resolved via `portfolio.custom_handbooks_dir` from the config block), applies the same `architecture/` + `general/` + `language/<lang>/` path conventions to both, and the operator can layer or shadow as they choose just by where they put the file.

The agent prompt for Rex (`.claude/agents/code-reviewer.md`) enumerates both roots in its discovery step. The framework's existing `handbooks/README.md` documents the layering.

## Consequences

### Positive

- Adopters get a private home for company-specific skills and handbooks without ever staging private content in the public fork's tree
- The `link-custom-skills.sh` hook is idempotent and SessionStart-driven, matching the existing framework hook patterns
- Name collisions are visible (`.framework.bak` artefact + one-line warning) rather than silent
- Rex picks up custom handbooks on the same diff-match conventions as framework handbooks — no per-handbook configuration
- Windows operators get a graceful decline with a manual-install pointer rather than a confusing failure

### Negative

- `.claude/skills/` becomes a mixed dir of real dirs (framework) + symlinks (custom) + `*.framework.bak` (overridden). Operators reviewing `ls` must remember to interpret each. Mitigated by the hook printing a summary line on link/override.
- Windows is degraded (manual install). Documented; same shape as LSP plugins.
- Two-layer handbook discovery has a slightly larger surface in Rex's agent prompt than a single-layer model would. Acceptable; the agent prompt already enumerates multiple sources.

### Open questions deferred to a future AgDR

- Whether to support per-project custom handbooks (currently org-wide only; a managed-project would need to handbook-customise via its own repo's `handbooks/`).
- Whether to expose custom-skill discovery to plain `claude` CLI (currently the symlink approach works for both interactive sessions and CLI use; verified during #243 implementation).

## Artifacts

- Implementation: `.claude/hooks/link-custom-skills.sh` (POSIX symlink, idempotent, Windows decline)
- Tests: `.claude/hooks/tests/test_link_custom_skills.sh` (6 cases — no-op, two-skill link, collision, Windows, idempotent re-run, subdir-without-SKILL.md skip)
- Path resolution: `_lib-portfolio-paths.sh` → `portfolio_custom_skills_dir`, `portfolio_custom_handbooks_dir`
- Setup docs: `.claude/skills/setup/SKILL.md` (config-block keys); `docs/multi-project.md` (split-portfolio v2 section); `handbooks/README.md` (two-layer discovery note)
- Wiring: `.claude/settings.json` (SessionStart entry); `.gitignore` (`.claude/skills/*.framework.bak`, custom-skills symlinks)
- Agent prompt: `.claude/agents/code-reviewer.md` (Rex's discovery step now enumerates both handbook roots)
- Issue: #243 / PR #253
