#!/usr/bin/env bash
# Read newline-separated changed paths from stdin or a file. Print ALL or tests.
# --docs-only exits successfully only when every path is documentation.
set -euo pipefail
cd "$(dirname "$0")/.."
mode=select
if [ "${1-}" = --docs-only ]; then mode=docs; shift; fi
input=${1:-/dev/stdin}
paths=$(cat "$input")
if [ "$mode" = docs ]; then
  [ -n "$paths" ] || exit 1
  while IFS= read -r path; do
    case "$path" in
      docs/*) ;;
      .claude/*) exit 1 ;;
      *.md) ;;
      *) exit 1 ;;
    esac
  done <<< "$paths"
  exit 0
fi
tests=$(find .claude/hooks/tests .claude/agents/tests .claude/skills -type f \( -name 'test_*.sh' -o -name '*.test.sh' \) | LC_ALL=C sort)
selected=$(mktemp)
trap 'rm -f "$selected"' EXIT
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    .claude/hooks/_lib-*.sh|.claude/settings.json|.claude/project-config.defaults.json|bin/run-hook-tests.sh|bin/select-affected-tests.sh|.github/workflows/tests.yml|.githooks/*)
      echo ALL; exit 0 ;;
  esac
  if printf '%s\n' "$tests" | grep -Fxq "$path"; then
    printf '%s\n' "$path" >> "$selected"
    continue
  fi
  case "$path" in
    # A shared test helper or fixture can change any suite.
    .claude/hooks/tests/*|.claude/agents/tests/*) echo ALL; exit 0 ;;
    .claude/hooks/*) needle=${path##*/} ;;
    # Any other file runs the tests that name its full path.
    *) needle=$path ;;
  esac
  while IFS= read -r test; do
    if grep -Fq -- "$needle" "$test"; then printf '%s\n' "$test" >> "$selected"; fi
  done <<< "$tests"
done <<< "$paths"
LC_ALL=C sort -u "$selected"
