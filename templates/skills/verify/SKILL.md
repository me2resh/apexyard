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

During adoption, keep the stack sections this project needs.
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

Start the local web server and record its URL.
Open that URL in an available browser automation tool.
Drive the primary user journey through its visible controls.
Check the changed screen and one relevant error path.
Capture screenshots with file paths and observed results.
Report a browser blocker when browser automation is unavailable.

### Mobile

Check the platform SDK and required runtime, including the JDK for Android.
Build and launch the app on a named emulator, simulator, or attached test device.
Record the device and operating system version.
Drive the main flow through UI automation.
Capture screenshots and relevant device logs.
Report missing SDKs, devices, or automation tools as blockers.

### Desktop

Build and launch the local desktop app in an available graphical session.
Record the operating system and application version.
Drive the main window's primary flow through UI automation.
Capture screenshots and relevant application logs.
Report unavailable display sessions or automation tools as blockers.

### Service

Start the service and its required local dependencies.
Wait for the documented health response within a bounded timeout.
Send requests for the main success flow and one invalid input.
Record request commands, status codes, and redacted response excerpts.
Check expected state changes when the flow writes data.
For a worker or pipeline, submit a fixture and inspect its output instead of inventing an HTTP endpoint.

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
