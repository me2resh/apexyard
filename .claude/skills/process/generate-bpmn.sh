#!/usr/bin/env bash
# /process generate-bpmn.sh
#
# Emit a BPMN 2.0 XML file from a structured candidate-model JSON.
# Adds deterministic grid coordinates, including pool and lane shapes,
# using Python 3 (standard library only).
#
# Usage:
#   generate-bpmn.sh --slug=<process-slug> --model=<model.json> -o <output.bpmn>
#                    [--pools]          # one pool per repo + message flows (vs default: swimlanes within one pool)
#                    [--skip-layout]    # emit bare BPMN without <bpmndi>
#
# Model JSON schema (consumed):
#   {
#     "slug": "onboarding",
#     "description": "Signup → email-verify → profile-complete",
#     "lanes": [ {"id": "lane_signup", "name": "signup-svc"}, ... ],
#     "nodes": [
#       {"id": "evt_start", "type": "event-start", "label": "Signup submitted",
#        "lane": "lane_signup", "evidence": "src/routes/signup.ts:14"},
#       {"id": "task_validate", "type": "task", ...},
#       {"id": "gw_email_verified", "type": "gateway-exclusive", "label": "Email verified?", ...}
#     ],
#     "edges": [
#       {"from": "evt_start", "to": "task_validate", "kind": "sequence", "label": ""},
#       {"from": "task_send_verify", "to": "task_verify_identity", "kind": "message",
#        "label": "verify-identity-requested"}
#     ]
#   }
#
# Node types (mapped to BPMN element names):
#   event-start         → bpmn:startEvent
#   event-end           → bpmn:endEvent
#   event-intermediate  → bpmn:intermediateCatchEvent
#   task                → bpmn:task
#   task-service        → bpmn:serviceTask
#   task-user           → bpmn:userTask
#   task-send           → bpmn:sendTask
#   task-receive        → bpmn:receiveTask
#   gateway             → bpmn:exclusiveGateway   (alias for gateway-exclusive)
#   gateway-exclusive   → bpmn:exclusiveGateway
#   gateway-parallel    → bpmn:parallelGateway
#   subprocess          → bpmn:subProcess
#
# Edge kinds:
#   sequence → bpmn:sequenceFlow (inside a single bpmn:process)
#   message  → bpmn:messageFlow  (inside bpmn:collaboration, between pools)

set -euo pipefail

SLUG=""
MODEL=""
OUTPUT=""
POOLS=0
SKIP_LAYOUT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --slug=*)    SLUG="${1#--slug=}";   shift ;;
    --model=*)   MODEL="${1#--model=}"; shift ;;
    -o)          OUTPUT="$2";           shift 2 ;;
    --output=*)  OUTPUT="${1#--output=}"; shift ;;
    --pools)     POOLS=1;               shift ;;
    --skip-layout) SKIP_LAYOUT=1;       shift ;;
    --help|-h)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *)
      echo "generate-bpmn.sh: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$SLUG" ] || [ -z "$MODEL" ] || [ -z "$OUTPUT" ]; then
  echo "generate-bpmn.sh: --slug, --model, and -o are required" >&2
  exit 2
fi
if [ ! -f "$MODEL" ]; then
  echo "generate-bpmn.sh: model file not found: $MODEL" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# XML escaping helpers — single source of truth so element labels with
# &, <, >, ", or ' don't break the output.
# ---------------------------------------------------------------------------
xml_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g'  \
    -e 's/>/\&gt;/g'  \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

