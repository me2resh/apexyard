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

# 11. Embedded double quotes in body — me2resh/apexyard#227.
#     Pre-227 the sed-based extractor's `[^"]*` truncated the body at the
#     first internal `"`, which had a security tail: private refs that
#     appeared in the BACK half of the body (past the truncation) slipped
#     past the leak gate. Post-fix the awk extractor is greedy + anchored
#     on next-flag-or-EOS, so a private project name in the back half is
#     correctly detected.
LEAK_AFTER_QUOTE_BODY='## Driver
The "admin notice" string is shown to users.

## Scope
- Mention the "current state" label

## Acceptance Criteria
- [ ] discovered during curios-dog rebuild'

run_case "leak in back half of body with embedded quote in front → block" \
  2 "project name: curios-dog" \
  "gh issue create --repo me2resh/apexyard --title 'fix' --body \"$LEAK_AFTER_QUOTE_BODY\""

# 12. Same but for repo-slug ref past the embedded quote.
LEAK_REPO_AFTER_QUOTE='Description of the issue.

The "needs attention" flag is wrong.

See me2resh/SharpPick#42 for similar.'

run_case "repo-slug leak past embedded quote → block" \
  2 "project repo: me2resh/SharpPick" \
  "gh pr create --repo me2resh/apexyard --title 'fix' --body \"$LEAK_REPO_AFTER_QUOTE\""

# 13. Clean body (no leak) with embedded quotes — should pass.
CLEAN_WITH_QUOTES='## Driver
The "admin notice" feature.

## Scope
- Updated to show "current state".

## Acceptance Criteria
- [ ] Updated.'

run_case "clean body with embedded quotes → pass (no false positive)" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'fix' --body \"$CLEAN_WITH_QUOTES\""

# ---------------------------------------------------------------------------
# 14–20. me2resh/apexyard#1039 — the hook must fail CLOSED.
#
# extract_flag_value's quoted branches used to anchor only on `--<letter>`
# or end-of-string. A quoted --body-file followed by a shell operator or a
# single-dash flag missed that anchor, fell through to the unquoted branch
# (which has none), and came back WITH its quotes attached. `[ -f "\"…\"" ]`
# was then false, the body was never read — and because this hook exits 0
# when it recovers no body, the private name reached a public tracker
# unscanned. Silent leak, not a visible block.
#
# These cases pin BOTH halves of the fix: the widened anchor, and the
# fail-closed behaviour when a body-file is named but unreadable. Every
# shape below returns exit 0 (leak) against the pre-#1039 hook.
# ---------------------------------------------------------------------------

LEAK_FILE="$TMPDIR/leak-body.md"
printf 'Discovered during the marlow-core rebuild.\n' > "$LEAK_FILE"
CLEAN_FILE="$TMPDIR/clean-body.md"
printf 'A generic framework bug. No project named.\n' > "$CLEAN_FILE"

GH_CREATE="gh issue create --repo me2resh/apexyard --title t"

# 14. Quoted path + shell pipe — the shape an operator most likely types.
run_case "#1039: quoted --body-file + pipe → blocked (was a silent leak)" \
  2 "marlow-core" \
  "$GH_CREATE --body-file \"$LEAK_FILE\" 2>&1 | tail -3"

# 15. Quoted path + single-dash flag (the old anchor only knew `--`).
run_case "#1039: quoted --body-file + single-dash flag → blocked" \
  2 "marlow-core" \
  "$GH_CREATE --body-file \"$LEAK_FILE\" -t \"[Bug] x\""

# 16. Single-quoted variant of the same shape.
run_case "#1039: single-quoted --body-file + pipe → blocked" \
  2 "marlow-core" \
  "$GH_CREATE --body-file '$LEAK_FILE' 2>&1 | tail -3"

# 17. Quoted path + redirect.
run_case "#1039: quoted --body-file + redirect → blocked" \
  2 "marlow-core" \
  "$GH_CREATE --body-file \"$LEAK_FILE\" > /dev/null"

# 18. Fail closed on a body-file we cannot read. Defence in depth: any
#     FUTURE parsing gap now blocks loudly instead of leaking silently.
run_case "#1039: named but unreadable --body-file → blocked, not skipped" \
  2 "not readable" \
  "$GH_CREATE --body-file $TMPDIR/does-not-exist.md"

# 19. Regression — a clean body in the previously-failing shape must still
#     pass. The fix must not convert a silent leak into a false positive.
run_case "#1039: clean body, quoted + pipe → pass (no new false positive)" \
  0 "" \
  "$GH_CREATE --body-file \"$CLEAN_FILE\" 2>&1 | tail -3"

# 20. Regression — `gh issue comment` with no body still opens gh's editor
#     and must remain a no-op, not a fail-closed block.
run_case "#1039: no body at all → still a no-op (editor case)" \
  0 "" \
  "gh issue comment 42 --repo me2resh/apexyard"

# ---------------------------------------------------------------------------
# 21–29. #1039 round 2 — back-half detection must survive the fix.
#
# The FIRST attempt at #1039 widened extract_flag_value's anchor to accept
# shell operators. That closed the --body-file bypasses above and REOPENED
# the leak #227 fixed, in a wider form — it was measurably worse than no fix
# at all (upstream: 5 failures; that attempt: 9).
#
# Mechanism: the closing-quote stripper is `sub()`, which is leftmost-first
# rather than suffix-anchored, and each alternative ended in `.*`. So an
# embedded `"` whose next non-space character was a boundary char truncated
# the body there, and everything after went unscanned — while this hook
# exits 0 on an empty scan.
#
# The shape that makes this not-theoretical: a markdown table row ending in
# a quoted term followed by ` |`. A Glossary table is MANDATORY in this
# framework's own issue and PR bodies, so the most likely body shape was the
# triggering one.
#
# Cases 11–13 above could not catch it: they use quote-followed-by-WORD, and
# case 13 passes more easily under truncation (a clean body stays clean).
# These cases put a private ref in the BACK half, after each boundary
# character, so truncation is detected rather than rewarded.
#
# The real fix is a parsing split, not a regex tweak: --body-file takes a
# PATH (non-greedy, stops at the first closing quote — paths cannot contain
# quotes) while --body takes CONTENT (greedy, terminates only on a real flag
# boundary). One extractor cannot serve both.
# ---------------------------------------------------------------------------

for boundary in '|' ';' '&' '<' '>' '(' ')'; do
  run_case "#1039 r2: inline body, quote then '$boundary' then leak → block" \
    2 "project name: curios-dog" \
    "gh issue create --repo me2resh/apexyard --title t --body \"The \\\"admin notice\\\" $boundary more text. Seen during the curios-dog rebuild.\""
done

# A single-dash flag as the boundary — same class, different trigger char.
run_case "#1039 r2: inline body, quote then ' -t' then leak → block" \
  2 "project name: curios-dog" \
  "gh issue create --repo me2resh/apexyard --title t --body \"The \\\"admin notice\\\" -t more. Seen during the curios-dog rebuild.\""

# The realistic shape: a mandatory Glossary table, then a leak below it.
run_case "#1039 r2: markdown table row then leak in the tail → block" \
  2 "project name: curios-dog" \
  "gh issue create --repo me2resh/apexyard --title t --body \"| Term | Definition |
| \\\"thing\\\" | a thing |

Discovered during the curios-dog rebuild.\""

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
