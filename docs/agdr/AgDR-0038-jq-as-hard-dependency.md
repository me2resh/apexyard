# AgDR-0038 — `jq` as a hard dependency (declare + check + warn)

> In the context of 22+ framework hooks reading `.claude/project-config.json` via `jq` to honour adopter overrides, facing the failure mode where a jq-less machine silently degrades every override to the framework default with no error and no warning, I decided to **declare `jq` as a hard dependency** with **`/setup` pre-flight detection**, a **SessionStart advisory hook**, and a **prerequisite line in `docs/getting-started.md`**, accepting that locked-down corporate environments without jq install rights cannot run the framework until they get jq onto PATH.

## Context

Framework hooks lean on `jq` to read adopter overrides from `.claude/project-config.json` and `.claude/project-config.defaults.json`. A non-exhaustive sample of what depends on it: `.ui_paths` + `.ui_paths_exclude` (design-review gate), `.tracker.*` (multi-tracker dispatch — AgDR-0033), `.migration_paths` (migration gate), `.ticket.bootstrap_skills` (bootstrap exemption — AgDR-0011), `.ticket.create_command_patterns` (skill-gated ticket-create — AgDR-0030), `.git.protected_branches`, `.leak_protection.public_framework_repos`, etc. All of those reads route through `_lib-read-config.sh → config_get → jq … 2>/dev/null`.

The failure mode surfaced on 2026-05-18 in an adopter fork: a `.ui_paths` override was added to silence a design-review-gate false positive on a non-UI `.jsx` file. The override appeared to have no effect because `jq` wasn't installed on the machine. `jq … 2>/dev/null` returned empty, the hook silently fell back to the default UI-paths array, the false positive kept firing. No error, no warning, no log line — just an invisible "your override doesn't work, and we won't tell you why".

This is a **class problem**, not a one-off: every adopter override that travels through `_lib-read-config.sh` silently degrades on jq-less machines. The cost of leaving it alone scales with the number of overrides the framework adds over time, and any new hook that consumes config inherits the same silent-degradation behaviour by default.

