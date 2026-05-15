---
name: compliance-check
description: GDPR and ePrivacy compliance audit — cookie consent, privacy policy, data handling, right to deletion, data processing agreements. Deep-dive companion to /launch-check's compliance dimension.
disable-model-invocation: false
argument-hint: "[project-path]"
effort: high
---

# /compliance-check — GDPR + ePrivacy Compliance

Deep-dive regulatory compliance analysis. Checks cookie consent, privacy policy, terms of service, data handling, and user rights. Invoke when `/launch-check`'s compliance row shows WARN or FAIL, or proactively before launching in the EU/UK.

## Compliance Areas

| Area | Regulation | Key requirement |
|------|-----------|-----------------|
| Cookie consent | ePrivacy Directive | Informed consent before setting non-essential cookies |
| Privacy policy | GDPR Art. 13-14 | Clear disclosure of what data is collected, why, and how long |
| Right to deletion | GDPR Art. 17 | Users can request their data be deleted |
| Data minimization | GDPR Art. 5 | Collect only what's necessary |
| Data retention | GDPR Art. 5 | Don't keep data longer than needed |
| Terms of service | Contract law | Clear terms governing use of the service |
| Third-party data sharing | GDPR Art. 28 | Data processing agreements with third parties |

## Process

### Step 1: Cookie and tracking audit

- Grep for cookie-setting code (`document.cookie`, `setCookie`, `cookie-parser`, `js-cookie`)
- Grep for analytics SDKs (Google Analytics, Mixpanel, Amplitude, PostHog, Segment, Facebook Pixel)
- Grep for cookie consent libraries (`cookieconsent`, `react-cookie-consent`, `cookie-banner`, `consent-manager`)
- Check if consent is obtained BEFORE analytics/tracking scripts load (not after)
- Check for a cookie policy page listing all cookies and their purposes

### Step 2: Privacy and legal pages

- Check for `/privacy` or `/privacy-policy` route
- Check for `/terms` or `/terms-of-service` route
- Check if privacy policy covers: what data is collected, legal basis, retention period, third parties, user rights, contact info
- Check for a link to the privacy policy in the sign-up flow and footer

### Step 3: User rights implementation

- Check for a "delete account" or "delete my data" feature
- Check for a "download my data" / data portability feature
- Check for opt-out mechanisms for marketing communications
- Check if the auth system supports account deactivation

### Step 4: Data handling

- Check what PII is stored (names, emails, addresses, phone numbers, payment info)
- Check if PII is encrypted at rest
- Check if sensitive data is logged (grep for logging calls that might include user data)
- Check for data retention policies (is old data cleaned up?)

### Step 5: Output findings

```
COMPLIANCE CHECK — <project> @ <sha>

| # | Area | Status | Finding | Action |
|----|------|--------|---------|--------|
| C1 | Cookies | FAIL | Analytics loads before consent | Gate GA4 behind consent callback |
| C2 | Privacy | WARN | Policy exists but doesn't list retention periods | Add retention section |
| C3 | Deletion | FAIL | No delete-account endpoint | Add DELETE /api/user/me endpoint |
| C4 | Data minimization | PASS | Only email + name collected at signup | — |

Summary: <N> findings (<N> fail, <N> warn, <N> pass)
GDPR readiness: <READY / PARTIAL / NOT READY>
```

## Persist the run + render trend

After printing the findings table (Step 5), persist a structured artefact via the shared audit-history lib so the compliance trend across runs becomes legible. See `docs/agdr/AgDR-0019-audit-artefact-persistence.md` for the schema rationale.

### Resolve project name + score + verdict

`<project-name>` is the project's registered name in `apexyard.projects.yaml`. If unregistered, use the basename of the project path and tell the operator to `/handover` it.

Compute the headline score: `score = max(0, 100 - 25*critical - 10*high - 3*medium - 1*low)`. Compute the verdict by worst-severity: `critical`/`high` → `fail`, `medium` → `conditional`, `low`/none → `pass`. The legacy "GDPR readiness" three-state vocabulary maps cleanly: NOT READY → `fail`, PARTIAL → `conditional`, READY → `pass`.

### Persist + render

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-audit-history.sh"

# Lowercase severity in the payload — the lib expects critical/high/medium/low/info.
payload=$(mktemp); cat > "$payload" <<'EOF'
{
  "schema_version": 1,
  "findings": [
    {"id": "C1", "severity": "high",   "status": "open", "summary": "No cookie consent UI; analytics fires before opt-in"},
    {"id": "C3", "severity": "medium", "status": "open", "summary": "Missing DPA with analytics vendor"},
    {"id": "C4", "severity": "high",   "status": "open", "summary": "No self-serve right-to-deletion endpoint"}
  ]
}
EOF

# Body: per templates/audits/compliance-check.md
body=$(mktemp); cat > "$body" <<'EOF'
... (filled-in body — findings table + Regulatory exposure + Recommended priority) ...
EOF

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
audit_run_persist "<project-name>" "compliance-check" "$ts" "fail" 55 "$body" < "$payload"
rm -f "$payload" "$body"

audit_render_trend "<project-name>" "compliance-check" 5
```

### Opt-in commit (history-tracked marker)

```bash
touch projects/<name>/audits/compliance-check/.audit-history-tracked
```

The MD artefacts are committed regardless; the marker controls whether the per-run JSON files are.

## Rules

1. **Not legal advice.** This audit identifies technical gaps. The user should consult a lawyer for legal compliance.
2. **Region-aware.** If the project doesn't target EU/UK users, some GDPR requirements may not apply. Ask the user about target markets if unclear.
3. **Auto-PASS for non-user-facing projects.** Internal tools, CLIs, and libraries without user data collection don't need this.
4. **Check third-party SDKs.** Analytics, error tracking, and ad SDKs often set cookies and process data — they need consent too.
5. **Always persist via the lib.** The persist step runs regardless of opt-in commit state. The marker only controls whether the JSON is committed.
6. **Severity vocabulary in the JSON is lowercase.** The lib's `stats.by_severity` derivation expects `critical`/`high`/`medium`/`low`/`info`. The human-readable findings table can use whatever capitalisation reads best.
