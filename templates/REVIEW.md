# Review severity

Give each finding exactly one tag: `Important`, `Nit`, or `Pre-existing`.
Apply these tags in every findings section, including tables and delta reviews.
Write each finding in the controlled technical writing profile.

## Important

An Important finding meets the applicable blocking rule.
Only Important findings can cause `CHANGES REQUESTED`.
Keep the Blocking-Severity Bar and all security rules in effect.
Tag blocking acceptance criteria, AgDR, glossary, and handbook violations Important.
Example: A changed access check lets an unauthorised user read private data.

## Nit

A Nit suggests an improvement that does not meet a blocking rule.
A Nit never blocks the PR.
Example: A local variable name hides its purpose.

## Pre-existing

A Pre-existing finding describes a problem that the change did not introduce or worsen.
A Pre-existing finding never blocks the PR.
Include base evidence and a suggested ticket title with each Pre-existing finding.
Do not classify a new exposure or regression as Pre-existing.
Worsened: the change increases the severity, reach or exploitability of an existing finding.
Base evidence: the finding reproduces on the PR base commit.
Keep independent CI, release, and security gates in effect.
A Pre-existing security finding does not block the PR. It gets a ticket due on its first-seen date plus its SLA (`.security.remediation_sla_days`: CRITICAL 7 days, HIGH 30 days, MEDIUM 90 days, LOW no SLA). It blocks a release only after the SLA is breached. The review names the severity, the SLA and the due date. Tracking: me2resh/apexyard#2109.
Report unknown provenance as unverified rather than claiming base evidence.

Examples from 21 November 2026:

- Pre-existing: Android unit tests already fail on the base. Suggested ticket title: Repair existing Android unit tests.
- Pre-existing: A withdrawn audit advisory predates this change. Suggested ticket title: Remove the withdrawn audit advisory.

Verify the base failure or advisory withdrawal before using these examples as findings.
An active security vulnerability still requires the existing security response.

Count every finding. List at most five nits.
Report other nits as `Additional nits: N`.
Use `- Important: <finding and evidence>` for a blocking finding.
Use `- Nit: <finding and evidence>` for an advisory finding.
Use `- Pre-existing: <finding and base evidence>. Suggested ticket title: <title>` for an existing problem.

## Security tracking fields

Each Pre-existing CRITICAL, HIGH, or MEDIUM line includes `Fingerprint: <fp>` and `Base proof: <short evidence>`.
Base proof identifies the base commit and the matching dependency advisory or code.
Without this proof, treat the finding as new and block the PR.
Hakim hands untracked findings to the orchestrator. Only the orchestrator files the SLA issue.
Repeat findings reference the existing open issue and preserve its due date.
See `.claude/hooks/_lib-sla.sh` and the security review instructions for the field format.