# ---------------------------------------------------------------------------
# Model parsing — use jq if present, fall back to python3 for portability.
# Outputs TAB-separated rows on stdout, one per node / edge / lane.
#
# Lane row:  TYPE=lane    id   name
# Node row:  TYPE=node    id   type   label   lane   evidence
# Edge row:  TYPE=edge    from to     kind    label
# Meta row:  TYPE=meta    slug description
# ---------------------------------------------------------------------------
parse_model() {
  if command -v jq >/dev/null 2>&1; then
    # Wrap each top-level expression in parens so the `|` inside one branch
    # doesn't leak into the next comma-separated branch (jq's pipe binds
    # tighter than comma, so the bare form interprets the model wrong on
    # mixed inputs).
    jq -r '
      ("meta\t" + (.slug // "") + "\t" + (.description // "")),
      ((.lanes // [])[] | "lane\t" + (.id // "") + "\t" + (.name // "")),
      ((.nodes // [])[] | "node\t" + (.id // "") + "\t" + (.type // "task") + "\t" + (.label // "") + "\t" + (.lane // "") + "\t" + (.evidence // "")),
      ((.edges // [])[] | "edge\t" + (.from // "") + "\t" + (.to // "") + "\t" + (.kind // "sequence") + "\t" + (.label // ""))
    ' "$MODEL"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$MODEL" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)
print(f"meta\t{m.get('slug','')}\t{m.get('description','')}")
for l in m.get("lanes", []):
    print(f"lane\t{l.get('id','')}\t{l.get('name','')}")
for n in m.get("nodes", []):
    print(f"node\t{n.get('id','')}\t{n.get('type','task')}\t{n.get('label','')}\t{n.get('lane','')}\t{n.get('evidence','')}")
for e in m.get("edges", []):
    print(f"edge\t{e.get('from','')}\t{e.get('to','')}\t{e.get('kind','sequence')}\t{e.get('label','')}")
PY
  else
    echo "generate-bpmn.sh: neither jq nor python3 found — install one" >&2
    exit 2
  fi
}

ROWS=$(parse_model)

# Split rows by type.
LANES=$(echo "$ROWS"  | awk -F'\t' '$1=="lane"')
NODES=$(echo "$ROWS"  | awk -F'\t' '$1=="node"')
EDGES=$(echo "$ROWS"  | awk -F'\t' '$1=="edge"')
META=$(echo "$ROWS"   | awk -F'\t' '$1=="meta"' | head -1)

META_SLUG=$(echo "$META"  | awk -F'\t' '{print $2}')
META_DESC=$(echo "$META"  | awk -F'\t' '{print $3}')
[ -z "$META_SLUG" ] && META_SLUG="$SLUG"

# ---------------------------------------------------------------------------
# BPMN element name dispatch
# ---------------------------------------------------------------------------
bpmn_element_for_type() {
  case "$1" in
    event-start)        echo "bpmn:startEvent" ;;
    event-end)          echo "bpmn:endEvent" ;;
    event-intermediate) echo "bpmn:intermediateCatchEvent" ;;
    task)               echo "bpmn:task" ;;
    task-service)       echo "bpmn:serviceTask" ;;
    task-user)          echo "bpmn:userTask" ;;
    task-send)          echo "bpmn:sendTask" ;;
    task-receive)       echo "bpmn:receiveTask" ;;
    gateway|gateway-exclusive) echo "bpmn:exclusiveGateway" ;;
    gateway-parallel)   echo "bpmn:parallelGateway" ;;
    subprocess)         echo "bpmn:subProcess" ;;
    *)                  echo "bpmn:task" ;;  # safest fallback
  esac
}

