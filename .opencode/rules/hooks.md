# Hooks and SDLC Enforcement

This document explains how ApexYard's SDLC enforcement works in OpenCode.

## Claude Code Hooks (Original)

The `.claude/hooks/` directory contains 18 shell scripts that enforce SDLC rules:

| Hook | Purpose |
|------|---------|
| `require-active-ticket.sh` | Block edits without active ticket |
| `require-migration-ticket.sh` | Block migration edits without migration ticket |
| `block-git-add-all.sh` | Block git add -A |
| `block-main-push.sh` | Block direct pushes to main |
| `validate-branch-name.sh` | Enforce branch naming |
| `validate-pr-create.sh` | Enforce PR title format |
| `validate-commit-format.sh` | Enforce commit message format |
| `check-secrets.sh` | Scan for hardcoded secrets |
| `block-unreviewed-merge.sh` | Require Rex + CEO approval |
| `require-design-review-for-ui.sh` | Require design approval for UI |
| `block-merge-on-red-ci.sh` | Block merge when CI fails |
| `pre-push-gate.sh` | Reminder for pre-push checks |

## OpenCode Equivalent

OpenCode handles enforcement differently:

### Permission System

Edit opencode.json to restrict actions:

```json
{
  "permission": {
    "bash": {
      "git add *": "deny",
      "git push main*": "deny"
    }
  }
}
```

### Skills Replace Hooks

| Hook Function | OpenCode Equivalent |
|--------------|---------------------|
| `/start-ticket` | Declares active ticket before editing |
| `/approve-merge` | Records CEO approval for merge |
| `/approve-design` | Records design approval |
| `/code-review` | Invokes Rex agent |
| `/security-review` | Invokes Shield agent |
| `/audit-deps` | Invokes Guardian agent |

### Workflow Gates via Skills

| Gate | Skill |
|------|-------|
| Ticket-first | `/start-ticket` required |
| Migration gate | `/migration` required |
| Code review | `/code-review` required |
| Merge approval | `/approve-merge` required |

## Key Difference

**Claude Code**: Mechanical enforcement (hooks block commands)
**OpenCode**: Advisory enforcement (skills guide the process)

The opencode approach relies on:
1. Following the AGENTS.md rules
2. Using skills before key actions
3. Permission restrictions in opencode.json

This is less strict than Claude Code hooks but maintains the same workflow patterns.