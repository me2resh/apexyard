#!/bin/bash
# Issue #1417: a sanctioned review can write to this session's scratchpad
# without a ticket. The export is an unextractable write, so the non-git
# exemption never sees it. A redirect or Edit into a non-git temp directory
# already passes without a marker. These cases use the literal export, or a
# git directory, so a missing marker still has to fail.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOK_SOURCE=${RATC_HOOK_SOURCE:-$SRC_ROOT/.claude/hooks/require-active-ticket.sh}
TMP_RAW=$(mktemp -d)
TMP=$(cd "$TMP_RAW" && pwd -P)
custom=""
cleanup() {
  rm -rf "$TMP"
  if [ -n "$custom" ]; then
    rm -rf "$custom"
  fi
}
trap cleanup EXIT

ops="$TMP/ops"
pad="$TMP/session-a/scratchpad"
sibling="$TMP/session-a/other"
outside="$TMP/nosid/place"
evil="$TMP/session-a/scratchpad-evil"
mkdir -p "$ops/.claude/hooks" "$ops/.claude/session" "$ops/workspace/demo" \
  "$TMP/pins" "$pad" "$sibling" "$outside" "$evil"
git -C "$ops" init -q
git -C "$ops" config user.email test@example.invalid
git -C "$ops" config user.name Test
: > "$ops/onboarding.yaml"
: > "$ops/apexyard.projects.yaml"
git -C "$ops" add onboarding.yaml apexyard.projects.yaml
git -C "$ops" commit -q -m initial
git -C "$ops/workspace/demo" init -q

cp "$HOOK_SOURCE" "$ops/.claude/hooks/require-active-ticket.sh"
for lib in _lib-awk-fallback.sh _lib-detect-bash-write.sh _lib-path-resolve.sh _lib-ops-root.sh \
  _lib-review-markers.sh _lib-active-ticket.sh _lib-ticket-path-exemptions.sh \
  _lib-read-config.sh \
  _lib-mask-quoted.sh _lib-fail-closed-json.sh; do
  cp "$SRC_ROOT/.claude/hooks/$lib" "$ops/.claude/hooks/$lib"
done
cp "$SRC_ROOT/.claude/project-config.defaults.json" "$ops/.claude/project-config.defaults.json"
printf '%s\n' "$ops" > "$TMP/pins/ops-root-session-a"

case "$pad" in
  *[!/A-Za-z0-9._-]*)
    printf 'FAIL: scratchpad path is outside the accepted character set: %s\n' "$pad" >&2
    exit 1
    ;;
esac

PASS=0
FAIL=0
run_case() {
  local label="$1" expected="$2" cwd="$3" input="$4" session="${5:-session-a}" keep="${6:-}"
  local output rc extra
  case "$keep" in
    keep-tmpdir) extra='-u TAR_OPTIONS -u TAR_OPTS' ;;
    keep-tar) extra='-u CLAUDE_CODE_TMPDIR' ;;
    *) extra='-u TAR_OPTIONS -u TAR_OPTS -u CLAUDE_CODE_TMPDIR' ;;
  esac
  # shellcheck disable=SC2086
  output=$(cd "$cwd" && printf '%s\n' "$input" | \
    env $extra \
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
  local command="$1" pad_arg="${2-__omit__}" agent="${3-}"
  if [ "$pad_arg" = "__omit__" ]; then
    if [ -n "$agent" ]; then
      jq -nc --arg command "$command" --arg agent "$agent" \
        '{tool_name:"Bash",tool_input:{command:$command},agent_type:$agent,agent_id:"a1"}'
    else
      jq -nc --arg command "$command" '{tool_name:"Bash",tool_input:{command:$command}}'
    fi
  elif [ -n "$agent" ]; then
    jq -nc --arg command "$command" --arg pad "$pad_arg" --arg agent "$agent" \
      '{tool_name:"Bash",tool_input:{command:$command},scratchpad_dir:$pad,agent_type:$agent,agent_id:"a1"}'
  else
    jq -nc --arg command "$command" --arg pad "$pad_arg" \
      '{tool_name:"Bash",tool_input:{command:$command},scratchpad_dir:$pad}'
  fi
}
edit_input() {
  local file_path="$1" pad_arg="${2-__omit__}" agent="${3-}"
  if [ "$pad_arg" = "__omit__" ]; then
    if [ -n "$agent" ]; then
      jq -nc --arg file_path "$file_path" --arg agent "$agent" \
        '{tool_name:"Edit",tool_input:{file_path:$file_path},agent_type:$agent,agent_id:"a1"}'
    else
      jq -nc --arg file_path "$file_path" '{tool_name:"Edit",tool_input:{file_path:$file_path}}'
    fi
  elif [ -n "$agent" ]; then
    jq -nc --arg file_path "$file_path" --arg pad "$pad_arg" --arg agent "$agent" \
      '{tool_name:"Edit",tool_input:{file_path:$file_path},scratchpad_dir:$pad,agent_type:$agent,agent_id:"a1"}'
  else
    jq -nc --arg file_path "$file_path" --arg pad "$pad_arg" \
      '{tool_name:"Edit",tool_input:{file_path:$file_path},scratchpad_dir:$pad}'
  fi
}

