# Semgrep release-gate severity policy: fail-on-ERROR

> In the context of the release-gated Security Scan (semgrep `r/bash`, added in #487), facing a first real run that red-flagged the v2.3.0 release on 0 ERROR + 4 WARNING pre-existing findings, I decided to set the fail threshold to ERROR (WARNING advisory) to achieve a gate that catches high-severity issues without blocking releases on pre-existing low-severity lint, accepting that medium-severity findings no longer hard-fail and must be watched via the step summary.

## Context

The release-gated scan runs on the tag push (post-merge), so it did not block v2.3.0 — but with `SEMGREP_FAIL_SEVERITY=WARNING`, any WARNING reds the scan, and it would red **every** release until the 4 pre-existing `r/bash` WARNING findings are resolved. Classic brand-new-strict-gate-meets-existing-debt (#511). The same default ships in the adopter golden-path template (`golden-paths/pipelines/security.yml`), so every adopter inherits the strict behaviour on their first scan too.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| (a) Relax to fail-on-ERROR; WARNING advisory | Stops releases reding on pre-existing low-severity lint; sane default for a freshly-added scan; one-line, reversible; same fix benefits adopters | Medium-severity findings no longer block — must be watched in the step summary |
| (b) Fix/suppress the 4 WARNING findings, keep fail-on-WARNING | Strictest gate retained | Pins the gate to a moving target (next new rule re-reds); doesn't help adopters who hit their own pre-existing WARNINGs; more work, recurring |

## Decision

Chosen: **(a) fail-on-ERROR**, WARNING advisory, in both `.github/workflows/security-scan.yml` (framework) and `golden-paths/pipelines/security.yml` (adopter template), because a release-gate's job is to stop genuinely dangerous changes, not to enforce zero low-severity lint at release time. WARNING findings remain visible in the step summary; teams that want stricter gating set `SEMGREP_FAIL_SEVERITY=WARNING` (template) or pass `fail_on_severity: WARNING` (framework workflow input).

## Consequences

- A clean release no longer reds on pre-existing WARNING-only findings.
- Medium-severity (WARNING) findings are advisory; track them in the step summary and address in normal PR flow.
- The 4 existing `r/bash` WARNINGs can be cleaned up later as ordinary debt, no longer release-blocking.
- Adopters get the same non-blocking-on-low-severity default; opting into stricter gating is a one-line change.

## Artifacts

- Issue: me2resh/apexyard#511
- Files: `.github/workflows/security-scan.yml`, `golden-paths/pipelines/security.yml`
- Originating run: v2.3.0 tag, run 26980436235 (0 ERROR + 4 WARNING)
