#!/bin/bash
# Issue #1402: a sanctioned review can write to a temporary standalone clone.
# Each repository in this test lives under its own temporary directory.
# Claude Code invokes the hook from the ops-fork sandbox, even when a tool
# writes an absolute path in a separate review clone.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


SRC_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOK_SOURCE=${RATC_HOOK_SOURCE:-$SRC_ROOT/.claude/hooks/require-active-ticket.sh}
TMP_RAW=$(mktemp -d)
TMP=$(cd "$TMP_RAW" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

ops="$TMP/ops"
scratch="$TMP/scratch"
mkdir -p "$ops/.claude/hooks" "$ops/.claude/session" "$ops/workspace/demo" "$TMP/pins"
git -C "$ops" init -q
git -C "$ops" config user.email test@example.invalid
git -C "$ops" config user.name Test
: > "$ops/onboarding.yaml"
: > "$ops/apexyard.projects.yaml"
git -C "$ops" add onboarding.yaml apexyard.projects.yaml
git -C "$ops" commit -q -m initial
git clone -q "$ops" "$scratch"
git -C "$ops/workspace/demo" init -q
mkdir "$TMP/unrelated"
git -C "$TMP/unrelated" init -q
git -C "$ops" worktree add -q -b linked-review "$TMP/linked"

cp "$HOOK_SOURCE" "$ops/.claude/hooks/require-active-ticket.sh"
for lib in _lib-awk-fallback.sh _lib-detect-bash-write.sh _lib-path-resolve.sh _lib-ops-root.sh \
  _lib-review-markers.sh _lib-active-ticket.sh _lib-ticket-path-exemptions.sh \
  _lib-read-config.sh \
  _lib-mask-quoted.sh _lib-fail-closed-json.sh; do
  cp "$SRC_ROOT/.claude/hooks/$lib" "$ops/.claude/hooks/$lib"
done
cp "$SRC_ROOT/.claude/project-config.defaults.json" "$ops/.claude/project-config.defaults.json"
printf '%s\n' "$ops" > "$TMP/pins/ops-root-session-a"
printf '%s\n' 'sample/project#42:rex' > "$ops/.claude/session/active-reviewer.session-a"

PASS=0
FAIL=0
run_case() {
  local label="$1" expected="$2" cwd="$3" input="$4" session="${5:-session-a}"
  local output rc
  output=$(cd "$cwd" && printf '%s\n' "$input" | \
    CLAUDE_CODE_SESSION_ID="$session" APEXYARD_OPS_PIN_DIR="$TMP/pins" \
    /bin/bash "$ops/.claude/hooks/require-active-ticket.sh" 2>&1)
  rc=$?
  if [ "$rc" -eq "$expected" ] && { [ "$expected" -ne 0 ] || [ -z "$output" ]; }; then
    printf 'PASS [%s]\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL [%s]: expected rc=%s, got rc=%s, output=%s\n' "$label" "$expected" "$rc" "$output" >&2
    FAIL=$((FAIL + 1))
  fi
}

bash_input() {
  jq -nc --arg command "$1" '{tool_name:"Bash",tool_input:{command:$command}}'
}
edit_input() {
  jq -nc --arg file_path "$1" '{tool_name:"Edit",tool_input:{file_path:$file_path}}'
}
write_input() {
  jq -nc --arg file_path "$1" '{tool_name:"Write",tool_input:{file_path:$file_path,content:"fixture"}}'
}

run_case 'rex may write a fixture in a scratch clone' 0 "$ops" \
  "$(bash_input "echo fixture > $scratch/fixture.txt")"
run_case 'rex may write through a system temp prefix into a scratch clone' 0 "$ops" \
  "$(bash_input "echo fixture > $TMP_RAW/scratch/raw-fixture.txt")"
printf '%s\n' 'sample/project#42:security' > "$ops/.claude/session/active-reviewer.session-a"
run_case 'security reviewer may edit a scratch clone' 0 "$ops" \
  "$(edit_input "$scratch/fixture.txt")"
printf '%s\n' 'sample/project#42:architecture' > "$ops/.claude/session/active-reviewer.session-a"
run_case 'solution architect may write in a scratch clone' 0 "$ops" \
  "$(bash_input "echo fixture > $scratch/architecture.txt")"

printf '%s\n' 'sample/project#42:rex' > "$ops/.claude/session/active-reviewer.session-a"
run_case 'reviewer cannot write into the ops fork' 2 "$ops" \
  "$(edit_input "$ops/source.txt")"
run_case 'reviewer cannot write into managed workspace' 2 "$ops" \
  "$(edit_input "$ops/workspace/demo/source.txt")"
run_case 'second target in ops fork still blocks' 2 "$ops" \
  "$(bash_input "echo fixture > $scratch/fixture.txt; echo source > $ops/source.txt")"

ln -s "$ops" "$scratch/ops-link"
run_case 'scratch symlink into ops fork blocks' 2 "$ops" \
  "$(edit_input "$scratch/ops-link/source.txt")"
: > "$ops/source.txt"
: > "$ops/workspace/demo/source.txt"
ln -s "$ops/source.txt" "$scratch/ops-file-link"
ln -s "$ops/missing.txt" "$scratch/ops-dangling-link"
ln -s "$ops/workspace/demo/missing.txt" "$scratch/workspace-dangling-link"
ln -s "$scratch/fixture.txt" "$scratch/local-file-link"
mkdir "$scratch/fixtures"
ln -s "$scratch/fixtures" "$scratch/fixture-dir-link"
run_case 'MUST-BLOCK scratch existing ops file link via Bash redirect' 2 "$ops" \
  "$(bash_input "echo fixture > $scratch/ops-file-link")"
run_case 'MUST-BLOCK scratch existing ops file link via Edit' 2 "$ops" \
  "$(edit_input "$scratch/ops-file-link")"
run_case 'MUST-BLOCK scratch existing ops file link via Write' 2 "$ops" \
  "$(write_input "$scratch/ops-file-link")"
run_case 'MUST-BLOCK scratch dangling ops file link' 2 "$ops" \
  "$(edit_input "$scratch/ops-dangling-link")"
run_case 'MUST-BLOCK scratch dangling workspace file link' 2 "$ops" \
  "$(write_input "$scratch/workspace-dangling-link")"
run_case 'MUST-BLOCK scratch dangling ops link through temp prefix' 2 "$ops" \
  "$(write_input "$TMP_RAW/scratch/ops-dangling-link")"
run_case 'MUST-BLOCK scratch local file link' 2 "$ops" \
  "$(edit_input "$scratch/local-file-link")"
run_case 'MUST-BLOCK scratch local directory link' 2 "$ops" \
  "$(edit_input "$scratch/fixture-dir-link/source.txt")"
run_case 'linked worktree is not a scratch clone' 2 "$ops" \
  "$(edit_input "$TMP/linked/source.txt")"
run_case 'temporary git init repository is not a scratch clone' 2 "$ops" \
  "$(edit_input "$TMP/unrelated/source.txt")"

run_case 'another session cannot use the review marker' 2 "$ops" \
  "$(edit_input "$scratch/fixture.txt")" session-b
printf '%s\n' 'sample/project#42:builder' > "$ops/.claude/session/active-reviewer.session-a"
run_case 'unrecognized review role cannot use scratch exemption' 2 "$ops" \
  "$(edit_input "$scratch/fixture.txt")"
rm "$ops/.claude/session/active-reviewer.session-a"
run_case 'review marker is required' 2 "$ops" \
  "$(edit_input "$scratch/fixture.txt")"

printf '%s\n' 'sample/project#42:rex' 'unexpected' > "$ops/.claude/session/active-reviewer.session-a"
run_case 'MUST-BLOCK marker with appended line' 2 "$ops" \
  "$(edit_input "$scratch/fixture.txt")"
printf '%s\n' 'unexpected' 'sample/project#42:rex' > "$ops/.claude/session/active-reviewer.session-a"
run_case 'MUST-BLOCK marker with valid second line' 2 "$ops" \
  "$(edit_input "$scratch/fixture.txt")"

printf '%s\n' 'sample/project#42:rex' > "$ops/.claude/session/active-reviewer.session-a"
APEXYARD_OPS_DISABLE_PIN=1 run_case 'unresolved ops root keeps scratch clone gated' 2 "$TMP/unrelated" \
  "$(edit_input "$scratch/fixture.txt")"

mkdir -p "$TMP/other-ops/.claude/hooks"
: > "$TMP/other-ops/onboarding.yaml"
: > "$TMP/other-ops/apexyard.projects.yaml"
printf '%s\n' "$TMP/other-ops" > "$TMP/pins/ops-root-session-a"
APEXYARD_OPS_DISABLE_PIN='' run_case 'pin for another ops fork keeps scratch clone gated' 2 "$ops" \
  "$(edit_input "$scratch/fixture.txt")"
printf '%s\n' "$ops" > "$TMP/pins/ops-root-session-a"

mkdir "$TMP/export"
run_case 'non-git review export keeps existing exemption' 0 "$ops" \
  "$(edit_input "$TMP/export/fixture.txt")"
run_case 'non-git export through a system temp prefix is exempt' 0 "$ops" \
  "$(edit_input "$TMP_RAW/export/raw-fixture.txt")"

ln -s "$ops/source.txt" "$TMP/export/ops-file-link"
ln -s "$ops/missing.txt" "$TMP/export/ops-dangling-link"
ln -s "$ops/workspace/demo/missing.txt" "$TMP/export/workspace-dangling-link"
mkdir "$TMP/export/fixtures"
ln -s "$TMP/export/fixtures" "$TMP/export/fixture-dir-link"
run_case 'MUST-BLOCK export existing ops file link via Bash redirect' 2 "$ops" \
  "$(bash_input "echo fixture > $TMP/export/ops-file-link")"
run_case 'MUST-BLOCK export existing ops file link via Edit' 2 "$ops" \
  "$(edit_input "$TMP/export/ops-file-link")"
run_case 'MUST-BLOCK export existing ops file link via Write' 2 "$ops" \
  "$(write_input "$TMP/export/ops-file-link")"
run_case 'MUST-BLOCK export dangling ops file link' 2 "$ops" \
  "$(edit_input "$TMP/export/ops-dangling-link")"
run_case 'MUST-BLOCK export dangling workspace file link' 2 "$ops" \
  "$(write_input "$TMP/export/workspace-dangling-link")"
run_case 'MUST-BLOCK export dangling workspace link through temp prefix' 2 "$ops" \
  "$(write_input "$TMP_RAW/export/workspace-dangling-link")"
run_case 'MUST-BLOCK export local directory link' 2 "$ops" \
  "$(edit_input "$TMP/export/fixture-dir-link/source.txt")"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
