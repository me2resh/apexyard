#!/usr/bin/env bash
# Test the offline review report and labeled-subset recall for GH-2096.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$ROOT/.claude/skills/eval-agents/lib"
FIXTURE="$ROOT/.claude/skills/eval-agents/tests/fixtures/recall-report"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/eval-recall-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
python3 "$LIB/blocking_rounds.py" --repo me2resh/apexyard --days 30 \
  --input "$FIXTURE/rounds.json" --as-of 2026-11-22T00:00:00Z >"$tmp/rounds"
printf 'PR  Blocking rounds  Reverted\n#7  2  yes\n#70  0  no\n' >"$tmp/expected"
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