use_marker() {
  local session="$1" kind="${2:-rex}" mode="${3:-per-review}"
  rm -rf "$ops/.claude/session/active-reviewers"
  rm -f "$ops/.claude/session"/active-reviewer.*
  if [ "$mode" = none ]; then
    return 0
  fi
  if [ "$mode" = legacy ]; then
    printf '%s\n' "sample/project#42:$kind" > "$ops/.claude/session/active-reviewer.$session"
    return 0
  fi
  mkdir -p "$ops/.claude/session/active-reviewers/$session"
  printf '%s\n' "sample/project#42:$kind" > \
    "$ops/.claude/session/active-reviewers/$session/sample__project__42-$kind"
}

export_to() {
  printf 'git archive HEAD | tar -x -C %s' "$1"
}

use_marker session-a rex
run_case 'reviewer export into the scratchpad passes with no ticket' 0 "$ops" \
  "$(bash_input "$(export_to "$pad")" "$pad")"
use_marker session-a rex legacy
run_case 'legacy reviewer marker also allows the scratchpad export' 0 "$ops" \
  "$(bash_input "$(export_to "$pad")" "$pad")"
use_marker session-a security
run_case 'security reviewer export into the scratchpad passes' 0 "$ops" \
  "$(bash_input "$(export_to "$pad")" "$pad")"
use_marker session-a architecture
run_case 'architecture reviewer export into the scratchpad passes' 0 "$ops" \
  "$(bash_input "$(export_to "$pad")" "$pad")"
use_marker session-a rex
run_case 'typed code-reviewer may export into the scratchpad' 0 "$ops" \
  "$(bash_input "$(export_to "$pad")" "$pad" code-reviewer)"
run_case 'typed build agent is denied the scratchpad exemption' 2 "$ops" \
  "$(bash_input "$(export_to "$pad")" "$pad" backend-engineer)"

use_marker session-a rex none
run_case 'the same export with no reviewer marker still needs a ticket' 2 "$ops" \
  "$(bash_input "$(export_to "$pad")" "$pad")"

use_marker session-a rex
run_case 'a write outside the scratchpad still needs a ticket' 2 "$ops" \
  "$(bash_input "$(export_to "$sibling")" "$pad")"
run_case 'a scratchpad prefix lookalike still needs a ticket' 2 "$ops" \
  "$(bash_input "$(export_to "$evil")" "$pad")"
run_case 'a path without this session id still needs a ticket' 2 "$ops" \
  "$(bash_input "$(export_to "$outside")")"
run_case 'reviewer cannot export into the ops fork' 2 "$ops" \
  "$(bash_input "$(export_to "$ops")" "$pad")"
run_case 'reviewer cannot export into a registered workspace' 2 "$ops" \
  "$(bash_input "$(export_to "$ops/workspace/demo")" "$pad")"

run_case 'a dotdot escape still needs a ticket' 2 "$ops" \
  "$(bash_input "$(export_to "$pad/../outside")" "$pad")"
run_case 'an edit through dotdot still needs a ticket' 2 "$ops" \
  "$(edit_input "$pad/../outside.txt" "$pad")"

ln -s "$ops" "$pad/escape"
run_case 'a symlink escape still needs a ticket' 2 "$ops" \
  "$(bash_input "$(export_to "$pad/escape")" "$pad")"
ln -s "$ops/missing" "$pad/dangling"
run_case 'a dangling symlink still needs a ticket' 2 "$ops" \
  "$(bash_input "$(export_to "$pad/dangling")" "$pad")"
