---
name: analytics-audit
description: Analytics audit — SDK config, event naming, funnel completeness, dashboards. Deep-dive for /launch-check analytics.
disable-model-invocation: false
argument-hint: "[project-path]"
effort: medium
---

# /analytics-audit — Event Taxonomy & Coverage

Deep-dive analytics analysis. Checks that tracking is configured, events follow a naming convention, key user funnels are instrumented, and dashboards exist. Invoke when `/launch-check`'s analytics row shows WARN or FAIL.

## Process

### Step 1: SDK detection

Grep for analytics SDK initialization:

- Google Analytics / GA4: `gtag`, `G-`, `UA-`, `analytics.js`, `@google-analytics`
- Mixpanel: `mixpanel.init`, `@mixpanel`
- Amplitude: `amplitude.init`, `@amplitude`
- PostHog: `posthog.init`, `posthog-js`
- Plausible: `plausible.io`, `data-domain`
- Segment: `analytics.load`, `@segment`
- Custom: any `track(`, `capture(`, `logEvent(` patterns

### Step 2: Event inventory

Find all tracking calls in the codebase and list them:

- Event name
- Where it fires (file + component/handler)
- Properties sent with the event
- Whether it has a consistent naming convention (snake_case, camelCase, verb_noun)

### Step 3: Funnel coverage

Identify the core user funnels and check if each step is tracked:

| Funnel | Steps to check |
|--------|---------------|
| **Signup** | page_view → form_start → form_submit → signup_complete |
| **Activation** | first_login → key_action_completed → aha_moment |
| **Purchase** (if applicable) | pricing_view → plan_select → checkout_start → payment_complete |
| **Retention** | return_visit → feature_usage → session_duration |

### Step 4: Output

```
ANALYTICS AUDIT — <project> @ <sha>

SDK: <GA4 / Mixpanel / PostHog / none>
Total events found: <N>
Naming convention: <consistent / inconsistent / none>

| # | Area | Status | Finding |
|----|------|--------|---------|
| E1 | SDK | PASS | GA4 initialized in _app.tsx |
| E2 | Events | WARN | 8 events found, 3 use camelCase, 5 use snake_case |
| E3 | Signup funnel | FAIL | form_submit tracked but signup_complete missing |
| E4 | Dashboard | WARN | No dashboard URL found in config or docs |

Event inventory:
  signup_start (pages/signup.tsx:42)
  form_submit (components/SignupForm.tsx:89)
  page_view (auto, GA4 enhanced measurement)
  ...
```

## Persist the run + render trend

After printing the findings table, persist via the shared audit-history lib so the analytics trend across runs becomes legible. See `docs/agdr/AgDR-0019-audit-artefact-persistence.md`.

### Resolve project name + score + verdict

`<project-name>` from `apexyard.projects.yaml` (or basename + `/handover` reminder if unregistered).

Score: `score = max(0, 100 - 25*critical - 10*high - 3*medium - 1*low)`. Verdict by worst-severity: critical/high → `fail`, medium → `conditional`, low/none → `pass`.

### Persist + render

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-audit-history.sh"

# Lowercase severity in the payload — the lib expects critical/high/medium/low/info.
payload=$(mktemp); cat > "$payload" <<'EOF'
{
  "schema_version": 1,
  "findings": [
    {"id": "E2", "severity": "medium", "status": "open", "summary": "Mixed event-naming conventions (snake_case + camelCase + Title Case)"},
    {"id": "E3", "severity": "high",   "status": "open", "summary": "signup_complete event missing — can't measure conversion"},
    {"id": "E4", "severity": "medium", "status": "open", "summary": "No dashboard URL found in config or docs"}
  ]
}
EOF

# Body: per templates/audits/analytics-audit.md
body=$(mktemp); cat > "$body" <<'EOF'
... (filled-in body — findings table + Event taxonomy gap + Recommended priority) ...
EOF

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
audit_run_persist "<project-name>" "analytics-audit" "$ts" "fail" 60 "$body" < "$payload"
rm -f "$payload" "$body"

audit_render_trend "<project-name>" "analytics-audit" 5
```

### Opt-in commit

```bash
touch projects/<name>/audits/analytics-audit/.audit-history-tracked
```

## Rules

1. **Auto-PASS for non-user-facing projects.** CLIs, libraries, and internal tools don't need analytics.
2. **Don't prescribe a specific SDK.** Note what's configured, check coverage, suggest improvements.
3. **Flag inconsistent naming** — mixed conventions make dashboard queries painful.
4. **Privacy-aware.** Flag if PII (email, name, IP) is being sent in event properties.
5. **Always persist via the lib.** The persist step runs regardless of opt-in commit state.
6. **Severity vocabulary in the JSON is lowercase.** The lib expects `critical`/`high`/`medium`/`low`/`info`.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
