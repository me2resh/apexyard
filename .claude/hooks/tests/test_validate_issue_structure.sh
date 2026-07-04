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
  "gh issue create --title '[Epic] big rollup' --body 'whatever'"

# --- Spike: pass path (apexyard#180) ---------------------------------------
SPIKE_OK_BODY='## Hypothesis
We believe library X handles 10k events/sec. We will know we are right
when a 10-minute soak test sustains 10k/s without backpressure.

## Budget
2 days of one engineer.

## Kill Criteria
- Library X has no TypeScript types — kill, too much yak-shave for a spike.
- 10k/s causes >50ms p95 latency in the first hour — kill, prove the bottleneck elsewhere.

## Disposition
PROMOTE — if the soak test passes, file a [Feature] for production-shaped
delivery with retry / observability / failover.'

run_case "Spike with all four required sections → pass" \
  0 "" \
  "gh issue create --title '[Spike] library X throughput' --body \"$SPIKE_OK_BODY\""

# --- Spike: fail path — missing Disposition --------------------------------
SPIKE_BAD_BODY='## Hypothesis
We believe X.

## Budget
2 days.

## Kill Criteria
- something'

run_case "Spike missing Disposition → block (suggests /spike)" \
  2 "missing section: ## Disposition" \
  "gh issue create --title '[Spike] explore Y' --body \"$SPIKE_BAD_BODY\""

run_case "Spike missing Disposition → block names /spike skill" \
  2 "/spike" \
  "gh issue create --title '[Spike] explore Z' --body \"$SPIKE_BAD_BODY\""

# --- Spike: fail path — missing Hypothesis ---------------------------------
SPIKE_NO_HYPOTHESIS='## Budget
3 days.

## Kill Criteria
- nothing.

## Disposition
DISCARD if no answer in 3 days.'

run_case "Spike missing Hypothesis → block" \
  2 "missing section: ## Hypothesis" \
  "gh issue create --title '[Spike] no hypothesis' --body \"$SPIKE_NO_HYPOTHESIS\""

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

# --- body-file: skip marker honoured (me2resh/apexyard#695) -----------------
# An off-template epic body that carries the skip marker must bypass
# validation when supplied via --body-file, exactly like the inline --body
# case above.
SKIP_FILE_PATH="$TMPDIR/skip-body.md"
cat > "$SKIP_FILE_PATH" <<'EOF'
free-form epic body, no required sections.
<!-- validate-issue-structure: skip -->
EOF

run_case "--body-file with skip marker → bypass (#695)" \
  0 "validate-issue-structure bypassed" \
  "gh issue create --title '[Feature] epic via file' --body-file $SKIP_FILE_PATH"

# --- body-file: missing required section still blocks -----------------------
MISSING_FILE_PATH="$TMPDIR/missing-body.md"
cat > "$MISSING_FILE_PATH" <<'EOF'
## User Story
As a user I want a thing.
EOF

run_case "--body-file missing Acceptance Criteria → block (#695)" \
  2 "missing section: ## Acceptance Criteria" \
  "gh issue create --title '[Feature] incomplete via file' --body-file $MISSING_FILE_PATH"

# --- gh-api field form: -F body=@<path> (me2resh/apexyard#695) --------------
# `gh api … -F body=@<file>` is the REST shape for posting an issue body from
# a file. Pre-#695 the field-value path after the `@` sigil was never resolved
# (the `-F` handler rejected any value containing `=`), AND a single-dash flag
# after a quoted --title broke title extraction — so the skip marker and the
# section checks were both blind to the file content. Cover skip-marker-honour
# and missing-section-block across -F / --field / -f.

run_case "-F body=@file with skip marker → bypass (#695)" \
  0 "validate-issue-structure bypassed" \
  "gh issue create --title '[Feature] epic via field' -F body=@$SKIP_FILE_PATH"

run_case "-F body=@file missing Acceptance Criteria → block (#695)" \
  2 "missing section: ## Acceptance Criteria" \
  "gh issue create --title '[Feature] incomplete via field' -F body=@$MISSING_FILE_PATH"

run_case "--field body=@file missing section → block (#695)" \
  2 "missing section: ## Acceptance Criteria" \
  "gh issue create --title '[Feature] incomplete via --field' --field body=@$MISSING_FILE_PATH"

run_case "-f body=@file missing section → block (#695)" \
  2 "missing section: ## Acceptance Criteria" \
  "gh issue create --title '[Feature] incomplete via -f' -f body=@$MISSING_FILE_PATH"

# --- Embedded double quotes in body — me2resh/apexyard#227 -----------------
# Pre-227 the awk extractor's non-greedy `"([^"]*)"` regex truncated the
# body at the FIRST embedded `"`, so any `##` heading past that point was
# invisible to the hook and falsely reported as missing. Post-fix the
# extractor is greedy + anchored on next-flag-or-EOS, so embedded `"` in
# prose (admin-notice strings, status labels in quotes) no longer truncate.

CHORE_EMBEDDED_QUOTE_BODY='## Driver
Test of the body extractor.

## Scope
- Mention an admin notice that says "do the thing"
- Another bullet mentioning "current state" labels

## Acceptance Criteria
- [ ] Whatever
- [ ] Another one'

run_case "Chore body with embedded double quotes → pass (no truncation)" \
  0 "" \
  "gh issue create --title '[Chore] Embedded-quote repro' --body \"$CHORE_EMBEDDED_QUOTE_BODY\""

