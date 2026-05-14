#!/bin/bash
# Test fixtures for require-agdr-for-arch-pr.sh.
#
# Each case builds a JSON tool_input payload, primes a throwaway git repo
# with base/HEAD state, and pipes the payload to the hook. We assert on the
# exit code and (optionally) a substring of stderr.
#
# To run:  ./.claude/hooks/tests/test_require_agdr_for_arch_pr.sh
# Exit 0 = all pass, 1 = at least one failure.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
HOOK="$REPO_ROOT/.claude/hooks/require-agdr-for-arch-pr.sh"

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook not found or not executable at $HOOK" >&2
  exit 1
fi

PASS=0
FAIL=0

make_payload() {
  local cmd="$1"
  jq -n --arg c "$cmd" '{tool_input: {command: $c}}'
}

# Create a minimal fake fork: an isolated git repo with a main branch plus a
# feature branch carrying the changes we want to test.
# Usage: setup_repo <base-setup-fn> <feature-setup-fn>
#   base-setup-fn      : runs on main, commits the starting state
#   feature-setup-fn   : runs on the feature branch, commits the PR changes
setup_repo() {
  local base_fn="$1"
  local feat_fn="$2"
  local dir
  dir=$(mktemp -d -t agdr-pr.XXXXXX)
  (
    cd "$dir" || exit 1
    git init -q -b main
    git config user.email t@t.test
    git config user.name test
    # Fork marker so the hook's (future) root-walk finds a plausible ops root.
    echo "company: test" > onboarding.yaml
    git add onboarding.yaml
    git commit -q -m init
    "$base_fn"
    git checkout -q -b feature
    "$feat_fn"
  )
  echo "$dir"
}

# Run the hook from inside $1 with payload built from $2 (command string).
# $3 = expected exit code, $4 = optional stderr substring.
run_case() {
  local name="$1"
  local dir="$2"
  local expected_exit="$3"
  local expected_stderr_substr="$4"
  local cmd="$5"

  local stderr_file
  stderr_file=$(mktemp)

  ( cd "$dir" && echo "$(make_payload "$cmd")" | "$HOOK" ) 2> "$stderr_file"
  local actual_exit=$?
  local stderr_content
  stderr_content=$(cat "$stderr_file")
  rm -f "$stderr_file"

  local ok=1
  if [ "$actual_exit" != "$expected_exit" ]; then ok=0; fi
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

  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Fixture setup helpers
# ---------------------------------------------------------------------------

# 1. Arch path change (domain/) on feature branch, no AgDR in body → BLOCK.
c1_base() {
  mkdir -p src/domain
  echo "export const x = 1" > src/domain/widget.ts
  git add src/domain/widget.ts
  git commit -q -m "base: add domain"
}
c1_feat() {
  echo "export const x = 2" > src/domain/widget.ts
  git add src/domain/widget.ts
  git commit -q -m "feat: tweak domain"
}

# 2. Same as above but PR body links an AgDR → PASS.
#    (Reuses c1_*)

# 3. Dep added to package.json (no version bump) → BLOCK.
c3_base() {
  cat > package.json <<'JSON'
{
  "name": "t",
  "version": "0.0.1",
  "dependencies": {
    "lodash": "^4.0.0"
  }
}
JSON
  git add package.json
  git commit -q -m "base: pkg"
}
c3_feat() {
  cat > package.json <<'JSON'
{
  "name": "t",
  "version": "0.0.1",
  "dependencies": {
    "lodash": "^4.0.0",
    "zod": "^3.0.0"
  }
}
JSON
  git add package.json
  git commit -q -m "feat: add zod"
}

# 4. Version-only bump — same keys, different version → NO FIRE → PASS.
c4_base() {
  cat > package.json <<'JSON'
{
  "name": "t",
  "dependencies": {
    "lodash": "^4.0.0"
  }
}
JSON
  git add package.json
  git commit -q -m "base: pkg"
}
c4_feat() {
  cat > package.json <<'JSON'
{
  "name": "t",
  "dependencies": {
    "lodash": "^4.17.0"
  }
}
JSON
  git add package.json
  git commit -q -m "feat: bump lodash"
}

# 5. Skip marker with arch change → PASS with warning on stderr.
#    (Reuses c1_*)

# 6. Non-triggering diff — a plain README change → PASS.
c6_base() {
  echo "# hello" > README.md
  git add README.md
  git commit -q -m "base: readme"
}
c6_feat() {
  echo "# hello world" > README.md
  git add README.md
  git commit -q -m "feat: tweak readme"
}

# ---------------------------------------------------------------------------
# Run cases
# ---------------------------------------------------------------------------

DIR=$(setup_repo c1_base c1_feat)
run_case "arch path changed, no AgDR → BLOCK" \
  "$DIR" 2 "no AgDR reference" \
  "gh pr create --base main --title 'feat(#1): tweak domain' --body 'just a change'"

DIR=$(setup_repo c1_base c1_feat)
run_case "arch path changed, AgDR referenced → PASS" \
  "$DIR" 0 "" \
  "gh pr create --base main --title 'feat(#1): tweak domain' --body 'See AgDR-0007-tweak-domain for rationale.'"

DIR=$(setup_repo c3_base c3_feat)
run_case "new dep added, no AgDR → BLOCK" \
  "$DIR" 2 "Triggering dep-file additions" \
  "gh pr create --base main --title 'feat(#2): add zod' --body 'needed it'"

DIR=$(setup_repo c4_base c4_feat)
run_case "version-only bump → PASS (no fire)" \
  "$DIR" 0 "" \
  "gh pr create --base main --title 'chore(#3): bump lodash' --body 'no decision here'"

DIR=$(setup_repo c1_base c1_feat)
run_case "skip marker bypasses → PASS with warning" \
  "$DIR" 0 "agdr: not-applicable marker present" \
  "gh pr create --base main --title 'refactor(#4): move domain' --body 'pure rename <!-- agdr: not-applicable -->'"

DIR=$(setup_repo c6_base c6_feat)
run_case "non-matching diff → PASS" \
  "$DIR" 0 "" \
  "gh pr create --base main --title 'docs(#5): readme' --body 'no arch change'"

DIR=$(setup_repo c1_base c1_feat)
run_case "non-gh command → no-op" \
  "$DIR" 0 "" \
  "git status"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
