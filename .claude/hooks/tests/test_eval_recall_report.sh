#!/usr/bin/env bash
# Test the offline review report and labeled-subset recall for GH-2096.
set -euo pipefail

# Isolate from live session pins and caches.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$ROOT/.claude/skills/eval-agents/lib"
FIXTURE="$ROOT/.claude/skills/eval-agents/tests/fixtures/recall-report"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/eval-recall-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
python3 "$LIB/blocking_rounds.py" --repo me2resh/apexyard --days 30 \
  --input "$FIXTURE/rounds.json" --as-of 2026-11-22T00:00:00Z >"$tmp/rounds"
printf 'PR  Blocking rounds  Reverted\n#7  5  yes\n#70  0  no\n' >"$tmp/expected"
diff -u "$tmp/expected" "$tmp/rounds"
echo 'PASS: blocking submissions, post-merge exclusion, window, and named revert'
python3 "$LIB/blocking_rounds.py" --repo me2resh/apexyard --days 1 \
  --input "$FIXTURE/rounds.json" --as-of 2026-11-22T00:00:00Z >"$tmp/short"
printf 'PR  Blocking rounds  Reverted\n' >"$tmp/empty"
diff -u "$tmp/empty" "$tmp/short"
echo 'PASS: custom day count changes the merge window' 
for agent in rex tariq; do
  python3 "$LIB/subset_recall.py" --corpus "$FIXTURE/$agent.json" \
    --results "$FIXTURE/$agent-results.json" >"$tmp/recall"
  grep -qF "21 November miss recall — $agent: 50% (1/2)" "$tmp/recall"
  grep -qF 'Clean-control false alarms: 1 (1 controls scored)' "$tmp/recall"
  echo "PASS: $agent subset recall and control false alarms"
done
python3 "$LIB/subset_recall.py" --corpus "$FIXTURE/rex.json" \
  --results "$FIXTURE/discarded.json" >"$tmp/discarded"
grep -qF 'n/a (0/0)' "$tmp/discarded"
grep -qF 'Pending or discarded cases: 4' "$tmp/discarded"
echo 'PASS: pending and contaminated cases do not enter recall'

python3 - "$ROOT" <<'PYTEST'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / ".claude/skills/eval-agents/lib"))
from subset_recall import report

corpus = json.loads((root / "docs/eval-agents/corpus/rex.json").read_text())
controls = [entry for entry in corpus["entries"]
            if entry.get("control_for") == "20261121-filter"]
assert controls, "The filter miss must have a linked control"
results = [{"id": entry["id"], "status": "SCORED", "caught_defects": [],
            "false_alarms": 1} for entry in controls]
expected = f"Clean-control false alarms: {len(controls)} ({len(controls)} controls scored)"
assert expected in report(corpus, results)
print("PASS: linked corpus controls enter scoring")
PYTEST
