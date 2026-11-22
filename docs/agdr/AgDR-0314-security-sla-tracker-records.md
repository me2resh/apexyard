# Track security remediation deadlines in tracker issues

## Context

Issue #2109 implements the owner decision behind AgDR-0313.
Repeated reviews must not restart a security finding's remediation deadline.

## Decision

The tracker issue stores the record. The orchestrator creates it, with `security`, severity, and `sla` labels.
Its tracker creation date supplies the first-seen date. No local ledger stores finding history.

A fingerprint is `sha256:` followed by 64 lowercase hexadecimal characters.
Hash the UTF-8 compact JSON array without its trailing newline.
Dependency inputs are `["dependency",package,advisory]`. Code inputs are `["code",rule,file,function]`.
Preserve case. Use repository-relative paths without `./` and `<module>` outside functions.
Exclude line numbers, dependency versions, and review identifiers.

Each body contains these exact field lines:

```text
Fingerprint: sha256:<64 lowercase hexadecimal characters>
Severity: HIGH
SLA days: 30
Due: YYYY-MM-DD
```

Compute the due date from the creation date in UTC plus the configured severity SLA.
Defaults are CRITICAL 7, HIGH 30, and MEDIUM 90 days. LOW uses `none` for days and due date.
Preserve the original fields when the fingerprint matches an open issue.
Hakim supplies base-commit proof and hands untracked findings to the orchestrator.
Without proof, the finding counts as new and blocks the PR.

The release check blocks after the due date while the issue remains open.
A comment from the supplied trusted owner login can accept the risk.
Its exact marker line is `Risk accepted by owner: <non-empty reason>`.
Check all comment pages. Tracker errors, incomplete issue lists, and malformed records block release.

## Consequences

The orchestrator serializes creation per repository because trackers do not enforce unique fingerprints.
Never retry an uncertain create automatically. Search and reconcile first.
Creation writes `Due: pending`, then updates the same issue using its tracker creation date.
A failed update leaves a visible pending record that blocks release until reconciliation.
Only the gh adapter currently exposes creation dates, comments, and body updates here.
Other adapters fail closed until equivalent metadata operations exist.

## Verification limits

The local branch ends at AgDR-0313. The available origin/dev ref ends at AgDR-0236.
The open-PR number check failed because the tracker API was unreachable.
AgDR-0314 is provisional until the orchestrator verifies that no open PR uses it.
