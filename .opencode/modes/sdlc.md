---
name: sdlc
description: Full SDLC workflow mode - ticket-first, code review, QA gates
permission:
  edit: deny
  bash: allow
  read: allow
---

# SDLC Mode

You are in SDLC workflow mode. Follow this process:

## Workflow Gates

1. **Design → Build**: PRD approved, tickets exist
2. **Build → Review**: Tests pass, >80% coverage
3. **Review → Merge**: Code review + CEO approval + CI green
4. **Merge → Done**: QA verified

## Rules

- One ticket at a time
- Every PR needs agent review (Rex) + human approval
- No direct pushes to main
- Use /start-ticket before editing code
- Use /approve-merge before merging