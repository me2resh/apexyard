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
  - name: zebrafish
    repo: acme/zebrafish-app
    workspace: workspace/zebrafish
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
# me2resh/apexyard#1068 — a trailing --repo ANYWHERE on the line disables
# the gate entirely.
#
# TARGET_REPO used to be resolved with a single greedy sed match:
#     sed -nE 's/.*--repo[[:space:]]+...'
# The leading `.*` is greedy, so on a line with more than one `--repo` token
# it binds the LAST one, not the one belonging to the actual write. A
# chained second `gh` call, or even a bare trailing shell comment mentioning
# `--repo`, made the hook resolve the wrong target, decide "not public
# class" at step 3, and exit 0 having scanned NOTHING — before any title or
# body extraction ran. `| head -1` only de-dupes matched LINES; sed's
# single substitution already picked the last match within a line before
# `head` ever sees it.
#
# The fix anchors resolution on the matched write invocation (`gh issue
# create`, `gh pr create`, `gh issue comment`, `gh pr comment`, `gh api`)
# and takes the FIRST `--repo` (or `repos/<owner>/<repo>` path, for the api
# shape) found AFTER that anchor — not the last one anywhere on the line.
#
# Baseline arithmetic, stated explicitly so it reconciles: the suite had
# 48 cases before any #1068 work. Cases 21-27 below are the 7 added for
# round 1 (55 total at that point). Cases 28-31 further down are the 4
# added for round 2 (59 total by the end of this file). Every count in
# this file's comments should reduce to those two numbers — if it doesn't,
# the comment is wrong, not the arithmetic.
#
# Cases 21-23 are genuine RED-before-round-1-fix leaks (exit 0, nothing
# scanned) — confirmed against the pre-fix hook. Case 24 is the CONTROL:
# it already blocked correctly pre-fix, which is what makes 21-23 bypasses
# rather than ordinary match failures. Cases 25-27 already behaved
# correctly pre-round-1-fix too, each for a different, more fragile reason
# than the real fix below — so the honest split for the 7 round-1 cases is
# 3 net fail→pass (21, 22, 23) and 4 already green (24 control, 25, 26, 27):
#
# NOTE on 21-23's expected message: once TARGET_REPO resolves correctly,
# these three commands hit a SECOND, previously-unreachable gap —
# extract_flag_value's greedy match() has no terminator alternative for
# "a shell command is chained right after this quoted value", so it falls
# through to a truncated unquoted read instead of the real body. The fix
# does not attempt to parse the chain (that class of widening is exactly
# what #1040 tried and #1039r2 below proves unsafe); it detects the
# truncation signature and refuses. So 21-23 block on "could not safely
# determine where the value ends", not on a specific "project name: x"
# match — the hook is correctly refusing to trust an extraction it knows
# is incomplete, which is the safe-direction behaviour #1068 asked for.
# This truncation-refusal is a COUPLING worth naming: 21-23 block only
# because refusal catches them once resolution has already decided the
# target is public. Removing the refusal later would silently reopen them.
#   - 25 (gh api shape) never had this bug — the api-path fallback already
#     used `grep -oE ... | head -1`, which is first-occurrence, not
#     last-occurrence like the buggy `--repo`-flag sed. Kept as a
#     same-shape regression guard for the shape the fix now also covers
#     explicitly.
#   - 26 never had this bug either — a single, unchained command with
#     --repo legitimately placed after --title/--body resolves the same
#     way both before and after any of this file's fixes.
#
# Case 27 is DELIBERATELY FLIPPED in round 2, and that is a correction to
# the test, not a new requirement discovered by the test. Round 1 encoded
# "private target, public repo mentioned later in a chained call → no-op"
# as a requirement. Round 2's class-based fix (see the source file's
# large comment above the resolution code) treats ANY public-repo mention
# anywhere in the write segment as reason to scan — which is what closes
# the round-1-introduced holes below — so this exact shape now BLOCKS
# instead. That is over-blocking (the explicitly sanctioned safe
# direction for this fix), not under-blocking, and it is a conscious
# tradeoff: a single Bash call chaining a private write with a public one
# now gets its private title/body scanned too, because the public repo's
# slug is present somewhere in the combined text the hook cannot cleanly
# attribute to one invocation or the other.
# ---------------------------------------------------------------------------

