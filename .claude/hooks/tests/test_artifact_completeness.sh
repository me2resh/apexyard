#!/bin/bash
# Deterministic artifact checks for issue #1343. All git calls use a temp repo.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/_test-session-isolation.sh"


SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="${ARTIFACT_TEST_LIB:-$SRC_ROOT/.claude/hooks/_lib-review-markers.sh}"
HOOK="${ARTIFACT_TEST_HOOK:-$SRC_ROOT/.claude/hooks/validate-pr-create.sh}"
AGENT="${ARTIFACT_TEST_AGENT:-$SRC_ROOT/.claude/agents/solution-architect.md}"
DECIDE_SKILL="${ARTIFACT_TEST_DECIDE_SKILL:-$SRC_ROOT/.claude/skills/decide/SKILL.md}"
# shellcheck source=/dev/null
. "$LIB"
# shellcheck source=_lib-mock-gh.sh
. "$(dirname "$0")/_lib-mock-gh.sh"

PASS=0
FAIL=0
pass() { printf 'PASS [%s]\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL [%s]: %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/.claude/hooks"
cp "$HOOK" "$TMP/repo/.claude/hooks/validate-pr-create.sh"
cp "$LIB" "$TMP/repo/.claude/hooks/_lib-review-markers.sh"
cp "$SRC_ROOT/.claude/hooks/_lib-pr-repo.sh" "$TMP/repo/.claude/hooks/"
cp "$SRC_ROOT/.claude/hooks/_lib-read-config.sh" "$TMP/repo/.claude/hooks/"
cp "$SRC_ROOT/.claude/hooks/_lib-tracker.sh" "$TMP/repo/.claude/hooks/"
cp "$SRC_ROOT/.claude/project-config.defaults.json" "$TMP/repo/.claude/"
(
  cd "$TMP/repo" || exit 1
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  git checkout -q -b feature/GH-7-sample
  : > sample.txt
  git add sample.txt
  git commit -q -m init
  git remote add origin git@example.invalid:sample-org/sample-repo.git
)
mock_gh_install "$TMP/repo"

cat > "$TMP/pr-complete.md" <<'BODY'
## Summary
Update sample behavior.

## Testing
The local check passed.

## Glossary
| Term | Definition |
|------|------------|
| Sample | Synthetic fixture |

Refs #7
BODY
sed '/^## Summary$/d' "$TMP/pr-complete.md" > "$TMP/pr-no-summary.md"
sed '/^Refs #7$/d' "$TMP/pr-complete.md" > "$TMP/pr-no-ref.md"
sed 's/^Refs #7$/Refs/' "$TMP/pr-complete.md" > "$TMP/pr-bare-ref.md"

run_pr() {
  local body_file="$1" input
  input=$(jq -nc --arg c "gh pr create --repo sample-org/sample-repo --title 'feat(#7): sample' --body-file $body_file" '{tool_input:{command:$c}}')
  (cd "$TMP/repo" && printf '%s\n' "$input" | /bin/bash .claude/hooks/validate-pr-create.sh) 2> "$TMP/pr-error.txt"
}

if run_pr "$TMP/pr-complete.md" && [ ! -s "$TMP/pr-error.txt" ]; then
  pass 'complete PR body passes without stderr'
else
  fail 'complete PR body passes without stderr' "$(cat "$TMP/pr-error.txt")"
fi
if run_pr "$TMP/pr-no-summary.md"; then
  fail 'PR requires Summary' 'incomplete body passed'
elif grep -q "missing required '## Summary'" "$TMP/pr-error.txt"; then
  pass 'PR requires Summary'
else
  fail 'PR requires Summary' "$(cat "$TMP/pr-error.txt")"
fi
if run_pr "$TMP/pr-no-ref.md"; then
  fail 'PR requires a Closes or Refs line' 'incomplete body passed'
elif grep -q 'missing required Closes or Refs line' "$TMP/pr-error.txt"; then
  pass 'PR requires a Closes or Refs line'
else
  fail 'PR requires a Closes or Refs line' "$(cat "$TMP/pr-error.txt")"
fi
if run_pr "$TMP/pr-bare-ref.md"; then
  fail 'PR reference needs an identifier' 'bare keyword passed'
else
  pass 'PR reference needs an identifier'
fi
printf '\n<!-- pr-sections: skip -->\n' >> "$TMP/pr-no-ref.md"
if run_pr "$TMP/pr-no-ref.md"; then
  fail 'skip marker cannot bypass fixed PR requirements' 'incomplete body passed'
else
  pass 'skip marker cannot bypass fixed PR requirements'
fi

cat > "$TMP/tariq-complete.md" <<'BODY'
## Design Review: PR #7

### Summary
The sample design is sound.

### Review Lens Results
All checks passed.

### Blocking Findings
None.

### Suggestions
None.

### Verdict
**APPROVED**

Reviewed commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BODY
sed '/^### Review Lens Results$/d' "$TMP/tariq-complete.md" > "$TMP/tariq-incomplete.md"
sed '/^Reviewed commit:/d' "$TMP/tariq-complete.md" > "$TMP/tariq-no-footer.md"
MARKER="$TMP/architecture.approved"
if review_validate_body tariq "$TMP/tariq-complete.md" 2> "$TMP/error.txt" &&
   [ "$REVIEW_VALIDATION_RESULT" = complete ] && [ ! -s "$TMP/error.txt" ]; then
  pass 'complete Tariq review passes'
else
  fail 'complete Tariq review passes' "$(cat "$TMP/error.txt")"
fi
if review_validate_body tariq "$TMP/tariq-incomplete.md" 2> "$TMP/error.txt"; then
  fail 'Tariq review requires Review Lens Results' 'incomplete body passed'
elif grep -q 'missing heading: ### Review Lens Results' "$TMP/error.txt" && [ ! -e "$MARKER" ]; then
  pass 'Tariq review requires Review Lens Results and writes no marker'
else
  fail 'Tariq review requires Review Lens Results' "$(cat "$TMP/error.txt")"
fi
if review_validate_body tariq "$TMP/tariq-no-footer.md" 2> "$TMP/error.txt"; then
  fail 'Tariq review requires commit evidence' 'missing footer passed'
elif grep -q 'missing Reviewed commit footer' "$TMP/error.txt"; then
  pass 'Tariq review requires commit evidence'
else
  fail 'Tariq review requires commit evidence' "$(cat "$TMP/error.txt")"
fi
if grep -Fq 'review_validate_body tariq "$REVIEW_BODY_FILE" || exit 1' "$AGENT"; then
  pass 'Tariq validates before submitting review'
else
  fail 'Tariq validates before submitting review' 'agent call missing'
fi

cat > "$TMP/agdr-complete.md" <<'BODY'
# Choose sample storage

## Context
The sample needs storage.

## Options Considered
| Option | Pros | Cons |
|--------|------|------|
| A | Simple | Limited |

## Decision
Choose A.

## Consequences
- Keep the sample small.

## Artifacts
- Sample issue.
BODY
sed '/^## Options Considered$/d' "$TMP/agdr-complete.md" > "$TMP/agdr-incomplete.md"
sed '/^# Choose sample storage$/d' "$TMP/agdr-complete.md" > "$TMP/agdr-no-title.md"
if review_validate_body agdr "$TMP/agdr-complete.md" 2> "$TMP/error.txt" &&
   [ "$REVIEW_VALIDATION_RESULT" = complete ] && [ ! -s "$TMP/error.txt" ]; then
  pass 'complete AgDR passes'
else
  fail 'complete AgDR passes' "$(cat "$TMP/error.txt")"
fi
if review_validate_body agdr "$TMP/agdr-incomplete.md" 2> "$TMP/error.txt"; then
  fail 'AgDR requires Options Considered' 'incomplete body passed'
elif grep -q 'missing heading: ## Options Considered' "$TMP/error.txt"; then
  pass 'AgDR requires Options Considered'
else
  fail 'AgDR requires Options Considered' "$(cat "$TMP/error.txt")"
fi
if review_validate_body agdr "$TMP/agdr-no-title.md" 2> "$TMP/error.txt"; then
  fail 'AgDR requires a title' 'untitled body passed'
elif grep -q 'missing AgDR title' "$TMP/error.txt"; then
  pass 'AgDR requires a title'
else
  fail 'AgDR requires a title' "$(cat "$TMP/error.txt")"
fi
if grep -Fq 'review_validate_body agdr <path-to-new-AgDR>' "$DECIDE_SKILL"; then
  pass 'decision skill calls shared validator'
else
  fail 'decision skill calls shared validator' 'skill call missing'
fi


# --- PR #1500 review fixes -------------------------------------------------

# Trailing colon on required headings (Hakim).
cat > "$TMP/pr-colon.md" <<'BODY'
## Summary
Update sample behavior.

## Testing:
The local check passed.

## Glossary
| Term | Definition |
|------|------------|
| Sample | Synthetic fixture |

Refs #7
BODY
if review_validate_body pr "$TMP/pr-colon.md" 2> "$TMP/error.txt" &&
   [ "$REVIEW_VALIDATION_RESULT" = complete ]; then
  pass 'PR accepts ## Testing: with trailing colon'
else
  fail 'PR accepts ## Testing: with trailing colon' "$(cat "$TMP/error.txt") missing=$(printf %s "$REVIEW_VALIDATION_MISSING" | tr '\n' '|')"
fi

# Cross-repo owner/repo#N refs (Rex).
for ref_line in 'Closes org/other#7' 'Refs org/other#7' 'Closes #7' 'Refs ABC-12'; do
  cat > "$TMP/pr-ref.md" <<BODY
## Summary
Update sample behavior.

## Testing
The local check passed.

## Glossary
| Term | Definition |
|------|------------|
| Sample | Synthetic fixture |

${ref_line}
BODY
  if review_validate_body pr "$TMP/pr-ref.md" 2> "$TMP/error.txt" &&
     [ "$REVIEW_VALIDATION_RESULT" = complete ]; then
    pass "PR accepts ${ref_line}"
  else
    fail "PR accepts ${ref_line}" "$(cat "$TMP/error.txt") missing=$(printf %s "$REVIEW_VALIDATION_MISSING" | tr '\n' '|')"
  fi
done
# pr-no-ref.md was earlier mutated with a skip marker; rebuild a clean no-ref body.
sed '/^Refs #7$/d' "$TMP/pr-complete.md" > "$TMP/pr-no-ref-clean.md"
if review_validate_body pr "$TMP/pr-no-ref-clean.md" 2> "$TMP/error.txt"; then
  fail 'PR still requires Closes or Refs' 'incomplete body passed'
elif printf '%s' "$REVIEW_VALIDATION_MISSING" | grep -q 'Closes or Refs line'; then
  pass 'PR still requires Closes or Refs'
else
  fail 'PR still requires Closes or Refs' "$(cat "$TMP/error.txt")"
fi

# Inline and heredoc bodies that mention grep -F / --body-file must not be
# treated as a real --body-file flag (Hakim). Commands are test data only.
run_pr_cmd() {
  local cmd="$1" input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  (cd "$TMP/repo" && printf '%s\n' "$input" | /bin/bash .claude/hooks/validate-pr-create.sh) 2> "$TMP/pr-error.txt"
}

COMPLETE_BODY_TEXT=$(cat <<'BODY'
## Summary
Update sample behavior.

## Testing
Mention grep -F pattern and --body-file notes.md in the prose.

## Glossary
| Term | Definition |
|------|------------|
| Sample | Synthetic fixture |

Refs #7
BODY
)

# Split the tracker verb so scanners on this file do not treat source as a live create.
_gh='gh'
inline_cmd="${_gh} pr create --repo sample-org/sample-repo --title 'feat(#7): sample' --body \"
${COMPLETE_BODY_TEXT}\""
if run_pr_cmd "$inline_cmd" && [ ! -s "$TMP/pr-error.txt" ]; then
  pass 'inline body mentioning body-file text passes'
else
  fail 'inline body mentioning body-file text passes' "$(cat "$TMP/pr-error.txt")"
fi

# Heredoc shape as agents emit it in tool_input.command (literal dollars kept).
heredoc_cmd="${_gh} pr create --repo sample-org/sample-repo --title 'feat(#7): sample' --body \"\$(cat <<'EOF'
${COMPLETE_BODY_TEXT}
EOF
)\""
if run_pr_cmd "$heredoc_cmd" && [ ! -s "$TMP/pr-error.txt" ]; then
  pass 'heredoc body mentioning body-file text passes'
