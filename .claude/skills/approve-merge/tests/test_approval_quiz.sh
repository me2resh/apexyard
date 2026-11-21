#!/bin/bash
# test_approval_quiz.sh - offline quiz helpers for #1997.
#
# Covers:
#   1. Default-off: merge.approval_quiz is false; should-run prints no
#   2. --quiz turns the quiz on without a config change
#   3. Config true turns the quiz on without --quiz
#   4. Fixture pack names files and lines from the sample PR diff
#   5. sample-questions cite file:line and stay inside the pack
#   6. Wrong-answer path: show-lines prints the packed line
#   7. SKILL.md keeps disable-model-invocation: true and runs quiz before marker write
#   8. Without --quiz and default-off, the skill does not require the quiz
#
# No network. Exit 0 on pass.

set -u

# Isolate from live Claude Code session pin/cache.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/../../../hooks/tests/_test-session-isolation.sh" 2>/dev/null || true

SRC_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SCRIPT="$SRC_ROOT/.claude/skills/approve-merge/scripts/approval-quiz.sh"
SKILL_MD="$SRC_ROOT/.claude/skills/approve-merge/SKILL.md"
QUIZ_DOC="$SRC_ROOT/docs/skills/approval-quiz.md"
FIXTURE="$SRC_ROOT/.claude/skills/approve-merge/tests/fixtures/sample-pr"
DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"

PASS=0
FAIL=0
FAILED=""

mark_pass() { printf "  PASS: %s\n" "$1"; PASS=$((PASS+1)); }
mark_fail() { printf "  FAIL: %s: %s\n" "$1" "$2" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}\n  - $1"; }

make_sandbox() {
  local sb
  sb=$(mktemp -d)
  mkdir -p "$sb/.claude/hooks"
  touch "$sb/.apexyard-fork"
  cp "$SRC_ROOT/.claude/hooks/_lib-read-config.sh" "$sb/.claude/hooks/"
  cp "$SRC_ROOT/.claude/hooks/_lib-ops-root.sh" "$sb/.claude/hooks/" 2>/dev/null || true
  cp "$DEFAULTS" "$sb/.claude/project-config.defaults.json"
  echo "$sb"
}

[ -x "$SCRIPT" ] || chmod +x "$SCRIPT"

# --- 1. shipped default is false -------------------------------------------
got=$(jq -r '.merge.approval_quiz' "$DEFAULTS" 2>/dev/null)
if [ "$got" = "false" ]; then
  mark_pass "shipped default: merge.approval_quiz == false"
else
  mark_fail "shipped default" "want 'false', got '${got:-<missing>}'"
fi

sb=$(make_sandbox)
got=$(bash "$SCRIPT" should-run "$sb")
rm -rf "$sb"
if [ "$got" = "no" ]; then
  mark_pass "should-run: default-off prints no"
else
  mark_fail "should-run default-off" "want 'no', got '$got'"
fi

# --- 2. --quiz forces yes --------------------------------------------------
sb=$(make_sandbox)
got=$(bash "$SCRIPT" should-run "$sb" --quiz)
rm -rf "$sb"
if [ "$got" = "yes" ]; then
  mark_pass "should-run: --quiz prints yes"
else
  mark_fail "should-run --quiz" "want 'yes', got '$got'"
fi

# --- 3. config true forces yes ---------------------------------------------
sb=$(make_sandbox)
printf '%s\n' '{"merge":{"approval_quiz":true}}' > "$sb/.claude/project-config.json"
got=$(bash "$SCRIPT" should-run "$sb")
rm -rf "$sb"
if [ "$got" = "yes" ]; then
  mark_pass "should-run: config true prints yes"
else
  mark_fail "should-run config" "want 'yes', got '$got'"
fi

# --- 4. fixture pack names files and lines ---------------------------------
PACK=$(mktemp)
if bash "$SCRIPT" pack "$FIXTURE/diff.patch" "$FIXTURE/body.md" > "$PACK"; then
  mark_pass "pack: runs on fixture PR"
else
  mark_fail "pack runs" "pack exited non-zero"
fi

if jq -e '.anchors | length >= 3' "$PACK" >/dev/null 2>&1; then
  mark_pass "pack: fixture yields at least 3 anchors"
else
  mark_fail "pack anchors" "want >=3 anchors"
fi

if jq -e '.anchors[] | select(.file=="hooks/greet.sh" and .line==3 and .text=="GREET_PREFIX=\"hello\"")' "$PACK" >/dev/null 2>&1; then
  mark_pass "pack: names hooks/greet.sh:3 from the fixture"
else
  mark_fail "pack file:line" "missing hooks/greet.sh:3 GREET_PREFIX"
fi

if jq -e --arg needle 'Comprehension check' '.body | contains($needle)' "$PACK" >/dev/null 2>&1; then
  mark_pass "pack: includes PR body text"
else
  mark_fail "pack body" "body missing glossary term"
fi

