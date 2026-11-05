---
id: AgDR-0283
timestamp: 2026-11-05T06:24:41Z
agent: codex
model: gpt-6
trigger: user-prompt
status: executed
---

# Default portfolio directory permission

> In the context of split portfolios, facing access prompts, we decided to grant directory permission to achieve default access, accepting next-session activation.

## Context

Issue #1966 requires the ops clone to grant access to its private portfolio directory by default.
SessionStart and `/setup` already share a writer for gitignored local settings.
The portfolio helper owns path selection. The writer must preserve user settings and refuse unsafe roots.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Extend the existing writer | Reuses safe reads, replacement, and lifecycle wiring | Requires a nested settings edit |
| Add an independent hook | Separates entry points | Introduces concurrent local settings writes |

## Decision

Extend the existing writer with a sequential portfolio permission operation.
Resolve the registry parent through `_lib-portfolio-paths.sh`, retaining unresolved components for symlink validation.
Reject missing, non-directory, symlinked, home-folder, filesystem, and ops ancestor roots.
Add only the exact resolved directory. Preserve existing entries and unrelated lexical bytes.
Use `APEXYARD_DISABLE_PORTFOLIO_PERMISSIONS=1` to prevent additions.
Run the writer again after `/setup` creates split-portfolio configuration.

## Consequences

Managed-project clones under portfolio `workspace/` open to file tools without a prompt, and the registry check limits the grant to a real portfolio.

The permission takes effect next session. Single-fork mode adds no permission.
Opting out does not remove an existing entry. The owner can remove that entry manually.
Invalid paths produce an advisory warning. Existing hook-disabling protections remain active.

## Artifacts

- Issue: me2resh/apexyard#1966
- `.claude/hooks/lib/rule-excludes.py`
- `.claude/hooks/_lib-portfolio-paths.sh`
- `.claude/hooks/write-rule-excludes.sh`
- `.claude/hooks/tests/test_write_portfolio_permissions.py`
- `.claude/skills/setup/SKILL.md`
- `docs/multi-project.md`
