# Compliance Check — {project} @ {short-sha}

> Persisted by `/compliance-check` via `_lib-audit-history.sh`. Frontmatter (above) is structured; the body is freeform per dimension. See `docs/agdr/AgDR-0019-audit-artefact-persistence.md` for the schema rationale.

## Scope

Regulatory regimes covered by this run: GDPR (EU/UK), ePrivacy (cookies), CCPA (California), and any project-specific regime declared in `onboarding.yaml`. Out of scope: industry-specific regimes (HIPAA, PCI-DSS) unless explicitly listed.

## Findings

| # | Area | Status | Detail | Severity |
|---|---|---|---|---|
| C1 | Cookie consent banner | FAIL | No consent UI on `/`; analytics fires before opt-in | high |
| C2 | Privacy policy reachable | PASS | Linked from footer + sign-up flow | — |
| C3 | DPA with sub-processors | WARN | Missing for analytics vendor | medium |
| C4 | Right-to-deletion endpoint | FAIL | No `/api/account/delete`; manual ticket required | high |
| C5 | Data-retention policy | WARN | Documented but no automated cleanup | medium |

## Regulatory exposure

Brief assessment of which findings expose which regulations:

- **C1 (consent)** — ePrivacy + GDPR Art. 6/7. EU-resident traffic without prior consent for analytics is a clear violation; supervisory authorities have fined €1M+ for the pattern.
- **C4 (right-to-deletion)** — GDPR Art. 17. Manual workflow is technically compliant but fragile; a missed ticket is a complaint trigger.

## Recommended priority

1. C1 — ship cookie banner + Consent Mode v2 wiring before any EU launch
2. C4 — surface deletion as a self-serve flow
3. C3 — DPA paperwork (legal task, not engineering)
4. C5 — retention automation (engineering task; can come post-launch)

## Notes

(Context: prior compliance reviews, regulatory letters received, geographic launch sequence.)
