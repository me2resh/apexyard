#!/usr/bin/env bash
# Regression test for me2resh/apexyard#1300.
#
# The markdownlint command must cap each xargs invocation. Without the cap,
# Windows routes npx through cmd.exe and rejects large tracked-file lists.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$ROOT/bin/run-pre-push-checks.sh"
EXAMPLE="$ROOT/.claude/project-config.example.json"
PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  echo "PASS [$1]"
}

bad() {
  FAIL=$((FAIL + 1))
  echo "FAIL [$1] $2"
}

if grep -Fq 'xargs -0 -s 7000 npx --yes markdownlint-cli2' "$SCRIPT"; then
  ok "runner-batches-markdownlint"
else
  bad "runner-batches-markdownlint" "run-pre-push-checks.sh has no Windows-safe xargs size cap"
fi

if jq -e '.pre_push.commands[] | select(.name == "markdownlint") | (.run | contains("xargs -0 -s 7000 npx --yes markdownlint-cli2"))' "$EXAMPLE" >/dev/null 2>&1; then
  ok "template-batches-markdownlint"
else
  bad "template-batches-markdownlint" "project-config.example.json has no Windows-safe xargs size cap"
fi

if ! grep -Eq 'xargs -0[[:space:]]+npx[[:space:]]+--yes[[:space:]]+markdownlint-cli2' "$SCRIPT" "$EXAMPLE"; then
  ok "no-unbounded-markdownlint"
else
  bad "no-unbounded-markdownlint" "an unbounded markdownlint xargs invocation remains"
fi

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
