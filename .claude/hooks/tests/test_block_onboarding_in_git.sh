#!/bin/bash
# Test fixtures for block-onboarding-in-git.sh (#517).
#
# Builds an isolated temp git repo, stages files, and pipes a JSON tool_input
# payload to the hook — asserting on exit code. No framework — bash + git + jq.
#
# Run:  ./.claude/hooks/tests/test_block_onboarding_in_git.sh
# Exit 0 = all pass, exit 1 = at least one failure.

set -u

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOK="$REPO_ROOT/.claude/hooks/block-onboarding-in-git.sh"

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook not found or not executable at $HOOK" >&2
  exit 1
fi

PASS=0
FAIL=0

EXAMPLE_CONTENT='company:
  name: "Your Company Name"
  website: ""'

FILLED_CONTENT='company:
  name: "Acme Health Inc"
  website: "https://acme.example"'

make_payload() {
  # $1 = the shell command string the hook should see
  jq -nc --arg c "$1" '{tool_input: {command: $c}}'
}

# run_case <name> <expected_exit> <env_assignment_or_-> <staged_onboarding_content_or_-> <command>
run_case() {
  local name="$1" expect="$2" envassign="$3" onboarding="$4" cmd="$5"

  local TMP
  TMP=$(mktemp -d -t onboarding-guard.XXXXXX)
  (
    cd "$TMP" || exit 1
    git init -q
    git config user.email t@t.t && git config user.name t
    # Always ship the example template (the placeholder baseline)
    printf '%s\n' "$EXAMPLE_CONTENT" > onboarding.example.yaml
    git add onboarding.example.yaml
    git commit -qm "seed" >/dev/null 2>&1

    # Stage what the case asks for (and ONLY that)
    case "$onboarding" in
      EXAMPLE) cp onboarding.example.yaml onboarding.yaml; git add -f onboarding.yaml ;;
      FILLED)  printf '%s\n' "$FILLED_CONTENT" > onboarding.yaml; git add -f onboarding.yaml ;;
      README)  echo "hi" > README.md; git add README.md ;;
      -)       : ;;
    esac

    local payload; payload=$(make_payload "$cmd")
    if [ "$envassign" != "-" ]; then
      echo "$payload" | env "$envassign" "$HOOK" >/dev/null 2>&1
    else
      echo "$payload" | "$HOOK" >/dev/null 2>&1
    fi
    exit $?
  )
  local got=$?

  if [ "$got" = "$expect" ]; then
    echo "PASS: $name (exit $got)"
    PASS=$((PASS+1))
  else
    echo "FAIL: $name (expected $expect, got $got)" >&2
    FAIL=$((FAIL+1))
  fi
  rm -rf "$TMP"
}

# 1. Filled-in onboarding.yaml staged → BLOCK (exit 2)
run_case "filled-in onboarding blocked" 2 - FILLED "git commit -m 'x'"

# 2. onboarding.yaml identical to example → ALLOW (exit 0)
run_case "placeholder-only onboarding allowed" 0 - EXAMPLE "git commit -m 'x'"

# 3. Env-var escape hatch honored → ALLOW (exit 0)
run_case "env-var escape hatch" 0 "APEXYARD_ALLOW_ONBOARDING_COMMIT=1" FILLED "git commit -m 'x'"

# 4. In-message marker escape hatch honored → ALLOW (exit 0)
run_case "marker escape hatch" 0 - FILLED "git commit -m 'x <!-- onboarding: allow -->'"

# 5. Non-onboarding file staged → ALLOW (exit 0)
run_case "non-onboarding file unaffected" 0 - README "git commit -m 'x'"

# 6. Not a git commit command → ALLOW (exit 0)
run_case "non-commit command ignored" 0 - FILLED "git status"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
