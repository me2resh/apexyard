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
# me2resh/apexyard#1046 — the trim, not the match anchor.
#
# extract_flag_value's greedy match() captured the body correctly, but the
# trim that followed used
#     sub("\"([[:space:]]+--[a-zA-Z].*)?$", "", chunk)
# and POSIX ERE substitution is leftmost-longest. It therefore deleted from
# the EARLIEST quote that happened to be followed by ` --<letter>` through to
# end-of-string, amputating the body's tail. The hook then exited 0 with the
# tail never scanned — a silent fail-open on a leak gate.
#
# TWO conditions must co-occur: an embedded quote AND a later double-dash
# token. Either alone still blocked correctly, which is why the repro
# originally filed on #1046 (a bare `--verbose` in prose, no embedded quote)
# did NOT reproduce. Both single-condition cases are asserted below so a
# future reader can see why.
#
# The fix scans backwards for the closing delimiter instead of regex-trimming,
# and deliberately leaves the greedy match() anchors alone: widening those was
# tried in #1040 and rejected for reopening #227 (9 failures vs 5).
# ---------------------------------------------------------------------------

# The two leaking commands recorded on the issue. Both exited 0 pre-fix.
run_case "#1046: double-quoted body, embedded quote then --flag, leak in tail → block" \
  2 "project name: curios-dog" \
  "gh issue create --repo me2resh/apexyard --title \"t\" --body \"quote \\\"done\\\" --verbose then curios-dog here\""

run_case "#1046: same shape with a trailing --label after the body → block" \
  2 "project name: curios-dog" \
  "gh issue create --repo me2resh/apexyard --title \"t\" --body \"x \\\"y\\\" --a b curios-dog\" --label bug"

# NOT on the issue: the single-quoted branch carried the identical
# leftmost-longest defect and leaked on the equivalent command shape.
run_case "#1046: single-quoted body, embedded quote then --flag, leak in tail → block" \
  2 "project name: curios-dog" \
  "gh issue create --repo me2resh/apexyard --title t --body 'quote '\"'\"'done'\"'\"' --verbose then curios-dog here'"

# Single-condition controls — these passed BEFORE the fix too. They are here to
# document why the originally filed repro did not reproduce, not as proof.
run_case "#1046 control: embedded quote alone (no --flag) → block" \
  2 "project name: curios-dog" \
  "gh issue create --repo me2resh/apexyard --title \"t\" --body \"quote \\\"done\\\" then curios-dog here\""

run_case "#1046 control: --flag alone (no embedded quote) → block" \
  2 "project name: curios-dog" \
  "gh issue create --repo me2resh/apexyard --title \"t\" --body \"no quotes --verbose curios-dog\""

# The false-positive guard: both trigger conditions present, nothing private.
run_case "#1046: embedded quote + --flag but clean body → pass" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title \"t\" --body \"quote \\\"done\\\" --verbose and nothing private\""

# Item 1 — the fail-closed message advised a bypass that cannot work, because
# the skip-marker check runs downstream of this block. The marker is read out
# of scanned body content; it cannot be read out of a file that never opened.
# Asserting on the corrected wording, which is absent pre-fix.
run_case "#1046: unreadable body-file message no longer advises the skip marker" \
  2 "does NOT apply here" \
  "gh issue create --repo me2resh/apexyard --title t --body-file /nonexistent-xyz-1046.md"

run_case "#1046: skip marker in --body does not unblock an unreadable --body-file" \
  2 "body-file named but not readable" \
  "gh issue create --repo me2resh/apexyard --title t --body-file /nonexistent-xyz-1046.md --body \"<!-- private-refs: allow -->\""

# Scope asymmetry (found in security review of this PR, not in #1046 itself).
# Retaining a superset is fail-closed for DETECTION but fail-OPEN for the
# skip MARKER: the greedy match cannot tell where the body ends, so a marker
# in a later quoted flag value rode in on the over-capture and bypassed the
# gate. Blocked on dev, briefly bypassed mid-PR, blocked again now that the
# marker check reads a conservative (subset) extraction.
run_case "#1046: skip marker in a later --label must NOT bypass the gate" \
  2 "project name: curios-dog" \
  "gh issue create --repo me2resh/apexyard --title \"t\" --body \"curios-dog\" --label \"<!-- private-refs: allow -->\""