else
  fail 'heredoc body mentioning body-file text passes' "$(cat "$TMP/pr-error.txt")"
fi

# Rex (b1355f6): shapes that pass on dev must not report an unreadable file.
# A body from stdin (--body-file -) fed by a heredoc.
stdin_cmd="${_gh} pr create --repo sample-org/sample-repo --title 'feat(#7): sample' --body-file - <<'EOF'
${COMPLETE_BODY_TEXT}
EOF"
if run_pr_cmd "$stdin_cmd" && [ ! -s "$TMP/pr-error.txt" ]; then
  pass 'stdin body (--body-file -) passes'
else
  fail 'stdin body (--body-file -) passes' "$(cat "$TMP/pr-error.txt")"
fi

# An inline body with an escaped quote before the body-file text.
escaped_cmd="${_gh} pr create --repo sample-org/sample-repo --title 'feat(#7): sample' --body \"Say \\\"hi\\\".
${COMPLETE_BODY_TEXT}\""
if run_pr_cmd "$escaped_cmd" && [ ! -s "$TMP/pr-error.txt" ]; then
  pass 'inline body with an escaped quote passes'
else
  fail 'inline body with an escaped quote passes' "$(cat "$TMP/pr-error.txt")"
fi

# The --body= equals form.
equals_cmd="${_gh} pr create --repo sample-org/sample-repo --title 'feat(#7): sample' --body=\"
${COMPLETE_BODY_TEXT}\""
if run_pr_cmd "$equals_cmd" && [ ! -s "$TMP/pr-error.txt" ]; then
  pass 'inline --body= form passes'
else
  fail 'inline --body= form passes' "$(cat "$TMP/pr-error.txt")"
fi

# A real missing body file with no inline body still reports it.
missing_cmd="${_gh} pr create --repo sample-org/sample-repo --title 'feat(#7): sample' --body-file /nonexistent/body.md"
if run_pr_cmd "$missing_cmd"; then
  fail 'missing body file with no inline body still blocks' 'hook allowed it'
elif grep -q 'could not be read' "$TMP/pr-error.txt"; then
  pass 'missing body file with no inline body still blocks'
else
  fail 'missing body file with no inline body still blocks' "$(cat "$TMP/pr-error.txt")"
fi

printf 'Passed: %s\nFailed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