# Same body but with --label tail to confirm greedy match stops at next flag
run_case "Chore body with embedded quotes + trailing --label → pass" \
  0 "" \
  "gh issue create --title '[Chore] x' --body \"$CHORE_EMBEDDED_QUOTE_BODY\" --label chore"

# Feature body with embedded quote between User Story and Acceptance Criteria
FEATURE_EMBEDDED_QUOTE_BODY='## User Story
As a user I want to see an "admin notice" so I know what to do.

## Acceptance Criteria
- [ ] notice renders
- [ ] dismiss button works'

run_case "Feature body with embedded quotes in User Story → pass" \
  0 "" \
  "gh issue create --title '[Feature] embedded notice' --body \"$FEATURE_EMBEDDED_QUOTE_BODY\""

# Bug body with embedded quotes — Given / When / Then often quotes prose
BUG_EMBEDDED_QUOTE_BODY='## Given / When / Then
Given the user sees an "admin notice"
When they click "dismiss"
Then the notice goes away

## Repro
1. open the app
2. observe the "admin notice"
3. click "dismiss"'

run_case "Bug body with multiple embedded quotes → pass" \
  0 "" \
  "gh issue create --title '[Bug] dismiss notice' --body \"$BUG_EMBEDDED_QUOTE_BODY\""

# Negative case: embedded quotes are no protection from missing sections.
# Body has embedded quotes AND is genuinely missing a required section.
BUG_EMBEDDED_BUT_INCOMPLETE='## Given / When / Then
Given the user sees an "admin notice"
When they click "dismiss"
Then the notice goes away'

run_case "Bug body with embedded quotes but missing Repro → still blocks" \
  2 "missing section: ## Repro" \
  "gh issue create --title '[Bug] no repro' --body \"$BUG_EMBEDDED_BUT_INCOMPLETE\""

# ---------------------------------------------------------------------------
# Framework-filing exemption (#712)
#
# /request-apexyard-feature and /report-apexyard-bug file [Feature]/[Bug] issues
# UPSTREAM using their own body template (Problem/Proposed/Why; Given/When/Then),
# which is deliberately distinct from this project's required-section schema.
# When one of those skills is the active filing skill (the active-issue-skill
# marker), the project schema does not apply. The exemption is narrow: only the
# configured framework-filing skills, detected via the SAME marker that
# require-skill-for-issue-create.sh reads.
# ---------------------------------------------------------------------------

# The exemption's ops-root resolution (resolve_ops_root) consults the session
# pin FIRST — with CLAUDE_CODE_SESSION_ID set it would return the real fork, not
# this fixture. Disable the pin so it walks up to THIS fixture's anchor. (The
# authoritative runner bin/run-hook-tests.sh already exports this globally.)
export APEXYARD_OPS_DISABLE_PIN=1

# Add the v2 ops-root anchor so the hook's ops-root resolution lands on the
# fixture fork, and create the session dir. The marker is written/removed
# per-case so it never leaks into the schema cases above.
touch "$TMPDIR/fork/.apexyard-fork"
mkdir -p "$TMPDIR/fork/.claude/session"
MARKER="$TMPDIR/fork/.claude/session/active-issue-skill"

# A [Feature] body in the framework-request template — MISSING the project
# [Feature] schema (User Story + Acceptance Criteria) by design.
FRAMEWORK_FEATURE_BODY='## Problem
The framework lacks X.

## Proposed behaviour
Add X.

## Why it helps adopters
Adopters get X today by doing Y manually.'

# Exempt: marker names a framework-filing skill → project schema skipped → pass.
echo "request-apexyard-feature" > "$MARKER"
run_case "Framework feature (no User Story/AC), marker=request-apexyard-feature → exempt (pass)" \
  0 "" \
  "gh issue create --title '[Feature] add X to the framework' --body \"$FRAMEWORK_FEATURE_BODY\""
rm -f "$MARKER"

# Report-apexyard-bug is also exempt (covers a [Bug] off-schema body symmetrically).
FRAMEWORK_BUGISH_BODY='## Affected
some hook

## Notes
free-form framework note without the project Bug schema.'
echo "report-apexyard-bug" > "$MARKER"
run_case "Framework bug body (no Given/When/Then), marker=report-apexyard-bug → exempt (pass)" \
  0 "" \
  "gh issue create --title '[Bug] hook misfires' --body \"$FRAMEWORK_BUGISH_BODY\""
rm -f "$MARKER"

# NOT exempt: marker names the PROJECT skill (/feature) → schema still enforced.
echo "feature" > "$MARKER"
run_case "Framework-shaped [Feature], marker=feature (project skill) → still blocks" \
  2 "missing section: ## User Story" \
  "gh issue create --title '[Feature] add X' --body \"$FRAMEWORK_FEATURE_BODY\""
rm -f "$MARKER"

# NOT exempt: no marker at all → unchanged behaviour, still blocks malformed [Feature].
run_case "Framework-shaped [Feature], no active-issue-skill marker → still blocks" \
  2 "missing section: ## User Story" \
  "gh issue create --title '[Feature] add X' --body \"$FRAMEWORK_FEATURE_BODY\""

# Remove the v2 anchor so it can't influence any later cases.
rm -f "$TMPDIR/fork/.apexyard-fork"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