# 21. The exact repro from the issue: a chained SECOND gh call mentions an
#     unrelated --repo after the real write. Pre-fix this exits 0 with
#     nothing scanned; the greedy match binds `acme/zebrafish-app`.
run_case "#1068: chained second gh call's --repo must not override the real target" \
  2 "could not safely determine" \
  "gh issue create --repo me2resh/apexyard --title \"T\" --body \"found during zebrafish rebuild\" && gh pr list --repo acme/zebrafish-app"

# 22. A bare trailing shell COMMENT is enough — no second command required.
run_case "#1068: trailing shell comment mentioning --repo must not override the real target" \
  2 "could not safely determine" \
  "gh issue create --repo me2resh/apexyard --title \"T\" --body \"found during zebrafish rebuild\" # see --repo foo/bar"

# 23. Same shape, `gh pr create` instead of `gh issue create` — the anchor
#     must cover every one of the five recognised write shapes, not just
#     the one in the issue's own repro.
run_case "#1068: chained bypass via gh pr create must not override the real target" \
  2 "could not safely determine" \
  "gh pr create --repo me2resh/apexyard --title \"T\" --body \"found during zebrafish rebuild\" && gh issue list --repo acme/zebrafish-app"

# 24. CONTROL — identical command, no trailing --repo. This already blocked
#     correctly before the fix; it is what proves 21/22/23 are bypasses
#     rather than a match failure the fix accidentally also repairs.
run_case "#1068 control: same command without the trailing --repo → still blocks" \
  2 "project name: zebrafish" \
  "gh issue create --repo me2resh/apexyard --title \"T\" --body \"found during zebrafish rebuild\""

# 25. gh api shape — the same class of bypass via the REST path form, a
#     second gh api call chained on.
run_case "#1068: gh api chained bypass must not override the real target" \
  2 "project name: zebrafish" \
  "gh api repos/me2resh/apexyard/issues -f title=T -f body='found during zebrafish rebuild' && gh api repos/acme/zebrafish-app/pulls"

# 26. Regression — --repo legitimately appearing AFTER --title/--body in a
#     single, unchained command (no bypass attempt at all) must still
#     resolve correctly. The fix must not start requiring --repo to appear
#     FIRST in the command.
run_case "#1068: --repo after title/body in a single command still resolves" \
  2 "project name: zebrafish" \
  "gh issue create --title \"T\" --body \"found during zebrafish rebuild\" --repo me2resh/apexyard"

# 27. DELIBERATELY FLIPPED in round 2 (was "stays a no-op" in round 1 — see
#     the block comment above case 21 for why that was the wrong bar).
#     A private-target write chained with a later call that mentions the
#     public framework repo now BLOCKS: the class-based fix treats any
#     public-repo mention in the write segment as reason to scan, so this
#     over-blocks rather than risk the ordering hole round 1 introduced.
run_case "#1068 round 2: private target chained with a later public mention now over-blocks (was a no-op; deliberate tradeoff)" \
  2 "could not safely determine" \
  "gh issue create --repo acme/zebrafish-app --title \"T\" --body \"mentions zebrafish freely, private target\" && gh pr list --repo me2resh/apexyard"

# ---------------------------------------------------------------------------
# me2resh/apexyard#1068 round 2 — security AND code review both found that
# round 1's "first --repo after the anchor" fix closed the AFTER hole
# (chained/trailing --repo, cases 21-23 above) but opened a BEFORE hole:
# a --repo-SHAPED token embedded inside an EARLIER flag's quoted value
# (--title or --body) now wins over the real flag, because it appears
# first in raw text. Round 1's own code comment claimed this shape was
# "a pre-existing weakness of the previous implementation too" — that
# claim was WRONG, not just unproven. Verified below against the actual
# `upstream/dev` blob at the commit this branch forked from (not reasoned
# from the code's shape): dev's "last --repo on the line wins" happens to
# land on the real, later flag for every one of these shapes, so dev
# BLOCKS all three. Round 1 LEAKS on all three. This is the mistake
# AgDR-0113 exists to catch — every "pre-existing" claim must cite the
# check that proves it against the real prior behaviour.
#
# The fix (see the source file's step 2/3 comment): class-based, not
# positional. Collect every --repo / repos/<owner>/<repo> candidate in the
# write segment and scan if ANY is public-class, rather than committing to
# one candidate by position (first OR last). All three shapes below close
# under that fix without touching extract_flag_value at all.
# ---------------------------------------------------------------------------

