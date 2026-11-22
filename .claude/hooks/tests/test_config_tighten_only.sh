#!/bin/bash
# Scoped regression for #2127. Exercise the actual gates with an offline forge.
set -uo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/hooks" "$TMP/bin"
cp "$ROOT"/.claude/hooks/_lib-*.sh "$TMP/.claude/hooks/"
cp "$ROOT"/.claude/hooks/require-{architecture-review,design-review-for-ui}.sh "$TMP/.claude/hooks/"
# Optional red-phase run uses the pre-layer readers without changing git state.
if [ "${1:-}" = --without-overlay ]; then
  for file in _lib-gate-mode.sh _lib-ui-paths.sh require-architecture-review.sh require-design-review-for-ui.sh; do
    git -C "$ROOT" show "HEAD:.claude/hooks/$file" > "$TMP/.claude/hooks/$file"
  done
fi
git -C "$TMP" init -q
printf '{}\n' > "$TMP/.claude/project-config.defaults.json"
: > "$TMP/.apexyard-fork"
cat > "$TMP/bin/gh" <<'MOCK'
#!/bin/bash
case "$*" in
  *api*pulls/77*changed_files*) printf '1\n' ;;
  *api*pulls/*/files*) printf '%s\n' "$TEST_FILES" ;;
  *'pr view'*baseRefName*) printf 'dev\n' ;;
  *contents/.claude/project-config.json*) cat "$TEST_BASE_CONFIG" ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" TEST_FILES TEST_BASE_CONFIG="$TMP/base.json"
pass=0 fail=0
check() {
  local label="$1" expected="$2" got="$3"
  if [ "$expected" = "$got" ]; then
    echo "PASS: $label"; pass=$((pass + 1))
  else
    echo "FAIL: $label (expected $expected, got $got)"; fail=$((fail + 1))
  fi
}
# Each case uses a permissive project value as the overlay comparison floor.
mkdir -p "$TMP/../$(basename "$TMP")-overlay/.claude"
OVERLAY="$(cd "$TMP/../$(basename "$TMP")-overlay" && pwd)"
trap 'rm -rf "$TMP" "$OVERLAY"' EXIT
run_gate() {
  local hook="$1" key="$2" project="$3" overlay="$4" file="$5" expected="$6" warnings="$7" base="${8:-0}" rc=0
  jq -nc --arg k "$key" --argjson v "$project" --arg registry "$OVERLAY/apexyard.projects.yaml" \
    '{($k):$v,portfolio:{registry:$registry}}' > "$TMP/.claude/project-config.json"
  if [ "$overlay" = absent ]; then
    rm -f "$OVERLAY/.claude/project-config.json"
  else
    jq -nc --arg k "$key" --argjson v "$overlay" '{($k):$v}' > "$OVERLAY/.claude/project-config.json"
  fi
  TEST_FILES="$file"
  if [ "$base" = 1 ]; then
    cp "$TMP/.claude/project-config.json" "$TEST_BASE_CONFIG"
    jq 'if $head == null then del(.[$k]) else .[$k] = $head end' --arg k "$key" --argjson head "${9:-null}" "$TEST_BASE_CONFIG" > "$TMP/.claude/project-config.json"
    TEST_FILES="$TEST_FILES"$'\n.claude/project-config.json'
  fi
  (cd "$TMP" || exit; bash ".claude/hooks/$hook" <<<'{"tool_input":{"command":"gh pr merge 77 --repo o/r"}}') > "$TMP/out" 2> "$TMP/err" || rc=$?
  check "$key result (overlay=$overlay base=$base)" "$expected" "$rc"
  check "$key overlay diagnostic count" "$warnings" "$(grep -c "^WARN:.*$key.*$OVERLAY/.claude/project-config.json" "$TMP/err" || true)"
}
for base in 0 1; do
  for kind in design ui; do
    if [ "$kind" = design ]; then hook=require-architecture-review.sh; else hook=require-design-review-for-ui.sh; fi
    key="${kind}_paths"
    run_gate "$hook" "$key" '["^custom/"]' '[]' custom/artifact.custom 2 1 "$base"
    run_gate "$hook" "$key" '["^custom/"]' '["^custom/","^extra/"]' extra/artifact.custom 2 0 "$base"
    run_gate "$hook" "$key" '["^custom/"]' absent src/Button.tsx 0 0 "$base"
    key="${kind}_paths_exclude"
    if [ "$kind" = design ]; then file=docs/technical-design.md; else file=src/Button.tsx; fi
    run_gate "$hook" "$key" '["^exempt/"]' '["^exempt/",".*"]' "$file" 2 1 "$base"
    run_gate "$hook" "$key" '[".*"]' '[]' "$file" 2 0 "$base"
    run_gate "$hook" "$key" '[".*"]' absent "$file" 0 0 "$base"
  done
done
# Head additions must retain paths that the sibling overlay adds to the base list.
for kind in design ui; do
  if [ "$kind" = design ]; then hook=require-architecture-review.sh; else hook=require-design-review-for-ui.sh; fi
  run_gate "$hook" "${kind}_paths" '["^custom/"]' '["^custom/","^overlay/"]' \
    overlay/artifact.custom 2 0 1 '["^custom/","^head/"]'
done
# Exercise registered gate modes with the real config reader.
sed 's/# Opted-in gate names go here. No production gate is opted in yet./fixture-new) return 0 ;;/' \
  "$TMP/.claude/hooks/_lib-gate-mode.sh" > "$TMP/mode.sh"
mv "$TMP/mode.sh" "$TMP/.claude/hooks/_lib-gate-mode.sh"
mode_case() {
  local project="$1" overlay="$2" expected="$3" warnings="$4" result
  jq -nc --arg mode "$project" --arg registry "$OVERLAY/apexyard.projects.yaml" \
    '{gates:{"fixture-new":{mode:$mode}},portfolio:{registry:$registry}}' > "$TMP/.claude/project-config.json"
  if [ "$overlay" = absent ]; then rm -f "$OVERLAY/.claude/project-config.json"
  else jq -nc --arg mode "$overlay" '{gates:{"fixture-new":{mode:$mode}}}' > "$OVERLAY/.claude/project-config.json"; fi
  result=$(cd "$TMP" || exit; . .claude/hooks/_lib-gate-mode.sh; gate_mode_resolve fixture-new enforce 2> "$TMP/err")
  check "mode $project + $overlay" "$expected" "$result"
  check 'mode overlay diagnostic count' "$warnings" "$(grep -c "^WARN:.*gates.fixture-new.mode.*$OVERLAY/.claude/project-config.json" "$TMP/err" || true)"
}
mode_case observe off observe 1
mode_case off enforce enforce 0
mode_case off absent off 0
mode_case observe absent observe 0
echo "Results: PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
