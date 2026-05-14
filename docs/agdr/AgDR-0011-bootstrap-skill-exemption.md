# Bootstrap-skill exemption for the ticket-first gate + Bash-write coverage

> In the context of `/setup` (and the rest of the bootstrap-class skills — `/handover`, `/update`, `/split-portfolio`) running BEFORE any portfolio is configured or any tickets exist, facing the dual problem that (a) `require-active-ticket.sh` blocks every Edit / Write the bootstrap skill needs to make and (b) the only escape hatch the agent organically discovered was a `Bash` write through `python -c '…write_text…'` that the hook didn't cover, I decided to ship a file-based active-skill marker (`.claude/session/active-bootstrap`) that the hook reads and exempts skills listed in `ticket.bootstrap_skills`, AND extend `require-active-ticket.sh` + `require-migration-ticket.sh` to fire on `Bash` via a shared `_lib-detect-bash-write.sh` helper that detects the common write shapes (output redirection, `tee`, `sed -i`, `awk -i inplace`, embedded `python` / `node` / `ruby`), to achieve a coherent ticket gate where the legitimate bootstrap path works without ceremony AND the illegitimate Bash bypass is closed in the same PR, accepting that the marker is opt-in (skills must write it; a non-cooperating skill won't get the exemption), that the Bash matcher uses heuristic regex with documented false-negative-preferred semantics, and that the two changes (legitimate-bypass + illegitimate-bypass) ship together because shipping #150 alone would issue an exemption mechanism for a gate that's still trivially bypassable, and shipping #151 alone would make `/setup` the worst first-impression in the framework.

## Context

The framework's safety story rests on `require-active-ticket.sh` blocking code edits without a tracked ticket. That story has two cracks that surfaced together during a fresh-adopter `/setup` test on 2026-05-03:

