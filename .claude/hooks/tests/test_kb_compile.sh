#!/bin/bash
# Tests for bin/kb-compile.
set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
COMPILE="$REPO_ROOT/bin/kb-compile"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1 — $2"; }

kb_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

tree_hashes() {
  local d=$1
  (cd "$d" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(kb_hash "$f")" "$f"
  done)
}

FX=$(mktemp -d)
trap 'rm -rf "$FX"' EXIT

git -C "$FX" init -q
mkdir -p "$FX/handbooks/architecture" "$FX/.claude/rules" "$FX/docs/agdr" "$FX/docs/orbit/plans" "$FX/rule-tests/handbooks/architecture"

# Unmigrated handbook (defaults in memory).
cat > "$FX/handbooks/architecture/plain.md" <<'MD'
# Handbook: Plain

Body.
MD

# Migrated-style handbook with FM.
cat > "$FX/handbooks/architecture/full.md" <<'MD'
---
owner: Carol
verified_by: Carol
verified_on: 2024-02-01
stale_after: 2024-07-30
sources: []
version: 2
status: active
---

# Handbook: Full

Body.
MD

cat > "$FX/.claude/rules/example.md" <<'MD'
# Rule: Example

Do the thing.
MD

cat > "$FX/docs/agdr/AgDR-0001-demo.md" <<'MD'
---
id: AgDR-0001
agent: platform-engineer
status: executed
---

# AgDR-0001 — Demo

Decision text.
MD

cat > "$FX/docs/orbit/plans/plan-demo.json" <<'JSON'
{
  "specVersion": "0.1",
  "id": "plan-demo"
}
JSON

# Good rule-test
cat > "$FX/rule-tests/handbooks/architecture/plain.md" <<'MD'
---
rule: handbooks/architecture/plain
---

## Must flag

```text
bad snippet
```
MD

# Bad rule-test (missing Must flag fence)
mkdir -p "$FX/rule-tests/broken"
cat > "$FX/rule-tests/broken/bad.md" <<'MD'
---
rule: handbooks/architecture/plain
---

## Must flag

no fence here
MD

git -C "$FX" add .
GIT_AUTHOR_DATE='2024-01-15T12:00:00' GIT_COMMITTER_DATE='2024-01-15T12:00:00' \
  git -C "$FX" -c user.name='Carol' -c user.email='c@example.com' commit -q -m 'seed'

# Hash sources before compile
src_before=$(mktemp)
find "$FX/handbooks" "$FX/.claude/rules" "$FX/docs" "$FX/rule-tests" -type f | LC_ALL=C sort | while IFS= read -r f; do
  printf '%s  %s\n' "$(kb_hash "$f")" "${f#"$FX"/}"
done > "$src_before"

warn=$("$COMPILE" --root "$FX" --out "$FX/kb" 2>&1)
echo "$warn" | grep -q 'warning: rule-test' && pass "bad rule-test warns" || fail "bad rule-test warns" "$warn"

# Sources untouched
src_after=$(mktemp)
find "$FX/handbooks" "$FX/.claude/rules" "$FX/docs" "$FX/rule-tests" -type f | LC_ALL=C sort | while IFS= read -r f; do
  printf '%s  %s\n' "$(kb_hash "$f")" "${f#"$FX"/}"
done > "$src_after"
cmp -s "$src_before" "$src_after" && pass "sources untouched" || fail "sources untouched" ""
rm -f "$src_before" "$src_after"

entry="$FX/kb/entries/handbooks__architecture__plain.md.json"
[ -f "$entry" ] && pass "plain entry exists" || fail "plain entry exists" ""

# Fields + hash
want_hash=$(kb_hash "$FX/handbooks/architecture/plain.md")
got_hash=$(jq -r '.hash' "$entry")
[ "$got_hash" = "$want_hash" ] && pass "sha256 matches source" || fail "sha256 matches source" "$got_hash vs $want_hash"

for field in id kind path title owner verified_by verified_on stale_after sources version status hash; do
  jq -e --arg f "$field" 'has($f)' "$entry" >/dev/null && pass "field $field" || fail "field $field" ""
done

jq -e '.owner == "Carol"' "$entry" >/dev/null && pass "unmigrated owner default" || fail "unmigrated owner default" "$(cat "$entry")"
jq -e '.verified_on == "2024-01-15"' "$entry" >/dev/null && pass "unmigrated verified_on" || fail "unmigrated verified_on" ""
jq -e '.stale_after == "2024-07-13"' "$entry" >/dev/null && pass "unmigrated stale_after" || fail "unmigrated stale_after" "$(jq -r .stale_after "$entry")"

agdr="$FX/kb/entries/docs__agdr__AgDR-0001-demo.md.json"
jq -e '.stale_after == null' "$agdr" >/dev/null && pass "agdr stale_after null" || fail "agdr stale_after null" "$(cat "$agdr")"
jq -e '.owner == "platform-engineer"' "$agdr" >/dev/null && pass "agdr owner from agent" || fail "agdr owner from agent" "$(cat "$agdr")"

orbit="$FX/kb/entries/docs__orbit__plans__plan-demo.json.json"
jq -e '.stale_after == null' "$orbit" >/dev/null && pass "orbit stale_after null" || fail "orbit stale_after null" "$(cat "$orbit")"

# Manifest sorted by id
ids=$(jq -r '.entries[].id' "$FX/kb/manifest.json")
sorted=$(printf '%s\n' "$ids" | LC_ALL=C sort)
[ "$ids" = "$sorted" ] && pass "manifest sorted by id" || fail "manifest sorted by id" "$ids"

# Second run byte-identical
h1=$(tree_hashes "$FX/kb")
"$COMPILE" --root "$FX" --out "$FX/kb" >/dev/null 2>&1
h2=$(tree_hashes "$FX/kb")
[ "$h1" = "$h2" ] && pass "second run byte-identical" || fail "second run byte-identical" ""

# Removed source removes JSON
rm -f "$FX/handbooks/architecture/full.md"
"$COMPILE" --root "$FX" --out "$FX/kb" >/dev/null 2>&1
if [ -f "$FX/kb/entries/handbooks__architecture__full.md.json" ]; then
  fail "removed source drops JSON" "still present"
else
  pass "removed source drops JSON"
fi

grep -q '^/kb/' "$REPO_ROOT/.gitignore" && pass "gitignore has /kb/" || fail "gitignore has /kb/" ""

echo
echo "Total: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
