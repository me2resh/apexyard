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

# #1367: the version must be pinned in BOTH places. An unpinned
# `npx --yes markdownlint-cli2` resolves to whatever is latest at that moment,
# so an upstream release can turn a green gate red with no local change.
# Anchored on the npx invocation so prose mentioning the tool doesn't match;
# fires when the package name there is NOT followed by `@<version>`.
if ! grep -Eq 'npx[[:space:]]+-(-yes|y)[[:space:]]+markdownlint-cli2[^@]' "$SCRIPT" "$EXAMPLE"; then
  ok "markdownlint-version-pinned"
else
  bad "markdownlint-version-pinned" "markdownlint-cli2 is invoked without an @version pin"
fi

# The two copies of the command must pin the SAME version. Asserting only that
# an `@` follows the package name lets them drift apart silently: the runner
# could say @0.99.0 while the example says @0.23.1 and every check still
# passes. Compare the extracted values, not the shape.
runner_pin=$(grep -oE 'markdownlint-cli2@[0-9]+\.[0-9]+\.[0-9]+' "$SCRIPT" | head -1 | cut -d@ -f2)
example_pin=$(grep -oE 'markdownlint-cli2@[0-9]+\.[0-9]+\.[0-9]+' "$EXAMPLE" | head -1 | cut -d@ -f2)
if [ -n "$runner_pin" ] && [ "$runner_pin" = "$example_pin" ]; then
  ok "markdownlint-pin-parity ($runner_pin)"
else
  bad "markdownlint-pin-parity" "runner pins '${runner_pin:-none}', example pins '${example_pin:-none}'"
fi

# The pin tracks the markdownlint-cli2 bundled by markdownlint-cli2-action.
# Dependabot bumps that action weekly against `dev`, and nothing else would
# notice: after a bump, CI runs a newer ruleset than the local gate, which is
# the reverse of the defect #1367 reports. The runner records the tag its pin
# belongs to; this compares it with the tag the workflow actually uses, so a
# Dependabot PR fails here until someone updates the pin deliberately.
WORKFLOW="$ROOT/.github/workflows/markdown-lint.yml"
recorded_tag=$(grep -oE 'MARKDOWNLINT_ACTION_TAG="[^"]+"' "$SCRIPT" | head -1 | cut -d'"' -f2)
workflow_tag=$(grep -E 'uses:.*markdownlint-cli2-action@' "$WORKFLOW" | grep -oE '#[[:space:]]*v[0-9]+\.[0-9]+\.[0-9]+' | grep -oE 'v[0-9.]+' | head -1)
if [ -z "$recorded_tag" ] || [ -z "$workflow_tag" ]; then
  bad "markdownlint-action-tag-parity" "could not read a tag (recorded='${recorded_tag:-none}', workflow='${workflow_tag:-none}')"
elif [ "$recorded_tag" = "$workflow_tag" ]; then
  ok "markdownlint-action-tag-parity ($recorded_tag)"
else
  bad "markdownlint-action-tag-parity" "runner records '$recorded_tag', workflow pins '$workflow_tag' — update the markdownlint-cli2 pin to the version that tag bundles"
fi

# CONTRIBUTING.md tells a contributor to run the same tool by hand, and says it
# is "the same pin as the gate". The two assertions above do not read that copy,
# so it can drift and the claim become false while every check passes.
CONTRIBUTING="$ROOT/CONTRIBUTING.md"
doc_pin=$(grep -oE 'markdownlint-cli2@[0-9]+\.[0-9]+\.[0-9]+' "$CONTRIBUTING" | head -1 | cut -d@ -f2)
if [ -n "$doc_pin" ] && [ "$doc_pin" = "$runner_pin" ]; then
  ok "markdownlint-contributing-pin-parity ($doc_pin)"
else
  bad "markdownlint-contributing-pin-parity" "CONTRIBUTING.md pins '${doc_pin:-none}', runner pins '${runner_pin:-none}'"
fi

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
