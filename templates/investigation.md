<!-- Source: ApexYard · templates/investigation.md · github.com/me2resh/apexyard · MIT -->

# [Investigation] {short title}

> In the context of {what kicked this off}, facing {the unknown we needed to resolve}, I investigated {hypothesis or scope} to achieve {what we needed to learn}, accepting {time / scope tradeoffs}.

## When to use this template

- **Use `/investigation`** when you need a written record of "why did this happen" or "what's actually going on" — incident retrospectives, bug archaeology, regression hunts, performance mysteries, competitive analyses.
- **Use `/spike`** if you're testing a *forward-looking* hypothesis ("does this approach work?") with a time budget.
- **Use `/bug`** if you already know what's broken and need to file an immediate fix.
- **Use `/decide`** if you're choosing between options and need an AgDR.

An investigation IS the artefact. A bug fix is the artefact's *consequence*.

## Trigger

{What kicked this off — incident link, customer report, "the bug from #N", a metric anomaly, a teammate's question. One paragraph. Include the date/time and the link.}

Example: *On 2026-05-12 at 14:03 UTC, error rate on `/api/orders` spiked from baseline 0.2 % to 11 % for 22 minutes. PagerDuty incident PD-4471. Self-resolved at 14:25 with no operator action.*

## Hypothesis being tested

{What you thought was happening BEFORE you started. What you needed to confirm or rule out. A hypothesis tree — bulleted, with sub-bullets for sub-hypotheses. Empty `[ ]` checkboxes for each so you can mark them as you go.}

Example:

- [ ] **H1 — Upstream dependency degradation.** Payments provider returned 5xx on a fraction of requests; our retry budget got eaten.
  - [ ] H1a — Provider's own incident page shows degradation in the matching window.
  - [ ] H1b — Our outbound error logs to the payments provider correlate with the spike.
- [ ] **H2 — Internal queue backup.** A slow consumer caused order creation to time out.
  - [ ] H2a — Queue depth metrics show a backlog in the matching window.
  - [ ] H2b — Consumer error logs reference the queue we suspect.
- [ ] **H3 — Recent deploy.** Code change in the last 24 h regressed order creation.
  - [ ] H3a — Deploy log shows a change to `OrderService` within the window.
  - [ ] H3b — Rolling back the change in staging reproduces the error rate.

## Method

{What you actually DID. Itemised so a reader can follow your path. Each item names the tool, the source, the time window. Distinguish *what you queried* from *what you found* (findings go below).}

Example:

1. Pulled production error logs from CloudWatch for `/api/orders`, 14:00–14:30 UTC. Filter: `5xx` responses. Result count → Findings.
2. Pulled payments provider's status page snapshot for 14:00–14:30 UTC.
3. Queried internal `order_events` table for `status='failed'` rows in the window. SQL recorded in artefacts/queries.md.
4. Diffed the last 4 deploys to `OrderService` against the spike window.
5. Reproduced the failure path in staging by replaying the top 5 failed payloads (sanitised).

## Findings

{What you confirmed, ruled out, what surprised you. Distinguish OBSERVATIONS (raw facts) from CONCLUSIONS (what they mean). Map each finding back to the hypothesis it supports or refutes.}

### Observations

- 217 failed `/api/orders` calls in the 22-minute window, all returning 502.
- Payments provider's status page shows no incident in the window — **rules out H1**.
- Queue depth metric (`order_queue.depth`) reached 4,200 at 14:08, vs baseline 100 — **supports H2**.
- Consumer log shows `OrderConsumer` swallowed `DBConnectionError` between 14:03 and 14:25.
- Last deploy to `OrderService` was 2 days prior — **rules out H3**.
- Surprise: the DB connection pool was at max capacity (50/50) during the window, despite traffic being only 2× baseline.

### Conclusions

- **H1 ruled out.** Payments provider was healthy.
- **H2 confirmed.** A DB connection pool exhaustion (50/50) caused `OrderConsumer` to error, which backed up the queue, which made order-creation requests time out at 502.
- **H3 ruled out.** No recent deploy in the suspect window.
- **Root cause: connection pool size of 50 is insufficient for 2× baseline traffic on the order path** — the autoscaling rule scales replicas but not the per-replica pool size.

## Conclusion

{One paragraph: the answer to the original question. Include the confidence level (high / medium / low) and what remaining uncertainty there is. If you couldn't reach a confident answer, say so explicitly.}

Example: *The 14:03 spike was caused by DB connection pool exhaustion on the order path, triggered by a 2× traffic burst that overran the per-replica pool size of 50. Confidence: HIGH (reproduced in staging by capping pool size and replaying traffic). Remaining uncertainty: whether other services share the same pool-sizing assumption — see follow-up actions.*

## Follow-up actions

{What's NEXT. Each action linked to a tracker ticket if filed, or marked `(no follow-up)`. The investigation ticket CLOSES when every action is resolved or explicitly dropped — NOT on PR merge.}

- [ ] **Raise pool size to 200 on the order path** — filed as #{NNN}, ships in next deploy.
- [ ] **Audit other services for the same pool-sizing assumption** — filed as #{NNN}.
- [ ] **Add an autoscaling rule that scales pool size with replica count** — filed as #{NNN}.
- [ ] **Write a runbook entry for "connection pool exhaustion under burst traffic"** — filed as #{NNN}.
- [ ] **Share findings with the platform team** — (no follow-up: shared in #platform on 2026-05-13).
- [ ] **Backport the pool-size change to the staging environment** — (no follow-up: staging already runs the new value as of the repro).

---

## Metadata

| Field | Value |
|-------|-------|
| Live-doc | `projects/{project}/investigations/{YYYY-MM-DD}-{slug}.md` |
| GitHub issue | #{NNN} |
| Started | YYYY-MM-DD |
| Resolved | YYYY-MM-DD (or "open — see Follow-up actions") |
| Investigator(s) | @handle |
| Related AgDR | — (link if a decision falls out of the investigation) |