mkdir -p "$pad/inner"
ln -s "$pad/inner" "$pad/inner-link"
run_case 'a symlink that stays inside the scratchpad still needs a ticket' 2 "$ops" \
  "$(bash_input "$(export_to "$pad/inner-link")" "$pad")"
ln -s "$pad" "$TMP/session-a/pad-link"
run_case 'a symlinked scratchpad_dir still needs a ticket' 2 "$ops" \
  "$(bash_input "$(export_to "$pad")" "$TMP/session-a/pad-link")"

use_marker session-b rex
run_case 'another session reviewer marker does not count' 2 "$ops" \
  "$(bash_input "$(export_to "$pad")" "$pad")"
run_case 'session b marker does not cover session a scratchpad' 2 "$ops" \
  "$(bash_input "$(export_to "$pad")" "$pad")" session-b

use_marker session-a rex
run_case 'absent scratchpad_dir allows the session temp path' 0 "$ops" \
  "$(bash_input "$(export_to "$pad")")"
run_case 'absent scratchpad_dir allows another directory with this session id' 0 "$ops" \
  "$(bash_input "$(export_to "$sibling")")"
run_case 'a present scratchpad_dir that points at the ops fork does not fall back' 2 "$ops" \
  "$(bash_input "$(export_to "$pad")" "$ops")"
run_case 'an empty scratchpad_dir does not fall back' 2 "$ops" \
  "$(bash_input "$(export_to "$pad")" "")"

run_case 'an absolute-name tar flag still needs a ticket' 2 "$ops" \
  "$(bash_input "git archive HEAD | tar -x -C $pad --absolute-names" "$pad")"
run_case 'a shell variable in the export still needs a ticket' 2 "$ops" \
  "$(bash_input 'git archive HEAD | tar -x -C $pad' "$pad")"
TAR_OPTIONS='--absolute-names' run_case 'TAR_OPTIONS keeps the export gated' 2 "$ops" \
  "$(bash_input "$(export_to "$pad")" "$pad")" session-a keep-tar

mkdir -p "$TMP/other-ops/.claude/hooks"
: > "$TMP/other-ops/onboarding.yaml"
: > "$TMP/other-ops/apexyard.projects.yaml"
printf '%s\n' "$TMP/other-ops" > "$TMP/pins/ops-root-session-a"
APEXYARD_OPS_DISABLE_PIN='' run_case 'pin for another ops fork keeps the scratchpad gated' 2 "$ops" \
  "$(bash_input "$(export_to "$pad")" "$pad")"
printf '%s\n' "$ops" > "$TMP/pins/ops-root-session-a"

# A directory that contains the ops fork is not a scratchpad, even when the
# session id is a path segment of that directory.
sid_root=$(basename "$TMP")
mkdir -p "$TMP/pins"
printf '%s\n' "$ops" > "$TMP/pins/ops-root-$sid_root"
use_marker "$sid_root" rex
run_case 'a scratchpad that contains the ops fork still needs a ticket' 2 "$ops" \
  "$(bash_input "$(export_to "$TMP")" "$TMP")" "$sid_root"

use_marker demo rex
run_case 'a workspace path that contains the session id still needs a ticket' 2 "$ops" \
  "$(bash_input "$(export_to "$ops/workspace/demo")" "$ops/workspace/demo")" demo

custom="$HOME/apexyard-gh1417-$$"
home_pad="$custom/session-a/scratchpad"
case "$home_pad" in
  *[!/A-Za-z0-9._-]*)
    printf 'FAIL: home scratchpad path is outside the accepted character set: %s\n' "$home_pad" >&2
    FAIL=$((FAIL + 1))
    ;;
  *)
    mkdir -p "$home_pad"
    use_marker session-a rex
    CLAUDE_CODE_TMPDIR="$custom" run_case 'CLAUDE_CODE_TMPDIR allows the named scratchpad' 0 "$ops" \
      "$(bash_input "$(export_to "$home_pad")" "$home_pad")" session-a keep-tmpdir
    run_case 'the same home path without CLAUDE_CODE_TMPDIR still needs a ticket' 2 "$ops" \
      "$(bash_input "$(export_to "$home_pad")" "$home_pad")"
    run_case 'an invalid scratchpad_dir does not fall back to the temp rule' 2 "$ops" \
      "$(bash_input "$(export_to "$pad")" "$home_pad")"
    ;;
esac