1. **Crack 1 — legitimate bypass needed (#150).** `/setup` runs before `apexyard.projects.yaml` exists, before any project is registered, before any tickets can be filed. The hook blocks every Edit it tries to make to `.gitignore`, `.claude/project-config.json`, etc. There is no ticket to declare and no place to file one — the framework's first interaction with a fresh adopter is a deadlock.

2. **Crack 2 — illegitimate bypass discovered (#151).** Hitting Crack 1, the agent's natural next move was *"let me try via bash (which doesn't fire that hook)"* — and proceeded to attempt `python3 -c 'pathlib.Path(".gitignore").write_text(...)'`. The bypass would have worked. The hook was scoped to `Edit|Write|MultiEdit` only; any `Bash` write — `echo > file`, `tee`, `sed -i`, embedded interpreters — slipped through.

Both cracks point at the same gate. Shipping a fix to one without the other leaves the framework incoherent:

- Fix Crack 1 only → bootstrap exemption, but the gate is still trivially bypassable. The exemption is a ceremony for a gate that doesn't actually gate anything.
- Fix Crack 2 only → gate is now strict, but `/setup` is now hard-blocked. Adoption flow is worse than before.

A coherent fix lands both at once.

## Options

### Option A — Path-based exemption only (today's pattern, extended)

The hook already exempts `.claude/`, `docs/`, `*.md`. Add `.gitignore`, `onboarding.yaml`, `apexyard.projects.yaml` to the path exemption list. Done.

| Pros | Cons |
|------|------|
| One-line change | Does NOT scale: every new bootstrap-touched file extends the exemption list and the list grows unboundedly |
| No new mechanisms | Path-based exemption is a permission, not a context — anyone editing those paths skips the gate, even outside `/setup` |
| | Doesn't address Crack 2 (Bash bypass) at all |

### Option B — SkillStart hook integration

Wait for Claude Code to expose an official "active skill" lifecycle hook. The skill name lands in a system-managed marker; the ticket hook reads it.

| Pros | Cons |
|------|------|
| Official mechanism, no skill-side opt-in needed | Doesn't exist today — would need an upstream Claude Code change |
| Cleaner: the harness manages the marker lifecycle | Coupling the framework's safety story to an unbuilt CC feature ships unbounded delay |
| | Punts on Crack 2 entirely |

### Option C — Active-skill marker (file-based, skill-cooperative) **CHOSEN**

Each bootstrap-class skill writes its name to `.claude/session/active-bootstrap` on entry and removes the file on completion. The ticket hook reads the marker and exempts skills whose names appear in the configured `ticket.bootstrap_skills` list. A SessionStart hook (`clear-bootstrap-marker.sh`) sweeps stale markers from interrupted sessions. Bash coverage is added in the same PR via `_lib-detect-bash-write.sh` so the gate is actually a gate.

| Pros | Cons |
|------|------|
| Works today, no upstream CC dependency | Skill-cooperative — a skill that forgets to write the marker doesn't get the exemption (correctly, but adds maintenance surface) |
| Scales: new bootstrap skills add themselves to `bootstrap_skills` | A skill that forgets to clear the marker leaves a stale exemption (mitigated by `clear-bootstrap-marker.sh` SessionStart sweep) |
| Closes both Cracks in one PR — coherent safety story | Heuristic Bash detection has documented false-negative tail — bypass surface narrows but isn't formally closed |
| Reuses existing config layer (`.claude/project-config.defaults.json` + `_lib-read-config.sh`) | |
| File-based marker is debuggable (`cat .claude/session/active-bootstrap`) | |

## Decision

Chosen: **Option C — file-based active-skill marker + same-PR Bash coverage extension.**

Three reasons it wins:

1. **Coherent safety story.** Crack 1 and Crack 2 are the same shape (gate not matching the work in front of it). Fixing them separately leaves a window where the framework is worse than before. Bundling them is the right shape — the AgDR captures the pair.
2. **No upstream dependency.** Option B is the prettier long-term mechanism, but waiting on Claude Code to expose a SkillStart lifecycle hook is unbounded delay. Option C works with what's there today and converts cleanly to Option B if/when CC ships the upstream hook (the marker file becomes the harness-written marker file; the consumer doesn't change).
3. **Reuses existing patterns.** The config layer, the `_lib-` helper convention, the SessionStart-sweep pattern — all already present. No new mechanisms; the marker is a one-line `.claude/session/<name>` file like `current-ticket`, the hook chain pattern is the same as `clear-fetch-cache` and friends.

## Scope summary

### 1. Schema — `.claude/project-config.defaults.json`

Adds `ticket.bootstrap_skills` listing `setup`, `handover`, `update`, `split-portfolio`. Adopters can extend in `.claude/project-config.json`. Same pattern as the rest of the config layer.

### 2. Hook changes

- `require-active-ticket.sh`:
  - Now fires on `Bash` in addition to `Edit|Write|MultiEdit`. Sources `_lib-detect-bash-write.sh`; if the Bash command appears to write, extracts the target (best-effort) and applies the same gate logic. If extraction fails, the gate is applied categorically.
  - New bootstrap-marker exemption: reads `.claude/session/active-bootstrap`; if its content matches a skill in `ticket.bootstrap_skills`, the gate is skipped.
- `require-migration-ticket.sh`: parallel Bash extension. The migration gate is path-specific, so an unextractable Bash target naturally falls outside scope (exits 0).

### 3. New library — `_lib-detect-bash-write.sh`

Heuristic Bash-command write detector. Two functions:

- `bash_command_appears_to_write COMMAND` — exits 0 on detected write, 1 otherwise.
- `bash_extract_write_target COMMAND` — best-effort path extraction; empty on failure.

Pattern coverage: output redirection, `tee`, `sed -i`, `awk -i inplace`, `python -c '…write…'`, `python <<EOF …`, `node -e '…writeFile…'`, `ruby -e '…File.write…'`. Design choice: false-negatives PREFERRED over false-positives. Better to miss an obscure write than block a legitimate read on a fresh-adopter test. Pattern table extends as new bypass shapes are observed.

### 4. New SessionStart hook — `clear-bootstrap-marker.sh`

Sweeps stale `.claude/session/active-bootstrap` files from interrupted sessions. Wired into `.claude/settings.json` after the existing `onboarding-check`, `check-upstream-drift`, `check-portfolio-config` chain. Logs to stderr only when it actually clears a marker; silent on the no-marker path (the common case).

### 5. Skill changes

`/setup`, `/handover`, `/update`, `/split-portfolio` each get a "Step 0: write the marker" instruction near the top of the Process section and a "Cleanup: remove the marker" instruction at the end. Skill content otherwise unchanged.

### 6. Tests

- `test_detect_bash_write.sh` — 32 cases covering each pattern in the matcher table, the negative-class read patterns, target extraction, and the exact #151 bypass repro.
- `test_require_active_ticket_bash.sh` — 12 integration cases covering: Bash writes blocked w/o ticket, the #151 python-write bypass closed, Bash reads pass through, path exemptions still work for Bash, bootstrap-marker exemption works for Edit and Bash, unknown / empty marker correctly falls through to the gate, and the legacy active-ticket path still works (regression).

### 7. Doc note

`.claude/rules/workflow-gates.md` § "Pre-Build Gate" gets a one-paragraph callout explaining the exemption.

## Consequences

### Now safer

- The Bash bypass surface is closed for ~95% of writes an agent would naturally reach for. The 5% tail is documented and extends as bypass shapes are observed.
- `/setup` runs end-to-end on a fresh fork without filing a placeholder ticket. Adoption flow is no longer first-impression-broken.
- Both cracks are closed together — no transition window where the framework is internally inconsistent.

### Now riskier

- Skill cooperation matters. A bootstrap skill that forgets to write the marker won't get the exemption (the gate will block — the adopter sees a confusing block on their first run). Caught in code review; documented in each affected SKILL.md.
- Heuristic Bash detection has false-negative tail. A determined agent that researches the matcher patterns will eventually find a shape that slips through. Mitigated by: pattern table is a living list extended on observation; the matcher's false-negative-preference is a deliberate design choice (an over-aggressive matcher that blocks legitimate read commands is a worse failure mode for adoption); commit-time secret scanning and `block-private-refs-in-public-repos` provide defence-in-depth at the persist-to-tracker layer.
- Marker hygiene. A skill that writes the marker but crashes before clearing leaves a stale exemption until the next session. `clear-bootstrap-marker.sh` SessionStart sweep handles this — but inside the same session, the stale marker persists. Acceptable: the next file edit either matches the bootstrap skill's intent (continuation) or is human-driven (operator notices the marker via `git status`).

### Future work — convert to Option B if/when Claude Code ships SkillStart

When/if upstream CC exposes a SkillStart lifecycle hook, this AgDR's Option B becomes available. Conversion is small: the marker file becomes a harness-managed file, the consumer reads the same path. Skills lose the "Step 0: write the marker" prose. No re-architecture needed.

## Artifacts

- `me2resh/apexyard#150` — bootstrap-skill exemption ticket
- `me2resh/apexyard#151` — Bash-write coverage ticket
- `.claude/hooks/_lib-detect-bash-write.sh` — new helper
- `.claude/hooks/require-active-ticket.sh` — Bash + bootstrap exemption extension
- `.claude/hooks/require-migration-ticket.sh` — parallel Bash extension
- `.claude/hooks/clear-bootstrap-marker.sh` — new SessionStart sweep
- `.claude/project-config.defaults.json` — `ticket.bootstrap_skills` entry
- `.claude/skills/{setup,handover,update,split-portfolio}/SKILL.md` — Step 0 + Cleanup
- `.claude/hooks/tests/test_detect_bash_write.sh` — lib unit tests (32 cases)
- `.claude/hooks/tests/test_require_active_ticket_bash.sh` — integration tests (12 cases)
- `.claude/rules/workflow-gates.md` — § Pre-Build Gate doc note
