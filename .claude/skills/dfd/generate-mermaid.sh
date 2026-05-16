#!/usr/bin/env bash
# /dfd — generate a Mermaid flowchart from the discover.sh + classify.sh
# structured discovery report.
#
# Reads the structured YAML-ish report from stdin (or a file argument)
# and emits a markdown file with:
#   1. A header pointing at the source-of-truth status and the generated-at date
#   2. The Mermaid flowchart block (trust boundaries as dashed subgraphs,
#      every cross-boundary arrow labelled with the payload hint)
#   3. A trust-boundaries table (same shape as templates/architecture/dfd.md)
#   4. A data-classifications table (from classify.sh's output)
#   5. Provenance metadata — evidence file:line for every element
#
# Usage:
#   generate-mermaid.sh <project-name> [<discovery-yaml-path>] [<classifications-yaml-path>]
#     If the YAML paths are omitted, read from stdin (combined report).
#
# Output: full markdown content on stdout. Caller writes to
# `projects/<project-name>/architecture/dfd.md`.
#
# This is a structural template — the actual element list comes from
# discover.sh + classify.sh's output. When invoked from inside Claude
# Code, the agent additionally enriches labels, picks better display
# names, and resolves the trust-boundary placements with the operator
# before re-running this generator.

set -uo pipefail

PROJECT="${1:-unknown-project}"
DISCOVERY="${2:-}"
CLASSIFICATIONS="${3:-}"

DATE=$(date -u +%Y-%m-%d)

cat <<EOF
# ${PROJECT} — Data Flow Diagram

> **Source of truth.** This file is the canonical DFD for ${PROJECT}. \`/threat-model\` and \`/compliance-check\` consume it instead of regenerating their own. Re-run \`/dfd ${PROJECT}\` after any architecture change that adds / removes a data store, external integration, or trust boundary.

**Generated**: ${DATE} by \`/dfd\` (apexyard)
**Format**: Mermaid flowchart (renders inline on GitHub) — also available as Threat Dragon JSON via \`/dfd ${PROJECT} --format=dragon\`

## Diagram

\`\`\`mermaid
flowchart LR
    %% External actors (outside all trust boundaries)
    user([External User])
    %% Third-party services live outside the system boundary too
    %% (one node per detected vendor; populated from discover.sh)

    %% Trust zones — dashed subgraphs mark each boundary
    subgraph public_zone["Public Zone (untrusted)"]
        frontend["Frontend"]
    end

    subgraph trusted_backend["Trusted Backend"]
        api["HTTP API"]
        worker["Background Worker"]
    end

    subgraph data_zone["Data Zone (most-trusted)"]
        primary_db[("Primary Store")]
    end

    %% Data flows — every cross-boundary arrow MUST carry a payload label
    user -->|credentials, form data| frontend
    frontend -->|auth token, request body| api
    api -->|read/write records| primary_db
    api -->|enqueue job + payload| worker

    style public_zone stroke-dasharray: 5 5
    style trusted_backend stroke-dasharray: 5 5
    style data_zone stroke-dasharray: 5 5
\`\`\`

The dashed subgraph borders mark **trust boundaries**. Every arrow that crosses a boundary is a STRIDE candidate — that's where authentication, authorisation, and data-classification rules apply most acutely.

> **Editing this diagram by hand.** The diagram above is a starting structure. Replace the placeholders with the actors / processes / stores / flows the discovery report below identified, and add additional cross-boundary arrows for every flow the operator confirmed during the \`/dfd\` interview. Re-running \`/dfd\` will OVERWRITE this file (after the default-no overwrite prompt) — preserve hand edits by copying them to a sibling file, or re-run with the same anchor + answers so the regeneration matches.

---

## Trust boundaries

| From | To | Authentication | Data classification (most-sensitive crossing) |
|------|-----|----------------|-----------------------------------------------|
| External User → Frontend | TLS only (browser session) | Credentials, form input |
| Frontend → API | TLS + bearer token (JWT / session) | Auth token, user PII, request body |
| API → Primary Store | VPC-internal + DB credentials from secrets store | All persistent user records |
| API → Worker | Internal queue (auth via shared transport credentials) | Job payload — may contain user PII |
| API → Third-party SaaS | TLS + API key | Outbound webhook payload — sanitise before sending |

Adjust this table to match the diagram. Each row is a STRIDE entry point — `/threat-model` iterates these crossings rather than inventing threats ad-hoc.

---

## Data classifications

The skill detected the following data classifications via the three heuristic pathways (annotations, env-var names, schema columns) plus any explicit registry the project ships:

| Label | Detected element | Pathway | Evidence |
|-------|------------------|---------|----------|
| _populated from classify.sh output during skill execution_ |

\`/compliance-check\` reads this table to flag cross-border transfers, third-party processors, and PII landing in unencrypted stores.

---

## Discovery provenance

The candidate model was assembled from the following evidence:

EOF

# Inline the raw discovery YAML for provenance — readers can see which
# code paths surfaced which elements.
if [ -n "$DISCOVERY" ] && [ -f "$DISCOVERY" ]; then
  echo "### From \`discover.sh\` (six-axis scan)"
  echo ""
  echo '```yaml'
  cat "$DISCOVERY"
  echo '```'
  echo ""
fi

if [ -n "$CLASSIFICATIONS" ] && [ -f "$CLASSIFICATIONS" ]; then
  echo "### From \`classify.sh\` (data-classification heuristics)"
  echo ""
  echo '```yaml'
  cat "$CLASSIFICATIONS"
  echo '```'
  echo ""
fi

# If neither file argument given, slurp stdin (combined report).
if [ -z "$DISCOVERY" ] && [ -z "$CLASSIFICATIONS" ] && [ ! -t 0 ]; then
  echo "### From discovery (combined stdin)"
  echo ""
  echo '```yaml'
  cat
  echo '```'
  echo ""
fi

cat <<EOF

---

## Notes

Each crossing of a trust boundary is where STRIDE threats apply most acutely:

- **Spoofing** — can the source's identity be forged on this hop?
- **Tampering** — can the data be modified in transit / at the receiver?
- **Repudiation** — can the sender deny having sent this?
- **Information disclosure** — what leaks if this hop is intercepted?
- **Denial of service** — what's the failure mode if this hop is overwhelmed?
- **Elevation of privilege** — does crossing this boundary grant additional permissions, and are those bounded correctly?

Pair this DFD with [\`/threat-model\`](../../../.claude/skills/threat-model/SKILL.md) so the boundary table feeds directly into a per-arrow STRIDE enumeration. Pair with [\`/compliance-check\`](../../../.claude/skills/compliance-check/SKILL.md) so the classifications table feeds directly into cross-border-transfer and DPA-coverage analysis.

---

_Generated by \`/dfd\` on ${DATE}. Re-run \`/dfd ${PROJECT}\` after architecture changes._
EOF