# 28. --title carries a --repo-shaped decoy BEFORE the real flag. This is
#     the more adversarial-looking of the two "before" shapes, but still
#     needs no special crafting beyond ordinary prose.
run_case "#1068 round 2: --repo-shaped text inside --title (before the real flag) must not be picked as target" \
  2 "project name: zebrafish" \
  "gh issue create --title \"use --repo acme-private/zebrafish here\" --repo me2resh/apexyard --body \"zebrafish leak\""

# 29. --body carries the decoy instead. Called out specifically because it
#     needs NO adversarial crafting at all: --body routinely precedes
#     --repo in real invocations, and body prose quoting a --repo example
#     is this very repo's own habit — #1068's own issue body does exactly
#     this. So this is the ordinary shape of an upstream bug report about
#     `gh`, not a crafted exploit.
run_case "#1068 round 2: --repo-shaped text inside --body (before the real flag) must not be picked as target" \
  2 "project name: zebrafish" \
  "gh issue create --body \"run with --repo other/x for zebrafish\" --repo me2resh/apexyard --title \"T\""

# 30. Two REAL writes chained: a private-repo write first, a public-repo
#     write second, with the leak in the SECOND (public) write's body.
#     Round 1 mis-resolved the target to the private repo (whichever
#     --repo it picked positionally) and exited 0 with the public write's
#     own leak never scanned. The class-based fix finds the public repo's
#     slug present in the segment (from the second write's own --repo
#     flag) and scans.
run_case "#1068 round 2: two real writes, private-then-public, leak in the public one's body" \
  2 "project name: zebrafish" \
  "gh issue create --repo acme-private/zebrafish --title \"A\" --body \"clean\" && gh issue create --repo me2resh/apexyard --title \"B\" --body \"zebrafish leak\""

# 31. DOCUMENTED, NOT FIXED — the `--repo=owner/name` equals form. Verified
#     against the real `upstream/dev` blob: it resolves nothing there
#     either (rc=0, nothing scanned), so this is genuinely pre-existing,
#     not something round 1 or round 2 introduced or silently regressed.
#     Asserting CURRENT (gap) behaviour here, not a requirement — a future
#     fix for the equals form should update this case, not treat its
#     presence as a regression.
run_case "#1068: KNOWN GAP (pre-existing on dev, not fixed here) — --repo=owner/name equals form resolves nothing" \
  0 "" \
  "gh issue create --repo=me2resh/apexyard --title \"T\" --body \"zebrafish leak here\""

# ---------------------------------------------------------------------------
# me2resh/apexyard#1068 round 3 (security review of round 2) — the round-2
# code comment claimed `find_write_segment`'s `(^|[[:space:]])gh` anchor
# "mirrors" step 1's `\bgh` classification regex. It does not: `\b` is a
# WORD boundary, firing wherever "gh"'s leading `g` is preceded by any
# NON-word character — `;`, `&`, `|`, `(`, `$`, not only whitespace. The
# anchor only covered the whitespace case, so step 1 (which matches `\b`)
# and the segment finder (which required a space) DISAGREED on exactly
# these four shapes. When they disagreed, step 1 said "this is a write"
# but the segment finder found no match, returned nothing, and the hook
# exited 0 at the empty-segment check — having scanned NOTHING, upstream
# of every fix in this file so far.
#
# The `$(...)` capture form (case 33) is the one that matters operationally:
# capturing a newly created issue/PR's URL — `out=$(gh issue create ...)`
# — is a routine agent idiom, not a crafted shape.
#
# This is also the second time in as many rounds that an unverified
# "these two things behave the same" claim in this file's own comments was
# wrong (round 1's "pre-existing" residue claim was the first) — plausible,
# cheap to check, and false both times. Every case below was confirmed
# failing (rc=0, nothing scanned) against the round-2 committed hook before
# the anchor fix.
#
# But NOT all six are the same class of finding against `dev`, and an
# earlier check here made exactly the mistake this file keeps warning
# about: it used a body where the leak token ("zebrafish") was the FIRST
# word, which let dev's truncated read catch it BY ACCIDENT and masked the
# real gap. Re-verified with a non-frontloaded body ("found during
# zebrafish rebuild"):
#   - 32 (`;gh`), 34 (`&&gh`), 35 (`|gh`) genuinely BLOCK on the real
#     `upstream/dev` blob — real regressions this round closes.
#   - 33 (`out=$(gh ...)`, single write, no chaining) also ALLOWS on dev
#     (rc=0) — pre-existing there too, NOT a round-2 regression, because
#     dev has no truncation-detection concept at all: the trailing `)`
#     defeats dev's extraction the same way it defeats this hook's, dev
#     just has no mechanism to notice and refuse. This fix still closes
#     it, but as a side effect of the segment no longer being empty (so
#     round 1/2's OWN refusal mechanism gets to run) — an improvement
#     over dev on this shape, not parity restoration.
#   - 36 is not a dev-comparison case at all — dev never had a truncation
#     refusal to defeat. It proves this round restores round 1/2's OWN
#     prior behaviour (case 21 unwrapped) once wrapped in `$(...)`.
#   - 37 (`-R`) is a new capability neither dev nor round 1/2 had; closing
#     an inconsistency, not a regression fix.
# ---------------------------------------------------------------------------

