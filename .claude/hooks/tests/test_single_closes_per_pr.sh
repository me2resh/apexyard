#!/bin/bash
# Tests for the single-Closes-keyword check in validate-pr-create.sh (#114).
#
# Note: the PR title in each case (`chore(#114): test`) references issue #114 in
# me2resh/apexyard. Rather than depend on that issue staying OPEN forever, the
# sandbox installs a fake `gh` on PATH (see _lib-mock-gh.sh) that returns a
# synthetic OPEN response for any `gh issue view`. Removes the live-tracker
# dependency from the suite. See me2resh/apexyard#154.

set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/validate-pr-create.sh"
# shellcheck source=_lib-mock-gh.sh
source "$(cd "$(dirname "$0")" && pwd)/_lib-mock-gh.sh"
PASS=0
FAIL=0
FAILED_CASES=""

make_sandbox() {
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git checkout -q -b chore/GH-114-test 2>/dev/null || git checkout -q -B chore/GH-114-test
    touch onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/validate-pr-create.sh"
  chmod +x "$sb/.claude/hooks/validate-pr-create.sh"
  local src_root
  src_root=$(cd "$(dirname "$0")/../../.." && pwd)
  cp "$src_root/.claude/hooks/_lib-read-config.sh" "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$src_root/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  echo "$sb"
}

run_case() {
  local label="$1" body_content="$2" want_rc="$3" want_stderr_regex="$4" extra_config="${5-}"
  local sb; sb=$(make_sandbox)
  mock_gh_install "$sb"
  # Body must satisfy the required-sections check so we're only testing the close-count logic.
  local body_file="$sb/body.md"
  printf '%s\n\n## Testing\nfoo\n\n## Glossary\n| t | d |\n' "$body_content" > "$body_file"
  if [ -n "$extra_config" ]; then
    echo "$extra_config" > "$sb/.claude/project-config.json"
  fi
  local cmd="gh pr create --repo me2resh/apexyard --title 'chore(#114): test' --body-file $body_file"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  local got_stderr got_rc
  got_stderr=$(cd "$sb" && echo "$input" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:200})" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# ---- Cases --------------------------------------------------------------

run_case "one Closes → pass" \
  "## Summary
does a thing

Closes #114" \
  0 ""

run_case "no closing keyword → pass (cross-ref is ok)" \
  "## Summary
relates to #99" \
  0 ""

run_case "two distinct Closes → block" \
  "## Summary

Closes #1
Closes #2" \
  2 "2 distinct closing references"

run_case "three mixed keywords → block" \
  "## Summary

Fixes #10
Resolves #20
Closes #30" \
  2 "3 distinct closing references"

run_case "same number twice → pass (only one distinct)" \
  "## Summary

Closes #5
Fixes #5" \
  0 ""

run_case "closing keyword inside code block → ignored" \
  "## Summary

\`\`\`
Fixes #99 — this is inside a fence
\`\`\`

Closes #114" \
  0 ""

run_case "multi-close skip marker bypasses" \
  "## Summary

Closes #1
Closes #2
<!-- multi-close: approved -->" \
  0 "multi-close check bypassed"

run_case "cross-ref without keyword + one Closes → pass" \
  "## Summary
depends on #99

Closes #114" \
  0 ""

run_case "opt-in config disables the check" \
  "## Summary

Closes #1
Closes #2
Closes #3" \
  0 "" \
  '{"pr": {"allow_multiple_closes": true}}'

run_case "cross-repo closing ref counted" \
  "## Summary

Closes me2resh/apexyard#10
Closes me2resh/apexyard#11" \
  2 "2 distinct closing references"

run_case "closing keywords in inline backticks → ignored (documentation)" \
  "## Summary
Documentation mentions \`Closes #1 Closes #2 Closes #3\` as examples.

Closes #114" \
  0 ""

run_case "skip marker inside inline backticks → does NOT bypass" \
  "## Summary
Documentation: \`<!-- multi-close: approved -->\` is the marker.

Closes #1
Closes #2" \
  2 "2 distinct closing references"

run_case "tilde fence also stripped" \
  "## Summary

~~~
Fixes #99 inside a tilde fence
~~~

Closes #114" \
  0 ""

# ---- Summary ------------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
