#!/bin/bash
# me2resh/apexyard#1038 — --body-file flag extraction across the PR-create hooks.
#
# Both hooks recover a flag's value from the RAW command text a PreToolUse
# hook receives. Two defects made them mis-parse ordinary command shapes:
#
#   1. require-agdr-for-arch-pr.sh — extract_flag_value's quoted branches
#      anchored only on `--<letter>` or end-of-string. A quoted value
#      followed by a shell operator or a single-dash flag missed those
#      branches, fell through to the unquoted branch (which has no anchor),
#      and returned the token WITH its quotes attached.
#
#   2. validate-pr-create.sh — its `[^[:space:]]+` sed token grab is
#      quote-blind, so a quoted path came back as `"/p/body.md"`.
#
# In both cases `[ -f "\"/p/body.md\"" ]` is false, so the file is never
# read. The consequences differ by hook:
#
#   - require-agdr-for-arch-pr.sh: the `<!-- agdr: not-applicable -->`
#     marker inside the body file is never seen → PR blocked for a missing
#     AgDR that was in fact declared.
#   - validate-pr-create.sh: `## Testing` / `## Glossary` are reported
#     missing when both are present.
#
# Both fail CLOSED, so these are false positives rather than a security
# hole — but the error messages point at the PR author instead of at the
# parser, which is what makes them expensive. The SAME extractor defect in
# block-private-refs-in-public-repos.sh fails OPEN (silent leak) and is
# covered separately by test_block_private_refs.sh (#1039).
#
# Note the failing combination is specifically QUOTED value + non-`--flag`
# follower. An unquoted path with a trailing pipe always extracted fine —
# which is why this went unnoticed.
#
# Exit 0 = all pass, exit 1 = at least one failure.

set -u

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
AGDR_HOOK="$REPO_ROOT/.claude/hooks/require-agdr-for-arch-pr.sh"
PRC_HOOK="$REPO_ROOT/.claude/hooks/validate-pr-create.sh"

for h in "$AGDR_HOOK" "$PRC_HOOK"; do
  if [ ! -f "$h" ]; then
    echo "FAIL: hook not found at $h" >&2
    exit 1
  fi
done

PASS=0
FAIL=0

TMPDIR=$(mktemp -d -t flag-extractor.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
# Part 1 — the two extractors, driven directly out of the hook source.
#
# Pulling the functions out rather than invoking the whole hook keeps these
# cases pinned to the parsing contract itself, independent of the diff
# inspection and git state the hook otherwise needs.
#
# There are TWO extractors on purpose, and the split is the fix:
#   extract_path_flag  — non-greedy, for --body-file (a path; no quotes in it)
#   extract_flag_value — greedy, for --title / --body (content; anything in it)
# ---------------------------------------------------------------------------

eval "$(awk '/^extract_flag_value\(\) \{/,/^\}/' "$AGDR_HOOK")"
eval "$(awk '/^extract_path_flag\(\) \{/,/^\}/' "$AGDR_HOOK")"

for fn in extract_flag_value extract_path_flag; do
  if ! command -v "$fn" >/dev/null 2>&1; then
    echo "FAIL: could not load $fn from $AGDR_HOOK" >&2
    exit 1
  fi
done

BODY_PATH="$TMPDIR/body.md"

check_extract() {
  local name="$1" expected="$2" cmd="$3" got
  got=$(extract_path_flag '--body-file' "$cmd")
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "   expected [$expected]"
    echo "   got      [$got]"
    FAIL=$((FAIL + 1))
  fi
}

# Content extraction must NOT be truncated by a boundary character. This is
# the guard against "fix the path case by widening the shared anchor" — that
# approach reopens the #227 leak, and in the sibling hook it measured WORSE
# than no fix at all (#1039). A --body carrying a quote followed by a shell
# operator must survive intact, tail included.
check_content() {
  local name="$1" needle="$2" cmd="$3" got
  got=$(extract_flag_value '--body|-b' "$cmd")
  case "$got" in
    *"$needle"*)
      echo "PASS: $name"
      PASS=$((PASS + 1)) ;;
    *)
      echo "FAIL: $name — content truncated before the tail"
      echo "   expected the value to contain [$needle]"
      echo "   got      [$got]"
      FAIL=$((FAIL + 1)) ;;
  esac
}

# Shapes that already worked — regression guards.
check_extract "extract: unquoted path, flag last" \
  "$BODY_PATH" "gh pr create --body-file $BODY_PATH"
check_extract "extract: unquoted path + trailing pipe" \
  "$BODY_PATH" "gh pr create --body-file $BODY_PATH 2>&1 | tail -5"
check_extract "extract: quoted path + following --flag" \
  "$BODY_PATH" "gh pr create --body-file \"$BODY_PATH\" --base dev"

# The #1038 shapes — each returned the token WITH quotes before the fix.
check_extract "extract: quoted path + pipe (#1038)" \
  "$BODY_PATH" "gh pr create --body-file \"$BODY_PATH\" 2>&1 | tail -5"
check_extract "extract: quoted path + single-dash flag (#1038)" \
  "$BODY_PATH" "gh pr create --body-file \"$BODY_PATH\" -t \"x\""
check_extract "extract: quoted path + redirect (#1038)" \
  "$BODY_PATH" "gh pr create --body-file \"$BODY_PATH\" > /dev/null"
