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

echo
echo "eval-agents smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
