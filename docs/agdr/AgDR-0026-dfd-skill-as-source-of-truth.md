# AgDR-0026: `/dfd` skill as single source of truth — Mermaid primary, Threat Dragon JSON secondary

> In the context of building a Data Flow Diagram (DFD) extractor for the apexyard skill family, facing the fact that `/threat-model` (#225) and `/compliance-check` each regenerate their own DFD slices and the upcoming `/threat-model --format=dragon` (#255) wants a Threat Dragon JSON export, I decided to ship `/dfd` as the canonical DFD producer that writes a Mermaid markdown file at `projects/<name>/architecture/dfd.md` (primary), an OWASP Threat Dragon v2 JSON at the same dir (secondary on `--format=dragon`), with first-class data-classification heuristics and a shared multi-repo trace helper, to achieve one place where the DFD lives, accepting one more skill to learn and one refactor pass through the two consumer skills.

## Context

Three forces converge on this decision:

1. **The DFD section in `/threat-model` (#225)** is a hand-rolled Mermaid stub that the operator + agent populate each run — same stub, regenerated every time. The Mermaid is good; the regeneration loop is wasteful and inconsistent across runs.
2. **`/compliance-check`** needs the same view of "what data flows where" to detect cross-border transfers, third-party processors, and PII landing in unencrypted stores. Today it walks the codebase independently with similar discovery logic to `/threat-model`.
3. **`#255` (`/threat-model --format=dragon`)** wants OWASP Threat Dragon JSON output. That format is a node-edge graph with trust boundaries and STRIDE findings attached — i.e. it's a DFD-shaped serialisation. Implementing it inside `/threat-model` couples the format to one consumer and bypasses `/compliance-check`'s need for the same view.

The natural seam: extract the DFD producer, let the two consumers read it. Same shape as `/c4` (system topology producer) sitting upstream of architecture-aware skills — one read-first scan, one canonical artefact, many consumers.

The sibling tickets `#256` (`/process` — multi-repo BPMN producer) and `#255` (Threat Dragon JSON serialiser) both want infrastructure that `/dfd` also needs:

- `#256` introduces multi-repo cross-service traversal via `apexyard.projects.yaml` registry lookup. `/dfd` needs the same shape for system-wide DFDs that span microservices.
- `#255` defines a Threat Dragon v2 JSON serialiser. `/dfd --format=dragon` needs that serialiser too.

Sharing both is in scope here.

## Options Considered

### A. Lift DFD into /dfd; both downstream skills read from a canonical file (CHOSEN)

| Pros | Cons |
| --- | --- |
| One discovery pass per system per change-set, not three | One more skill in the family (43 → 44) |
| `/threat-model` becomes shorter — STRIDE walk only, not "build DFD then STRIDE" | Refactor pass through `/threat-model` and `/compliance-check` required (in this PR) |
| `/compliance-check` gets PII / PCI / Secrets classifications it currently can only grep for | Adopters who already have a hand-edited `dfd.md` need a "skip and use what's there" path — handled via the existing-file overwrite prompt |
| Mermaid renders inline on GitHub — zero new toolchain dependency for the primary output | The Threat Dragon JSON branch needs schema validation (smoke test handles this) |
| `--format=dragon` reuses `#255`'s serialiser — no duplication | If `#255` ships first with the serialiser inside `/threat-model`, we either import from there or accept duplication during the transition window |
| Aligns with the `/c4` precedent: producer skill writes Mermaid; consumers reference the file | |

### B. Keep the DFD inside /threat-model; expose it as an export

| Pros | Cons |
| --- | --- |
| Zero new skill | `/compliance-check` still has no shared view of data flows |
| Smaller surface area | `/threat-model` becomes the "owner" of a non-security artefact (a DFD is just a data-flow view; security is one consumer) |
| | Cross-service / multi-repo DFD logic awkwardly lives inside a security-named skill |
| | `#255`'s serialiser is locked to `/threat-model`'s internal state, harder for `/compliance-check` to consume |

### C. No skill — operator writes the DFD by hand, both consumers read it

| Pros | Cons |
| --- | --- |
| Simplest implementation (literally none) | The "hand-roll the DFD" gap is the whole point of automating discovery |
| Adopter retains full control over the diagram | `/threat-model` and `/compliance-check` either re-scan (current state, the problem) or do nothing without a hand-written file |
| | No mechanism to refresh the DFD after a code change (drift is silent) |

### D. Generate a registry-format-agnostic IR, then render to N formats from one walker

| Pros | Cons |
| --- | --- |
| Long-term clean — one walker, many renderers (Mermaid, Dragon, PlantUML, D2…) | Premature abstraction for v1; we have two formats and one set of consumers |
| Trivial to add a new output format later | Adds an IR-design step before any user-facing artefact ships |
| | Same outcome as Option A in v1 because we still ship Mermaid + Dragon; the IR layer is internal and can be introduced later under-the-hood without changing the skill's contract |

## Decision

Chosen: **Option A**, because the discovery pass is the expensive part (axis walks, classification heuristics, cross-repo trace) and centralising it removes duplicate work across three skills. Mermaid as primary leverages the existing `/c4` precedent and the apexyard "Mermaid in markdown renders on GitHub, zero toolchain" rule (AgDR-0003); Threat Dragon JSON as secondary covers the security-team-visual-editing use case from `#255`.

The IR (Option D) is the right long-term shape but adds a layer before v1 ships. Keep the per-format generators (`generate-mermaid.sh`, `generate-dragon.sh`) as pure functions over the same in-memory model so Option D can be retrofitted without changing the contract.

## Sub-decisions made in the same scope

### A1. Output location: `projects/<name>/architecture/dfd.md`

Same convention as `/c4` writing to `projects/<name>/architecture/{context,container}.md`. Renders inline on GitHub, ops-fork view of the project's architecture, sits next to the C4 diagrams so an observer browsing `projects/<name>/architecture/` sees three diagrams of the same system from three angles (context, container, data-flow).

### A2. Data classifications as a first-class concept, three pathways

Classifications are the load-bearing input for `/compliance-check`'s cross-border-transfer detection and for `/threat-model`'s severity weighting. Three detection pathways (additive, not exclusive):

| Pathway | Signal | Example |
| --- | --- | --- |
| **Annotation** | Code-level comment / decorator | `@PII`, `// CLASSIFIED: pii`, `// classification: secrets` |
| **Env-var heuristic** | Naming pattern in `.env*` / `process.env.*` / `os.environ[...]` | `*_SECRET`, `*_TOKEN`, `*_KEY`, `*_PASSWORD` → `secrets`; `SMTP_*`, `EMAIL_*` → `email-routing` |
| **Schema heuristic** | DB / ORM column names matching PII patterns | `email`, `phone`, `ssn`, `dob`, `address`, `card_number`, `cvv`, `ip_address` |
| **Explicit registry** (opt-in) | `docs/data-classification.{md,yaml}` in the project repo | Operator-authored canonical truth — wins over heuristics |

The heuristics are deliberately conservative — false positives are louder than false negatives (an `email` column labelled PII can be re-labelled by the operator; a missing PII label means the threat model under-weights the field's risk). Adopters who want different patterns override via the explicit registry.

### A3. Multi-repo trace via shared helper `_lib-multi-repo-trace.sh`

`/process` (#256) needs the same cross-service registry-lookup logic (HTTP host / message-broker topic / shared event-table → registered project name in `apexyard.projects.yaml`). Rather than duplicate, extract a shared helper:

```bash
mrt_resolve_target <hostname_or_topic_or_url>   # → project name (if registered) or empty
mrt_follow_into <project_name>                  # → workspace path if cloned, else offer-to-clone path
mrt_is_third_party <hostname_or_url>            # → "stripe" / "sendgrid" / "" — detected against known-vendor signatures
```

Both `/dfd` and `/process` consume the helper. If this PR ships first, the helper lives here; if `/process` ships first, this PR adds to whatever shape `/process` extracted. Either way, the helper is the seam.

### A4. Refactor `/threat-model` and `/compliance-check` in the same PR

The refactor is the load-bearing payoff of this decision — without it, `/dfd` is just another producer with no consumers. Scope is deliberately minimal:

- `/threat-model` Step 1 changes from "populate the DFD section yourself" to "read from `projects/<name>/architecture/dfd.md`; if missing, OFFER to run `/dfd` first". Output format stays the same (markdown threat catalogue + persisted JSON via the audit-history lib).
- `/compliance-check` Step 4 (Data handling) gains an upstream read: load the DFD's classification table + flow targets to surface cross-border transfers + third-party processors automatically rather than via independent grep.

Both refactors preserve the existing audit-history persistence contract — only the discovery upstream changes.

### A5. Threat Dragon JSON serialiser shared with `#255`

`#255` adds `/threat-model --format=dragon`. The serialiser logic (Mermaid graph → Threat Dragon v2 JSON nodes/edges/boundaries) is identical work. Two paths:

1. **If `#255` merges first**: import its serialiser into `/dfd`. The serialiser becomes `_lib-threat-dragon-serialiser.sh` (or similar — co-locate near both consumers).
2. **If `/dfd` merges first** (this PR): `generate-dragon.sh` is the serialiser; `#255` imports from here.

Either way, end-state has one serialiser, two callers. Coordinated via PR cross-references.

## Consequences

### Wins

- **Three skills, one DFD source.** A code change that adds a new data store, new external API, new PII field re-runs `/dfd` once; both `/threat-model` and `/compliance-check` pick up the change on their next run.
- **Mermaid renders on GitHub** — the DFD becomes a first-class architecture artefact a reviewer can see in a PR diff. Today's DFD is regenerated in-chat per run; nobody can link to it.
- **Cross-service threat surface visible by default.** A system-wide `/dfd --scope-all` puts every cross-service flow as a trust-boundary crossing — exactly the surface STRIDE cares about. Microservice adopters get this without operator intuition.
- **Data classifications as a structured artefact.** Today the operator runs through STRIDE asking "is this PII?" each time. After this, the DFD's classification column is the source — both for STRIDE severity weighting and for GDPR cross-border-transfer detection.

### Costs

- **One more skill to discover.** Mitigated by `/threat-model`'s "DFD missing — run `/dfd` first?" prompt and by `/handover`'s post-clone follow-up offering `/dfd` alongside `/c4`.
- **Refactor risk in two existing skills.** Both refactors are bounded to a single read-from-file step; existing output shapes stay the same. The audit-history persistence contract is unchanged, so trend data continues uninterrupted.
- **Cross-PR coordination with `#255` and `#256`.** Mitigated by extracting the trace helper as a separate file (clear seam for `/process` to consume), keeping the Dragon serialiser as a pure function over the in-memory model (clear seam for `/threat-model --format=dragon` to consume), and explicit PR-body cross-references so Rex flags duplication during review.
- **Adopters with hand-edited `dfd.md`** lose their version on re-run if they accept the overwrite prompt. The prompt defaults to `N` and the file's footer signature (`Generated by /dfd on YYYY-MM-DD`) makes the source visible.

### Out of scope (explicit non-goals for v1)

- **IaC reading** (Terraform / CloudFormation / SAM) for trust-boundary inference — code + env config only in v1. IaC integration is a follow-up.
- **SAST/DAST substitution** — `/dfd` informs threat modelling and compliance, doesn't substitute for actual security scans.
- **Pretty SVG/PNG export** — Threat Dragon does that after JSON import. The skill emits Mermaid (which GitHub renders) and JSON (which Threat Dragon renders); image generation is downstream tooling.
- **PlantUML DFD format** — listed in the AC as v2 follow-up; not in v1 scope.
- **Round-trip import** — hand-edited `dfd.md` → re-parsed back into the discovery model. v1 is producer-only; operators edit either the Mermaid file directly (one-shot) or re-run `/dfd` with corrected anchors / answers.

## Artifacts

- Ticket: [me2resh/apexyard#257](https://github.com/me2resh/apexyard/issues/257)
- Sibling tickets coordinated: [#255](https://github.com/me2resh/apexyard/issues/255), [#256](https://github.com/me2resh/apexyard/issues/256)
- Related prior art:
  - [AgDR-0003: Mermaid C4 for diagrams](AgDR-0003-mermaid-c4-for-diagrams.md) — why Mermaid is the default architecture-diagram format in apexyard (same logic applies here)
  - [me2resh/apexyard#225](https://github.com/me2resh/apexyard/issues/225) — original DFD section added to `/threat-model` (the thing being lifted out)
  - [`templates/architecture/dfd.md`](../../templates/architecture/dfd.md) — the DFD template `/dfd` populates
