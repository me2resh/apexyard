#!/bin/bash
# Regression tests for the Git-native staged private-reference gate (#1218).

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$ROOT/.claude/hooks/check-private-refs-staged.sh"
RUNTIME_SRC="$ROOT/.claude/hooks/check-private-refs-runtime.sh"
PRE_COMMIT_SRC="$ROOT/.githooks/pre-commit"

PASS=0
FAIL=0

pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s: %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

make_sandbox() {
  local sandbox
  sandbox=$(mktemp -d)
  mkdir -p "$sandbox/.claude/hooks" "$sandbox/.githooks"
  cp "$HOOK_SRC" "$sandbox/.claude/hooks/check-private-refs-staged.sh"
  cp "$RUNTIME_SRC" "$sandbox/.claude/hooks/check-private-refs-runtime.sh"
  cp "$PRE_COMMIT_SRC" "$sandbox/.githooks/pre-commit"
  chmod +x "$sandbox/.claude/hooks/check-private-refs-staged.sh" "$sandbox/.claude/hooks/check-private-refs-runtime.sh" "$sandbox/.githooks/pre-commit"
  cat > "$sandbox/apexyard.projects.yaml" <<'YAML'
projects:
  - name: amber-lantern
    repo: acme/amber-lantern
    workspace: workspace/amber-lantern
YAML
  (
    cd "$sandbox" || exit 1
    git init -q
    git config user.email test@example.com
    git config user.name Test
    git add apexyard.projects.yaml
    git commit -q -m baseline
  )
  printf '%s\n' "$sandbox"
}

run_hook() {
  local sandbox="$1"; shift
  local out rc
  out=$(cd "$sandbox" && "$HOOK_SRC" 2>&1); rc=$?
  printf '%s\n%s\n' "$rc" "$out"
}

assert_hook() {
  local label="$1" sandbox="$2" expected_rc="$3" expected_text="$4" forbidden_text="$5"
  local result rc output
  result=$(run_hook "$sandbox")
  rc=$(printf '%s\n' "$result" | head -1)
  output=$(printf '%s\n' "$result" | sed '1d')
  if [ "$rc" != "$expected_rc" ]; then
    fail "$label" "expected exit $expected_rc, got $rc: $output"
  elif [ -n "$expected_text" ] && ! printf '%s' "$output" | grep -qF -- "$expected_text"; then
    fail "$label" "missing diagnostic: $expected_text"
  elif [ -n "$forbidden_text" ] && printf '%s' "$output" | grep -qF -- "$forbidden_text"; then
    fail "$label" "diagnostic disclosed private identifier"
  else
    pass "$label"
  fi
}

echo "== Staged private-reference gate (#1218)"

sandbox=$(make_sandbox)
printf 'Private reference: amber-lantern\n' > "$sandbox/leak.md"
git -C "$sandbox" add leak.md
assert_hook "staged project name blocks without disclosing token" "$sandbox" 2 "File: leak.md" "amber-lantern"
rm -rf "$sandbox"

sandbox=$(make_sandbox)
printf 'Reference: acme/amber-lantern#42\n' > "$sandbox/repo.md"
git -C "$sandbox" add repo.md
assert_hook "staged repository slug blocks" "$sandbox" 2 "File: repo.md" "acme/amber-lantern"
rm -rf "$sandbox"

sandbox=$(make_sandbox)
printf 'Path: workspace/amber-lantern/src\n' > "$sandbox/path.md"
git -C "$sandbox" add path.md
assert_hook "staged workspace path blocks" "$sandbox" 2 "File: path.md" "workspace/amber-lantern"
rm -rf "$sandbox"

sandbox=$(make_sandbox)
printf 'The generic workspace term is safe.\n' > "$sandbox/clean.md"
git -C "$sandbox" add clean.md
assert_hook "generic workspace word remains allowed" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox)
printf 'Private reference: amber-lantern\n' > "$sandbox/history.md"
git -C "$sandbox" add history.md
assert_hook "first add blocks before a later removal can hide it" "$sandbox" 2 "File: history.md" "amber-lantern"
git -C "$sandbox" restore --staged history.md
printf 'Private reference removed.\n' > "$sandbox/history.md"
git -C "$sandbox" add history.md
assert_hook "clean replacement is evaluated from its staged blob" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox)
printf 'Private reference: amber-lantern\n' > "$sandbox/working-only.md"
assert_hook "unstaged content does not block a different staged commit" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox)
git -C "$sandbox" config core.hooksPath .githooks
printf 'Private reference: amber-lantern\n' > "$sandbox/commit.md"
git -C "$sandbox" add commit.md
commit_output=$(git -C "$sandbox" commit -m 'test private reference' 2>&1); commit_rc=$?
if [ "$commit_rc" = "0" ]; then
  fail "installed pre-commit hook blocks the commit" "commit unexpectedly succeeded"
elif printf '%s' "$commit_output" | grep -qF 'File: commit.md' && ! printf '%s' "$commit_output" | grep -qF 'amber-lantern'; then
  pass "installed pre-commit hook blocks the commit"
else
  fail "installed pre-commit hook blocks the commit" "$commit_output"
fi
rm -rf "$sandbox"

sandbox=$(make_sandbox)
resolved_repo="me2resh/apexyard"
runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "$resolved_repo" 'Reviewed amber-lantern' '' 2>&1); runtime_rc=$?
if [ "$runtime_rc" = "2" ] && ! printf '%s' "$runtime_output" | grep -qF 'amber-lantern'; then
  pass "resolved wrapper values block without disclosing token"
else
  fail "resolved wrapper values block without disclosing token" "$runtime_output"
fi
rm -rf "$sandbox"

echo
echo "===== test_check_private_refs_staged.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
