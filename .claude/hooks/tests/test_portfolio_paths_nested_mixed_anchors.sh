#!/bin/bash
# Regression test for split-portfolio v2 nested under an enclosing Git repo.
# A sibling portfolio directory has the legacy v1 anchor pair. The explicit
# v2 fork marker must still select the fork for relative portfolio paths.

set -eu

SRC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OPS_LIB="$SRC_ROOT/hooks/_lib-ops-root.sh"
CONFIG_LIB="$SRC_ROOT/hooks/_lib-read-config.sh"
PORTFOLIO_LIB="$SRC_ROOT/hooks/_lib-portfolio-paths.sh"
DEFAULTS="$SRC_ROOT/project-config.defaults.json"

outer=$(mktemp -d)
fork="$outer/fork"
portfolio="$outer/portfolio"
mkdir -p "$fork/.claude/hooks" "$portfolio"
git init -q "$outer"

: > "$fork/.apexyard-fork"
: > "$portfolio/onboarding.yaml"
cat > "$portfolio/apexyard.projects.yaml" <<'YAML'
version: 1
projects: []
YAML

cp "$OPS_LIB" "$fork/.claude/hooks/_lib-ops-root.sh"
cp "$CONFIG_LIB" "$fork/.claude/hooks/_lib-read-config.sh"
cp "$PORTFOLIO_LIB" "$fork/.claude/hooks/_lib-portfolio-paths.sh"
cp "$DEFAULTS" "$fork/.claude/project-config.defaults.json"
cat > "$fork/.claude/project-config.json" <<'JSON'
{
  "portfolio": {
    "registry": "../portfolio/apexyard.projects.yaml"
  }
}
JSON

expected="$(cd "$portfolio" && pwd -P)/apexyard.projects.yaml"
actual=$(
  cd "$fork"
  # shellcheck source=/dev/null
  . .claude/hooks/_lib-read-config.sh
  # shellcheck source=/dev/null
  . .claude/hooks/_lib-portfolio-paths.sh
  portfolio_registry
)

if [ "$actual" = "$expected" ]; then
  echo "PASS: nested mixed anchors resolve portfolio registry to sibling"
  exit 0
fi

echo "FAIL: expected '$expected', got '$actual'" >&2
exit 1
