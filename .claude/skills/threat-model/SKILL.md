---
name: threat-model
description: STRIDE threat modelling — spoofing, tampering, repudiation, disclosure, DoS, EoP. Deep-dive for /launch-check security.
disable-model-invocation: false
argument-hint: "[project-path] [--format=markdown|dragon|both]"
effort: high
---

# /threat-model — STRIDE Threat Modelling

Deep-dive security analysis using the STRIDE framework. Produces a prioritized threat catalogue with mitigations. This is the expert companion to `/launch-check`'s security row — invoke it when security shows WARN or FAIL, or proactively before any launch.

**Consumes the DFD produced by [`/dfd`](../dfd/SKILL.md).** The Data Flow Diagram at `projects/<project>/architecture/dfd.md` is the source of truth; this skill iterates its trust-boundary crossings rather than rebuilding its own data-flow view. If the DFD doesn't exist, this skill OFFERS to run `/dfd` first (see Step 1). See AgDR-0026 for the single-source-of-truth rationale.

## LSP-aware (optional, recommended)

This skill performs semantic code navigation — finding definitions, walking references, tracing handlers across modules. With LSP enabled (`ENABLE_LSP_TOOL=1` + per-language plugin per `docs/getting-started.md`), queries are ~3-15× cheaper in token cost than grep + Read on shallow lookups, and ~1.4-5× cheaper on multi-hop traces. Without LSP, the skill falls back to grep + Read transparently — no new failure mode, just optional speed.

Per-language LSP plugins live in Claude Code's marketplace. Install once; the skill detects the active language and dispatches automatically.

## Usage

```
/threat-model                                # default: markdown only (unchanged)
/threat-model --format=markdown              # explicit markdown only
/threat-model --format=dragon                # OWASP Threat Dragon v2 JSON only
/threat-model --format=both                  # both markdown AND Threat Dragon JSON
/threat-model workspace/example-app --format=both
```

