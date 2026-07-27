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
# Part 1 — extract_flag_value, driven directly out of the hook source.
#
# Pulling the function out rather than invoking the whole hook keeps these
# cases pinned to the parsing contract itself, independent of the diff
# inspection and git state the hook otherwise needs.
# ---------------------------------------------------------------------------

eval "$(awk '/^extract_flag_value\(\) \{/,/^\}/' "$AGDR_HOOK")"

if ! command -v extract_flag_value >/dev/null 2>&1; then
  echo "FAIL: could not load extract_flag_value from $AGDR_HOOK" >&2
  exit 1
fi

BODY_PATH="$TMPDIR/body.md"

check_extract() {
  local name="$1" expected="$2" cmd="$3" got
  got=$(extract_flag_value '--body-file' "$cmd")
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

check_hook() {
  local name="$1" expected_exit="$2" cmd="$3" actual
  ( cd "$TMPDIR" && jq -n --arg c "$cmd" '{tool_input:{command:$c}}' | "$PRC_HOOK" ) >/dev/null 2>&1
  actual=$?
  if [ "$actual" = "$expected_exit" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name — expected exit $expected_exit, got $actual"
    FAIL=$((FAIL + 1))
  fi
}

check_hook "validate-pr-create: unquoted path, complete body → pass" \
  0 "$PR_CREATE --body-file $TMPDIR/full-body.md"
check_hook "validate-pr-create: QUOTED path, complete body → pass (#1038)" \
  0 "$PR_CREATE --body-file \"$TMPDIR/full-body.md\""
check_hook "validate-pr-create: single-quoted path, complete body → pass (#1038)" \
  0 "$PR_CREATE --body-file '$TMPDIR/full-body.md'"

# Regression: the fix must not make the hook permissive. A body genuinely
# missing required sections still blocks, whether the path is quoted or not.
check_hook "validate-pr-create: thin body still blocked (unquoted)" \
  2 "$PR_CREATE --body-file $TMPDIR/thin-body.md"
check_hook "validate-pr-create: thin body still blocked (quoted)" \
  2 "$PR_CREATE --body-file \"$TMPDIR/thin-body.md\""

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
