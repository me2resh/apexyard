---
name: analytics-audit
description: Analytics coverage and event taxonomy audit — SDK configuration, event naming, funnel completeness, dashboard existence. Deep-dive companion to /launch-check's analytics dimension.
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

## Rules

1. **Auto-PASS for non-user-facing projects.** CLIs, libraries, and internal tools don't need analytics.
2. **Don't prescribe a specific SDK.** Note what's configured, check coverage, suggest improvements.
3. **Flag inconsistent naming** — mixed conventions make dashboard queries painful.
4. **Privacy-aware.** Flag if PII (email, name, IP) is being sent in event properties.
