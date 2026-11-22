---
name: verify
description: Start this project, exercise its main flows, and print evidence before a PR.
---

# Verify this project

Use the controlled technical writing profile for evidence.
Keep instructions within 20 words and descriptive sentences within 25 words.

Prove the changed behavior on the build machine before opening a PR.
A successful build alone does not prove an application flow works.

## Configure this skeleton

Keep one matching stack skeleton beside this skill for each project stack.
Use the project-relative paths below.
Replace the setup fields below with concrete project commands and expected results.
Discover commands from project manifests, scripts, and operating documentation.
Do not invent commands or credentials.

- Prerequisites: [runtime versions, SDKs, devices, and environment variable names].
- Install: [dependency command].
- Start: [local startup command, working directory, and readiness check].
- Main flows: [actions, test data, and expected visible or returned results].
- Stop: [cleanup command for processes and test data created by verify].

Unresolved setup fields block verification.
Report them rather than executing placeholders.

## Run

1. Record the revision and any uncommitted changes being checked.
2. Check prerequisites before starting the app.
3. Install dependencies with the project's documented command.
4. Start the app with local test configuration.
5. Confirm readiness within a bounded timeout.
6. Exercise the main flows and the changed acceptance criteria.
7. Compare observed results with expected results.
8. Stop processes and remove test data created by this run.
9. Print the evidence below, including failures and cleanup results.

### Web

Use `.claude/skills/verify/web.md` for the start, flow, and evidence steps.

### Mobile

Use `.claude/skills/verify/mobile.md` for the start, flow, and evidence steps.

### Desktop

Use `.claude/skills/verify/desktop.md` for the start, flow, and evidence steps.

### Service

Use `.claude/skills/verify/service.md` for the start, flow, and evidence steps.

## Evidence for the PR

Print a `## Verify evidence` section for the build hand-back and PR body.
Include these fields:

- Result: Passed, Failed, or Verify could not run.
- Revision and working tree state.
- Environment: runtime, platform, and device or browser when applicable.
- Commands run: working directories, exit codes, and relevant output.
- Flows exercised: expected results and observed results.
- Artifacts: screenshot paths, logs, or response excerpts.
- Cleanup result.
- Unverified criteria and concrete blockers.

Redact secrets and personal data from evidence.
Report partial runs as partial evidence.
When a required step fails or cannot run, do not report Passed.
For example, state `Verify could not run: Android requires a JDK, which this machine lacks.`
Do not replace runtime evidence with a source inspection or a green CI result.