# ---------------------------------------------------------------------------
# Build a per-node outgoing/incoming index for <bpmn:incoming> / <bpmn:outgoing>
# References from sequence flows are required for valid BPMN.
# ---------------------------------------------------------------------------
TMP=$(mktemp -d -t process-bpmn-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# Pre-compute sequence flow IDs (deterministic: flow_<from>_<to>).
SEQ_FLOWS=()
MSG_FLOWS=()
while IFS=$'\t' read -r _ from to kind label; do
  [ -z "$from" ] && continue
  flow_id="flow_${from}_${to}"
  if [ "$kind" = "message" ]; then
    MSG_FLOWS+=("$flow_id|$from|$to|$label")
  else
    SEQ_FLOWS+=("$flow_id|$from|$to|$label")
  fi
done <<< "$EDGES"

incoming_for() {
  local node="$1"
  local f
  for f in ${SEQ_FLOWS[@]+"${SEQ_FLOWS[@]}"}; do
    IFS='|' read -r fid ffrom fto _ <<< "$f"
    [ "$fto" = "$node" ] && echo "$fid"
  done
}

outgoing_for() {
  local node="$1"
  local f
  for f in ${SEQ_FLOWS[@]+"${SEQ_FLOWS[@]}"}; do
    IFS='|' read -r fid ffrom fto _ <<< "$f"
    [ "$ffrom" = "$node" ] && echo "$fid"
  done
}

# ---------------------------------------------------------------------------
# Emit the BPMN
# ---------------------------------------------------------------------------
BARE="$TMP/bare.bpmn"

emit_bare_bpmn() {
  local slug_esc desc_esc
  slug_esc=$(xml_escape "$META_SLUG")
  desc_esc=$(xml_escape "$META_DESC")

  cat > "$BARE" <<HEADER
<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions
  xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
  xmlns:bpmndi="http://www.omg.org/spec/BPMN/20100524/DI"
  xmlns:dc="http://www.omg.org/spec/DD/20100524/DC"
  xmlns:di="http://www.omg.org/spec/DD/20100524/DI"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  id="Definitions_${slug_esc}"
  targetNamespace="http://apexyard/process/${slug_esc}"
  exporter="apexyard /process"
  exporterVersion="1.0">
HEADER

  # Process body. We emit one <bpmn:process> (default mode) or one per pool.
  # For simplicity the default emits a single process containing all lanes.
  cat >> "$BARE" <<PROC_OPEN
  <bpmn:process id="Process_${slug_esc}" name="$(xml_escape "$META_SLUG")" isExecutable="false">
    <bpmn:documentation>${desc_esc}

Generated by /process from code-discovery + interview. Do not hand-edit —
re-run /process ${slug_esc} after the underlying code changes.</bpmn:documentation>
PROC_OPEN

  # Lane set (only when lanes are present and we're in swimlane mode).
  if [ -n "$LANES" ] && [ "$POOLS" -eq 0 ]; then
    echo '    <bpmn:laneSet id="LaneSet_'"$slug_esc"'">' >> "$BARE"
    while IFS=$'\t' read -r _ lid lname; do
      [ -z "$lid" ] && continue
      echo "      <bpmn:lane id=\"$(xml_escape "$lid")\" name=\"$(xml_escape "$lname")\">" >> "$BARE"
      # Per-lane flowNodeRef listing.
      while IFS=$'\t' read -r _ nid _ _ nlane _; do
        [ -z "$nid" ] && continue
        if [ "$nlane" = "$lid" ]; then
          echo "        <bpmn:flowNodeRef>$(xml_escape "$nid")</bpmn:flowNodeRef>" >> "$BARE"
        fi
      done <<< "$NODES"
      echo '      </bpmn:lane>' >> "$BARE"
    done <<< "$LANES"
    echo '    </bpmn:laneSet>' >> "$BARE"
  fi

  # Nodes
  while IFS=$'\t' read -r _ nid ntype nlabel _ nevidence; do
    [ -z "$nid" ] && continue
    elem=$(bpmn_element_for_type "$ntype")
    id_esc=$(xml_escape "$nid")
    label_esc=$(xml_escape "$nlabel")
    evidence_esc=$(xml_escape "$nevidence")
    echo "    <${elem} id=\"${id_esc}\" name=\"${label_esc}\">" >> "$BARE"
    if [ -n "$nevidence" ]; then
      echo "      <bpmn:documentation>Source: ${evidence_esc}</bpmn:documentation>" >> "$BARE"
    fi
    # Incoming / outgoing flow refs.
    while IFS= read -r fid; do
      [ -z "$fid" ] && continue
      echo "      <bpmn:incoming>$(xml_escape "$fid")</bpmn:incoming>" >> "$BARE"
    done < <(incoming_for "$nid")
    while IFS= read -r fid; do
      [ -z "$fid" ] && continue
      echo "      <bpmn:outgoing>$(xml_escape "$fid")</bpmn:outgoing>" >> "$BARE"
    done < <(outgoing_for "$nid")
    echo "    </${elem}>" >> "$BARE"
  done <<< "$NODES"

  # Sequence flows
  for f in ${SEQ_FLOWS[@]+"${SEQ_FLOWS[@]}"}; do
    IFS='|' read -r fid ffrom fto flabel <<< "$f"
    fid_esc=$(xml_escape "$fid")
    ffrom_esc=$(xml_escape "$ffrom")
    fto_esc=$(xml_escape "$fto")
    # Only gateway branches carry sequence-flow labels.
    source_type=$(awk -F'\t' -v id="$ffrom" '$1=="node" && $2==id {print $3}' <<< "$NODES")
    case "$source_type" in
      gateway|gateway-exclusive|gateway-parallel)
        if [ "$(outgoing_for "$ffrom" | wc -l)" -le 1 ]; then
          flabel=""
        fi
        ;;
      *) flabel="" ;;
    esac
    flabel_esc=$(xml_escape "$flabel")
    if [ -n "$flabel" ]; then
      echo "    <bpmn:sequenceFlow id=\"${fid_esc}\" sourceRef=\"${ffrom_esc}\" targetRef=\"${fto_esc}\" name=\"${flabel_esc}\"/>" >> "$BARE"
    else
      echo "    <bpmn:sequenceFlow id=\"${fid_esc}\" sourceRef=\"${ffrom_esc}\" targetRef=\"${fto_esc}\"/>" >> "$BARE"
    fi
  done

  echo '  </bpmn:process>' >> "$BARE"

  # Keep the participant and all message flows in one collaboration.
  if [ -n "$LANES" ] || [ -n "${MSG_FLOWS[*]:-}" ]; then
    echo "  <bpmn:collaboration id=\"Collaboration_${slug_esc}\">" >> "$BARE"
    echo "    <bpmn:participant id=\"Participant_${slug_esc}\" name=\"${slug_esc}\" processRef=\"Process_${slug_esc}\"/>" >> "$BARE"
    for f in ${MSG_FLOWS[@]+"${MSG_FLOWS[@]}"}; do
      IFS='|' read -r fid ffrom fto flabel <<< "$f"
      fid_esc=$(xml_escape "$fid")
      ffrom_esc=$(xml_escape "$ffrom")
      fto_esc=$(xml_escape "$fto")
      flabel_esc=$(xml_escape "$flabel")
      if [ -n "$flabel" ]; then
        echo "    <bpmn:messageFlow id=\"${fid_esc}\" sourceRef=\"${ffrom_esc}\" targetRef=\"${fto_esc}\" name=\"${flabel_esc}\"/>" >> "$BARE"
      else
        echo "    <bpmn:messageFlow id=\"${fid_esc}\" sourceRef=\"${ffrom_esc}\" targetRef=\"${fto_esc}\"/>" >> "$BARE"
      fi
    done
    echo '  </bpmn:collaboration>' >> "$BARE"
  fi

  # Trailer — no <bpmndi> yet; auto-layout pass adds it.
  echo '</bpmn:definitions>' >> "$BARE"
}