# A leading dash after `git archive` is an option, not a tree-ish.
# `git archive -o<path>` creates or truncates that path before git checks
# the tree-ish, so the exempt shape allows no archive options.
echo precious > "$ops/README.md"
use_marker session-a rex
run_case 'git archive -o to an ops file still needs a ticket' 2 "$ops" \
  "$(bash_input "git archive -o$ops/README.md | tar -x -C $pad" "$pad")"
run_case 'git archive -o with a relative path still needs a ticket' 2 "$ops" \
  "$(bash_input "git archive -oREADME.md | tar -x -C $pad" "$pad")"
run_case 'git archive -o still needs a ticket when scratchpad_dir is absent' 2 "$ops" \
  "$(bash_input "git archive -o$ops/README.md | tar -x -C $pad")"
run_case 'an archive long option still needs a ticket' 2 "$ops" \
  "$(bash_input "git archive --list | tar -x -C $pad" "$pad")"
run_case 'an archive option after the ref still needs a ticket' 2 "$ops" \
  "$(bash_input "git archive HEAD -o$ops/README.md | tar -x -C $pad" "$pad")"
run_case 'an archive ref may contain an interior dash' 0 "$ops" \
  "$(bash_input "git archive release-1 | tar -x -C $pad" "$pad")"
use_marker session-a rex none
run_case 'git archive -o still needs a ticket with no reviewer marker' 2 "$ops" \
  "$(bash_input "git archive -o$ops/README.md | tar -x -C $pad" "$pad")"
use_marker session-a rex
mkdir -p "$TMP/SESSION-A/x"
run_case 'a case-variant session segment still needs a ticket' 2 "$ops" \
  "$(bash_input "$(export_to "$TMP/SESSION-A/x")")"
upper_ops=$(printf '%s' "$ops" | tr 'a-z' 'A-Z')
run_case 'an uppercase ops path still needs a ticket' 2 "$ops" \
  "$(bash_input "$(export_to "$upper_ops")" "$pad")"
mkdir -p "$pad/a..b"
run_case 'a doubled dot inside a name still needs a ticket' 2 "$ops" \
  "$(bash_input "$(export_to "$pad/a..b")" "$pad")"
run_case 'a trailing slash on the scratchpad export passes' 0 "$ops" \
  "$(bash_input "$(export_to "$pad/")" "$pad")"
run_case 'a second tar -C still needs a ticket' 2 "$ops" \
  "$(bash_input "git archive HEAD | tar -x -C $pad -C $ops" "$pad")"
run_case 'tar -f in the export still needs a ticket' 2 "$ops" \
  "$(bash_input "git archive HEAD | tar -x -C $pad -f /etc/x" "$pad")"

# A linked worktree of the ops fork has a .git file, not a .git directory.
# The scratchpad git arm uses the same directory check as #1402.
use_marker session-a rex
if ! git -C "$ops" worktree add -q "$pad/wt" HEAD; then
  printf 'FAIL [linked worktree setup]: git worktree add failed\n' >&2
  FAIL=$((FAIL + 1))
elif [ -d "$pad/wt/.git" ] || [ ! -f "$pad/wt/.git" ]; then
  printf 'FAIL [linked worktree setup]: expected a .git file at %s\n' "$pad/wt/.git" >&2
  FAIL=$((FAIL + 1))
else
  run_case 'a linked worktree edit in the scratchpad still needs a ticket' 2 "$ops" \
    "$(edit_input "$pad/wt/onboarding.yaml" "$pad")"
  run_case 'a linked worktree edit by code-reviewer still needs a ticket' 2 "$ops" \
    "$(edit_input "$pad/wt/onboarding.yaml" "$pad" code-reviewer)"
  run_case 'a redirect into a linked worktree in the scratchpad still needs a ticket' 2 "$ops" \
    "$(bash_input "echo x > $pad/wt/onboarding.yaml" "$pad")"
  use_marker session-a rex none
  run_case 'the same linked worktree edit with no marker still needs a ticket' 2 "$ops" \
    "$(edit_input "$pad/wt/onboarding.yaml" "$pad")"
fi

use_marker session-a rex
git -C "$pad" init -q
run_case 'a fixture edit in a git scratchpad passes with a reviewer marker' 0 "$ops" \
  "$(edit_input "$pad/fixture.txt" "$pad")"
use_marker session-a rex none
run_case 'a fixture edit in a git scratchpad still needs a ticket without a marker' 2 "$ops" \
  "$(edit_input "$pad/fixture.txt" "$pad")"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
