#!/bin/bash
# Required awk dependencies must fail closed before scanning merge/write text.
set -u
# Isolate from live session pins and caches.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/hooks" "$TMP/src" "$TMP/db/migrations"
cp "$HOOK_DIR/"*.sh "$TMP/.claude/hooks/"
cp "$HOOK_DIR/../project-config.defaults.json" "$TMP/.claude/"
rm "$TMP/.claude/hooks/_lib-awk-fallback.sh"
touch "$TMP/onboarding.yaml" "$TMP/.apexyard-fork"
printf 'version: 1\nprojects: []\n' > "$TMP/apexyard.projects.yaml"
(cd "$TMP" && git init -q)
PASS=0
FAIL=0
for hook in block-unreviewed-merge block-merge-on-red-ci require-architecture-review require-design-review-for-ui require-active-ticket require-migration-ticket validate-pr-create dispatch-bash; do
  case "$hook" in
    require-active-ticket) cmd='echo x > src/a.ts' ;;
    require-migration-ticket) cmd='echo x > db/migrations/001.sql' ;;
    validate-pr-create) cmd='gh pr create --title invalid --body invalid' ;;
    *) cmd='gh pr merge 7 --squash' ;;
  esac
  input=$(jq -nc --arg c "$cmd" --arg cwd "$TMP" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}')
  (cd "$TMP" && printf '%s' "$input" | APEXYARD_OPS_DISABLE_PIN=1 /bin/bash ".claude/hooks/$hook.sh") > "$TMP/out" 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "PASS: $hook missing awk library"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $hook missing awk library: expected 2, got $rc"
    FAIL=$((FAIL + 1))
  fi
done
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
