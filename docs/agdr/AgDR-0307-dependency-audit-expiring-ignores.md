---
id: AgDR-0307
timestamp: 2026-11-18T09:30:00Z
agent: claude-code
model: claude-opus-5-5
session: 7fef1a01-205b-4cc5-9aac-9a28f79d0941
trigger: user-prompt
status: executed
category: security
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Expiring advisory ignores for this repo's dependency audit

> In the context of this repo's Dependency Audit job, facing a High advisory with no patched release that fails every PR, I decided to add a checked-in list of expiring advisory ignores, applied by a small policy script, to achieve green CI for unrelated PRs, accepting that one named advisory does not fail the job until its expiry date.

## Context

- GHSA-fc5q-39xc-vjpf (ReDoS in `picomatch` 4.0.7 and earlier) reached the audit database on 18 Nov 2026. No patched release exists.
- `picomatch` is in dev-time glob tooling only: `harness-adapters/opencode` and the `topologies/typescript-nextjs/starter` template.
- The job failed on High through an inline Python step. It had no way to except one advisory.
- The owner approved a time-boxed ignore for this one advisory on 18 Nov 2026 (ticket #2084).

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Expiring ignore list, applied by a repo-only policy script | One advisory is excepted. Every other High or Critical still fails. The expiry stops a silent, permanent exception. Testable. | A new file and script to maintain. |
| Leave the audit red | No change. | Every PR shows a red check. Real new findings are hard to see. |
| Lower the audit threshold to Critical | Simple. | Hides every new High advisory. |
| Change the shared helper in golden-paths/ | One place for adopters too. | Changes adopter behaviour without a request. Larger review. |

## Decision

Chosen: **an expiring ignore list, applied by a repo-only policy script**.

- `.github/dependency-audit-ignore.json` holds entries with `id`, `reason` and `expires` (YYYY-MM-DD).
- `.github/scripts/dependency-audit-policy.py` reads the helper's JSON report. A High or Critical finding fails the job unless a valid, unexpired entry names its advisory ID or an alias.
- A derived finding follows package links within the same audited project. It passes only when every reachable root advisory has a valid ignore. Missing links, cycles, and unknown shapes fail.
- An entry with a missing field, a bad date or a past expiry fails the job and is named.
- An incomplete audit, an Unknown severity or a helper error still fails the job.
- Ignored findings are listed in the log and the job summary.
- The shared helper and the adopter pipeline in `golden-paths/` do not change.

## Consequences

- GHSA-fc5q-39xc-vjpf does not fail the job until 31 Dec 2026.
- On 1 Jan 2027 the expired entry fails the job. Someone must remove the entry, or add a new one with a new owner approval.
- Remove the entry when `picomatch` ships a fix and the lockfiles update.

## Artifacts

- Ticket: me2resh/apexyard#2084
- Tests: `.claude/hooks/tests/test_dependency_audit_policy.sh` (7 cases)
