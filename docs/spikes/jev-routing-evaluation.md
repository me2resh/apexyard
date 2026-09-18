# Jev routing evaluation

## Hypothesis

Jev may improve advisory routing for framework skills, roles, and ceremony
classification when users describe work without the exact phrases in the
current maps. It must not change an enforcement decision or remove the
deterministic fallback.

## Method

The evaluation ran on the current `dev` line (v5.6.3) on 2026-09-18. The
corpus contains 15 sanitised prompts:

- Six skill-intent cases.
- Six explicit role-activation cases.
- Two ceremony cases and one neutral case.

Each Jev request sent one state and three typed choice questions: skill, role,
and ceremony. The request used `jev-latest` and the local `JEV_API_KEY`. The
key was read from the local secrets file and was not written to output or
repository files.

The deterministic baseline ran the shipped
`.claude/hooks/detect-skill-intent.sh` and
`.claude/hooks/detect-role-trigger.sh` against the same prompts. The baseline
uses the framework's current literal phrase maps and prompted role patterns.

The evaluator is reproducible with Python's standard library only:

```bash
bin/evaluate-jev-routing.py --live --output /tmp/jev-routing.json
```

## Results

| Measure | Result |
| --- | ---: |
| Corpus cases | 15 |
| Jev successful requests | 15 |
| Jev provider failures | 0 |
| Mean latency | 724.1 ms |
| Median latency | 594.5 ms |
| Jev input tokens | 11,118 |
| Jev output tokens | 3,187 |
| Jev skill label accuracy | 73.3% |
| Jev role label accuracy | 80.0% |
| Jev ceremony label accuracy | 33.3% |

The deterministic hooks preserved their existing behaviour. They detected the
exact skill phrases and explicit role-activation forms, but did not detect
paraphrases that are intentionally outside the literal maps. This is the
trade-off the spike is testing: Jev supplied broader semantic coverage, while
also suggesting a skill on role-only prompts and selecting a ceremony that did
not match the labeled expectation in several cases.

The corpus is too small to claim production quality, and it does not provide a
Haiku comparison. No Haiku credential or benchmark harness was supplied, so
the latency, cost, and quality comparison from #195 remains open.

### Repeatability pass

The same corpus was run three times sequentially, for 45 Jev requests. All
requests succeeded. Mean request latency by run was 632.3 ms, 625.1 ms, and
656.3 ms; the three-run mean was 637.9 ms. Skill accuracy stayed at 73.3% in
all three runs. Role accuracy was 80.0% on the first run and 73.3% on the next
two. Ceremony accuracy stayed at 33.3%. One case changed its role answer
between runs, which confirms that the result is not fully stable even on this
small corpus.

The repeated pass used 33,354 input tokens and 9,563 output tokens. It did not
change the disposition below.

### Corrected structured-state pass

The smoke test was repeated with a richer state and independent questions. Each
case included the hook event, changed paths, ticket type, file and line counts,
reversibility, and risk flags. Jev received one typed question per routing
dimension rather than inferring all dimensions from a bare sentence. The run
contained 15 cases and 45 requests:

| Measure | Result |
| --- | ---: |
| Jev skill accuracy | 73.3% |
| Jev role accuracy | 66.7% |
| Jev ceremony accuracy | 46.7% |
| Mean request latency | 637.1 ms |
| Provider failures | 0 |

This is a fairer input shape, but it still does not support enabling Jev. Jev
misclassified several path-trigger cases that the existing deterministic hook
handled directly, and it added skill suggestions to role-only work. The labels
are human-authored pilot labels, not a statistically powered benchmark; a
larger independently reviewed holdout set is required before a routing change.

### Separate AgDR quality pass

AgDR quality was tested separately from routing. Twenty historical records were
sampled across the framework's AgDR history. Each state included required
section presence, missing sections, metadata, document length, and excerpts
from Context, Decision, and Consequences. Jev answered one typed completeness
question per record: `complete`, `incomplete`, or `needs_review`.

| Measure | Result |
| --- | ---: |
| AgDR records | 20 |
| Jev requests | 20 |
| Provider failures | 0 |
| Mean latency | 610.0 ms |
| Agreement with structural proxy | 80.0% |
| Incomplete records missed by Jev | 4 of 5 |

This result is only a structural pilot. The comparison label was generated
from required headings, minimum content, and placeholder checks; it was not an
independent judgment of decision quality. It suggests that AgDR completeness
triage is a more plausible Jev experiment than intent routing, but it does not
justify a gate. A follow-up needs independently reviewed labels for
completeness, trade-off quality, and staleness, plus an abstention threshold.

## Safety and fallback result

No hook, settings file, merge gate, or routing decision was changed. Jev is
not on the execution path. If the provider is unavailable, the shipped hooks
continue to run exactly as before because they do not depend on Jev. This is a
pass for the no-behaviour-change fallback condition, but it is not evidence
that a future Jev integration has a safe fallback; that integration would need
an explicit failure-path test.

## Disposition

**Discard the integration hypothesis for the current framework gates.** The
routing runs do not show that Jev beats the existing deterministic phrase maps
on false positives and false negatives, and ceremony classification remains
unreliable. The separate AgDR pass is a promising research direction, but its
structural proxy is not a quality oracle. Keep Jev out of enforcement and
approval decisions unless larger independently labeled corpora, an abstention
policy, and a Haiku cost/latency comparison show a clear benefit.

The dependent feature tickets (#1342 and #1343) should remain blocked until
that evidence exists. The current framework continues to use deterministic
hooks and human-readable advisory banners.
