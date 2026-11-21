---
name: verify
description: Run ApexYard hook regression tests and a skill smoke test before a framework PR.
allowed-tools: Bash, Read, Grep, Glob
---

# Verify ApexYard

Read `.claude/rules/writing-standard.md`.
Use the controlled technical writing profile for evidence.

This framework has no application server or graphical interface.
Its main flows are governance hooks and prompt-driven skills.
This verify checks those flows through regression tests and one skill smoke test.
It does not verify an adopter's application.

Run from the repository root.
Use Bash, Git, Python 3, and jq.
Report missing dependencies as blockers.

1. Record `git rev-parse HEAD` and `git status --short`.
2. Run the focused hook regression suite. Run each test as its own command, so the protected-target gate can read each path. Record the command and its exit code for each line:

   ```bash
   bash .claude/hooks/tests/test_verify_skill.sh
   bash .claude/hooks/tests/test_handover_clone_prompt.sh
   bash .claude/hooks/tests/test_scaffold_interview.sh
   bash .claude/hooks/tests/test_writing_standard.sh
   ```

   Any non-zero exit fails verify.

3. Run one skill smoke test:

   ```bash
   bash .claude/skills/handover/tests/test_topology_pick.sh
   ```

Print `## Verify evidence` with the revision, commands, exit codes, and test summaries.
Include any skipped checks and concrete blockers.
Use Passed only when both commands succeed without unresolved required checks.
Otherwise report Failed or `Verify could not run` with the reason.
Paste this evidence into the PR body before requesting review.
This focused suite does not cover every framework hook.
Run additional hook tests when the changed paths require them.
No app startup or screenshot applies to this framework.
Test fixtures manage their own cleanup.
