#!/bin/bash
# apexyard#1455 — a registry entry marked `public: true` is not a leak.
#
# Kept in its own file, separate from test_block_private_refs.sh, because
# that file's fixture registry already carries real registered project
# names (a pre-existing, out-of-scope condition unrelated to this ticket)
# and this file must not go anywhere near that. Every name/repo/workspace
# below is synthetic.
#
# Exercises block-private-refs-in-public-repos.sh directly, mirroring the
# harness in test_block_private_refs.sh (JSON tool_input payload piped to
# the hook, run from a fixture fork directory so the registry-walk finds
# the fixture).

set -u

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOK="$REPO_ROOT/.claude/hooks/block-private-refs-in-public-repos.sh"

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook not found or not executable at $HOOK" >&2
  exit 1
fi

PASS=0
FAIL=0

TMPDIR=$(mktemp -d -t block-private-refs-public-entry.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/fork/subdir"
cat > "$TMPDIR/fork/onboarding.yaml" <<'YAML'
company: test
YAML
cat > "$TMPDIR/fork/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: open-marketing-site
    repo: acme-org/open-marketing-site
    public: true
    workspace: workspace/open-marketing-site
    status: active
  - name: secret-app
    repo: acme-org/secret-app
    workspace: workspace/secret-app
    status: active
YAML

make_payload() {
  local cmd="$1"
  jq -n --arg c "$cmd" '{tool_input: {command: $c}}'
}

run_case() {
  local name="$1" expected_exit="$2" expected_stderr_substr="$3" cmd="$4"
  local stderr_file actual_exit stderr_content ok
  stderr_file=$(mktemp)
  ( cd "$TMPDIR/fork/subdir" && make_payload "$cmd" | "$HOOK" ) 2> "$stderr_file"
  actual_exit=$?
  stderr_content=$(cat "$stderr_file")
  rm -f "$stderr_file"

  ok=1
  [ "$actual_exit" != "$expected_exit" ] && ok=0
  if [ -n "$expected_stderr_substr" ] && ! echo "$stderr_content" | grep -qF -- "$expected_stderr_substr"; then
    ok=0
  fi

  if [ "$ok" = 1 ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "   expected exit=$expected_exit, got $actual_exit"
    echo "   stderr was:"
    echo "$stderr_content" | sed 's/^/     /'
    FAIL=$((FAIL + 1))
  fi
}

run_case "public:true entry — name does not block" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'launch' --body 'announcing open-marketing-site'"

run_case "public:true entry — repo slug does not block" \
  0 "" \
  "gh pr create --repo me2resh/apexyard --title 'docs' --body 'see acme-org/open-marketing-site for source'"

run_case "public:true entry — workspace path does not block" \
  0 "" \
  "gh issue comment 3 --repo me2resh/apexyard --body 'lives in workspace/open-marketing-site/README.md'"

run_case "entry without public field still blocks (default private)" \
  2 "project name: secret-app" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'discovered during secret-app rebuild'"

run_case "public entry mention alongside a real leak still blocks on the leak" \
  2 "project name: secret-app" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'open-marketing-site is fine; secret-app is not'"

# ---------------------------------------------------------------------------
# apexyard#1457 review round 2 (Rex B2 / Hakim HIGH-1) — entry-boundary
# scoping. Swaps the fixture registry per case; each writes its own
# registry, so order after this point does not depend on the block above.
# ---------------------------------------------------------------------------

write_registry() {
  printf '%s' "$1" > "$TMPDIR/fork/apexyard.projects.yaml"
}

# Case A: private entry, then a public entry whose first key is repo:.
write_registry 'version: 1
projects:
  - name: secret-app
    repo: acme-org/secret-app
    workspace: workspace/secret-app
  - repo: acme-org/open-site
    name: open-site
    public: true
    workspace: workspace/open-site
'
run_case "case A: repo:-first public entry does not unblock the entry above it" \
  2 "project name: secret-app" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'discovered during secret-app rebuild'"

# Case A2: public entry, then a private entry whose first key is workspace:.
write_registry 'version: 1
projects:
  - name: open-site
    repo: acme-org/open-site
    public: true
    workspace: workspace/open-site
  - workspace: workspace/secret-app
    name: secret-app
    repo: acme-org/secret-app
'
run_case "case A2: workspace:-first private entry after a public one still blocks" \
  2 "project name: secret-app" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'discovered during secret-app rebuild'"

# Case C: private entry with a nested map holding public: true.
write_registry 'version: 1
projects:
  - name: secret-app
    repo: acme-org/secret-app
    deploy:
      public: true
      region: us
    workspace: workspace/secret-app
'
run_case "case C: public: true nested under a sub-map does not unscrub the entry" \
  2 "project name: secret-app" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'discovered during secret-app rebuild'"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