# The legitimate bypasses must still work — the marker is a documented escape
# hatch, and narrowing its scope must not remove it from title or body.
run_case "#1046: skip marker in the body still bypasses (documented escape hatch)" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title \"t\" --body \"curios-dog <!-- private-refs: allow -->\""

run_case "#1046: skip marker in the title still bypasses (documented escape hatch)" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title \"<!-- private-refs: allow -->\" --body \"curios-dog\""

# Round-2 security review: the first scope-asymmetry fix keyed the conservative
# cut on a DOUBLE dash, so it closed `--label` and left the short spellings
# open. `-l` IS `--label` — same shape, two spellings. The anchor is now
# `-{1,2}[a-zA-Z]` in the "first" branch only, which cannot reach detection.
run_case "#1046: skip marker in -l must NOT bypass (short spelling of --label)" \
  2 "project name: curios-dog" \
  "gh issue create --repo me2resh/apexyard --title \"t\" --body \"curios-dog\" -l \"<!-- private-refs: allow -->\""

run_case "#1046: skip marker in -a must NOT bypass (short spelling of --assignee)" \
  2 "project name: curios-dog" \
  "gh issue create --repo me2resh/apexyard --title \"t\" --body \"curios-dog\" -a \"<!-- private-refs: allow -->\""

run_case "#1046: skip marker in --assignee must NOT bypass" \
  2 "project name: curios-dog" \
  "gh issue create --repo me2resh/apexyard --title \"t\" --body \"curios-dog\" --assignee \"<!-- private-refs: allow -->\""

# A marker present but not where it counts used to block with no explanation:
# the operator reads the escape-hatch advice, adds the marker, is blocked
# again, and goes hunting for a typo in a marker that is demonstrably there.
run_case "#1046: a misplaced marker gets a diagnostic explaining why it did not apply" \
  2 "not in a position" \
  "gh issue create --repo me2resh/apexyard --title \"t\" --body \"curios-dog\" -l \"<!-- private-refs: allow -->\""

# ...and the diagnostic must NOT fire when no marker was supplied at all,
# or it becomes noise on every ordinary block.
run_case "#1046: plain leak with no marker still blocks (diagnostic not asserted here)" \
  2 "project name: curios-dog" \
  "gh issue create --repo me2resh/apexyard --title \"t\" --body \"curios-dog here\""

# ---------------------------------------------------------------------------
# Portability lock: no ERE intervals in the hook's awk program.
#
# `{n,m}` support is not universal in awk — mawk 1.3.3 lacks it, BWK awk only
# gained it around 2019, gawk 3.x needed --re-interval. Where unsupported the
# pattern is treated LITERALLY, which for the conservative trim means the cut
# fires only at end-of-chunk and the subset silently degrades toward the
# superset, reopening the marker bypass on some machines and not others.
#
# The behavioural cases above cannot catch this — they pass on any awk that
# DOES support intervals, which includes most developer machines and CI. This
# is a source-level assertion precisely because the failure is environmental.
# `--?[a-zA-Z]` is exactly equivalent and interval-free.
# ---------------------------------------------------------------------------

HOOK_SRC="$REPO_ROOT/.claude/hooks/block-private-refs-in-public-repos.sh"

# Strip comment lines BEFORE matching. The first version of this check
# grepped the raw file and flagged the explanatory comment that documents
# why the interval was removed — a check that fires on prose describing the
# bug rather than on the bug. That is the same class as me2resh/apexyard#1066
# (hooks matching command text rather than commands), reproduced here in
# miniature, so it is worth naming rather than quietly fixing.
#
# Only bracket-quantifier forms like {1,2} / {2} / {1,} count. Braces in
# awk's own block syntax and in shell ${VAR} expansions are not intervals,
# and neither is matched by this pattern.
INTERVAL_HITS=$(grep -vE '^[[:space:]]*#' "$HOOK_SRC" | grep -nE '\{[0-9]+(,[0-9]*)?\}' || true)
if [ -n "$INTERVAL_HITS" ]; then
  FAIL=$((FAIL+1))
  echo "FAIL: hook source contains an ERE interval {n,m} — not portable across awks; use --? or an explicit alternation"
  printf '%s\n' "$INTERVAL_HITS" | head -3
else
  PASS=$((PASS+1))
  echo "PASS: no ERE intervals in hook source (portable across awk implementations)"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