# 32. Semicolon immediately before "gh", no space.
run_case "#1068 round 3: ';gh' (no space) must still anchor the write" \
  2 "project name: zebrafish" \
  "echo hi ;gh issue create --repo me2resh/apexyard --title \"T\" --body \"zebrafish leak\""

# 33. `$(...)` COMMAND SUBSTITUTION — the operationally important shape.
#     Capturing the created issue/PR URL is routine agent usage, not an
#     adversarial construction.
#
#     Expected message here is the TRUNCATION REFUSAL, not a named leak —
#     and that is correct, not a second bug. The trailing `)` that closes
#     the substitution sits right after --body's closing quote, so
#     extract_flag_value's boundary check (whitespace+--flag OR
#     whitespace* END-OF-STRING) fails there too: a lone `)` is neither.
#     Widening that boundary to accept a bare `)` was NOT done, because
#     `)` is one of the exact boundary characters #1039r2 below already
#     proves must NOT be treated as a terminator (a body legitimately
#     containing `(...)` followed by more leak content must still be
#     scanned to the end). So a write wrapped in `$(...)` correctly hits
#     the SAME safe refusal as a chained command — over-blocking, not a
#     leak, and the anchor fix has already done its job by this point:
#     the target resolved to public and the hook did not exit 0 silently.
run_case "#1068 round 3: out=\$(gh ...) command substitution must still anchor the write (and correctly hits the truncation refusal, not a silent leak)" \
  2 "could not safely determine" \
  "out=\$(gh issue create --repo me2resh/apexyard --title \"T\" --body \"zebrafish leak\")"

# 34. `&&gh` — no space between the chain operator and "gh".
run_case "#1068 round 3: '&&gh' (no space) must still anchor the write" \
  2 "project name: zebrafish" \
  "true &&gh issue create --repo me2resh/apexyard --title \"T\" --body \"zebrafish leak\""

# 35. `|gh` — no space between the pipe and "gh".
run_case "#1068 round 3: '|gh' (no space) must still anchor the write" \
  2 "project name: zebrafish" \
  "echo hi |gh issue create --repo me2resh/apexyard --title \"T\" --body \"zebrafish leak\""

# 36. Structural proof that the anchor bug also defeated the truncation
#     refusal from round 1/2: this EXACT chained-command shape correctly
#     REFUSES unwrapped (case 21 above); wrapped in `$(...)` it used to
#     exit 0 instead, because the segment finder ran before extraction and
#     found nothing to extract from.
run_case "#1068 round 3: \$(...) wrapping must not silently defeat the truncation refusal" \
  2 "could not safely determine" \
  "out=\$(gh issue create --repo me2resh/apexyard --title \"T\" --body \"found during zebrafish rebuild\" && gh pr list --repo acme/zebrafish-app)"

# 37. `-R` — gh's own documented short flag for `--repo` (`gh help issue
#     create` lists `-R, --repo [HOST/]OWNER/REPO`), on the same footing as
#     the `-t`/`-b` short forms this hook already recognises. Previously
#     undetected; closes an inconsistency rather than adding scope.
run_case "#1068 round 3: -R (short flag for --repo) must be recognised" \
  2 "project name: zebrafish" \
  "gh issue create -R me2resh/apexyard --title \"T\" --body \"zebrafish leak\""

