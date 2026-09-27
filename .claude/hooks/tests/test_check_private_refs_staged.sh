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

sandbox=$(make_sandbox)
printf '%s\n' 'projects:' '  - name: amber-secondary' '    repos:' '      - acme/amber-primary' '      - acme/amber-secondary' '    workspace: workspace/amber-secondary' > "$sandbox/apexyard.projects.yaml"
runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "$resolved_repo" 'Reviewed acme/amber-secondary#7' '' 2>&1); runtime_rc=$?
if [ "$runtime_rc" = "2" ] && ! printf '%s' "$runtime_output" | grep -qF 'acme/amber-secondary'; then
  pass "plural repos entries block secondary repository references"
else
  fail "plural repos entries block secondary repository references" "$runtime_output"
fi
rm -rf "$sandbox"

echo
echo "== Upstream owner/repo exemption (#1431)"
#
# An ops fork's `origin` remote is the fork itself. The public framework
# lives at the `upstream` remote. The hook used to exempt only a registered
# name or repo slug equal to `origin`'s bare name or slug, so a registry
# that lists the framework repo itself, or a registered project whose name
# equals the upstream owner login, blocked the ordinary
# `<upstream-owner>/<repo>#N` issue-reference form. All fixture names below
# are SYNTHETIC.

# make_sandbox_with_remotes REGISTRY_YAML ORIGIN_URL [UPSTREAM_URL] — like
# make_sandbox, but takes the registry content and configures the given
# remotes (upstream is optional, matching a fork with none configured).
make_sandbox_with_remotes() {
  local registry_yaml="$1" origin_url="$2" upstream_url="${3:-}"
  local sandbox
  sandbox=$(mktemp -d)
  mkdir -p "$sandbox/.claude/hooks" "$sandbox/.githooks"
  cp "$HOOK_SRC" "$sandbox/.claude/hooks/check-private-refs-staged.sh"
  cp "$RUNTIME_SRC" "$sandbox/.claude/hooks/check-private-refs-runtime.sh"
  cp "$PRE_COMMIT_SRC" "$sandbox/.githooks/pre-commit"
  chmod +x "$sandbox/.claude/hooks/check-private-refs-staged.sh" "$sandbox/.claude/hooks/check-private-refs-runtime.sh" "$sandbox/.githooks/pre-commit"
  printf '%s' "$registry_yaml" > "$sandbox/apexyard.projects.yaml"
  (
    cd "$sandbox" || exit 1
    git init -q
    git config user.email test@example.com
    git config user.name Test
    git add apexyard.projects.yaml
    git commit -q -m baseline
    git remote add origin "$origin_url"
    if [ -n "$upstream_url" ]; then
      git remote add upstream "$upstream_url"
    fi
  )
  printf '%s\n' "$sandbox"
}

# "acme-framework" collides with the synthetic upstream owner login.
# "framework" is that upstream's own bare repo name, registered by its slug
# ("acme-framework/framework") — the "registry lists the framework repo
# itself" case the issue names. "secret-app" is an ordinary unrelated
# private project that must keep blocking throughout.
UPSTREAM_REGISTRY_YAML='projects:
  - name: acme-framework
    repo: acme-org/acme-framework-app
    workspace: workspace/acme-framework-app
  - name: framework
    repo: acme-framework/framework
    workspace: workspace/framework-mirror
  - name: secret-app
    repo: acme-org/secret-app
    workspace: workspace/secret-app
'
FORK_ORIGIN_URL="https://github.com/atlas-fork/ops-fork.git"
FRAMEWORK_UPSTREAM_URL="https://github.com/acme-framework/framework.git"

# 1. The exact repro: an upstream issue cited as <owner>/<repo>#N. Exercises
#    the owner-login name exemption and the upstream repo-slug exemption
#    together (the registered "framework" project's repo IS the upstream
#    slug).
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'See acme-framework/framework#12 for the same root cause.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "upstream owner/repo#N reference does not block" "$sandbox" 0 "" ""
rm -rf "$sandbox"

# 2. A bare, standalone mention of the upstream owner login must still
#    block, exactly like any other registered private project's name.
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'The acme-framework project needs a rename.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "bare upstream-owner mention still blocks" "$sandbox" 2 "File: notes.md" "acme-framework"
rm -rf "$sandbox"

# 3. An unrelated registered private project's name must still block.
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'Discovered while touching secret-app during the rebuild.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "unrelated registered project name still blocks" "$sandbox" 2 "File: notes.md" "secret-app"
rm -rf "$sandbox"

# 4. With no upstream remote configured, today's (origin-only) behaviour
#    holds: the same owner/repo reference has no exemption to fall back on
#    and still blocks.
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL")
printf 'See acme-framework/framework#12 for the same root cause.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "no upstream remote keeps origin-only behaviour (still blocks)" "$sandbox" 2 "File: notes.md" "acme-framework"
rm -rf "$sandbox"

# 5. @-mentioning the upstream owner login (no slash, no repo name) is the
#    other safe form and must not block either.
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'Thanks @acme-framework, filing the fix now.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "@-mentioning the upstream owner login does not block" "$sandbox" 0 "" ""
rm -rf "$sandbox"

# 6. Regression guard — a hyphen-joined form of the owner login is NOT the
#    safe form and must still block, matching the narrow #1400 boundary
#    this fix ports.
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'Ship the acme-framework-cli update first.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "hyphen-joined owner-login form still blocks" "$sandbox" 2 "File: notes.md" "acme-framework"
rm -rf "$sandbox"

# 7. Regression guard — an owner-form mention alongside a genuine leak in
#    the same file must still catch the real leak. The owner exemption
#    skips only the owner's own name entry.
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'Filed against acme-framework/framework; also seen in secret-app.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "owner mention plus a real leak still blocks" "$sandbox" 2 "File: notes.md" "secret-app"
rm -rf "$sandbox"

# 8. Fail-before proof — the SAME case-1 content, run against the unfixed
#    hook as it exists on upstream/dev, must reproduce the bug (block).
#    Confirms this is a genuine fail→pass fix, not a pre-existing pass.
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'See acme-framework/framework#12 for the same root cause.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
pre_fix_hook=$(mktemp)
if git -C "$ROOT" show upstream/dev:.claude/hooks/check-private-refs-staged.sh > "$pre_fix_hook" 2>/dev/null \
  && [ -s "$pre_fix_hook" ]; then
  chmod +x "$pre_fix_hook"
  cp "$pre_fix_hook" "$sandbox/.claude/hooks/check-private-refs-staged.sh"
  prefix_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-staged.sh 2>&1); prefix_rc=$?
  if [ "$prefix_rc" = "2" ]; then
    pass "fail-before: upstream/dev's hook still blocks the owner/repo form"
  else
    fail "fail-before: upstream/dev's hook still blocks the owner/repo form" "expected exit 2, got $prefix_rc: $prefix_output"
  fi
else
  echo "  skip fail-before proof: could not read upstream/dev's copy of the hook"
fi
rm -f "$pre_fix_hook"
rm -rf "$sandbox"

echo
echo "===== test_check_private_refs_staged.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
