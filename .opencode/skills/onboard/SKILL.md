---
name: onboard
description: "DEPRECATED — use /setup for framework configuration, /handover for adding a project to the portfolio. This skill redirects to the correct flow."
disable-model-invocation: false
argument-hint: ""
effort: low
---

# /onboard — DEPRECATED

This skill has been split into two purpose-specific flows:

| What you want to do | Run instead |
|---------------------|-------------|
| **Configure the ApexYard fork** (first-run setup, company info, tech stack defaults) | `/setup` |
| **Add a project to the portfolio** (onboard an external repo, per-project discovery) | `/handover <repo>` |

## Why the split

`/onboard` mixed two concerns: framework-level bootstrap (writing `onboarding.yaml`) and per-project discovery (writing `project-config.json`). These happen at different times, write to different files, and have different triggers:

- `/setup` runs **once per fork** and writes `onboarding.yaml` (committed, framework-wide).
- `/handover` runs **once per project** and writes `project-config.json` (per-project, in the workspace).

The per-project discovery questions (tracker repo, CI checks, architecture paths, UI paths, commit types) are now part of `/handover`'s assessment flow — they're asked when a project enters the portfolio, not as a standalone ceremony.

## If you got here from the SessionStart hook

The `onboarding-check.sh` hook now checks `onboarding.yaml` for placeholder values, not a session marker. Run `/setup` to configure your fork.