# --- 5. sample-questions cite file and line, stay in pack ------------------
QS=$(mktemp)
if bash "$SCRIPT" sample-questions "$PACK" > "$QS"; then
  mark_pass "sample-questions: runs on fixture pack"
else
  mark_fail "sample-questions runs" "exited non-zero"
fi

q_ok=1
while IFS= read -r row; do
  [ -n "$row" ] || continue
  qf=$(printf '%s' "$row" | jq -r '.file')
  ql=$(printf '%s' "$row" | jq -r '.line')
  qa=$(printf '%s' "$row" | jq -r '.answer')
  qq=$(printf '%s' "$row" | jq -r '.question')
  case "$qq" in
    *"$qf"*|*"line ${ql}"*|*"line $ql"*) ;;
    *) q_ok=0; mark_fail "question names file:line" "question='$qq'"; break ;;
  esac
  if ! jq -e --arg f "$qf" --argjson n "$ql" --arg t "$qa" \
    '.anchors[] | select(.file==$f and .line==$n and .text==$t)' "$PACK" >/dev/null; then
    q_ok=0
    mark_fail "question grounded" "answer not in pack for $qf:$ql"
    break
  fi
done <<EOF
$(jq -c '.[]' "$QS")
EOF
if [ "$q_ok" -eq 1 ]; then
  mark_pass "sample-questions: each question names file:line and stays in the pack"
fi

# --- 6. show-lines for wrong-answer path -----------------------------------
out=$(bash "$SCRIPT" show-lines "$PACK" "hooks/greet.sh" 3)
case "$out" in
  hooks/greet.sh:3:*GREET_PREFIX*) mark_pass "show-lines: prints packed line for wrong-answer path" ;;
  *) mark_fail "show-lines" "got '$out'" ;;
esac

# --- 7. SKILL.md contracts -------------------------------------------------
if grep -q '^disable-model-invocation: true$' "$SKILL_MD"; then
  mark_pass "SKILL.md keeps disable-model-invocation: true"
else
  mark_fail "disable-model-invocation" "frontmatter changed"
fi

if grep -qE '\-\-quiz' "$SKILL_MD" \
  && grep -qF 'Follow docs/skills/approval-quiz.md.' "$SKILL_MD" \
  && grep -qF 'approval-quiz.sh' "$QUIZ_DOC" \
  && grep -qF 'AskUserQuestion' "$QUIZ_DOC" \
  && grep -qF 'merge.approval_quiz' "$SKILL_MD"; then
  mark_pass "SKILL.md links quiz procedure; doc pins script and AskUserQuestion"
else
  mark_fail "SKILL.md quiz docs" "missing quiz contract markers"
fi

# Quiz step must appear before the CEO marker write section.
quiz_line=$(grep -n 'Optional comprehension quiz' "$SKILL_MD" | head -1 | cut -d: -f1)
marker_line=$(grep -n 'Write the structured CEO marker' "$SKILL_MD" | head -1 | cut -d: -f1)
if [ -n "$quiz_line" ] && [ -n "$marker_line" ] && [ "$quiz_line" -lt "$marker_line" ]; then
  mark_pass "SKILL.md: quiz step is before the marker write"
else
  mark_fail "quiz before marker" "quiz_line=$quiz_line marker_line=$marker_line"
fi

# --- 8. default path does not force the quiz -------------------------------
# Without --quiz and with default-off, should-run is no - already covered.
# Also require the skill to say the quiz never blocks other modes.
if grep -qF 'never blocks a merge in any other mode' "$SKILL_MD" \
  || grep -qF 'does not run the quiz' "$SKILL_MD"; then
  mark_pass "SKILL.md: quiz stays opt-in for other modes"
else
  mark_fail "opt-in prose" "missing default-off / never-blocks wording"
fi

rm -f "$PACK" "$QS"

# Claude Code fills in $ARGUMENTS only in SKILL.md. The --quiz flag must be
# read there; the procedure doc must reuse QUIZ_FLAG and never read $ARGUMENTS.
# shellcheck disable=SC2016  # $ARGUMENTS is literal text to find, not to expand.
if grep -Fq 'case " $ARGUMENTS " in *" --quiz "*) QUIZ_FLAG="--quiz"' "$SKILL_MD"; then
  mark_pass "SKILL.md reads the --quiz flag from \$ARGUMENTS"
else
  mark_fail "SKILL.md reads the --quiz flag from \$ARGUMENTS" "flag read missing from SKILL.md"
fi
# shellcheck disable=SC2016  # literal text, as above.
if grep -v 'must not read it' "$QUIZ_DOC" | grep -Fq '$ARGUMENTS'; then
  mark_fail "procedure doc does not read \$ARGUMENTS" "docs/skills/approval-quiz.md reads \$ARGUMENTS"
else
  mark_pass "procedure doc does not read \$ARGUMENTS"
fi

echo
echo "===== test_approval_quiz.sh ====="
printf "Passed: %s\n" "$PASS"
printf "Failed: %s\n" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf "Failed cases:%b\n" "$FAILED"
  exit 1
fi
exit 0
