#!/bin/bash
# Regression coverage for private slugs in paths and runtime public references.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
PUBLIC_HOOK_SOURCE=${PUBLIC_HOOK_SOURCE:-$ROOT/.claude/hooks/block-private-refs-in-public-repos.sh}
RUNTIME_HOOK_SOURCE=${RUNTIME_HOOK_SOURCE:-$ROOT/.claude/hooks/check-private-refs-runtime.sh}
PARSER_SOURCE="$ROOT/.claude/hooks/_lib-registry-parser.sh"
CONFIG_SOURCE="$ROOT/.claude/hooks/_lib-read-config.sh"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/.claude/hooks" "$SANDBOX/child"
cp "$PUBLIC_HOOK_SOURCE" "$SANDBOX/.claude/hooks/block-private-refs-in-public-repos.sh"
cp "$RUNTIME_HOOK_SOURCE" "$SANDBOX/.claude/hooks/check-private-refs-runtime.sh"
cp "$PARSER_SOURCE" "$CONFIG_SOURCE" "$SANDBOX/.claude/hooks/"
chmod +x "$SANDBOX/.claude/hooks/block-private-refs-in-public-repos.sh" \
  "$SANDBOX/.claude/hooks/check-private-refs-runtime.sh"
printf 'company: synthetic\n' > "$SANDBOX/onboarding.yaml"
cat > "$SANDBOX/.claude/project-config.defaults.json" <<'JSON'
{"leak_protection":{"public_framework_repos":["atlas-yard/portal"]}}
JSON
cat > "$SANDBOX/apexyard.projects.yaml" <<'YAML'
projects:
  - name: alpha
    repo: acme/beta
    workspace: workspace/alpha
  - name: atlas-yard
    repo: acme/private-owner
    workspace: workspace/private-owner
  - name: framework
    repo: atlas-yard/framework
    workspace: workspace/framework-mirror
YAML
git -C "$SANDBOX" init -q
git -C "$SANDBOX" remote add origin https://github.com/atlas-fork/ops-fork.git
git -C "$SANDBOX" remote add upstream https://github.com/atlas-yard/framework.git

check() {
  local label="$1" expected_rc="$2" expected_text="$3" actual_rc="$4" output="$5"
  if [ "$actual_rc" -eq "$expected_rc" ] \
    && { [ -z "$expected_text" ] || printf '%s' "$output" | grep -qF "$expected_text"; } \
    && { [ "$expected_rc" -ne 0 ] || [ -z "$output" ]; }; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s (exit=%s, output=%s)\n' "$label" "$actual_rc" "$output"
    FAIL=$((FAIL + 1))
  fi
}

public_case() {
  local label="$1" body="$2" output rc command
  command="gh issue create --repo atlas-yard/framework --title 'Reference' --body '$body'"
  output=$(cd "$SANDBOX/child" && jq -n --arg c "$command" '{tool_input:{command:$c}}' \
    | "$SANDBOX/.claude/hooks/block-private-refs-in-public-repos.sh" 2>&1)
  rc=$?
  check "$label" 2 'project repo: acme/beta' "$rc" "$output"
}

runtime_case() {
  local label="$1" target="$2" body="$3" expected_rc="$4" output rc
  output=$(cd "$SANDBOX" && .claude/hooks/check-private-refs-runtime.sh "$target" "$body" '' 2>&1)
  rc=$?
  check "$label" "$expected_rc" '' "$rc" "$output"
}

public_case 'GitHub URL contains a private slug' 'See https://github.com/acme/beta'
public_case 'issue URL contains a private slug' 'See https://github.com/acme/beta/issues/3'
public_case 'path contains a private slug' 'See acme/beta/issues/3'
public_case 'markdown link contains a private slug' 'See [details](https://github.com/acme/beta)'

runtime_case 'runtime public repo and owner reference passes' \
  atlas-yard/framework 'See atlas-yard/framework#3 and thanks @atlas-yard.' 0
runtime_case 'runtime upstream slug passes for another public target' \
  atlas-yard/portal 'See atlas-yard/framework#3.' 0

# Simulate a read failure without depending on file permissions or the host.
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/cat" <<'SH'
#!/bin/sh
case "$1" in
  */unreadable-body.md) exit 1 ;;
esac
exec /bin/cat "$@"
SH
chmod +x "$SANDBOX/bin/cat"
printf 'See acme/beta.\n' > "$SANDBOX/unreadable-body.md"
read_output=$(cd "$SANDBOX" && PATH="$SANDBOX/bin:$PATH" \
  .claude/hooks/check-private-refs-runtime.sh atlas-yard/framework '' \
  "$SANDBOX/unreadable-body.md" 2>&1)
read_rc=$?
check 'runtime body read failure blocks' 2 'body file cannot be read' "$read_rc" "$read_output"

# A coincidental bare name must not be exempt unless that registry entry
# actually names the upstream repository.
cat > "$SANDBOX/apexyard.projects.yaml" <<'YAML'
projects:
  - name: framework
    repo: acme/framework-internal
    workspace: workspace/internal
YAML
runtime_case 'runtime mismatched upstream name still blocks' \
  atlas-yard/framework 'The framework needs review.' 2

printf 'Passed: %s  Failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