check_extract "extract: quoted path + semicolon (#1038)" \
  "$BODY_PATH" "gh pr create --body-file \"$BODY_PATH\"; echo done"

# Content must survive a quote followed by each boundary character. These
# fail against the rejected "widen the shared anchor" approach, which is the
# whole point of keeping the two extractors separate.
for boundary in '|' ';' '&' '<' '>' '(' ')'; do
  check_content "content: quote then '$boundary' keeps the tail" \
    "TAIL_MARKER" \
    "gh pr create --title t --body \"The \\\"admin notice\\\" $boundary more text. TAIL_MARKER\""
done
check_content "content: quote then ' -t' keeps the tail" \
  "TAIL_MARKER" \
  "gh pr create --title t --body \"The \\\"admin notice\\\" -t more. TAIL_MARKER\""
check_content "content: markdown table row keeps the tail" \
  "TAIL_MARKER" \
  "gh pr create --title t --body \"| Term | Definition |
| \\\"thing\\\" | a thing |

TAIL_MARKER\""
check_extract "extract: single-quoted path + pipe (#1038)" \
  "$BODY_PATH" "gh pr create --body-file '$BODY_PATH' 2>&1 | tail -5"

# ---------------------------------------------------------------------------
# Part 2 — validate-pr-create.sh end-to-end, quoted vs unquoted path.
# ---------------------------------------------------------------------------

cat > "$TMPDIR/full-body.md" <<'MD'
## Summary

- Does a thing, and here is why it matters.

## Testing

- Ran the suite.

Refs #1038

## Glossary

| Term | Definition |
|------|------------|
| thing | a thing |
MD

# Deliberately missing ## Testing and ## Glossary.
printf '## Summary\n\n- only a summary\n' > "$TMPDIR/thin-body.md"

PR_CREATE="gh pr create --repo me2resh/apexyard --title \"fix(#1038): x\""

# Assert on STDERR CONTENT, not on the exit code.
#
# validate-pr-create.sh derives its exit code from several independent
# checks — branch name, ticket existence in the tracker (a network call),
# PR-title format — all of which read AMBIENT state. An earlier version of
# these cases asserted `exit 0`, which passed locally (conforming branch,
# resolvable ticket) and failed 3/22 in CI, where neither holds. A PR fixing
# false-positive hook failures cannot ship a test that itself false-fails.
#
# What is actually under test here is narrow: can the hook READ a quoted
# --body-file path? That is observable precisely, and independently of every
# ambient check, through two stderr signals:
#
#   "not readable"                  -> the path was mis-parsed (the #1038 bug)
#   "missing required '## Testing'" -> it read the file but not the content
#
# Neither appears when extraction works, whatever the exit code ends up
# being for unrelated reasons.
check_stderr_absent() {
  local name="$1" needle="$2" cmd="$3" err
  err=$( cd "$TMPDIR" && jq -n --arg c "$cmd" '{tool_input:{command:$c}}' | "$PRC_HOOK" 2>&1 >/dev/null )
  case "$err" in
    *"$needle"*)
      echo "FAIL: $name — stderr still reports [$needle]"
      echo "   stderr: $(printf '%s' "$err" | head -2)"
      FAIL=$((FAIL + 1)) ;;
    *)
      echo "PASS: $name"
      PASS=$((PASS + 1)) ;;
  esac
}

check_stderr_present() {
  local name="$1" needle="$2" cmd="$3" err
  err=$( cd "$TMPDIR" && jq -n --arg c "$cmd" '{tool_input:{command:$c}}' | "$PRC_HOOK" 2>&1 >/dev/null )
  case "$err" in
    *"$needle"*)
      echo "PASS: $name"
      PASS=$((PASS + 1)) ;;
    *)
      echo "FAIL: $name — expected stderr to report [$needle]"
      echo "   stderr: $(printf '%s' "$err" | head -2)"
      FAIL=$((FAIL + 1)) ;;
  esac
}

# The path must be READ — no "not readable" warning — however it is quoted.
check_stderr_absent "validate-pr-create: unquoted path is read" \
  "not readable" "$PR_CREATE --body-file $TMPDIR/full-body.md"
check_stderr_absent "validate-pr-create: QUOTED path is read (#1038)" \
  "not readable" "$PR_CREATE --body-file \"$TMPDIR/full-body.md\""
check_stderr_absent "validate-pr-create: single-quoted path is read (#1038)" \
  "not readable" "$PR_CREATE --body-file '$TMPDIR/full-body.md'"

# Having read it, the hook must SEE the sections — the pre-fix symptom was
# reporting them missing because the file was never opened.
check_stderr_absent "validate-pr-create: quoted path — sections found (#1038)" \
  "## Testing" "$PR_CREATE --body-file \"$TMPDIR/full-body.md\""

# Regression: the fix must not make the hook permissive. A body genuinely
# missing its sections is still reported, quoted or not — proving the
# absence assertions above are meaningful rather than vacuous.
check_stderr_present "validate-pr-create: thin body still reported (unquoted)" \
  "## Testing" "$PR_CREATE --body-file $TMPDIR/thin-body.md"
check_stderr_present "validate-pr-create: thin body still reported (quoted)" \
  "## Testing" "$PR_CREATE --body-file \"$TMPDIR/thin-body.md\""

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