The decision space had two live options.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A — declare `jq` as a hard dependency** (this AgDR) | Simplest possible mechanism. Explicit failure beats silent degradation — the operator sees a clear error message at `/setup` time, or a one-line SessionStart banner if jq disappears later. Zero changes to hook internals; `_lib-read-config.sh` stays the way it is. Detection cost is one `command -v jq` per invocation site. jq is broadly available — `brew install jq` / `apt-get install jq` / `dnf install jq` / Windows via choco or scoop, ~5s install on the happy path. | Locked-down corporate environments that can't easily install new system packages can't run ApexYard until jq is on PATH. Dependency-management burden lives with the adopter. |
| **B — implement a jq-free fallback inside `_lib-read-config.sh`** | No new install burden on the adopter — the framework "just works" on a fresh machine with only Python 3 installed (which is true for every modern Linux distro, macOS, and most CI images). | Two JSON parsers to maintain (jq path + Python path), with the Python path getting less testing because most CI runs hit jq. Subtle semantic differences (jq's filter language vs `json.loads()` + dict access) become a long-term tax — every new override key has to work in both parsers. Dependency-management burden shifts onto the framework. Adds latency on the Python path (Python startup is ~50-100ms; jq is <10ms). Doesn't fix the broader pattern (any future hook adding a new external dep faces the same fallback-or-fail choice). |

The earlier framework patterns — Mermaid lint (`_lib-mermaid-lint.sh`), BPMN lint (`/process` skill), PDF converter dispatch (AgDR-0034 / `/pdf`) — all chose **graceful degrade with a single advisory at use time**, NOT a multi-tool dispatch inside the core library. That precedent argues for A: surface the missing dep loudly, keep the lib path single.

## Decision

Chosen: **Option A — declare `jq` as a hard dependency**, because:

1. **Explicit failure beats silent degradation.** The whole point of this AgDR is that the adopter was burned by a silent fallback. A noisy "jq missing" banner is strictly better than an invisibly-ignored override, even if it costs them one `brew install jq`.
2. **Dependency-management burden shifts to adopters either way.** Option B looks like it removes the burden, but the Python fallback path is itself a dep (`python3` on PATH, JSON-shaped dicts matching jq's filter semantics). Adopters who don't have jq are usually adopters who have constrained installs in general; if they can install Python, they can install jq. The shift is illusory.
3. **Simpler is the right shape for a class problem.** Every hook reading config already calls `config_get`. Adding a single pre-flight check (in `/setup`) + a single SessionStart advisory (a new hook) + a single prerequisite doc line covers every override key, current and future. No per-key changes, no parser-compatibility tests, no two-codepaths-to-maintain.
4. **jq is genuinely broadly available.** The framework's target audience (CTOs, engineering leads on macOS / Linux / WSL) almost always has jq one package-manager command away. The hard-dep cost is small in practice.

Where the failure surfaces:

| Surface | Mechanism | What the operator sees |
|---------|-----------|-----------------------|
| First-run `/setup` | Pre-flight `command -v jq` check; refuses with exit 1 + install instructions before any state-mutating step. | `✗ ApexYard requires jq for reading project-config overrides…` |
| Every SessionStart (after first-run) | New advisory hook `check-jq-installed.sh` mirrors `check-upstream-drift.sh` shape — exits 0 always, prints a one-line banner if jq is missing AND a project-config file exists. | `ApexYard: jq is not installed. Hooks that read project-config overrides… will silently fall back to framework defaults.` |
| Onboarding docs | `docs/getting-started.md § Prerequisites` lists `jq` alongside `gh`. | One bullet in the prerequisites list with install instructions. |

The SessionStart hook **does not block** — it's an advisory in the same vein as `check-upstream-drift.sh`. Blocking on jq-missing at SessionStart would brick the session for an adopter who happens to be running `/threat-model` or `/audit-deps` and doesn't touch any overrides — disproportionate. The banner lets them choose: install jq now, or accept that any active overrides aren't taking effect.

## Consequences

### Positive

- **Visible failure mode.** Silent degradation becomes a clear refusal at `/setup` and a one-line banner at every SessionStart after. The adopter cannot miss it.
- **`_lib-read-config.sh` stays single-path.** No parallel JSON parser to maintain, no semantic drift between two paths, no per-key compatibility tests. New override keys "just work" with no extra plumbing.
- **Uniform with existing graceful-degrade patterns.** Mermaid lint, BPMN lint, PDF converter dispatch — all of them surface missing deps loudly at use time rather than rewriting the core library. This decision matches that shape and is easy to teach.
- **Zero per-hook changes.** The 22+ hooks calling `config_get` need no edits. The mitigation lives at three discrete points (`/setup`, the new SessionStart hook, the docs).
- **Cheap to roll back.** If Option B becomes preferred later, the SessionStart hook can be removed and `_lib-read-config.sh` can grow a Python fallback — no decisions in this AgDR foreclose that future.

### Negative

- **Locked-down corporate environments without jq install rights are blocked.** A team behind a paranoid IT department that doesn't whitelist jq cannot run the framework until they whitelist it. The README + AgDR-0038 give them the request-this-package case to take to IT, but the unblock is on their side.
- **Adopter who never overrides anything still pays the install cost.** Even forks that run on pure framework defaults need jq on PATH to avoid the SessionStart banner. Mitigation: the banner is opt-out-of-warning style — "Or skip if you don't override any defaults." reads as permission to ignore for those adopters.
- **A new SessionStart hook is one more bootstrap dep.** Adds ~10ms to SessionStart (one `command -v jq` + an `ops_root` walk). Negligible, but non-zero.
- **Behaviour change for adopters who were inadvertently relying on silent fallback** (i.e. their overrides were never being honoured but they didn't know). This is the right change — they should know — but it surfaces as a "wait, what?" moment when they first run a new session after upgrading.

### Migration / rollback

- **No data migration needed.** This is additive: new hook + new doc line + new `/setup` pre-flight step.
- **Rollback** is `git revert` of the introducing PR. No state in `.claude/session/` is created. Adopters who had jq-less forks continue to work (silently degraded) the way they always did.
- **Adopters who hit the SessionStart banner and don't want it** can either install jq (the intended path) or stop using ApexYard. There's no escape-hatch env var in v1 — adding one (`APEXYARD_ALLOW_NO_JQ=1`) is a follow-up if real adopter pressure surfaces; for now the explicit refusal is the point.

## Artifacts

- PR: <to be filled at merge time>
- Issue: [me2resh/apexyard#280](https://github.com/me2resh/apexyard/issues/280)
- Skill: `.claude/skills/setup/SKILL.md` (new Step −1 pre-flight check)
- Hook: `.claude/hooks/check-jq-installed.sh` (new SessionStart advisory)
- Hook wiring: `.claude/settings.json` (new SessionStart entry, sibling to `check-upstream-drift.sh`)
- Tests: `.claude/hooks/tests/test_check_jq_installed.sh`
- Docs: `docs/getting-started.md § Prerequisites` (new bullet)
- Sibling patterns this AgDR reuses:
  - AgDR-0005 — tag-based upstream drift detection (same SessionStart advisory shape, exit 0 always)
  - AgDR-0034 — `/pdf` converter dispatch (same "loud at use time, no fallback in core lib" pattern)
  - `_lib-mermaid-lint.sh` — same shape, npx-fallback case for a different external dep