| Flag | Effect |
|------|--------|
| (none) | Persist the markdown catalogue via `_lib-audit-history.sh` (default). Backwards-compatible. |
| `--format=markdown` | Same as default — explicit form. |
| `--format=dragon` | Skip the markdown body; emit only `<output-dir>/threat-model.json` in OWASP Threat Dragon v2 schema. JSON still flows through `_lib-audit-history.sh` for findings persistence (the lib's per-run JSON is unrelated to the Dragon export). |
| `--format=both` | Emit markdown AND `<output-dir>/threat-model.json`. Recommended when you want PR-reviewable markdown AND a Dragon-openable file. |

The Threat Dragon export is implemented by `serialize_dragon.py` (sibling to this SKILL.md). It reads a small structured-input file the skill builds during Step 1–2 (entities + flows + boundaries + threats) and writes a Threat Dragon v2 JSON document that opens directly in [OWASP Threat Dragon](https://github.com/OWASP/threat-dragon) (desktop or web). Format-choice rationale: [`docs/agdr/AgDR-0024-threat-dragon-export.md`](../../../docs/agdr/AgDR-0024-threat-dragon-export.md).

### Worked example (--format=dragon)

```
/threat-model workspace/example-app --format=dragon
```

After the STRIDE walk produces the entities + flows + threats, the skill emits:

```
projects/example-app/audits/threat-model/threat-model.json
```

Open the JSON in Threat Dragon (`File → Open Existing Threat Model`). Dragon's auto-arrange (toolbar) re-flows the auto-grid layout into a tidier view — the grid is just a sane starting state. STRIDE findings appear pinned to their parent shapes; click any shape's threat tab to edit them visually.

## STRIDE Categories

| Category | Question | What to look for |
|----------|----------|-----------------|
| **S**poofing | Can an attacker pretend to be someone else? | Auth implementation, session management, token validation, API key handling |
| **T**ampering | Can data be modified in transit or at rest? | Input validation, CSRF protection, data integrity checks, signed tokens |
| **R**epudiation | Can actions be denied after the fact? | Audit logging, action trails, non-repudiation mechanisms |
| **I**nformation Disclosure | Can sensitive data leak? | Error messages, logs, API responses, hardcoded secrets, .env exposure, debug mode |
| **D**enial of Service | Can the system be overwhelmed? | Rate limiting, input size limits, resource exhaustion, recursive queries |
| **E**levation of Privilege | Can a user gain unauthorized access? | Role checks, admin routes, authorization middleware, IDOR vulnerabilities |

## Process

### Step 1: Read the DFD (source of truth) — refuse if absent

The DFD is produced by [`/dfd`](../dfd/SKILL.md) and lives at `projects/<project>/architecture/dfd.md` — this is the **source of truth**. This skill consumes it; it does NOT regenerate it. The STRIDE walk in Step 2 iterates the DFD's trust-boundary crossings (the table in `dfd.md` § "Trust boundaries") rather than inventing threats ad-hoc.

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
projects_dir=$(portfolio_projects_dir)

dfd="${projects_dir}/${project_name}/architecture/dfd.md"
if [ ! -f "$dfd" ]; then
  cat >&2 <<MSG
BLOCKED: /threat-model requires a DFD at $dfd.

A STRIDE walk without a DFD is reactive — threats get invented per
entry point rather than enumerated per trust-boundary crossing. Worse,
without a DFD snapshot inlined at audit time, future readers can't tell
which architecture the threat model was enumerated against (#270).

Run /dfd ${project_name} first to produce the canonical DFD, then
re-run /threat-model.
MSG
  exit 1
fi
```

**Refusal (not fallback) is deliberate (#270).** The audit artefact embeds a DFD snapshot at audit time so the threat model remains internally consistent after the live DFD evolves. A threat model authored without a DFD has no anchor; the legacy "inline discovery" fallback that preceded #270 silently produced low-quality artefacts whose threats couldn't be re-validated later. Better to fail fast.

The DFD's structured elements feed Step 2:

- **Entry points** — every external actor → process arrow in the DFD is an entry point
- **Data stores** — every store node in the DFD
- **External integrations** — every external-service actor in the DFD
- **Trust boundaries** — every dashed subgraph border in the DFD; the per-boundary auth + classification table in `dfd.md` is the STRIDE worksheet

### Step 1b: Extract DFD sections for snapshot inlining

The threat-model audit output will inline three sections from `dfd.md` so the artefact is self-contained. Extract them now into separate variables so they can be embedded in the Step 5b body:

```bash
# Extract the ```mermaid ... ``` fenced block under `## Diagram`
dfd_mermaid=$(awk '
  /^## Diagram/        { in_diagram = 1; next }
  /^## /               { if (in_diagram) exit }
  in_diagram           { print }
' "$dfd")

# Extract the `## Trust boundaries` section (heading + body, up to next `## `)
dfd_trust=$(awk '
  /^## Trust boundaries/  { capture = 1 }
  /^## / && !/^## Trust/  { if (capture && NR > 1) exit }
  capture                 { print }
' "$dfd")

# Extract the `## Data classifications` section
dfd_classifications=$(awk '
  /^## Data classifications/ { capture = 1 }
  /^## / && !/^## Data classifications/ { if (capture && NR > 1) exit }
  capture                    { print }
' "$dfd")

# Discovery provenance is intentionally NOT extracted — too noisy for an
# audit snapshot. Readers click through to the live DFD for that.

dfd_captured_at=$(date -u +"%Y-%m-%d")
```

These three blocks become the `## DFD (snapshot as of YYYY-MM-DD)` section at the top of the audit body in Step 5b.

### Step 2: Apply STRIDE to each entry point

For each entry point, ask all 6 STRIDE questions. Record findings by severity:

| Severity | Meaning | Action |
|----------|---------|--------|
| **CRITICAL** | Exploitable now, data at risk | Fix before launch, no exceptions |
| **HIGH** | Likely exploitable, significant impact | Fix before launch |
| **MEDIUM** | Possible exploit, moderate impact | Fix in next sprint |
| **LOW** | Theoretical risk, minimal impact | Track, fix when convenient |

### Step 3: Output the threat catalogue

```
THREAT MODEL — <project> @ <sha>

Attack surface: <N> entry points, <N> data stores, <N> external integrations

| # | Category | Threat | Severity | Entry point | Mitigation |
|----|----------|--------|----------|-------------|------------|
| T1 | Spoofing | No rate limit on login | HIGH | POST /auth/login | Add rate limiter (5/min/IP) |
| T2 | Info Disc | API returns stack traces in prod | MEDIUM | Global error handler | Strip stack traces when NODE_ENV=production |
| T3 | Tampering | No CSRF token on state-changing forms | HIGH | POST /settings | Add CSRF middleware |
| ...| ... | ... | ... | ... | ... |

Summary: <N> threats found (<N> critical, <N> high, <N> medium, <N> low)

Recommended priority:
  1. [ ] T1 — rate limit on login (HIGH, easy fix)
  2. [ ] T3 — CSRF protection (HIGH, middleware addition)
  3. [ ] T2 — strip stack traces (MEDIUM, config change)
```

### Step 4: Check common OWASP patterns

After the STRIDE sweep, explicitly check for:

- SQL/NoSQL injection (parameterized queries? ORM used consistently?)
- XSS (dangerouslySetInnerHTML, v-html, template literals in HTML?)
- Insecure deserialization (JSON.parse on untrusted input without validation?)
- Security misconfiguration (CORS *, debug mode, default credentials?)
- Using components with known vulnerabilities (`npm audit` / `pip audit`)

### Step 5: Persist the run + render trend

After printing the human-readable catalogue (Step 3) and OWASP check (Step 4), persist a structured artefact via the shared audit-history lib so the threat-model trend across runs becomes legible. See `docs/agdr/AgDR-0019-audit-artefact-persistence.md` for the schema rationale.

#### 5a. Resolve project name + score + verdict

`<project-name>` is the project's registered name in `apexyard.projects.yaml`. If the project isn't registered, use the basename of the project path and tell the operator to `/handover` it for cross-machine trend continuity.

Compute a single headline score from the severity distribution:

```
score = max(0, 100 - 25*critical - 10*high - 3*medium - 1*low)
```

Compute the verdict by the worst-severity rule:

| Worst severity present | Verdict |
|---|---|
| critical or high       | `fail` |
| medium only            | `conditional` |
| low only / none        | `pass` |

#### 5b. Build payload + body, persist via the lib

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-audit-history.sh"

# Lowercase severity in the payload — the lib's stats derivation expects
# critical / high / medium / low / info. The visible catalogue from Step 3
# can keep whatever capitalisation reads best.
payload=$(mktemp); cat > "$payload" <<'EOF'
{
  "schema_version": 1,
  "findings": [
    {"id": "T1", "severity": "high",   "status": "open", "summary": "No rate limit on /auth/login"},
    {"id": "T2", "severity": "medium", "status": "open", "summary": "Stack traces in prod errors"},
    {"id": "T3", "severity": "high",   "status": "open", "summary": "No CSRF on state-changing forms"}
  ]
}
EOF

# Body = DFD snapshot + catalogue + OWASP cross-check (per templates/audits/threat-model.md).
# The DFD snapshot (#270) sits at the top so readers see the architecture
# this threat model was enumerated against BEFORE the threats themselves.
# Use a heredoc-with-expansion (no quotes around 'EOF') so the captured
# variables from Step 1b interpolate.
body=$(mktemp); cat > "$body" <<EOF
## DFD (snapshot as of ${dfd_captured_at})

> **Point-in-time capture.** This is the DFD as it was when this threat model
> was enumerated. The live DFD evolves at \`${dfd}\` — re-run \`/threat-model\`
> to refresh against current architecture. Future runs of this audit will
> snapshot the DFD as-it-was-then, not as-it-is-now.

\`\`\`mermaid
${dfd_mermaid}\`\`\`

${dfd_trust}

${dfd_classifications}

---

## Attack surface

3 entry points, 1 data store, 0 external integrations.

## Threats by STRIDE category

| # | Category | Threat | Severity | Entry point | Mitigation |
|---|---|---|---|---|---|
| T1 | Spoofing | No rate limit on /auth/login | high | POST /auth/login | Add rate limiter (5/min/IP) |
| T2 | Info Disclosure | Stack traces in prod errors | medium | Global error handler | Strip when NODE_ENV=production |
| T3 | Tampering | No CSRF on state-changing forms | high | POST /settings | Add CSRF middleware |

## Recommended priority

1. T1 — rate limit on /auth/login
2. T3 — CSRF middleware
3. T2 — strip stack traces

## OWASP cross-check

(... per Step 4 results ...)
EOF

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
audit_run_persist "<project-name>" "threat-model" "$ts" "fail" 65 "$body" < "$payload"
rm -f "$payload" "$body"
```

After persistence, lint the inlined Mermaid (#266) to catch any DFD-syntax breakage that would render badly on GitHub:

```bash
# The audit_run_persist writes to projects/<name>/audits/threat-model/<ts>.md.
# Resolve the path the lib used and run the shared Mermaid lint.
audit_md="$(audit_resolve_dir "<project-name>" "threat-model")/${ts//:/}.md"
ops_root="$(git rev-parse --show-toplevel)"
"$ops_root/.claude/skills/_lib-mermaid-lint.sh" "$audit_md" || lint_rc=$?
```

Exit 1 (parse error in the snapshotted block) → the DFD itself has broken Mermaid; surface that and ask the operator to fix the live DFD before re-running. Exit 3 (Node missing) → one-line warning, proceed. The snapshot's lint passes whenever the live DFD's lint passes — same parser, same input.

#### 5c. Render the trend section

```bash
audit_render_trend "<project-name>" "threat-model" 5
```

- < 2 prior runs → silent (no trend section). Don't append anything.
- ≥ 2 prior runs → prints a markdown trend block (heading + table + ASCII chart of `score` over time) to stdout. Append it to this run's MD artefact and to the chat output.

### Step 6: Emit Threat Dragon JSON (only if `--format=dragon` or `--format=both`)

When `--format=dragon` or `--format=both` is set, build a structured-input YAML (or JSON — either is accepted by the serialiser) from the DFD + STRIDE catalogue, then invoke `serialize_dragon.py`.

Structured-input schema (see `fixtures/sample-input.yaml` for a worked example):

| Top-level key | Type | Purpose |
|---------------|------|---------|
| `title` | string | Becomes `summary.title` (required by Threat Dragon schema). |
| `description` | string | Optional `summary.description`. |
| `owner` | string | Optional `summary.owner`. |
| `contributors` | list[string] | Becomes `detail.contributors[]`. |
| `reviewer` | string | Optional `detail.reviewer`. |
| `actors` | list[{id, name}] | External entities → `shape: actor`. |
| `processes` | list[{id, name}] | Processes → `shape: process`. |
| `stores` | list[{id, name}] | Data stores → `shape: store`. |
| `boundaries` | list[{id, name, children: [id, ...]}] | Trust boundaries → `shape: trust-boundary-box` wrapping their children with a 40px margin. |
| `flows` | list[{id, source, target, label}] | Data flows → `shape: flow` with `source.cell` / `target.cell` UUIDs. |
| `threats` | list[{parent, type, severity, title, description, mitigation}] | STRIDE findings → attached to the parent entity's `data.threats[]`. |

Severity vocabulary in the input matches the rest of the skill (lowercase `critical / high / medium / low / info`); the serialiser maps it into Dragon's `High / Medium / Low` enum. STRIDE `type` is one of `Spoofing`, `Tampering`, `Repudiation`, `Information disclosure`, `Denial of service`, `Elevation of privilege` (the canonical labels Dragon uses; common shortenings like `info disc`, `DoS`, `EoP` are accepted and normalised).

#### 6a. Resolve the output path

```bash
out_dir=$(audit_resolve_dir "<project-name>" "threat-model")
dragon_path="$out_dir/threat-model.json"
```

`$out_dir` is the same per-project audit dir Step 5 writes to. The Dragon JSON sits alongside the per-run JSON + per-run MD; one Dragon export per project at a time (overwritten on subsequent runs). Operators who want to keep historic Dragon exports for diffing should rename them by hand — the markdown trend in Step 5c is the supported way to track findings over time.

#### 6b. Build the structured input and invoke the serialiser

Write the structured input to a temp file, then invoke `serialize_dragon.py`:

```bash
input=$(mktemp --suffix=.yaml)
cat > "$input" <<'YAML'
title: "Example Web Application"
description: "Threat model run on 2026-05-16, commit <sha>."
owner: "Security Team"
contributors: ["Alice", "Bob"]
reviewer: "Carol"

actors:
  - { id: user, name: "External user" }

processes:
  - { id: web, name: "Web frontend" }
  - { id: api, name: "API service" }

stores:
  - { id: db, name: "Primary data store" }

boundaries:
  - { id: internet, name: "Public internet", children: [web] }
  - { id: backend,  name: "Backend network", children: [api, db] }

flows:
  - { id: f1, source: user, target: web, label: "credentials" }
  - { id: f2, source: web,  target: api, label: "auth token, user PII" }
  - { id: f3, source: api,  target: db,  label: "user PII, transaction" }

threats:
  - parent: api
    type: "Spoofing"
    severity: "high"
    title: "No rate limit on /auth/login"
    description: "Attacker can brute-force login credentials."
    mitigation: "Add a rate limiter (5/min/IP) at the API gateway."
YAML

python3 "$(git rev-parse --show-toplevel)/.claude/skills/threat-model/serialize_dragon.py" \
  "$input" --out "$dragon_path"
rm -f "$input"
```

#### 6c. Tell the operator what was written

After the file is written, surface it in the chat output so the operator knows where to find it:

```
Threat Dragon v2 JSON written to: <dragon_path>
Open in https://www.threatdragon.com or the OWASP Threat Dragon desktop app.
Dragon's auto-arrange (toolbar) re-flows the auto-grid layout on first open.
```

#### 6d. Layout note

The serialiser uses an auto-grid layout (actors row at `y=0`, processes at `y=200`, stores at `y=400`; x-spaced 200px). Trust-boundary boxes wrap their children with a 40px margin. This is a sane starting state — Threat Dragon's own auto-arrange button re-flows the diagram into a tidier view on first open. Hand-authored coordinates are out of scope for v1 (see AgDR-0024 § "Auto-grid layout decision").

#### 5d. Opt-in commit (history-tracked marker)

By default the dimension's runs/ JSON files are gitignored — most adopters don't want audit history bloat in the repo. The lib applies a `.gitignore` based on the presence of the marker:

```bash
# Opt in to commit threat-model history (per-project, per-dimension)
touch projects/<name>/audits/threat-model/.audit-history-tracked
```

The lib re-evaluates the marker on every persist; the operator can toggle freely. The MD artefacts at `<dim_dir>/<ts>.md` are committed regardless — they are the durable human-readable artefact.

## Rules

1. **Lead with the summary table.** Details (code snippets, exploit scenarios) go AFTER the table, organized by severity.
2. **Be specific about mitigations.** "Add auth" is not a mitigation. "Add JWT verification middleware to routes /api/admin/* using the existing authMiddleware.ts" is.
3. **Don't cry wolf.** Only flag threats that are realistic for this codebase. A static site doesn't need CSRF protection.
4. **Adapt scope to project type.** API-only? Focus on auth, input validation, rate limiting. Full-stack? Add XSS, CSRF, cookie security. Library? Focus on supply chain and input handling.
5. **Always persist.** Step 5 always writes a JSON + MD pair via `audit_run_persist`, regardless of opt-in commit state. The marker only controls whether the JSON is committed; persistence is unconditional so the trend is visible across runs.
6. **Severity vocabulary in the JSON is lowercase.** The lib's `stats.by_severity` derivation expects `critical` / `high` / `medium` / `low` / `info`. The human-readable Step 3 table can use whatever capitalisation reads best.
7. **Default output is unchanged.** `--format=dragon` and `--format=both` are opt-in; the markdown-only path stays default so existing adopters see no behaviour change. See AgDR-0024 for the format-choice rationale.
8. **No DFD → no threat model (#270).** Refuse rather than fall back to inline discovery. A threat model that wasn't enumerated against a DFD has no point-in-time anchor; future readers can't replay the analysis. The fail-fast behaviour is mechanical (Step 1 `exit 1`), not advisory.
9. **DFD snapshot is by copy, not by link.** The audit artefact embeds the DFD's Mermaid block + Trust-boundaries table + Data-classifications table inline. This is deliberate (#270) — linking would couple the rendering of historical threat models to whatever the live DFD says today, defeating the audit's point-in-time guarantee. Re-run `/threat-model` to refresh the snapshot.
10. **Discovery provenance is excluded from the snapshot.** The live DFD's `## Discovery provenance` section (raw axis-by-axis evidence) is too noisy for an audit artefact. Readers click through to the live DFD if they need the provenance trail.

## Anti-patterns

- **Don't link to the live DFD.** Inline copy at audit time. The whole point of the snapshot is that the threat model survives later DFD edits without rotting.
- **Don't fall back to "inline discovery" when the DFD is missing.** That was the pre-#270 behaviour; it produced low-quality artefacts that couldn't be re-validated later. Refuse instead.
- **Don't extract from `dfd.md` programmatically beyond the three sections named in Step 1b.** The contract is: Mermaid block + trust boundaries + classifications. Adding more (e.g. provenance) bloats the artefact; adding less breaks the audit's self-containment.
- **Don't skip the Mermaid lint after persistence.** If the live DFD has broken Mermaid, the snapshot inherits it. Surfacing that here is cheaper than discovering it on GitHub.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