# ---------------------------------------------------------------------------
# me2resh/apexyard#1070 — uncovered `gh api` body shapes, and a missing
# `-F body=@file` fails OPEN unlike `--body-file` (#1039 established fail
# closed for the identical condition one code path over).
#
# Three fixes, all in the IS_GH_API body-extraction block:
#   1. `-F/--field body=@<path>` now shares the same fail-closed posture as
#      `--body-file`: a missing/unreadable file BLOCKS instead of silently
#      falling through to an empty scan (cases 38-39).
#   2. The LONG forms `--field` (alias of -F) and `--raw-field` (alias of
#      -f) are now recognised alongside the short forms, closing the same
#      class of gap `-R`/`--repo` closed above for #1068 round 3 (case 40).
#   3. `--input <file>` / `--input -` now fail CLOSED outright rather than
#      being silently unextracted. `--input -` reads STDIN, invisible to a
#      PreToolUse hook; `--input <file>` hands gh a raw, endpoint-specific
#      JSON payload rather than one known field, so correctly pulling a
#      body/title out of it would mean parsing an arbitrary document —
#      exactly the "enumerate one more shape" treadmill AgDR-0104 says
#      command-text matching cannot win. Both shapes are refused rather
#      than published unscanned (cases 41-42); case 42 (`--input -`) is the
#      one the issue calls out as the case that MUST fail closed, since
#      there is no readability question to resolve for stdin at all.
# ---------------------------------------------------------------------------

# 38. The exact first repro from the issue: `-F body=@missing` used to fall
#     through to the literal-`body=` branch (which cannot match a `body=@`
#     token either), leaving API_BODY empty and the write open (rc=0) at
#     the empty-haystack short-circuit. Mirrors case 18's `--body-file`
#     assertion, one code path over.
run_case "#1070: gh api -F body=@<missing file> → blocked, not silently open" \
  2 "gh api body=@file named but not readable" \
  "gh api repos/me2resh/apexyard/issues -f title=t -F body=@/nonexistent-zzz-1070.md"

# 39. Same shape via the `--field` long form.
run_case "#1070: gh api --field body=@<missing file> → blocked" \
  2 "gh api body=@file named but not readable" \
  "gh api repos/me2resh/apexyard/issues --field body=@/nonexistent-zzz-1070.md"

# 40. `--field` / `--raw-field` long forms — previously unrecognised
#     entirely, so a leak sent through them went unscanned. Now equivalent
#     to -F/-f.
run_case "#1070: gh api --raw-field/--field long forms are recognised" \
  2 "project name: curios-dog" \
  "gh api repos/me2resh/apexyard/issues --raw-field title=bug --field body='discovered during curios-dog rebuild'"

# 41. The second repro from the issue: `--input <file>` was not extracted
#     at all, so a leak sent through it went unscanned (rc=0). Now refused
#     outright rather than chasing JSON-field parse coverage.
run_case "#1070: gh api --input <file> → blocked (was unscanned, rc=0)" \
  2 "gh api --input body cannot be scanned" \
  "gh api repos/me2resh/apexyard/issues --input /nonexistent-zzz-1070.json"

# 42. `--input -` (STDIN) — the shape the issue singles out as the one that
#     MUST fail closed: the hook cannot see stdin at PreToolUse time under
#     any circumstance, so there is no readability question to resolve —
#     refusal is the only sound answer.
run_case "#1070: gh api --input - (stdin) → MUST fail closed" \
  2 "gh api --input body cannot be scanned" \
  "gh api repos/me2resh/apexyard/issues --input -"

# 43. Regression guard — a public-repo `gh api` write with no --input and a
#     readable body=@file must still be SCANNED (and blocked on a leak),
#     not swept up by the new --input refusal.
LEAK_FILE_1070="$TMPDIR/leak-body-1070.md"
printf 'Discovered during the curios-dog rebuild.\n' > "$LEAK_FILE_1070"
run_case "#1070: --field body=@<readable leak file> is still read and scanned" \
  2 "project name: curios-dog" \
  "gh api repos/me2resh/apexyard/issues --field body=@$LEAK_FILE_1070"

# 44. False-positive guard for the readable-file path above — a clean body
#     read from a real file must pass, not be swept up by the new checks.
CLEAN_FILE_1070="$TMPDIR/clean-body-1070.md"
printf 'A generic framework bug. No project named.\n' > "$CLEAN_FILE_1070"
run_case "#1070: --field body=@<readable clean file> → pass (no false positive)" \
  0 "" \
  "gh api repos/me2resh/apexyard/issues --field body=@$CLEAN_FILE_1070"

