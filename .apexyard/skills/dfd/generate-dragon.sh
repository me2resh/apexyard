#!/usr/bin/env bash
# /dfd — generate an OWASP Threat Dragon v2 JSON file from the DFD
# discovery model. Shared serialiser path with #255
# (`/threat-model --format=dragon`).
#
# Design:
#   - This is a pure function over the in-memory DFD model. The skill's
#     SKILL.md flow assembles the model from discover.sh + classify.sh +
#     operator input, then calls this script with structured input on
#     stdin.
#   - When `/threat-model --format=dragon` (#255) ships, it imports this
#     script (or its successor `_lib-threat-dragon-serialiser.sh`) so
#     both consumers produce byte-compatible Threat Dragon JSON.
#
# Input format (read from stdin or --input <path>):
#   A JSON document with the in-memory DFD model:
#   {
#     "project": "...",
#     "actors":   [ { "id": "...", "name": "...", "type": "human|external_service" } ],
#     "processes":[ { "id": "...", "name": "...", "type": "http_handler|queue_consumer|scheduled" } ],
#     "stores":   [ { "id": "...", "name": "...", "type": "rdbms|cache|object_storage|search|..." } ],
#     "flows":    [ { "source": "id", "target": "id", "label": "payload hint" } ],
#     "boundaries": [ { "id": "...", "name": "...", "contains": [ "id1", "id2", ... ] } ],
#     "threats":  [ { "element": "id", "type": "S|T|R|I|D|E", "severity": "...", "description": "...", "mitigation": "...", "status": "Open" } ]
#   }
#
# Output: Threat Dragon v2 JSON on stdout. Caller writes to
# `projects/<name>/architecture/dfd.json` (or `threat-model.json` for #255).
#
# Schema reference:
#   https://github.com/OWASP/threat-dragon/blob/main/td.vue/src/service/migration/schema/threat-model.v2.json

set -uo pipefail

INPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: generate-dragon.sh requires jq" >&2
  exit 2
fi

# Read the input model
if [ -n "$INPUT" ] && [ -f "$INPUT" ]; then
  MODEL=$(cat "$INPUT")
elif [ ! -t 0 ]; then
  MODEL=$(cat)
else
  echo "ERROR: no input — pass --input <path> or pipe JSON model on stdin" >&2
  exit 2
fi

# Validate the input is JSON
if ! echo "$MODEL" | jq empty 2>/dev/null; then
  echo "ERROR: input is not valid JSON" >&2
  exit 2
fi

PROJECT=$(echo "$MODEL" | jq -r '.project // "unknown-project"')
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Auto-grid layout (same as #255 spec): external actors row y=0,
# processes y=200, data stores y=400; x-spaced by 200px. Threat Dragon
# auto-arranges on first open; the grid is just a sane starting state.
#
# We assign sequential X positions per row by reading the model and
# letting jq do the indexing.

# Build the Threat Dragon v2 model structure.
# Key shapes:
#   tm.title, tm.version, tm.summary.description, tm.detail.contributors[]
#   tm.detail.diagrams[0].cells[]
#     - actors  → shape: tm.actor (rectangle), labelled with .data.name
#     - processes → shape: tm.process (circle)
#     - stores   → shape: tm.store (cylinder)
#     - boundaries → shape: tm.boundary (dashed boundary box wrapping its children)
#     - flows    → shape: tm.flow (arrow with source/target IDs)
#   Each .data block carries the element's threats[] (from STRIDE walk)

JQ_SCRIPT='
  def xy(row; idx): { x: (200 * (idx + 1)), y: row };

  ((.actors    // []) | to_entries | map(.value + (xy(0;   .key) | {position: .})))  as $actors  |
  ((.processes // []) | to_entries | map(.value + (xy(200; .key) | {position: .})))  as $procs   |
  ((.stores    // []) | to_entries | map(.value + (xy(400; .key) | {position: .})))  as $stores  |
  ((.flows     // []))                                                                as $flows   |
  ((.boundaries // []))                                                               as $bounds  |
  ((.threats    // []))                                                               as $threats |

  def cell_for_element(el; td_type):
    (el.id) as $eid |
    {
      id: $eid,
      type: td_type,
      data: {
        name: el.name,
        type: td_type,
        outOfScope: false,
        threats: [
          $threats[] | select(.element == $eid) | {
            id: (.id // (.element + "-" + .type)),
            title: (.title // .description // "Untitled threat"),
            type: (
              if   .type == "S" then "Spoofing"
              elif .type == "T" then "Tampering"
              elif .type == "R" then "Repudiation"
              elif .type == "I" then "Information disclosure"
              elif .type == "D" then "Denial of service"
              elif .type == "E" then "Elevation of privilege"
              else "Unknown" end
            ),
            severity: (.severity // "Medium"),
            description: (.description // ""),
            mitigation:  (.mitigation  // "TBD"),
            status: (.status // "Open"),
            modelType: "STRIDE"
          }
        ]
      },
      position: el.position,
      size: { width: 160, height: 60 }
    };

  {
    version: "2.3",
    summary: {
      title: ($project + " — DFD"),
      owner: "apexyard /dfd",
      description: "Generated DFD for STRIDE threat modelling. Source of truth — threat-model and compliance-check consume from this file."
    },
    detail: {
      contributors: [{ name: "apexyard /dfd" }],
      diagrams: [
        {
          id: "dfd-1",
          title: "Data Flow Diagram",
          diagramType: "STRIDE",
          placeholder: "Edit in Threat Dragon — auto-layout will re-flow elements on first open.",
          thumbnail: "./public/content/images/thumbnail.stride.jpg",
          version: "2.3",
          cells: (
            ( $actors | map(cell_for_element(.; "tm.actor")) )
            + ( $procs  | map(cell_for_element(.; "tm.process")) )
            + ( $stores | map(cell_for_element(.; "tm.store")) )
            + ( $bounds | map({
                id: .id,
                type: "tm.boundary",
                data: {
                  name: .name,
                  type: "tm.boundary",
                  description: (.rationale // ""),
                  isTrustBoundary: true,
                  contains: (.contains // [])
                },
                position: { x: 50, y: 50 },
                size: { width: 600, height: 400 }
              }) )
            + ( $flows | to_entries | map(.value as $f | {
                id: ("flow-" + (.key | tostring)),
                type: "tm.flow",
                data: {
                  name: ($f.label // "data"),
                  type: "tm.flow",
                  isEncrypted: false,
                  isPublicNetwork: false,
                  protocol: ""
                },
                source: { cell: $f.source },
                target: { cell: $f.target }
              }) )
          )
        }
      ]
    },
    generatedBy: "apexyard /dfd",
    generatedAt: $ts
  }
'

echo "$MODEL" | jq --arg project "$PROJECT" --arg ts "$DATE" "$JQ_SCRIPT"
