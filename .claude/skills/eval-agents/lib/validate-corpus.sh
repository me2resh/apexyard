#!/usr/bin/env bash
# validate-corpus.sh — schema-check a docs/eval-agents/corpus/<agent>.json file.
#
# Usage: validate-corpus.sh <agent> <corpus-path>
#
# Checks structure and required fields only — NOT ground-truth accuracy.
# Exit 0 + prints entry count on success. Exit 1 on any schema violation,
# with every violation listed (not just the first) so a corpus author fixes
# everything in one pass.
#
# No PyYAML / jq-only assumptions: corpus files are plain JSON, validated
# with python3's stdlib json module (always available, no extra install).

set -euo pipefail

AGENT="${1:-}"
CORPUS_PATH="${2:-}"

if [ -z "$AGENT" ] || [ -z "$CORPUS_PATH" ]; then
  echo "usage: validate-corpus.sh <agent> <corpus-path>" >&2
  exit 2
fi

if [ ! -f "$CORPUS_PATH" ]; then
  echo "✗ corpus file not found: $CORPUS_PATH" >&2
  exit 1
fi

python3 - "$AGENT" "$CORPUS_PATH" <<'PYEOF'
import json, sys

agent, path = sys.argv[1], sys.argv[2]
errors = []

try:
    with open(path) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f"✗ {path}: not valid JSON — {e}", file=sys.stderr)
    sys.exit(1)

VALID_AGENTS = {"rex", "hakim", "tariq"}
VALID_SEVERITY = {"BLOCKING", "HIGH", "MEDIUM", "LOW", "NIT"}
VALID_VERDICT = {"APPROVED", "CHANGES REQUESTED", "COMMENT"}
VALID_ORACLE_SOURCE = {"independent_review", "confirmed_fix", "no_contradiction", "human"}

if not isinstance(data, dict):
    errors.append("top level must be a JSON object")
else:
    if data.get("agent") != agent:
        errors.append(f"'agent' field is {data.get('agent')!r}, expected {agent!r} (must match the --agent argument / filename stem)")
    if data.get("agent") not in VALID_AGENTS:
        errors.append(f"'agent' must be one of {sorted(VALID_AGENTS)}")
    if data.get("schema_version") != 1:
        errors.append(f"'schema_version' is {data.get('schema_version')!r}, this validator only understands 1")

    entries = data.get("entries")
    if not isinstance(entries, list):
        errors.append("'entries' must be an array")
        entries = []

    seen_ids = set()
    for i, e in enumerate(entries):
        where = f"entries[{i}]"
        if not isinstance(e, dict):
            errors.append(f"{where}: must be an object")
            continue

        eid = e.get("id")
        if not eid:
            errors.append(f"{where}: missing 'id'")
        elif eid in seen_ids:
            errors.append(f"{where}: duplicate id {eid!r}")
        else:
            seen_ids.add(eid)
        where = f"entry {eid or i}"

        for field in ("pr", "repo", "commit", "diff_range"):
            if field not in e:
                errors.append(f"{where}: missing '{field}'")

        oracle = e.get("oracle")
        if not isinstance(oracle, dict):
            errors.append(f"{where}: missing/invalid 'oracle' object")
        else:
            if oracle.get("source") not in VALID_ORACLE_SOURCE:
                errors.append(f"{where}: oracle.source {oracle.get('source')!r} not in {sorted(VALID_ORACLE_SOURCE)}")
            if not oracle.get("established_by"):
                errors.append(f"{where}: oracle.established_by is required (how was this ground truth established?)")

        defects = e.get("ground_truth_defects")
        if not isinstance(defects, list):
            errors.append(f"{where}: 'ground_truth_defects' must be an array (use [] for a clean diff)")
        else:
            for j, d in enumerate(defects):
                dwhere = f"{where} defect[{j}]"
                if not isinstance(d, dict):
                    errors.append(f"{dwhere}: must be an object")
                    continue
                for field in ("id", "description", "severity", "location"):
                    if not d.get(field):
                        errors.append(f"{dwhere}: missing '{field}'")
                if "severity" in d and d["severity"] not in VALID_SEVERITY:
                    errors.append(f"{dwhere}: severity {d['severity']!r} not in {sorted(VALID_SEVERITY)}")

        rv = e.get("recorded_verdict")
        if not isinstance(rv, dict):
            errors.append(f"{where}: missing/invalid 'recorded_verdict' object")
        else:
            if rv.get("verdict") not in VALID_VERDICT:
                errors.append(f"{where}: recorded_verdict.verdict {rv.get('verdict')!r} not in {sorted(VALID_VERDICT)}")
            if not isinstance(rv.get("was_justified"), bool):
                errors.append(f"{where}: recorded_verdict.was_justified must be a boolean")

if errors:
    print(f"✗ {path}: {len(errors)} schema violation(s):", file=sys.stderr)
    for err in errors:
        print(f"  - {err}", file=sys.stderr)
    sys.exit(1)

n = len(data.get("entries", []))
blocking_defects = sum(
    1 for e in data.get("entries", []) for d in e.get("ground_truth_defects", [])
    if d.get("severity") in ("BLOCKING", "HIGH")
)
misses = sum(1 for e in data.get("entries", []) if e.get("recorded_verdict", {}).get("was_justified") is False)
print(f"✓ {path}: schema valid — {n} entries, {blocking_defects} BLOCKING/HIGH ground-truth defects, {misses} recorded MISS(es)")
PYEOF
