#!/bin/bash
# Test fixtures for block-private-refs-in-public-repos.sh.
#
# Each test case builds a JSON tool_input payload and pipes it to the hook,
# then asserts on exit code and (optionally) stderr substring.
#
# No framework — just bash + grep + exit codes, so this runs anywhere the
# other hooks run. To execute:
#
#   ./.claude/hooks/tests/test_block_private_refs.sh
#
# Exit 0 = all pass, exit 1 = at least one failure.

set -u

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOK="$REPO_ROOT/.claude/hooks/block-private-refs-in-public-repos.sh"

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook not found or not executable at $HOOK" >&2
  exit 1
fi

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Set up an isolated fake fork with a minimal registry. Running tests from
# inside the real ops fork would be fine (the real registry is available)
# but the tests are clearer with a controlled registry.
# ---------------------------------------------------------------------------

TMPDIR=$(mktemp -d -t block-private-refs.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/fork"
cat > "$TMPDIR/fork/onboarding.yaml" <<'YAML'
company: test
YAML
cat > "$TMPDIR/fork/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: curios-dog
    repo: me2resh/curios-dog
    workspace: workspace/curios-dog
    status: active
  - name: sharppick
    repo: me2resh/SharpPick
    workspace: workspace/sharppick
    status: active
  - name: marlow-core
    repo: acme-private/marlow-svc
    workspace: workspace/ws-marlow
    status: active
YAML

# A directory to cd into so the hook walks up to find the registry.
mkdir -p "$TMPDIR/fork/subdir"

# Build a JSON tool_input payload. Uses jq to escape the command cleanly.
make_payload() {
  local cmd="$1"
  jq -n --arg c "$cmd" '{tool_input: {command: $c}}'
}

# Run the hook with a payload and capture exit + stderr.
# $1 = test name, $2 = expected exit code, $3 = stderr substring (optional),
# $4 = bash command string (tool_input.command).
run_case() {
  local name="$1"
  local expected_exit="$2"
  local expected_stderr_substr="$3"
  local cmd="$4"

  local stderr_file
  stderr_file=$(mktemp)

  # Run from the fork subdir so the registry-walk finds the fixture.
  ( cd "$TMPDIR/fork/subdir" && echo "$(make_payload "$cmd")" | "$HOOK" ) 2> "$stderr_file"
  local actual_exit=$?
  local stderr_content
  stderr_content=$(cat "$stderr_file")
  rm -f "$stderr_file"

  local ok=1
  if [ "$actual_exit" != "$expected_exit" ]; then
    ok=0
  fi
  if [ -n "$expected_stderr_substr" ]; then
    if ! echo "$stderr_content" | grep -qF -- "$expected_stderr_substr"; then
      ok=0
    fi
  fi

  if [ "$ok" = 1 ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "   expected exit=$expected_exit, got $actual_exit"
    if [ -n "$expected_stderr_substr" ]; then
      echo "   expected stderr to contain: $expected_stderr_substr"
    fi
    echo "   stderr was:"
    echo "$stderr_content" | sed 's/^/     /'
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

# 1. Name leak — body mentions a registered project name, target is public.
run_case "name leak on gh issue create to me2resh/apexyard" \
  2 "project name: curios-dog" \
  "gh issue create --repo me2resh/apexyard --title 'bug in rebuild' --body 'discovered during curios-dog rebuild'"

# 2. Repo-slug leak — body contains `owner/repo#N`.
run_case "repo-slug leak with ticket ref" \
  2 "project repo: me2resh/curios-dog" \
  "gh pr create --repo me2resh/apexyard --title 'fix: patch' --body 'same as me2resh/curios-dog#42'"

# 3. Bare repo-slug leak without #N.
run_case "bare repo-slug leak" \
  2 "project repo: me2resh/SharpPick" \
  "gh issue comment 5 --repo me2resh/apexyard --body 'reproduces in me2resh/SharpPick too'"

# 4. Skip marker — body has the allow comment, hook exits 0 with a warning.
run_case "skip marker bypasses leak check" \
  0 "private-refs: allow marker present" \
  "gh issue create --repo me2resh/apexyard --title 'legit cross-ref' --body 'refs curios-dog intentionally <!-- private-refs: allow -->'"

# 5. Missing registry — registry file not present, hook is a no-op.
mv "$TMPDIR/fork/apexyard.projects.yaml" "$TMPDIR/fork/apexyard.projects.yaml.bak"
run_case "missing registry → no-op" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'x' --body 'mentions curios-dog'"
mv "$TMPDIR/fork/apexyard.projects.yaml.bak" "$TMPDIR/fork/apexyard.projects.yaml"

# 6. Non-public target — same body but a private repo target; hook ignores.
run_case "non-public target → no-op" \
  0 "" \
  "gh issue create --repo me2resh/curios-dog --title 'x' --body 'mentions curios-dog freely'"

# 7. Empty body — nothing to scan, hook is a no-op.
run_case "empty body → no-op" \
  0 "" \
  "gh pr comment 12 --repo me2resh/apexyard"

# 8. Workspace-path leak — uses a project whose workspace path does NOT
#    also contain the project name, so the workspace match fires alone.
run_case "workspace path leak" \
  2 "workspace path: workspace/ws-marlow" \
  "gh pr create --repo me2resh/apexyard --title 'fix: path' --body 'seen in workspace/ws-marlow/app.ts'"

# 9. Non-gh command — hook does not fire.
run_case "non-gh command → no-op" \
  0 "" \
  "echo curios-dog"

# 10. gh api issues shape — mirrors gh issue create via REST.
run_case "gh api issues leak" \
  2 "project name: curios-dog" \
  "gh api repos/me2resh/apexyard/issues -f title=bug -f body='discovered during curios-dog rebuild'"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
