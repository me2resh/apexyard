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
#
# Runs the hook inside an isolated SANDBOX, not against the ambient checkout.
#
# Two earlier attempts failed, and the second failed in an instructive way.
# The first ran in the repo's own working directory and asserted on the exit
# code: passed locally, failed 3/22 in CI. The second asserted on stderr
# instead — and failed VACUOUSLY. validate-pr-create.sh exits on the
# ticket-existence check (~line 447) well before the --body-file logic
# (~line 502), so in CI the hook never reached the code under test, and every
# "this message is absent" assertion passed because nothing ran at all.
#
# The fix is the pattern test_validate_pr_required_sections.sh already uses
# and which passes in CI: a `git init` sandbox on a CONFORMING branch, plus
# the shared gh mock (_lib-mock-gh.sh) so the ticket check resolves against
# synthetic OPEN data rather than the network. Only then does execution reach
# the body-file parsing this PR changes.
#
# Asserting rc == 0 for a complete body is what makes these non-vacuous:
# rc 0 is reachable ONLY if the hook opened the file and found its sections.
# ---------------------------------------------------------------------------

# shellcheck source=/dev/null
. "$(dirname "$0")/_lib-mock-gh.sh"

SRC_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)

make_sandbox() {
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git checkout -q -b chore/GH-113-test 2>/dev/null || git checkout -q -B chore/GH-113-test
    touch onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "chore: seed the sandbox"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$PRC_HOOK" "$sb/.claude/hooks/validate-pr-create.sh"
  chmod +x "$sb/.claude/hooks/validate-pr-create.sh"
  cp "$SRC_ROOT/.claude/hooks/_lib-read-config.sh" "$sb/.claude/hooks/_lib-read-config.sh"
  [ -f "$SRC_ROOT/.claude/hooks/_lib-tracker.sh" ] && \
    cp "$SRC_ROOT/.claude/hooks/_lib-tracker.sh" "$sb/.claude/hooks/_lib-tracker.sh"
  [ -f "$SRC_ROOT/.claude/hooks/_lib-pr-repo.sh" ] && \
    cp "$SRC_ROOT/.claude/hooks/_lib-pr-repo.sh" "$sb/.claude/hooks/_lib-pr-repo.sh"
  cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  mock_gh_install "$sb"
  echo "$sb"
}

# run_prc BODY QUOTING -> "<rc>|<stderr>"   QUOTING: bare | double | single
run_prc() {
  local body_content="$1" quoting="$2" sb body_file cmd rc err
  sb=$(make_sandbox)
  body_file="$sb/body.md"
  printf '%s' "$body_content" > "$body_file"
  case "$quoting" in
    double) cmd="gh pr create --repo me2resh/apexyard --title 'chore(#113): test' --body-file \"$body_file\"" ;;
    single) cmd="gh pr create --repo me2resh/apexyard --title 'chore(#113): test' --body-file '$body_file'" ;;
    *)      cmd="gh pr create --repo me2resh/apexyard --title 'chore(#113): test' --body-file $body_file" ;;
  esac
  # EXPORT the mock onto PATH for the whole subshell. `PATH=... jq ...` would
  # scope it to jq alone, leaving the hook to find the real gh — which then
  # answers from the live tracker and reports #113 as CLOSED, exactly the
  # network dependency the mock exists to remove.
  err=$(cd "$sb" && export PATH="$sb/bin:$PATH" && \
        jq -nc --arg c "$cmd" '{tool_input:{command:$c}}' \
        | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
  rc=$?
  rm -rf "$sb"
  printf '%s|%s' "$rc" "$err"
}

FULL_BODY='## Summary

- Does a thing, and here is why it matters.

## Testing

- Ran the suite.

## Glossary

| Term | Definition |
|------|------------|
| thing | a thing |
'

THIN_BODY='## Summary

- only a summary
'

check_prc() {
  local name="$1" want_rc="$2" absent="$3" body="$4" quoting="$5" out rc err
  out=$(run_prc "$body" "$quoting")
  rc=${out%%|*}
  err=${out#*|}
  if [ "$rc" != "$want_rc" ]; then
    echo "FAIL: $name — expected rc=$want_rc, got $rc"
    echo "   stderr: $(printf '%s' "$err" | head -2)"
    FAIL=$((FAIL + 1)); return
  fi
  if [ -n "$absent" ]; then
    case "$err" in
      *"$absent"*)
        echo "FAIL: $name — stderr still reports [$absent]"
        echo "   stderr: $(printf '%s' "$err" | head -2)"
        FAIL=$((FAIL + 1)); return ;;
    esac
  fi
  echo "PASS: $name"
  PASS=$((PASS + 1))
}

# A complete body must PASS whatever the quoting. rc 0 is reachable only if
# the hook opened the file and found its sections, so these cannot pass
# vacuously the way the earlier stderr-only assertions could.
check_prc "validate-pr-create: unquoted path, complete body -> rc 0" \
  0 "not readable" "$FULL_BODY" bare
check_prc "validate-pr-create: QUOTED path, complete body -> rc 0 (#1038)" \
  0 "not readable" "$FULL_BODY" double
check_prc "validate-pr-create: single-quoted path, complete body -> rc 0 (#1038)" \
  0 "not readable" "$FULL_BODY" single

# Regression: a body genuinely missing its sections still blocks, quoted or
# not — so the passes above reflect real extraction, not permissiveness.
check_prc "validate-pr-create: thin body still blocked (unquoted)" \
  2 "" "$THIN_BODY" bare
check_prc "validate-pr-create: thin body still blocked (quoted)" \
  2 "" "$THIN_BODY" double

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
