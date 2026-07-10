#!/usr/bin/env bash
# validate-corpus.sh — schema-check a docs/eval-agents/corpus/<agent>.json file.
#
# Usage: validate-corpus.sh <agent> <corpus-path>
#
# Checks structure and required fields, PLUS one ground-truth-adjacent check:
# every ground_truth_defects[].location must appear in the entry's diff_range
# changed-file set (git-resolved). This is NOT re-deriving ground truth (still
# forbidden — see SKILL.md rule 1) — it's a structural guard against the
# rex-770 class of mislabel (me2resh/apexyard#861), where the corpus pointed
# at a diff that never contained the defect it claimed to carry, making the
# entry unscoreable. A location the validator can't resolve locally (commit
# not fetched) is a best-effort SKIP with a warning, not a hard failure — CI
# checkouts don't always have every historical commit's full ancestry.
#
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

# Repo root for git diff resolution — derive from the corpus file's own
# location so this works regardless of the caller's cwd.
REPO_ROOT="$(git -C "$(dirname "$CORPUS_PATH")" rev-parse --show-toplevel 2>/dev/null || pwd)"

python3 - "$AGENT" "$CORPUS_PATH" "$REPO_ROOT" <<'PYEOF'
import json, subprocess, sys

agent, path, repo_root = sys.argv[1], sys.argv[2], sys.argv[3]
errors = []
unresolvable = 0


def changed_files(diff_range):
    """git diff --name-only over diff_range, resolved against repo_root.
    Returns a set of changed paths, or None if the range can't be resolved
    locally (unfetched commit, malformed range, etc.) — caller treats None
    as best-effort SKIP, not a failure."""
    try:
        proc = subprocess.run(
            ["git", "-C", repo_root, "diff", "--name-only", diff_range],
            capture_output=True, text=True, timeout=15,
        )
    except Exception:
        return None
    if proc.returncode != 0:
        return None
    return {line.strip() for line in proc.stdout.splitlines() if line.strip()}


def location_file(location):
    """Extract the leading file path from a location string that may carry
    a trailing ':line' or ' (note)' annotation (per SCHEMA.md: 'File path
    (± line)')."""
    token = location.split()[0] if location else ""
    return token.split(":")[0]

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

            # Defect-in-diff guard (me2resh/apexyard#861): every defect's
            # location must actually appear in the reviewed diff — otherwise
            # the agent-under-test could never have caught it, and scoring
            # the entry is meaningless (the rex-770 corpus mislabel).
            diff_range = e.get("diff_range")
            valid_locations = [
                (j, d.get("location")) for j, d in enumerate(defects)
                if isinstance(d, dict) and d.get("location")
            ]
            if valid_locations and isinstance(diff_range, str) and diff_range:
                files = changed_files(diff_range)
                if files is None:
                    unresolvable += 1
                    print(
                        f"⚠ {where}: diff_range {diff_range!r} not resolvable locally "
                        f"(commit not fetched, or malformed range) — skipping "
                        f"defect-in-diff check for this entry",
                        file=sys.stderr,
                    )
                else:
                    for j, loc in valid_locations:
                        lf = location_file(loc)
                        if lf not in files and not any(lf in f or f in lf for f in files):
                            errors.append(
                                f"{where} defect[{j}]: location {loc!r} does not appear in "
                                f"diff_range {diff_range!r}'s changed files "
                                f"({sorted(files) or '[]'}) — the ground-truth defect must "
                                f"live inside the reviewed diff, or the entry is unscoreable "
                                f"(the rex-770 class of mislabel, me2resh/apexyard#861)"
                            )

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
skip_note = f", {unresolvable} defect-in-diff check(s) skipped (unresolvable locally)" if unresolvable else ""
print(f"✓ {path}: schema valid — {n} entries, {blocking_defects} BLOCKING/HIGH ground-truth defects, {misses} recorded MISS(es){skip_note}")
PYEOF
