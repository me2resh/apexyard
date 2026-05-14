#!/bin/bash
# Test fixtures for validate-issue-structure.sh.
#
# Each case builds a JSON tool_input payload, pipes it to the hook, then
# asserts on exit code and (optionally) a stderr substring. Same shape as
# test_block_private_refs.sh — bash + jq + grep, no framework.
#
# Run:
#   ./.claude/hooks/tests/test_validate_issue_structure.sh
#
# Exit 0 = all pass, exit 1 = at least one failure.

set -u

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOK="$REPO_ROOT/.claude/hooks/validate-issue-structure.sh"

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook not found or not executable at $HOOK" >&2
  exit 1
fi

PASS=0
FAIL=0

# An isolated fake fork with defaults copied in so the hook's config reader
# walks up to THIS root, not the real repo's. Running against the real repo
# would also work (the real defaults match), but a fixture keeps the test
# self-contained and immune to upstream changes.
TMPDIR=$(mktemp -d -t validate-issue-structure.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/fork/.claude/hooks" "$TMPDIR/fork/subdir"
cat > "$TMPDIR/fork/onboarding.yaml" <<'YAML'
company: test
YAML
# Seed the fake fork with git metadata so `git rev-parse --show-toplevel`
# resolves to the fixture, not the real repo.
( cd "$TMPDIR/fork" && git init -q && git config user.email t@t && git config user.name t && git add -f onboarding.yaml && git commit -q -m init ) >/dev/null 2>&1

# Copy the real defaults + lib so the hook reads real schema.
cp "$REPO_ROOT/.claude/project-config.defaults.json" "$TMPDIR/fork/.claude/project-config.defaults.json"
cp "$REPO_ROOT/.claude/hooks/_lib-read-config.sh" "$TMPDIR/fork/.claude/hooks/_lib-read-config.sh"

# Build a JSON tool_input payload.
make_payload() {
  local cmd="$1"
  jq -n --arg c "$cmd" '{tool_input: {command: $c}}'
}

# $1 = test name, $2 = expected exit code, $3 = stderr substring ('' to skip),
# $4 = bash command string.
run_case() {
  local name="$1"
  local expected_exit="$2"
  local expected_stderr_substr="$3"
  local cmd="$4"

  local stderr_file
  stderr_file=$(mktemp)

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

# --- Feature: pass path ----------------------------------------------------
FEATURE_OK_BODY='## User Story
As a user I want to log in so that I can access my account.

## Acceptance Criteria
- [ ] login form present
- [ ] error on bad creds'

run_case "Feature with User Story + Acceptance Criteria → pass" \
  0 "" \
  "gh issue create --title '[Feature] add login' --body \"$FEATURE_OK_BODY\""

# --- Feature: fail path — missing Acceptance Criteria ----------------------
FEATURE_BAD_BODY='## User Story
As a user I want login.'

run_case "Feature missing Acceptance Criteria → block" \
  2 "missing section: ## Acceptance Criteria" \
  "gh issue create --title '[Feature] add login' --body \"$FEATURE_BAD_BODY\""

# --- Chore: pass path ------------------------------------------------------
CHORE_OK_BODY='## Driver
Replace hardcoded config with project-config.

## Scope
- update hook
- update defaults

## Acceptance Criteria
- [ ] hook reads config'

run_case "Chore with all three sections → pass" \
  0 "" \
  "gh issue create --title '[Chore] config-driven hook' --body \"$CHORE_OK_BODY\""

# --- Chore: fail path — missing Scope --------------------------------------
CHORE_BAD_BODY='## Driver
Just the driver.

## Acceptance Criteria
- [ ] done'

run_case "Chore missing Scope → block" \
  2 "missing section: ## Scope" \
  "gh issue create --title '[Chore] refactor X' --body \"$CHORE_BAD_BODY\""

# --- Bug: pass path (canonical Given / When / Then heading) ----------------
BUG_OK_BODY='## Given / When / Then
Given a logged-in user
When they click logout
Then the session ends

## Repro
1. login
2. click logout
3. session cookie still present'

run_case "Bug with Given / When / Then + Repro → pass" \
  0 "" \
  "gh issue create --title '[Bug] logout not clearing session' --body \"$BUG_OK_BODY\""

# --- Bug: heading variant — no spaces around slashes -----------------------
BUG_OK_COMPACT='## Given/When/Then
Given X
When Y
Then Z

## Repro
1. do X'

run_case "Bug with Given/When/Then compact heading → pass" \
  0 "" \
  "gh issue create --title '[Bug] compact heading' --body \"$BUG_OK_COMPACT\""

# --- Bug: fail path — missing Repro ----------------------------------------
BUG_BAD_BODY='## Given / When / Then
Given X, When Y, Then Z.'

run_case "Bug missing Repro → block" \
  2 "missing section: ## Repro" \
  "gh issue create --title '[Bug] oops' --body \"$BUG_BAD_BODY\""

# --- Empty section check ---------------------------------------------------
EMPTY_SECTION_BODY='## User Story

## Acceptance Criteria
- [ ] something'

run_case "Feature with empty User Story section → block" \
  2 "empty section: ## User Story" \
  "gh issue create --title '[Feature] empty header' --body \"$EMPTY_SECTION_BODY\""

# --- Skip marker bypasses every check --------------------------------------
SKIP_BODY='free-form epic body, no required sections.
<!-- validate-issue-structure: skip -->'

run_case "skip marker bypasses validation" \
  0 "validate-issue-structure bypassed" \
  "gh issue create --title '[Feature] epic meta-thread' --body \"$SKIP_BODY\""

# --- Unknown prefix --------------------------------------------------------
run_case "unknown title prefix → block" \
  2 "unrecognised prefix" \
  "gh issue create --title '[Spike] explore X' --body 'whatever'"

# --- No bracketed prefix → silent pass (not every issue uses [Foo]) --------
run_case "title without bracketed prefix → pass" \
  0 "" \
  "gh issue create --title 'just a note' --body 'some content'"

# --- Non-gh command → silent pass ------------------------------------------
run_case "non gh-issue-create command → no-op" \
  0 "" \
  "echo hello"

# --- No body (gh opens editor) → silent pass -------------------------------
run_case "gh issue create with no body → no-op" \
  0 "" \
  "gh issue create --title '[Feature] interactive'"

# --- Docs prefix -----------------------------------------------------------
DOCS_OK='## Driver
The docs are stale.

## Acceptance Criteria
- [ ] update README'

run_case "Docs with Driver + Acceptance Criteria → pass" \
  0 "" \
  "gh issue create --title '[Docs] refresh README' --body \"$DOCS_OK\""

# --- body-file path support ------------------------------------------------
BODY_FILE_PATH="$TMPDIR/body.md"
cat > "$BODY_FILE_PATH" <<'EOF'
## User Story
As a user I want Y.

## Acceptance Criteria
- [ ] X
EOF

run_case "--body-file path with valid Feature body → pass" \
  0 "" \
  "gh issue create --title '[Feature] X' --body-file $BODY_FILE_PATH"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
