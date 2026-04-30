# ApexYard OpenCode Configuration

This directory contains the complete ApexYard framework migrated to OpenCode format.

## Directory Structure

```
.opencode/
├── agents/          # 5 custom agents (rex, shield, guardian, pr-manager, ticket-manager)
├── commands/       # Shell commands for common operations
├── modes/          # Workflow modes (sdlc)
├── rules/          # Project rules and guidelines
└── skills/        # 33 skills for project operations
```

## Quick Start

1. Open OpenCode in this directory:
   ```bash
   opencode /home/zeyad/learn/apexyard
   ```

2. The AGENTS.md file at the project root provides the main instructions.

## Key Components

### Agents (5)

| Agent | Purpose | Usage |
|-------|---------|-------|
| rex | Code Reviewer | `Use Rex to review PR #42` |
| shield | Security Reviewer | `Use Shield to review PR #42 for security` |
| guardian | Dependency Auditor | `Use Guardian to audit dependencies` |
| pr-manager | PR Workflow | `Use PR Manager to help with PR creation` |
| ticket-manager | Issue Management | `Use Ticket Manager to create an issue` |

### Skills (33)

Use skills by typing their name:
- `/setup` - First-run bootstrap
- `/start-ticket` - Declare active ticket
- `/code-review` - Invoke Rex on a PR
- `/security-review` - Invoke Shield on a PR
- `/audit-deps` - Run dependency audit
- `/approve-merge` - Record CEO approval
- `/approve-design` - Record design approval
- `/decide` - Create Agent Decision Record
- `/write-spec` - Generate PRD
- `/feature` - Create feature ticket
- `/bug` - Create bug report
- `/task` - Create technical task
- `/migration` - Create migration ticket
- `/idea` - Capture product idea
- `/handover` - Onboard external repo
- `/c4` - Generate C4 diagrams
- `/projects` - List managed projects
- `/inbox` - Show items needing attention
- `/status` - Show current snapshot
- `/tasks` - Show actionable tasks
- `/roadmap` - Update roadmap
- `/stakeholder-update` - Generate updates
- `/launch-check` - Production readiness audit
- And 12 more audit skills...

### Commands (3)

| Command | Purpose |
|---------|---------|
| `new-feature.sh` | Create new feature branch |
| `make-pr.sh` | Create PR with proper format |
| `check-branch.sh` | Validate branch name |

### Rules

Located in `.opencode/rules/`:
- workflow-gates.md - SDLC workflow gates
- git-conventions.md - Branch/PR/commit naming
- pr-workflow.md - PR approval process
- hooks.md - Enforcement explanation
- settings.md - Configuration mapping
- And more...

## Comparison with Claude Code

| Original (.claude/) | OpenCode (.opencode/) |
|---------------------|----------------------|
| agents/ | agents/ |
| hooks/ (18 shell scripts) | rules/hooks.md + permissions |
| settings.json (hooks config) | opencode.json |
| skills/ (33) | skills/ (33) |
| rules/ (8 files) | rules/ (10 files) |

## Key Differences

1. **Enforcement**: Claude Code uses mechanical hooks; OpenCode uses skills + permissions
2. **Config Format**: JSON vs YAML-like in agent files
3. **Hooks → Skills**: Most hook functions are replaced by skills

## Documentation

- AGENTS.md - Main project instructions (in project root)
- ./rules/hooks.md - How enforcement works
- ./rules/settings.md - Config mapping
- ../workflows/ - SDLC workflows (in project root)
- ../roles/ - Role definitions (in project root)
- ../templates/ - Templates (in project root)

## OpenCode Configuration

The main config is in `opencode.json`:
- Defines all 5 custom agents
- Configures permissions
- Sets up skills discovery

Edit this file to customize agent behavior or add new permissions.