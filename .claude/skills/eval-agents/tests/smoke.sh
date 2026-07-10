#!/usr/bin/env bash
# smoke.sh — schema-validator smoke tests for /eval-agents.
# Run: .claude/skills/eval-agents/tests/smoke.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/../lib/validate-corpus.sh"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

pass=0
fail=0

check() {
  local desc="$1" expect_rc="$2"; shift 2
  "$@" >/tmp/eval-agents-smoke.out 2>&1
  local rc=$?
  if [ "$rc" -eq "$expect_rc" ]; then
    echo "✓ $desc"
    pass=$((pass + 1))
  else
    echo "✗ $desc (expected exit $expect_rc, got $rc)"
    cat /tmp/eval-agents-smoke.out
    fail=$((fail + 1))
  fi
}

# 1. Seeded starter corpora validate clean.
check "rex.json validates" 0 bash "$VALIDATE" rex "$ROOT/docs/eval-agents/corpus/rex.json"
check "hakim.json validates" 0 bash "$VALIDATE" hakim "$ROOT/docs/eval-agents/corpus/hakim.json"

# 2. Missing file is a clean failure, not a crash.
check "missing corpus file fails cleanly" 1 bash "$VALIDATE" rex "$ROOT/docs/eval-agents/corpus/does-not-exist.json"

# 3. Wrong --agent vs corpus 'agent' field is caught.
check "agent/filename mismatch is caught" 1 bash "$VALIDATE" hakim "$ROOT/docs/eval-agents/corpus/rex.json"

# 4. Malformed JSON is caught, not a python traceback.
tmpbad="$(mktemp /tmp/eval-agents-bad-XXXX.json)"
echo '{not valid json' > "$tmpbad"
check "malformed JSON is caught" 1 bash "$VALIDATE" rex "$tmpbad"
rm -f "$tmpbad"

# 5. Missing required field is caught.
tmpbad2="$(mktemp /tmp/eval-agents-bad2-XXXX.json)"
cat > "$tmpbad2" <<'EOF'
{"agent": "rex", "schema_version": 1, "entries": [{"id": "x", "pr": 1}]}
EOF
check "missing required fields are caught" 1 bash "$VALIDATE" rex "$tmpbad2"
rm -f "$tmpbad2"

# 6-7. Defect-in-diff guard (me2resh/apexyard#861 — the rex-770 mislabel
# class): a ground_truth_defects[].location must appear in diff_range's
# changed-file set. Built on a throwaway fixture git repo (not this repo's
# own history) so the test is deterministic regardless of checkout depth —
# it doesn't depend on any real apexyard commit being locally fetchable.
fixture="$(mktemp -d)"
git -C "$fixture" init -q
git -C "$fixture" config user.email "test@example.com"
git -C "$fixture" config user.name "Eval Agents Smoke Test"
printf 'one\n' > "$fixture/present.sh"
printf 'two\n' > "$fixture/absent.sh"
git -C "$fixture" add present.sh absent.sh
git -C "$fixture" commit -q -m "base"
printf 'one changed\n' > "$fixture/present.sh"
git -C "$fixture" add present.sh
git -C "$fixture" commit -q -m "touch present.sh only"
FIXTURE_HEAD="$(git -C "$fixture" rev-parse HEAD)"

fixture_corpus() { # <location>
  cat <<EOF
{"agent":"rex","schema_version":1,"entries":[{"id":"fixture-1","pr":1,"repo":"x/y","commit":"$FIXTURE_HEAD","diff_range":"$FIXTURE_HEAD~1..$FIXTURE_HEAD","oracle":{"source":"human","established_by":"fixture"},"ground_truth_defects":[{"id":"D1","description":"fixture defect","severity":"LOW","location":"$1"}],"recorded_verdict":{"verdict":"CHANGES REQUESTED","was_justified":true}}]}
EOF
}

fixture_corpus "present.sh" > "$fixture/good.json"
check "defect-in-diff guard: location in diff passes" 0 bash "$VALIDATE" rex "$fixture/good.json"

fixture_corpus "absent.sh" > "$fixture/bad.json"
check "defect-in-diff guard: location NOT in diff fails (rex-770-class mislabel)" 1 bash "$VALIDATE" rex "$fixture/bad.json"

rm -rf "$fixture"

echo
echo "eval-agents smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
