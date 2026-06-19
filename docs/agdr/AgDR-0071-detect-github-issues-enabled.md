# Detect (and offer to enable) GitHub Issues during /setup + /handover

> In the context of apexyard's tracker model assuming a working issue tracker, facing GitHub's default of **disabling Issues on forks** (so a fresh github-kind fork fails every issue-creating skill with a cryptic error), I decided to add a **tracker.kind-gated detection** to `/setup` and `/handover` that **warns and offers to enable** (never auto-enables) Issues, plus a shared `_lib-tracker.sh` helper, to achieve early, friendly failure-prevention, accepting that the check is advisory and only meaningful for github-kind trackers.

## Context

GitHub disables Issues on forks (and can on new repos) by default. apexyard's issue-creating skills (`/feature`, `/bug`, `/task`, `/tickets-batch`, `/idea`, `/migration`, `/spike`, `/investigation`) all assume `gh issue create` works against the configured tracker repo. When Issues are off, every one of them fails with `the '<owner>/<repo>' repository has disabled issues` — a silent first-run footgun nothing in the bootstrap flow surfaces. This was hit live while trying to file a fork-maintenance chore.

The tracker is configurable (`.tracker.kind` = `gh` | `linear` | `jira` | `asana` | `custom` | `none`). For non-github kinds, GitHub Issues being off is *correct*, so any check must be gated.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Do nothing (status quo) | No work | The footgun persists; every fresh github fork hits it at first issue-creating skill |
| **Detect + warn + offer-to-enable in /setup + /handover, gated on tracker.kind** | Catches it at the cheapest moment (bootstrap / adoption); respects non-github trackers; one shared lib helper; never mutates repo settings without consent | A new helper + two SKILL steps to maintain |
| Auto-enable Issues during setup | Zero-friction fix | Externally-visible repo-settings change without consent; needs admin scope; wrong for adopters who intentionally track elsewhere |
| Only fix at point-of-use (catch the gh error in each skill) | Fixes the actual failure site | 8 skills to edit; the operator still hits the error once per skill before the hint; misses the "tell me up front" value |

## Decision

Chosen: **detect + warn + offer-to-enable in `/setup` and `/handover`, gated on `tracker.kind`, backed by a shared `_lib-tracker.sh` helper** — with point-of-use graceful-degrade as a complementary (not primary) layer.

Load-bearing principles:

1. **Gate on `tracker.kind`** — github-only (`gh`/`github`); a silent no-op for `linear`/`jira`/`asana`/`custom`/`none`.
2. **Inform always, enable only on explicit opt-in** — `tracker_check_issues` only *reports*; enabling (`gh repo edit <repo> --enable-issues`) is the caller's explicit y/n step. Never silent (admin scope + externally visible + may be intentional).
3. **Never false-alarm** — when `gh` can't answer (missing / network / auth), the verdict is `ok`, not `disabled`.
4. **Pure, testable core** — `tracker_issues_verdict <kind> <has_issues_enabled>` is I/O-free so the decision logic is unit-tested exhaustively; the gh round-trip is a thin wrapper.

Surfaces:

- `_lib-tracker.sh`: `tracker_issues_verdict` (pure), `tracker_issues_enabled_raw` (gh probe), `tracker_issues_enable_hint`, `tracker_check_issues` (compose: warn + return 1 when disabled).
- `/setup` Step 7b: probe the ops fork repo; offer to enable.
- `/handover` Step 7.5 pre-check: probe the adopted project's repo before the Next-Steps filing loop; advisory.

## Consequences

- A fresh github-kind fork is told at `/setup` time that Issues are off, with a one-command fix, instead of discovering it via a cryptic error later.
- Non-github adopters see nothing (gated).
- No repo settings change without explicit consent.
- Point-of-use graceful-degrade across all 8 issue-creating skills is a follow-up (the lib helper is the shared mechanism they'll call); this AgDR's scope is the bootstrap/adoption detection + the helper.

## Artifacts

- Issue: me2resh/apexyard#653
- Lib: `.claude/hooks/_lib-tracker.sh` (`tracker_issues_*`)
- Skills: `.claude/skills/setup/SKILL.md` (Step 7b), `.claude/skills/handover/SKILL.md` (Step 7.5 pre-check)
- Tests: `.claude/hooks/tests/test_tracker_issues_detection.sh`