emit_bare_bpmn

# ---------------------------------------------------------------------------
# Grid layout pass (AgDR-0248). Needs Python 3.9 or later. Without it, warn
# and emit bare BPMN, as the earlier Node fallback did. --skip-layout needs
# no Python. A layout error on an invalid model still exits non-zero.
# ---------------------------------------------------------------------------
LAYOUT_OUT="$TMP/layout.bpmn"

if [ "$SKIP_LAYOUT" -eq 1 ]; then
  cp "$BARE" "$LAYOUT_OUT"
  echo "generate-bpmn.sh: --skip-layout set, emitting bare BPMN (no <bpmndi>)" >&2
elif ! command -v python3 >/dev/null 2>&1 \
  || ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; then
  cp "$BARE" "$LAYOUT_OUT"
  echo "generate-bpmn.sh: WARNING — python3 3.9 or later not found; emitting bare BPMN (no <bpmndi>)" >&2
else
  python3 "$(dirname "$0")/layout-bpmn.py" "$BARE" "$LAYOUT_OUT"
fi

# ---------------------------------------------------------------------------
# Write the output. Create parent dir if needed.
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$OUTPUT")"
cp "$LAYOUT_OUT" "$OUTPUT"

# Optional xmllint sanity check.
if command -v xmllint >/dev/null 2>&1; then
  if ! xmllint --noout "$OUTPUT" 2>"$TMP/xmllint.err"; then
    echo "generate-bpmn.sh: WARNING — emitted file failed xmllint:" >&2
    cat "$TMP/xmllint.err" >&2
    exit 1
  fi
fi

echo "generate-bpmn.sh: wrote $OUTPUT ($(wc -c < "$OUTPUT" | tr -d ' ') bytes)"
exit 0
