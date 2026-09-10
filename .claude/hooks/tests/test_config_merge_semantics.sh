#!/bin/bash
# Regression test for project-config merge semantics (#1207).

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

mkdir -p "$SB/.claude/hooks"
touch "$SB/.apexyard-fork"
cp "$SRC_ROOT/.claude/hooks/_lib-read-config.sh" "$SB/.claude/hooks/"
cp "$SRC_ROOT/.claude/hooks/_lib-ops-root.sh" "$SB/.claude/hooks/"
cat > "$SB/.claude/project-config.defaults.json" <<'JSON'
{
  "portfolio": {"stale_days": 30, "registry": "default"},
  "ticket": {"bootstrap_skills": ["setup", "handover"]}
}
JSON
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "portfolio": {"registry": "custom"},
  "ticket": {"bootstrap_skills": ["custom-bootstrap"]}
}
JSON

merged=$(cd "$SB" && APEXYARD_DISABLE_RESOLUTION_CACHE=1 bash -c '
  . .claude/hooks/_lib-read-config.sh
  config_get .
')

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "PASS [$label]"
  else
    echo "FAIL [$label]: want '$want', got '$got'" >&2
    return 1
  fi
}

assert_eq "object members are retained recursively" "30" \
  "$(printf '%s' "$merged" | jq -r '.portfolio.stale_days')"
assert_eq "object override wins scalar conflict" "custom" \
  "$(printf '%s' "$merged" | jq -r '.portfolio.registry')"
assert_eq "array override replaces inherited array" "custom-bootstrap" \
  "$(printf '%s' "$merged" | jq -r '.ticket.bootstrap_skills | join(" ")')"

echo "===== test_config_merge_semantics.sh ====="
echo "Passed: 3"
echo "Failed: 0"
