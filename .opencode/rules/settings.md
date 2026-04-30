# Configuration Mapping

This document maps the original Claude Code settings to OpenCode configuration.

## Original .claude/settings.json

```json
{
  "hooks": {
    "SessionStart": ["onboarding-check.sh", "check-upstream-drift.sh"],
    "PreToolUse": {
      "Edit|Write|MultiEdit": ["require-migration-ticket.sh", "require-active-ticket.sh"],
      "Bash": {
        "git add *": "block-git-add-all.sh",
        "git push *": ["block-main-push.sh", "validate-branch-name.sh", "pre-push-gate.sh"],
        "git commit *": ["check-secrets.sh", "verify-commit-refs.sh", "validate-commit-format.sh", "require-agdr-for-arch-changes.sh"],
        "gh pr merge *": ["block-unreviewed-merge.sh"],
        "gh issue create *": "suggest-ticket-template.sh"
      }
    },
    "PostToolUse": {
      "Bash(gh pr create *)": "auto-code-review.sh"
    }
  }
}
```

## OpenCode equivalent in opencode.json

### SessionStart equivalent

The instructions field in opencode.json serves a similar purpose:

```json
{
  "instructions": [
    "Read AGENTS.md for project rules and workflows",
    "Read onboarding.yaml for company configuration",
    "Read apexyard.projects.yaml for portfolio registry"
  ]
}
```

### PreToolUse equivalent

OpenCode's permission system provides similar blocking:

```json
{
  "permission": {
    "bash": {
      "git add *": "deny",
      "git push main*": "deny",
      "git push master*": "deny"
    },
    "skill": {
      ".opencode/skills/*": "allow",
      ".claude/skills/*": "allow"
    }
  }
}
```

### Hooks replaced by Skills

| Claude Code Hook | OpenCode Skill |
|-----------------|---------------|
| require-active-ticket.sh | /start-ticket |
| require-migration-ticket.sh | /migration |
| check-secrets.sh | (manual check) |
| block-unreviewed-merge.sh | /approve-merge + agent review |
| auto-code-review.sh | /code-review |

## Agent Configuration

In OpenCode, agents are defined in opencode.json:

```json
{
  "agent": {
    "rex": {
      "description": "Code Reviewer...",
      "mode": "subagent",
      "permission": { "edit": "deny", "bash": "allow" }
    }
  }
}
```

The agent files in `.opencode/agents/` provide the system prompt for each agent.

## Summary

| Claude Code | OpenCode |
|------------|---------|
| settings.json hooks | opencode.json permissions + instructions |
| .claude/agents/ | .opencode/agents/ |
| .claude/skills/ | .opencode/skills/ |
| .claude/rules/ | .opencode/rules/ |