# 45. `--input` on a NON-public target must stay a no-op — the fail-closed
#     refusal only applies once TARGET_REPO has already resolved to a
#     public-class repo (step 3, upstream of this block).
run_case "#1070: --input on a non-public target → still a no-op" \
  0 "" \
  "gh api repos/me2resh/curios-dog/issues --input /nonexistent-zzz-1070.json"

# 46. Regression guard — the pre-existing SHORT forms (-f/-F) must still
#     work exactly as before; #1070 only adds coverage, it does not change
#     the short-form behaviour case 10 above already pins.
run_case "#1070: existing -f/-F short forms are unaffected" \
  2 "project name: curios-dog" \
  "gh api repos/me2resh/apexyard/issues -f title=bug -f body='discovered during curios-dog rebuild'"

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

# BLANK comments rather than deleting the lines, and blank trailing comments
# too — `sed 's/#.*$//'`, not `grep -v '^[[:space:]]*#'`.
#
# This check has now had the same bug twice, which is why the mechanism is
# spelled out. v1 grepped the raw file and flagged the explanatory comment
# saying why the interval was removed — firing on prose describing the bug
# rather than on the bug, i.e. me2resh/apexyard#1066's class inside the guard
# against it. v2 dropped whole comment lines, which left two residues:
#   - a TRAILING comment on a code line still matched (`x=1  # the {1,2} case`)
#   - `grep -n` then numbered the *filtered* stream, so a hit at real line 669
#     reported as 396 — the same `grep -n` interaction that caused v1
#
# Blanking preserves line numbering and kills both. `${1}` / `${3}` still trip
# it; that is a false positive and it fails CLOSED, so leave it. Do NOT
# "fix" it by loosening the pattern — a looser pattern is how the real
# interval gets back in.
#
# SCOPE: this lock reads THIS FILE ONLY. No sourced lib currently contains an
# interval or performs the conservative cut, so today's surface is covered.
# If the awk program ever moves into a shared lib, this must follow it.
#
# Only bracket-quantifier forms like {1,2} / {2} / {1,} count. `{,3}` is
# deliberately not matched: it is not a valid POSIX interval, so every awk
# treats it literally and there is no divergence to catch.
INTERVAL_HITS=$(sed 's/#.*$//' "$HOOK_SRC" | grep -nE '\{[0-9]+(,[0-9]*)?\}' || true)
if [ -n "$INTERVAL_HITS" ]; then
  FAIL=$((FAIL+1))
  echo "FAIL: hook source contains an ERE interval {n,m} — not portable across awks; use --? or an explicit alternation"
  printf '%s\n' "$INTERVAL_HITS" | head -3
else
  PASS=$((PASS+1))
  echo "PASS: no ERE intervals in hook source (portable across awk implementations)"
fi

# Both directions of the lock itself, against fixtures. Proving only that it
# FIRES on a reintroduced interval is half a test: this check's first two
# versions both fired on prose *describing* an interval, which is the failure
# that actually happened. The false-positive direction is the one with a
# track record here, so it gets asserted rather than assumed.
LOCKFIX=$(mktemp)
cat > "$LOCKFIX" <<'FIXTURE'
# We removed the {1,2} interval here because awk support is not universal.
sub(d "([[:space:]]+--?[a-zA-Z].*)?$", "", chunk)   # was -{1,2}, see #1046
mode="${3:-last}"
FIXTURE
if [ -z "$(sed 's/#.*$//' "$LOCKFIX" | grep -nE '\{[0-9]+(,[0-9]*)?\}' || true)" ]; then
  PASS=$((PASS+1))
  echo "PASS: interval lock ignores intervals mentioned in full-line AND trailing comments"
else
  FAIL=$((FAIL+1))
  echo "FAIL: interval lock fires on prose describing an interval (me2resh/apexyard#1066 class)"
fi

printf 'x = 1\nsub(s, "-{1,2}[a-z]", "")\n' > "$LOCKFIX"
LOCK_HIT=$(sed 's/#.*$//' "$LOCKFIX" | grep -nE '\{[0-9]+(,[0-9]*)?\}' || true)
if [ "${LOCK_HIT%%:*}" = "2" ]; then
  PASS=$((PASS+1))
  echo "PASS: interval lock catches a real interval and reports the correct line number"
else
  FAIL=$((FAIL+1))
  echo "FAIL: interval lock missed a real interval, or misreported its line (got '${LOCK_HIT:-nothing}', want line 2)"
fi
rm -f "$LOCKFIX"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
