#!/usr/bin/env bash
# Tests for the Antigravity CLI (agy) adapter (AgDR-0314):
#   harness-adapters/agy/agy-hook.sh   the hook wrapper
#   bin/sync-agy-adapter.sh            the .agents/hooks.json generator
#
# No case runs agy. Each case feeds a recorded agy hook payload to the
# wrapper inside a temporary fork.
#
# Part A uses stub gates to test the transport contract.
# Part B tests the generator, its --check mode, and the Codex co-existence.
# Part C runs the real .claude/hooks gates for the ticket's acceptance cases.

set -u

# shellcheck disable=SC1007  # Intentionally empty CDPATH keeps cd silent.
TMPDIR=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P) || exit 1
export TMPDIR

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
WRAPPER_SRC="$ROOT/harness-adapters/agy/agy-hook.sh"
SYNC_SRC="$ROOT/bin/sync-agy-adapter.sh"
CODEX_SYNC_SRC="$ROOT/bin/sync-codex-adapter.sh"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

PASS=0
FAIL=0
FAILED=""
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1: $2" >&2; FAIL=$((FAIL + 1)); FAILED="$FAILED|$1"; }

TMPROOT=$(mktemp -d "$TMPDIR/agy-adapter-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT
ALL_OUT="$TMPROOT/all-outputs.txt"
: > "$ALL_OUT"

CONV="0b6c5e1a-7f0e-4c39-9d0e-3c1f5a2b9e11"

# The resolver shim from the real settings.json, with the hook name swapped.
SHIM_BASH=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$ROOT/.claude/settings.json")
case "$SHIM_BASH" in
  *dispatch-bash.sh*) ;;
  *) echo "FAIL: cannot find the dispatch-bash shim in .claude/settings.json" >&2; exit 1 ;;
esac
shim_for() { printf '%s' "${SHIM_BASH//dispatch-bash.sh/$1}"; }

# --- payload builders (recorded agy shapes) -----------------------------------
p_run() { # <command> <workspace> [cwd]
  jq -cn --arg c "$1" --arg ws "$2" --arg cwd "${3:-$2}" --arg id "$CONV" '{
    toolCall: {name: "run_command", args: {CommandLine: $c, Cwd: $cwd, WaitMsBeforeAsync: 0}},
    stepIdx: 3, conversationId: $id, workspacePaths: [$ws],
    transcriptPath: "/tmp/agy-transcript.jsonl", artifactDirectoryPath: "/tmp/agy-artifacts",
    modelName: "test-model", lastUserInput: "do the thing"}'
}
# The agy CLI shape: no args.Cwd, and a top-level cwd (bundled contract).
p_run_top() { # <command> <workspace> <top-level cwd JSON value>
  jq -cn --arg c "$1" --arg ws "$2" --argjson top "$3" --arg id "$CONV" '{
    toolCall: {name: "run_command", args: {CommandLine: $c, WaitMsBeforeAsync: 500, toolSummary: "run"}},
    conversationId: $id, workspacePaths: [$ws], hookEventName: "PreToolUse", cwd: $top}'
}
p_write() { # <path> <content> <workspace>
  jq -cn --arg p "$1" --arg body "$2" --arg ws "$3" --arg id "$CONV" '{
    toolCall: {name: "write_to_file", args: {TargetFile: $p, Overwrite: true, CodeContent: $body, Description: "test"}},
    stepIdx: 4, conversationId: $id, workspacePaths: [$ws]}'
}
p_replace() { # <path> <old> <new> <workspace>
  jq -cn --arg p "$1" --arg o "$2" --arg n "$3" --arg ws "$4" --arg id "$CONV" '{
    toolCall: {name: "replace_file_content", args: {TargetFile: $p, Instruction: "i", Description: "d",
      AllowMultiple: false, TargetContent: $o, ReplacementContent: $n, StartLine: 1, EndLine: 2}},
    stepIdx: 5, conversationId: $id, workspacePaths: [$ws]}'
}
# agy CLI 1.5.14 write_file shape, from a live check (key names only).
p_write_file() { # <path> <content> <workspace> [append true|false]
  jq -cn --arg p "$1" --arg body "$2" --arg ws "$3" --argjson app "${4:-false}" --arg id "$CONV" '{
    toolCall: {name: "write_file", args: {Path: $p, Content: $body, Append: $app, toolSummary: "write"}},
    stepIdx: 6, conversationId: $id, workspacePaths: [$ws]}'
}
p_session() { # <workspace>
  jq -cn --arg ws "$1" --arg id "$CONV" '{conversationId: $id, workspacePaths: [$ws], modelName: "test-model"}'
}

# run_wrapper <fork> <event> <payload>: sets OUT and RC. Appends OUT to ALL_OUT.
# The wrapper's stderr goes to $TMPROOT/stderr.
run_wrapper() {
  local fork="$1" event="$2" payload="$3"
  OUT=$(printf '%s' "$payload" | bash "$fork/harness-adapters/agy/agy-hook.sh" "$event" 2>"$TMPROOT/stderr")
  RC=$?
  printf '%s\n' "$OUT" >> "$ALL_OUT"
}

decision() { printf '%s' "$OUT" | jq -r '.decision // "none"' 2>/dev/null || echo invalid; }
reason() { printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null; }

expect_decision() { # <label> <ask|deny> [reason ERE]
  local label="$1" want="$2" rx="${3:-}" got
  got=$(decision)
  if [ "$RC" != 0 ]; then bad "$label" "wrapper exit $RC (out: ${OUT:0:200})"; return; fi
  if [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" != 1 ]; then bad "$label" "output is not one line: ${OUT:0:300}"; return; fi
  if [ "$got" != "$want" ]; then bad "$label" "want $want, got $got (out: ${OUT:0:300})"; return; fi
  if [ -n "$rx" ] && ! reason | grep -Eq -- "$rx"; then bad "$label" "reason did not match /$rx/: $(reason | head -c 300)"; return; fi
  ok "$label"
}

copy_adapter() { # <fork>
  mkdir -p "$1/harness-adapters/agy" "$1/bin"
  cp "$WRAPPER_SRC" "$1/harness-adapters/agy/agy-hook.sh"
  cp "$SYNC_SRC" "$1/bin/sync-agy-adapter.sh"
  cp "$CODEX_SYNC_SRC" "$1/bin/sync-codex-adapter.sh"
  chmod +x "$1/harness-adapters/agy/agy-hook.sh" "$1/bin/"*.sh
}

# ==============================================================================
echo "== Part A: transport contract with stub gates"

A="$TMPROOT/fork-a"
mkdir -p "$A/.claude/hooks" "$A/src"
: > "$A/.apexyard-fork"
copy_adapter "$A"

cat > "$A/.claude/hooks/record-gate.sh" <<'SH'
#!/usr/bin/env bash
input=$(cat)
dir="$(cd "$(dirname "$0")/../.." && pwd)"
printf '%s\n' "$input" > "$dir/last-input.json"
{
  printf 'APEXYARD_SESSION_ID=%s\n' "${APEXYARD_SESSION_ID-<unset>}"
  printf 'CLAUDE_CODE_SESSION_ID=%s\n' "${CLAUDE_CODE_SESSION_ID-<unset>}"
  printf 'CLAUDE_PROJECT_DIR=%s\n' "${CLAUDE_PROJECT_DIR-<unset>}"
  printf 'PWD=%s\n' "$PWD"
} > "$dir/last-env.txt"
case "$input" in
  *deny-me*) echo "BLOCKED: record gate refuses deny-me" >&2; exit 2 ;;
  *crash-me*) echo "record gate crashed" >&2; exit 1 ;;
  *sleep-me*) sleep 20; exit 0 ;;
esac
echo "this stdout must not reach agy"
exit 0
SH
cat > "$A/.claude/hooks/strict-gate.sh" <<'SH'
#!/usr/bin/env bash
input=$(cat)
case "$input" in *strict-crash*) exit 1 ;; esac
exit 0
SH
cat > "$A/.claude/hooks/policy-gate.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "BLOCKED: policy predicate gate fired" >&2
exit 2
SH
cat > "$A/.claude/hooks/banner.sh" <<'SH'
#!/usr/bin/env bash
input=$(cat)
dir="$(cd "$(dirname "$0")/../.." && pwd)"
printf '%s\n' "$input" > "$dir/last-session-input.json"
echo "ApexYard banner line"
SH
chmod +x "$A/.claude/hooks/"*.sh

write_settings_a() { # [extra jq filter]
  jq -n --arg rec "$(shim_for record-gate.sh)" --arg strict "$(shim_for strict-gate.sh)" \
        --arg pol "$(shim_for policy-gate.sh)" --arg ban "$(shim_for banner.sh)" '{
    hooks: {
      SessionStart: [{hooks: [{type: "command", command: $ban}]}],
      PreToolUse: [
        {matcher: "Edit|Write|MultiEdit|NotebookEdit", hooks: [{type: "command", command: $rec, timeout: 4}]},
        {matcher: "Bash", hooks: [
          {type: "command", command: $rec, timeout: 4},
          {type: "command", command: $strict, timeout: 5, onFailure: "block"},
          {type: "command", if: "Bash(policy *)", command: $pol}
        ]}
      ],
      PostToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $pol}]}]
    }
  }' | jq "${1:-.}" > "$A/.claude/settings.json"
}
write_settings_a

run_wrapper "$A" PreToolUse "$(p_run "git status" "$A")"
expect_decision "A1 allowed run_command gets ask" ask
if grep -q "must not reach agy" <<<"$OUT"; then bad "A1b gate stdout is kept off wrapper stdout" "$OUT"; else ok "A1b gate stdout is kept off wrapper stdout"; fi

jq -e --arg ws "$A" --arg id "$CONV" '
  .tool_name == "Bash" and .tool_input.command == "git status" and .cwd == $ws
  and .session_id == $id and .hook_event_name == "PreToolUse"' "$A/last-input.json" >/dev/null \
  && ok "A2 Bash payload carries tool_name, command, cwd, session_id, hook_event_name" \
  || bad "A2 Bash payload" "$(cat "$A/last-input.json")"

export CLAUDE_CODE_SESSION_ID=parent-claude-session
run_wrapper "$A" PreToolUse "$(p_run "ls" "$A" "$A/src")"
unset CLAUDE_CODE_SESSION_ID
grep -qx "APEXYARD_SESSION_ID=$CONV" "$A/last-env.txt" \
  && grep -qx 'CLAUDE_CODE_SESSION_ID=<unset>' "$A/last-env.txt" \
  && grep -qx "CLAUDE_PROJECT_DIR=$A" "$A/last-env.txt" \
  && grep -qx "PWD=$A" "$A/last-env.txt" \
  && ok "A3 gate env: APEXYARD_SESSION_ID from conversationId, inherited CLAUDE_CODE_SESSION_ID removed" \
  || bad "A3 gate env" "$(cat "$A/last-env.txt")"
jq -e --arg c "$A/src" '.cwd == $c' "$A/last-input.json" >/dev/null \
  && ok "A4 run_command Cwd becomes the payload cwd" || bad "A4 payload cwd" "$(cat "$A/last-input.json")"
run_wrapper "$A" PreToolUse "$(p_run "ls" "$A/src")"
grep -qx "CLAUDE_PROJECT_DIR=$A" "$A/last-env.txt" && grep -qx "PWD=$A/src" "$A/last-env.txt" \
  && ok "A4a subfolder workspace: CLAUDE_PROJECT_DIR is the fork root, the gates run in the workspace" \
  || bad "A4a subfolder env" "$(cat "$A/last-env.txt")"

run_wrapper "$A" PreToolUse "$(p_run "echo ok" "$A" "$A/does-not-exist")"
expect_decision "A4b run_command Cwd that does not exist gets deny" deny "Cwd '$A/does-not-exist' is not an existing directory"
run_wrapper "$A" PreToolUse "$(p_run "echo ok" "$A" "src")"
expect_decision "A4c relative Cwd resolves and reaches the gates" ask
jq -e --arg c "$A/src" '.cwd == $c' "$A/last-input.json" >/dev/null \
  && ok "A4d relative Cwd reaches the gates as the physical workspace path" || bad "A4d relative cwd" "$(cat "$A/last-input.json")"
run_wrapper "$A" PreToolUse "$(p_run "echo ok" "$A" "")"
jq -e --arg c "$A" '.cwd == $c' "$A/last-input.json" >/dev/null && [ "$(decision)" = ask ] \
  && ok "A4e empty Cwd uses the workspace" || bad "A4e empty cwd" "$OUT $(cat "$A/last-input.json")"
run_wrapper "$A" PreToolUse "$(jq -cn --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"run_command",args:{CommandLine:"ls",Cwd:7}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "A4f non-string Cwd gets deny" deny "Cwd is not a string"
run_wrapper "$A" PreToolUse "$(p_run "echo ok" "$A" "$A/src
")"
expect_decision "A4h Cwd with a trailing newline gets deny" deny "argument Cwd contains a control character"
run_wrapper "$A" PreToolUse "$(p_run "echo ok" "$A" "$A/s	rc")"
expect_decision "A4i Cwd with an embedded tab gets deny" deny "argument Cwd contains a control character"
run_wrapper "$A" PreToolUse "$(p_run "echo ok" "$A" "$A/src$(printf '\033')[0m")"
expect_decision "A4j Cwd with an ESC character gets deny" deny "argument Cwd contains a control character"
run_wrapper "$A" PreToolUse "$(p_write "$A/src/app.ts
" "x" "$A")"
expect_decision "A4k TargetFile with a newline gets deny" deny "argument TargetFile contains a control character"
run_wrapper "$A" PreToolUse "$(p_run "echo one
echo deny-me" "$A")"
expect_decision "A4l multi-line CommandLine still reaches the gates" deny "refuses deny-me"
jq -e '.tool_input.command == "echo one\necho deny-me"' "$A/last-input.json" >/dev/null \
  && ok "A4m multi-line CommandLine reaches the gates unchanged" || bad "A4m multi-line command" "$(cat "$A/last-input.json")"
run_wrapper "$A" PreToolUse "$(p_run "echo ok" "$A" "src/../../..")"
expect_decision "A4g relative Cwd that leaves the fork still resolves to a real directory" ask

run_wrapper "$A" PreToolUse "$(p_run_top "echo ok" "$A" "$(jq -n --arg d "$A/src" '$d')")"
expect_decision "A4n run_command without Cwd uses the top-level cwd" ask
jq -e --arg c "$A/src" '.cwd == $c and (has("apexyard_cwd_source") | not)' "$A/last-input.json" >/dev/null \
  && ok "A4o the top-level cwd reaches the gates as the payload cwd" || bad "A4o top cwd payload" "$(cat "$A/last-input.json")"
top_and_args=$(jq -cn --arg ws "$A" --arg id "$CONV" --arg args_cwd "$A" --arg top "$A/src" \
  '{toolCall:{name:"run_command",args:{CommandLine:"echo ok",Cwd:$args_cwd}}, conversationId:$id, workspacePaths:[$ws], cwd:$top}')
run_wrapper "$A" PreToolUse "$top_and_args"
jq -e --arg c "$A" '.cwd == $c' "$A/last-input.json" >/dev/null && [ "$(decision)" = ask ] \
  && ok "A4p args.Cwd wins over the top-level cwd" || bad "A4p args.Cwd precedence" "$OUT $(cat "$A/last-input.json")"
run_wrapper "$A" PreToolUse "$(p_run_top "echo ok" "$A" '"src"')"
jq -e --arg c "$A/src" '.cwd == $c' "$A/last-input.json" >/dev/null && [ "$(decision)" = ask ] \
  && ok "A4q a relative top-level cwd resolves against the workspace" || bad "A4q relative top cwd" "$OUT $(cat "$A/last-input.json")"
run_wrapper "$A" PreToolUse "$(p_run_top "echo ok" "$A" "$(jq -n --arg d "$A/no-such-dir" '$d')")"
expect_decision "A4r a top-level cwd that does not exist gets deny" deny "is not an existing directory"
run_wrapper "$A" PreToolUse "$(p_run_top "echo ok" "$A" "$(jq -n --arg d "$TMPROOT" '$d')")"
expect_decision "A4s a top-level cwd outside the fork gets deny" deny "top-level cwd .* is outside the ApexYard fork"
run_wrapper "$A" PreToolUse "$(p_run_top "echo ok" "$A" "$(jq -n --arg d "$A/src" '$d + "\n"')")"
expect_decision "A4t a top-level cwd with a control character gets deny" deny "the top-level cwd contains a control character"
run_wrapper "$A" PreToolUse "$(p_run_top "echo ok" "$A" '7')"
expect_decision "A4u a non-string top-level cwd gets deny" deny "the top-level cwd is not a string"

run_wrapper "$A" PreToolUse "$(p_run "echo deny-me" "$A")"
expect_decision "A5 gate exit 2 gets deny with the gate stderr" deny "record gate refuses deny-me"

run_wrapper "$A" PreToolUse "$(p_run "policy check" "$A")"
expect_decision "A6 if predicate Bash(policy *) runs its handler" deny "policy predicate gate fired"
run_wrapper "$A" PreToolUse "$(p_run "echo not-policy" "$A")"
expect_decision "A7 if predicate skips a non-matching command" ask

run_wrapper "$A" PreToolUse "$(p_run "echo crash-me" "$A")"
expect_decision "A8 non-zero exit without onFailure gets ask (Claude Code semantics)" ask
run_wrapper "$A" PreToolUse "$(p_run "echo strict-crash" "$A")"
expect_decision "A9 non-zero exit with onFailure=block gets deny" deny "onFailure=block"

start=$SECONDS
run_wrapper "$A" PreToolUse "$(p_run "echo sleep-me" "$A")"
elapsed=$((SECONDS - start))
expect_decision "A10 gate past its timeout gets deny" deny "did not finish in 4s"
[ "$elapsed" -lt 15 ] && ok "A10b watchdog stops the gate early (${elapsed}s, the gate sleeps 20s)" || bad "A10b watchdog" "took ${elapsed}s"

run_wrapper "$A" PreToolUse "$(p_write "$A/src/app.ts" "const x = 1;" "$A")"
expect_decision "A11 write_to_file gets ask" ask
jq -e --arg p "$A/src/app.ts" '.tool_name == "Write" and .tool_input.file_path == $p and .tool_input.content == "const x = 1;"' \
  "$A/last-input.json" >/dev/null && ok "A12 write_to_file maps to Write file_path and content" \
  || bad "A12 Write mapping" "$(cat "$A/last-input.json")"

run_wrapper "$A" PreToolUse "$(p_write "src/new-file.ts" "const y = 2;" "$A")"
jq -e --arg p "$A/src/new-file.ts" '.tool_input.file_path == $p' "$A/last-input.json" >/dev/null && [ "$(decision)" = ask ] \
  && ok "A12b relative TargetFile resolves against the workspace (file need not exist)" \
  || bad "A12b relative TargetFile" "$OUT $(cat "$A/last-input.json")"
run_wrapper "$A" PreToolUse "$(p_write "" "x" "$A")"
expect_decision "A12c empty TargetFile gets deny" deny "TargetFile is missing or empty"

run_wrapper "$A" PreToolUse "$(p_write_file "$A/src/w.ts" "const w = 1;" "$A")"
jq -e --arg p "$A/src/w.ts" '.tool_name == "Write" and .tool_input.file_path == $p and .tool_input.content == "const w = 1;"' \
  "$A/last-input.json" >/dev/null && [ "$(decision)" = ask ] \
  && ok "A12d write_file maps Path and Content to Write" || bad "A12d write_file mapping" "$OUT $(cat "$A/last-input.json")"
run_wrapper "$A" PreToolUse "$(p_write_file "src/w.ts" "deny-me" "$A" true)"
expect_decision "A12e write_file with Append=true runs the same gates" deny "refuses deny-me"
jq -e --arg p "$A/src/w.ts" '.tool_name == "Write" and .tool_input.file_path == $p' "$A/last-input.json" >/dev/null \
  && ok "A12f write_file relative Path resolves against the workspace" || bad "A12f write_file relative" "$(cat "$A/last-input.json")"
run_wrapper "$A" PreToolUse "$(p_write_file "" "x" "$A")"
expect_decision "A12g write_file with an empty Path gets deny" deny "argument Path is missing or empty"
run_wrapper "$A" PreToolUse "$(p_write_file "$A/src/w.ts
" "x" "$A")"
expect_decision "A12h write_file Path with a newline gets deny" deny "argument Path contains a control character"
run_wrapper "$A" PreToolUse "$(jq -cn --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"write_file",args:{Path:"src/w.ts",Content:7}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "A12i write_file with a non-string Content gets deny" deny "argument Content is missing or is not a string"

# agy CLI 1.5.14 tool list: write_file Overwrite and ArtifactMetadata,
# read_file ByteOffset, and edit_file.
write_meta=$(jq -cn --arg p "$A/src/w.ts" --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"write_file",args:{Path:$p, Content:"deny-me", Overwrite:true,
  ArtifactMetadata:{Summary:"s", UserFacing:false, RequestFeedback:false}}}, conversationId:$id, workspacePaths:[$ws]}')
run_wrapper "$A" PreToolUse "$write_meta"
expect_decision "A12j write_file with Overwrite and ArtifactMetadata reaches the Write gates" deny "refuses deny-me"
jq -e --arg p "$A/src/w.ts" '.tool_name == "Write" and .tool_input.file_path == $p' "$A/last-input.json" >/dev/null \
  && ok "A12k write_file with Overwrite maps to Write" || bad "A12k write_file overwrite mapping" "$(cat "$A/last-input.json")"
run_wrapper "$A" PreToolUse "$(jq -cn --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"write_file",args:{Path:"src/w.ts", Content:"x", ArtifactMetadata:"summary"}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "A12l ArtifactMetadata that is not an object gets deny" deny "ArtifactMetadata is not an object"
run_wrapper "$A" PreToolUse "$(jq -cn --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"write_file",args:{Path:"src/w.ts", Content:"x", ArtifactMetadata:{Summary:"s", Approve:true}}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "A12m an unknown ArtifactMetadata key gets deny" deny 'ArtifactMetadata has the key "Approve"'
run_wrapper "$A" PreToolUse "$(jq -cn --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"read_file",args:{Path:"README.md", ByteOffset:1024}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "A12n read_file with ByteOffset gets ask" ask
p_edit_file() { # <path> <target> <replacement> <workspace>
  jq -cn --arg p "$1" --arg t "$2" --arg r "$3" --arg ws "$4" --arg id "$CONV" '{
    toolCall: {name: "edit_file", args: {Path: $p, Target: $t, Replacement: $r,
      ArtifactMetadata: {Summary: "edit", UserFacing: false, RequestFeedback: false}, toolSummary: "edit"}},
    conversationId: $id, workspacePaths: [$ws]}'
}
run_wrapper "$A" PreToolUse "$(p_edit_file "src/app.ts" "x = 1" "x = 2" "$A")"
expect_decision "A12o edit_file reaches the Edit gates" ask
jq -e --arg p "$A/src/app.ts" '.tool_name == "Edit" and .tool_input.file_path == $p and .tool_input.old_string == "x = 1"
    and .tool_input.new_string == "x = 2" and .tool_input.replace_all == true' "$A/last-input.json" >/dev/null \
  && ok "A12p edit_file maps Path, Target, Replacement to Edit with replace_all=true" || bad "A12p edit_file mapping" "$(cat "$A/last-input.json")"
run_wrapper "$A" PreToolUse "$(p_edit_file "$A/src/app.ts" "x" "deny-me" "$A")"
expect_decision "A12q edit_file content reaches the gate" deny "refuses deny-me"
run_wrapper "$A" PreToolUse "$(jq -cn --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"edit_file",args:{Path:"src/app.ts", Target:"a", Replacement:"b", AllowMultiple:false}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "A12r edit_file with an unknown key gets deny" deny 'args key "AllowMultiple"'
run_wrapper "$A" PreToolUse "$(jq -cn --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"edit_file",args:{Path:"src/app.ts", Replacement:"b"}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "A12s edit_file without Target gets deny" deny "argument Target is missing or is not a string"

run_wrapper "$A" PreToolUse "$(p_replace "$A/src/app.ts" "x = 1" "x = 2" "$A")"
jq -e '.tool_name == "Edit" and .tool_input.old_string == "x = 1" and .tool_input.new_string == "x = 2" and .tool_input.replace_all == false' \
  "$A/last-input.json" >/dev/null && [ "$(decision)" = ask ] \
  && ok "A13 replace_file_content maps to Edit old_string and new_string" \
  || bad "A13 Edit mapping" "$OUT $(cat "$A/last-input.json")"

multi=$(jq -cn --arg p "$A/src/app.ts" --arg ws "$A" --arg id "$CONV" '{
  toolCall: {name: "multi_replace_file_content", args: {TargetFile: $p, ReplacementChunks: [
    {TargetContent: "a", ReplacementContent: "b", AllowMultiple: true, StartLine: 1, EndLine: 1},
    {TargetContent: "c", ReplacementContent: "deny-me", StartLine: 2, EndLine: 2}]}},
  conversationId: $id, workspacePaths: [$ws]}')
run_wrapper "$A" PreToolUse "$multi"
expect_decision "A14 multi_replace_file_content content reaches the gate" deny "refuses deny-me"
jq -e '.tool_name == "MultiEdit" and (.tool_input.edits | length) == 2 and .tool_input.edits[0].replace_all == true
  and .tool_input.edits[1].new_string == "deny-me"' "$A/last-input.json" >/dev/null \
  && ok "A15 multi_replace_file_content maps to MultiEdit edits" || bad "A15 MultiEdit mapping" "$(cat "$A/last-input.json")"

multi_bad=$(jq -cn --arg p "$A/src/app.ts" --arg ws "$A" --arg id "$CONV" '{
  toolCall: {name: "multi_replace_file_content", args: {TargetFile: $p, ReplacementChunks: [{Old: "a", New: "b"}]}},
  conversationId: $id, workspacePaths: [$ws]}')
run_wrapper "$A" PreToolUse "$multi_bad"
expect_decision "A16 unknown ReplacementChunks shape gets deny" deny "ReplacementChunks item"

run_wrapper "$A" PreToolUse "this is not json"
expect_decision "A17 malformed stdin gets deny" deny "not a JSON object"
run_wrapper "$A" PreToolUse ""
expect_decision "A18 empty stdin gets deny" deny "not a JSON object"
run_wrapper "$A" PreToolUse "$(jq -cn --arg ws "$A" '{toolCall:{name:"run_command",args:{CommandLine:"ls"}}, workspacePaths:[$ws]}')"
expect_decision "A19 missing conversationId gets deny" deny "conversationId"
run_wrapper "$A" PreToolUse "$(jq -cn --arg ws "$A" '{toolCall:{name:"run_command",args:{CommandLine:"ls"}}, conversationId:"../../x", workspacePaths:[$ws]}')"
expect_decision "A20 conversationId with path characters gets deny" deny "conversationId"
run_wrapper "$A" PreToolUse "$(jq -cn --arg id "$CONV" '{toolCall:{name:"run_command",args:{CommandLine:"ls"}}, conversationId:$id}')"
expect_decision "A21 missing workspacePaths gets deny" deny "workspacePaths"
run_wrapper "$A" PreToolUse "$(p_run "ls" "$TMPROOT")"
expect_decision "A22 workspace outside the fork gets deny" deny "outside the ApexYard fork"
run_wrapper "$A" PreToolUse "$(jq -cn --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"run_command",args:{Cwd:"/"}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "A23 run_command without CommandLine gets deny" deny "CommandLine"
p_tool() { # <agy tool name> <workspace>
  jq -cn --arg t "$1" --arg ws "$2" --arg id "$CONV" '{toolCall:{name:$t,args:{}}, conversationId:$id, workspacePaths:[$ws]}'
}
run_wrapper "$A" PreToolUse "$(p_tool frobnicate_everything "$A")"
expect_decision "A24 unknown agy tool gets deny naming the tool" deny "agy tool 'frobnicate_everything' is not routed by the ApexYard adapter"
run_wrapper "$A" PreToolUse "$(p_tool mcp_github_create_pull_request "$A")"
expect_decision "A24b mcp_* tool gets deny" deny "'mcp_github_create_pull_request' is not routed"
for t in invoke_subagent define_subagent manage_subagents schedule browser_subagent browser_action send_message generate_image run_persistent; do
  run_wrapper "$A" PreToolUse "$(p_tool "$t" "$A")"
  expect_decision "A24c $t gets deny" deny "'$t' is not routed"
done
run_wrapper "$A" PreToolUse "$(p_tool send_command_input "$A")"
expect_decision "A24d send_command_input is always denied" deny "keystrokes"
p_task() { # <action JSON value> <workspace>
  jq -cn --argjson act "$1" --arg ws "$2" --arg id "$CONV" \
    '{toolCall:{name:"manage_task",args:({TaskId:"t1"} + (if $act == null then {} else {Action:$act} end))}, conversationId:$id, workspacePaths:[$ws]}'
}
for act in list kill status; do
  run_wrapper "$A" PreToolUse "$(p_task "\"$act\"" "$A")"
  expect_decision "A24e manage_task Action $act gets ask" ask
done
run_wrapper "$A" PreToolUse "$(p_task '"send_input"' "$A")"
expect_decision "A24f manage_task Action send_input gets the keystroke deny" deny "Action send_input is always denied. It types keystrokes"
run_wrapper "$A" PreToolUse "$(p_task null "$A")"
expect_decision "A24g manage_task without an Action gets deny" deny "manage_task needs a string Action"
run_wrapper "$A" PreToolUse "$(p_task '"restart"' "$A")"
expect_decision "A24h manage_task with an unknown Action gets deny" deny "manage_task needs a string Action"
run_wrapper "$A" PreToolUse "$(p_task 3 "$A")"
expect_decision "A24i manage_task with a non-string Action gets deny" deny "manage_task needs a string Action"
run_wrapper "$A" PreToolUse "$(p_task '"list\n"' "$A")"
expect_decision "A24j manage_task Action with a control character gets deny" deny "manage_task needs a string Action"
# Duplicate and case-variant keys: raw JSON text, because jq would merge them.
raw_payload() { # <args JSON text> <tool name>
  printf '{"toolCall":{"name":"%s","args":%s},"conversationId":"%s","workspacePaths":["%s"]}' "$2" "$1" "$CONV" "$A"
}
# jq keeps the last duplicate. With "list" last, jq would see a safe action.
run_wrapper "$A" PreToolUse "$(raw_payload '{"Action":"send_input","TaskId":"task-20","Action":"list"}' manage_task)"
expect_decision "A24n duplicate Action key gets deny" deny 'repeats the key\(s\) "Action"'
run_wrapper "$A" PreToolUse "$(raw_payload '{"Action":"list","TaskId":"task-20","Action":"send_input"}' manage_task)"
expect_decision "A24n2 duplicate Action ending in send_input gets the keystroke deny" deny 'Action send_input is always denied'
run_wrapper "$A" PreToolUse "$(raw_payload '{"Action":"list","action":"send_input","TaskId":"task-20"}' manage_task)"
expect_decision "A24o case-variant action key gets deny" deny 'the keys "Action" and "action" differ only in case'
run_wrapper "$A" PreToolUse "$(raw_payload '{"CommandLine":"git status","WaitMsBeforeAsync":500,"CommandLine":"git add -A"}' run_command)"
expect_decision "A24p duplicate CommandLine key gets deny" deny 'repeats the key\(s\) "CommandLine"'
run_wrapper "$A" PreToolUse "$(raw_payload '{"CommandLine":"git status","commandline":"git add -A"}' run_command)"
expect_decision "A24q case-variant CommandLine key gets deny" deny 'differ only in case'
run_wrapper "$A" PreToolUse "$(raw_payload '{"Action":"list","TaskId":"task-20","Input":"git add -A"}' manage_task)"
expect_decision "A24r unknown key on manage_task gets deny naming it" deny 'args key "Input", which is not on its key list'
run_wrapper "$A" PreToolUse "$(raw_payload '{"CommandLine":"git status","Shell":"/bin/zsh"}' run_command)"
expect_decision "A24s unknown key on run_command gets deny naming it" deny 'args key "Shell", which is not on its key list'
run_wrapper "$A" PreToolUse "$(raw_payload '{"Action":"kill","TaskId":"task-20","toolSummary":"stop the daemon"}' manage_task)"
expect_decision "A24t valid manage_task kill with toolSummary gets ask" ask
run_wrapper "$A" PreToolUse "$(raw_payload '{"CommandLine":"git status","WaitMsBeforeAsync":500,"toolSummary":"status","IsDaemon":false,"BypassSandbox":false}' run_command)"
expect_decision "A24u valid run_command with toolSummary reaches the gates" ask
# An existing terminal can sit in another directory than the gated Cwd.
run_wrapper "$A" PreToolUse "$(raw_payload '{"CommandLine":"rm -f settings.json","RequestedTerminalID":"term-1"}' run_command)"
expect_decision "A24ua run_command with RequestedTerminalID gets deny" deny "RequestedTerminalID runs in an existing terminal whose directory the gates cannot see"
run_wrapper "$A" PreToolUse "$(raw_payload '{"CommandLine":"git status","RequestedTerminalID":""}' run_command)"
expect_decision "A24ub run_command with an empty RequestedTerminalID gets deny" deny "runs in an existing terminal whose directory the gates cannot see"
run_wrapper "$A" PreToolUse "$(raw_payload '{"CommandLine":"cd .claude/hooks","RunPersistent":true}' run_command)"
expect_decision "A24uc run_command with RunPersistent true gets deny" deny "RunPersistent runs in an existing terminal whose directory the gates cannot see"
run_wrapper "$A" PreToolUse "$(raw_payload '{"CommandLine":"git status","RunPersistent":"true"}' run_command)"
expect_decision "A24ud run_command with RunPersistent \"true\" as a string gets deny" deny "RunPersistent runs in an existing terminal"
run_wrapper "$A" PreToolUse "$(raw_payload '{"CommandLine":"git status","RunPersistent":null}' run_command)"
expect_decision "A24ue run_command with RunPersistent null gets deny" deny "RunPersistent runs in an existing terminal"
run_wrapper "$A" PreToolUse "$(raw_payload '{"CommandLine":"git status","RunPersistent":false}' run_command)"
expect_decision "A24uf run_command with RunPersistent false still reaches the gates" ask
# The repo enforces, not agy: agy may not drop its terminal sandbox.
for v in true '"true"' null 1; do
  # Build the args outside "$(...)": bash 3.2 mangles escaped quotes there.
  bypass_args=$(jq -cn --argjson b "$v" '{CommandLine: "git status", BypassSandbox: $b}')
  run_wrapper "$A" PreToolUse "$(raw_payload "$bypass_args" run_command)"
  expect_decision "A24ug run_command with BypassSandbox $v gets deny" deny "BypassSandbox asks agy to run outside its terminal sandbox; ApexYard does not allow agy to drop its sandbox"
done
run_wrapper "$A" PreToolUse "$(raw_payload '{"CommandLine":"git status","BypassSandbox":false}' run_command)"
expect_decision "A24uh run_command with BypassSandbox false still reaches the gates" ask
run_wrapper "$A" PreToolUse "$(raw_payload '{"CommandLine":"sh","IsDaemon":true}' run_command)"
expect_decision "A24ui run_command with IsDaemon true still reaches the gates" ask
# Keep the escaped literal outside "$(...)": bash 3.2 mangles backslashes
# in single quotes inside a double-quoted command substitution.
string_args='"{\"CommandLine\":\"git status\",\"CommandLine\":\"git add -A\"}"'
run_wrapper "$A" PreToolUse "$(raw_payload "$string_args" run_command)"
expect_decision "A24v duplicate key inside a string args gets deny" deny 'toolCall.args repeats the key\(s\) "CommandLine"'
run_wrapper "$A" PreToolUse "$(raw_payload '{"TargetFile":"/x","ReplacementChunks":[{"TargetContent":"a","ReplacementContent":"b","replacementcontent":"c"}]}' multi_replace_file_content)"
expect_decision "A24w case-variant key inside a ReplacementChunks item gets deny" deny 'differ only in case'
run_wrapper "$A" PreToolUse "$(raw_payload '{"Action":"send_input","TaskId":"task-20","Input":"git add -A"}' manage_task)"
expect_decision "A24wa send_input with Input gets the keystroke deny" deny 'Action send_input is always denied. It types keystrokes'
run_wrapper "$A" PreToolUse "$(raw_payload '{"Action":"send_input","Bogus":1,"bogus":2}' manage_task)"
expect_decision "A24wb send_input keystroke reason wins over other key faults" deny 'Action send_input is always denied. It types keystrokes'
run_wrapper "$A" PreToolUse "$(raw_payload '{"Action":"status","TaskId":"task-20","Input":"x"}' manage_task)"
expect_decision "A24wc status with an Input key gets deny" deny 'args key "Input", which is not on its key list'
chunks_string='{"TargetFile":"/x","ReplacementChunks":"[{\"TargetContent\":\"a\",\"ReplacementContent\":\"b\"}]"}'
run_wrapper "$A" PreToolUse "$(raw_payload "$chunks_string" multi_replace_file_content)"
expect_decision "A24wd string-typed ReplacementChunks gets deny" deny 'ReplacementChunks is a string, not an array'
run_wrapper "$A" PreToolUse "$(raw_payload '{"TargetFile":"/x","ReplacementChunks":[{"TargetContent":"a","ReplacementContent":"b","Extra":1}]}' multi_replace_file_content)"
expect_decision "A24we unknown key in a ReplacementChunks item gets deny" deny 'ReplacementChunks item has the key "Extra"'
run_wrapper "$A" PreToolUse "$(raw_payload '{"TargetFile":"/x","ReplacementChunks":[{"TargetContent":"a","ReplacementContent":"b","ReplacementContent":"c"}]}' multi_replace_file_content)"
expect_decision "A24wf duplicate key in a ReplacementChunks item gets deny" deny 'repeats the key\(s\) "ReplacementContent"'
run_wrapper "$A" PreToolUse "$(printf '{"toolCall":{"name":"view_file","name":"run_command","args":{}},"conversationId":"%s","workspacePaths":["%s"]}' "$CONV" "$A")"
expect_decision "A24x duplicate toolCall.name gets deny" deny 'repeats the key\(s\) "name"'

run_wrapper "$A" PreToolUse "$(raw_payload '{"TaskId":"task-20","Action":"send_input","Action":"list"}' manage_task)"
expect_decision "A24y adjacent duplicate Action key gets deny" deny 'repeats the key\(s\) "Action"'
run_wrapper "$A" PreToolUse "$(raw_payload '{"CommandLine":{"x":"git status"},"CommandLine":"git add -A"}' run_command)"
expect_decision "A24z nested value then scalar duplicate gets deny" deny 'repeats the key\(s\) "CommandLine"'

run_wrapper "$A" PreToolUse "$(p_tool "view_file
" "$A")"
expect_decision "A24k tool name with a trailing newline gets deny" deny "toolCall.name holds characters outside"
run_wrapper "$A" PreToolUse "$(jq -cn --arg ws "$A" --arg id "$CONV
" '{toolCall:{name:"run_command",args:{CommandLine:"ls"}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "A24l conversationId with a trailing newline gets deny" deny "conversationId"
run_wrapper "$A" PreToolUse "$(p_run "ls" "$A
")"
expect_decision "A24m workspace path with a trailing newline gets deny" deny "workspacePaths"
args_string=$(jq -cn --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"run_command",args:({CommandLine:"echo deny-me"}|tojson)}, conversationId:$id, workspacePaths:[$ws]}')
run_wrapper "$A" PreToolUse "$args_string"
expect_decision "A25 args as a JSON string still reach the gate" deny "refuses deny-me"

# Read-only tools get allow before settings.json is read: a broken
# settings.json would deny any gated tool.
cp "$A/.claude/settings.json" "$A/settings.good"
printf '{ not json' > "$A/.claude/settings.json"
# grep_search reads file content under a folder, which a path rule cannot
# see. So it is not read-only, and it gets the unrouted deny.
run_wrapper "$A" PreToolUse "$(p_tool grep_search "$A")"
expect_decision "A25a grep_search gets deny as an unrouted tool" deny "'grep_search' is not routed"
for t in read_file view_file list_dir find_by_name search_web read_url_content command_status read_terminal ask_question ask_permission list_permissions; do
  run_wrapper "$A" PreToolUse "$(p_tool "$t" "$A")"
  expect_decision "A25b read-only $t gets ask without settings.json" ask
done
run_wrapper "$A" PreToolUse "$(p_run "git status" "$A")"
expect_decision "A25c a gated tool with the same broken settings.json gets deny" deny "not valid JSON"
run_wrapper "$A" PreToolUse "$(jq -cn --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"read_file",args:{Path:"README.md"}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "A25c2 read_file with a path and an unreadable settings.json gets deny" deny "cannot read permissions.deny"
mv "$A/settings.good" "$A/.claude/settings.json"

# permissions.deny Edit(...) and Write(...) rules, and a rule type that the
# wrapper does not apply.
cp "$A/.claude/settings.json" "$A/settings.good"
jq '.permissions = {deny: ["Edit(//**/locked/**)", "Write(secret.txt)", "WebFetch(domain:example.com)"]}' \
  "$A/settings.good" > "$A/.claude/settings.json"
run_wrapper "$A" PreToolUse "$(p_write_file "$A/locked/a.ts" "x" "$A")"
expect_decision "A25f write_file under an Edit(...) rule gets deny" deny 'rule Edit\(//\*\*/locked/\*\*\)'
run_wrapper "$A" PreToolUse "$(jq -cn --arg p "$A/locked/b.ts" --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"edit_file",args:{Path:$p,Target:"a",Replacement:"b"}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "A25g edit_file under an Edit(...) rule gets deny" deny 'rule Edit\(//\*\*/locked/\*\*\)'
run_wrapper "$A" PreToolUse "$(p_write_file "$A/sub/secret.txt" "x" "$A")"
expect_decision "A25h write_file under a fork-relative Write(...) rule gets deny" deny 'rule Write\(secret\.txt\)'
run_wrapper "$A" PreToolUse "$(jq -cn --arg p "$A/sub/secret.txt" --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"edit_file",args:{Path:$p,Target:"a",Replacement:"b"}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "A25i edit_file is not under a Write(...) rule" ask
run_wrapper "$A" PreToolUse "$(jq -cn --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"read_url_content",args:{Url:"https://example.com/"}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "A25j a WebFetch(...) rule is not applied" ask
jq '.permissions = {deny: "Read(//**/.env)"}' "$A/settings.good" > "$A/.claude/settings.json"
run_wrapper "$A" PreToolUse "$(jq -cn --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"read_file",args:{Path:"README.md"}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "A25k a permissions.deny that is not an array gets deny" deny "cannot read permissions.deny"
mv "$A/settings.good" "$A/.claude/settings.json"

# A nearer nested anchor would make the settings.json resolver run another
# fork's gates. Its stub gates allow everything, so only the root check denies.
N="$A/nested-fork"
mkdir -p "$N/.claude/hooks"
: > "$N/.apexyard-fork"
for g in record-gate.sh strict-gate.sh policy-gate.sh; do
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$N/.claude/hooks/$g"
done
chmod +x "$N/.claude/hooks/"*.sh
run_wrapper "$A" PreToolUse "$(p_run "echo deny-me" "$N")"
expect_decision "A25d workspace with a nested fake fork anchor gets deny" deny "resolves to a different ApexYard fork"
mkdir -p "$A/plain-dir"
run_wrapper "$A" PreToolUse "$(p_run "echo deny-me" "$A/plain-dir")"
expect_decision "A25e workspace in a plain subdirectory of the fork reaches the gate" deny "refuses deny-me"
rm -rf "$N" "$A/plain-dir"

# A nested .agents hook or plugin config between agy's directory and the
# fork root could override the fork's hooks. Every call gets deny.
NA_RX="nested \.agents hook or plugin config at $A/sub/\.agents can override the fork's hooks; remove it from the live fork"
mkdir -p "$A/sub/deeper/.agents" "$A/sub/.agents" "$A/other/.agents"
for kind in hooks.json plugins.json plugins; do
  if [ "$kind" = plugins ]; then mkdir -p "$A/sub/.agents/plugins"; else printf '{}' > "$A/sub/.agents/$kind"; fi
  run_wrapper "$A" PreToolUse "$(p_tool list_dir "$A/sub/deeper")"
  expect_decision "A25n1 nested .agents/$kind gets deny for a read-only tool" deny "$NA_RX"
  run_wrapper "$A" PreToolUse "$(p_run "git status" "$A/sub/deeper")"
  expect_decision "A25n2 nested .agents/$kind gets deny for run_command" deny "$NA_RX"
  run_wrapper "$A" PreToolUse "$(p_run_top "git status" "$A" "\"$A/sub/deeper\"")"
  expect_decision "A25n3 nested .agents/$kind on the top-level cwd path gets deny" deny "$NA_RX"
  run_wrapper "$A" SessionStart "$(p_session "$A/sub/deeper")"
  printf '%s' "$OUT" | jq -e '.injectSteps | length == 1 and (.[0].errorMessage.userMessage | test("nested .agents hook or plugin config at .*/sub/.agents"))' >/dev/null 2>&1 \
    && ok "A25n4 nested .agents/$kind gives a SessionStart error step" || bad "A25n4 SessionStart nested $kind" "$OUT"
  rm -rf "$A/sub/.agents/$kind"
done
ln -s "$A/no-such-file.json" "$A/sub/.agents/hooks.json"
run_wrapper "$A" PreToolUse "$(p_tool list_dir "$A/sub")"
expect_decision "A25n5 a dangling nested .agents/hooks.json symlink gets deny" deny "$NA_RX"
rm -f "$A/sub/.agents/hooks.json"
# Off the path: a sibling, the fork root's own wiring, and a managed project.
printf '{}' > "$A/other/.agents/hooks.json"
run_wrapper "$A" PreToolUse "$(p_tool list_dir "$A/sub/deeper")"
expect_decision "A25n6 a sibling folder's .agents/hooks.json is not on the path" ask
na_root_made=0
if [ ! -e "$A/.agents/hooks.json" ]; then mkdir -p "$A/.agents"; printf '{}' > "$A/.agents/hooks.json"; na_root_made=1; fi
mkdir -p "$A/workspace/proj/.agents/plugins"
printf '{}' > "$A/workspace/proj/.agents/hooks.json"
run_wrapper "$A" PreToolUse "$(p_tool list_dir "$A")"
expect_decision "A25n7 the fork root's own .agents wiring is not denied" ask
run_wrapper "$A" PreToolUse "$(p_run "git status" "$A")"
expect_decision "A25n8 a managed project's .agents under workspace/ does not trip agy at the fork root" ask
# A linked worktree is its own fork root: its .agents/ is its wiring, and
# the parent fork's .agents/ is above the walk.
W="$A/.claude/worktrees/wt"
mkdir -p "$W/.claude" "$W/.agents"
: > "$W/.apexyard-fork"
cp -R "$A/.claude/hooks" "$W/.claude/hooks"
cp "$A/.claude/settings.json" "$W/.claude/settings.json"
copy_adapter "$W"
printf '{}' > "$W/.agents/hooks.json"
run_wrapper "$W" PreToolUse "$(p_tool list_dir "$W")"
expect_decision "A25n9 a worktree session with its own wiring is not denied (read-only)" ask
run_wrapper "$W" PreToolUse "$(p_run "git status" "$W")"
expect_decision "A25n10 a worktree session with its own wiring is not denied (run_command)" ask
rm -rf "$A/.claude/worktrees" "$A/sub" "$A/other" "$A/workspace"
[ "$na_root_made" = 0 ] || rm -f "$A/.agents/hooks.json"

run_wrapper "$A" Bogus "$(p_run "ls" "$A")"
expect_decision "A26 unknown event argument gets deny" deny "unknown event"

# Missing gate script.
write_settings_a
jq --arg x "$(shim_for no-such-gate.sh)" '.hooks.PreToolUse[1].hooks += [{type:"command", command:$x}]' \
  "$A/.claude/settings.json" > "$A/s.tmp" && mv "$A/s.tmp" "$A/.claude/settings.json"
run_wrapper "$A" PreToolUse "$(p_run "git status" "$A")"
expect_decision "A27 missing gate script gets deny" deny "no-such-gate.sh is missing"

# A gate the resolver can exec but that is not executable.
write_settings_a
chmod -x "$A/.claude/hooks/strict-gate.sh"
run_wrapper "$A" PreToolUse "$(p_run "git status" "$A")"
expect_decision "A28 gate that cannot execute (exit 126) gets deny" deny "could not run"
chmod +x "$A/.claude/hooks/strict-gate.sh"

# Non-command handler type.
jq '.hooks.PreToolUse[1].hooks += [{type:"prompt", prompt:"judge it"}]' "$A/.claude/settings.json" > "$A/s.tmp" \
  && mv "$A/s.tmp" "$A/.claude/settings.json"
run_wrapper "$A" PreToolUse "$(p_run "git status" "$A")"
expect_decision "A29 non-command handler type gets deny" deny "type 'prompt'"
write_settings_a

# Broken settings.json.
cp "$A/.claude/settings.json" "$A/settings.good"
printf '{ not json' > "$A/.claude/settings.json"
run_wrapper "$A" PreToolUse "$(p_run "git status" "$A")"
expect_decision "A30 invalid settings.json gets deny" deny "not valid JSON"
mv "$A/settings.good" "$A/.claude/settings.json"

# jq missing: PATH holds only bash builtins' needs.
EMPTY_BIN="$TMPROOT/empty-bin"
mkdir -p "$EMPTY_BIN"
OUT=$(printf '%s' "$(p_run "git status" "$A")" | PATH="$EMPTY_BIN" /bin/bash "$A/harness-adapters/agy/agy-hook.sh" PreToolUse 2>/dev/null)
RC=$?
printf '%s\n' "$OUT" >> "$ALL_OUT"
case "$OUT" in
  '{"decision":"deny","reason":"ApexYard agy adapter: jq is not installed'*) ok "A31 missing jq gets deny" ;;
  *) bad "A31 missing jq gets deny" "rc=$RC out=$OUT" ;;
esac

# Fork without an anchor file.
rm -f "$A/.apexyard-fork"
run_wrapper "$A" PreToolUse "$(p_run "git status" "$A")"
expect_decision "A32 fork without .apexyard-fork or onboarding.yaml gets deny" deny "Run /setup first"
: > "$A/.apexyard-fork"

# SessionStart.
run_wrapper "$A" SessionStart "$(p_session "$A")"
printf '%s' "$OUT" | jq -e '.injectSteps | length == 1 and (.[0] | keys == ["systemMessage"])
    and (.[0].systemMessage | type) == "object" and (.[0].systemMessage.systemMessage | contains("ApexYard banner line"))' >/dev/null \
  && ok "A33 SessionStart returns hook stdout in the nested systemMessage.systemMessage shape" || bad "A33 SessionStart" "$OUT"
jq -e --arg id "$CONV" --arg ws "$A" '.session_id == $id and .cwd == $ws and .hook_event_name == "SessionStart" and .source == "startup"' \
  "$A/last-session-input.json" >/dev/null && ok "A34 SessionStart payload carries session_id, cwd, source" \
  || bad "A34 SessionStart payload" "$(cat "$A/last-session-input.json")"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho context-line\nexit 3\n' > "$A/.claude/hooks/banner.sh"
run_wrapper "$A" SessionStart "$(p_session "$A")"
printf '%s' "$OUT" | jq -e '.injectSteps | length == 2
    and .[0].systemMessage.systemMessage == "context-line\n"
    and (.[1] | keys == ["errorMessage"]) and (.[1].errorMessage | keys == ["userMessage"])
    and (.[1].errorMessage.userMessage | contains("banner.sh exited 3"))' >/dev/null \
  && ok "A33b a failing SessionStart hook adds a nested errorMessage.userMessage step" || bad "A33b SessionStart error step" "$OUT"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$A/.claude/hooks/banner.sh"
run_wrapper "$A" SessionStart "$(p_session "$A")"
[ "$OUT" = '{"injectSteps":[]}' ] && ok "A35 silent SessionStart hook adds no step" || bad "A35 silent SessionStart" "$OUT"
run_wrapper "$A" SessionStart "not json"
printf '%s' "$OUT" | jq -e '.injectSteps[0] | keys == ["errorMessage"] and (.errorMessage.userMessage | contains("not a JSON object"))' >/dev/null \
  && ok "A36 malformed SessionStart payload returns a nested errorMessage step" || bad "A36 SessionStart malformed" "$OUT"
OUT=$(printf '{}' | PATH="$EMPTY_BIN" /bin/bash "$A/harness-adapters/agy/agy-hook.sh" SessionStart 2>/dev/null)
printf '%s\n' "$OUT" >> "$ALL_OUT"
printf '%s' "$OUT" | jq -e '.injectSteps[0].errorMessage.userMessage | contains("jq is not installed")' >/dev/null \
  && ok "A36b SessionStart without jq returns a nested errorMessage step" || bad "A36b SessionStart no jq" "$OUT"

# --budget.
b_bash=$(bash "$A/harness-adapters/agy/agy-hook.sh" --budget PreToolUse Bash)
b_write=$(bash "$A/harness-adapters/agy/agy-hook.sh" --budget PreToolUse Write)
b_read=$(bash "$A/harness-adapters/agy/agy-hook.sh" --budget PreToolUse Read)
b_ss=$(bash "$A/harness-adapters/agy/agy-hook.sh" --budget SessionStart)
# Bash: 4 + 5 + 30 (default) + 15 margin = 54. Write: 4 + 15 = 19. SessionStart: 30 + 15 = 45.
[ "$b_bash" = 54 ] && [ "$b_write" = 19 ] && [ "$b_read" = 0 ] && [ "$b_ss" = 45 ] \
  && ok "A37 --budget sums handler timeouts plus the margin" \
  || bad "A37 --budget" "bash=$b_bash write=$b_write read=$b_read session=$b_ss"

# ==============================================================================
echo "== Part B: generator, --check, and Codex co-existence"

SYNC="$A/bin/sync-agy-adapter.sh"
if bash "$SYNC" > "$TMPROOT/sync.out" 2>&1; then ok "B1 sync writes .agents/hooks.json"; else bad "B1 sync" "$(cat "$TMPROOT/sync.out")"; fi
H="$A/.agents/hooks.json"
jq -e --arg w "$A/harness-adapters/agy/agy-hook.sh" '
  (keys == ["apexyard"])
  and (.apexyard.PreToolUse | length) == 1
  and .apexyard.PreToolUse[0].matcher == ".*"
  and (.apexyard.PreToolUse[0].hooks | length) == 1
  and (.apexyard.PreToolUse[0].hooks[0].command | contains($w) and endswith(" PreToolUse"))
  and .apexyard.PreToolUse[0].hooks[0].timeout == 54
  and (.apexyard.SessionStart | length) == 1
  and (.apexyard.SessionStart[0].command | endswith(" SessionStart"))
  and (.apexyard.SessionStart[0].timeout) == 45
' "$H" >/dev/null && ok "B2 hooks.json routes every agy tool through one catch-all entry with the largest budget" \
  || bad "B2 hooks.json shape" "$(cat "$H")"
grep -q "auto_approve" "$H" && bad "B3 hooks.json never names auto_approve" "found" || ok "B3 hooks.json never names auto_approve"
jq '.apexyard.PreToolUse = []' "$H" > "$A/h.tmp" && cp "$H" "$A/h.good" && mv "$A/h.tmp" "$H"
if bash "$SYNC" --check > "$TMPROOT/check.out" 2>&1; then bad "B4 --check catches removal of the catch-all entry" "exit 0"
else grep -q "DRIFT" "$TMPROOT/check.out" && ok "B4 --check catches removal of the catch-all entry" || bad "B4 message" "$(cat "$TMPROOT/check.out")"; fi
mv "$A/h.good" "$H"
# The generator refuses a wrapper whose gated-tool list differs from its own.
cp "$A/harness-adapters/agy/agy-hook.sh" "$A/wrapper.good"
awk '/^GATED_TOOLS=/ { print "GATED_TOOLS=\"run_command write_to_file\""; next } { print }' "$A/wrapper.good" \
  > "$A/harness-adapters/agy/agy-hook.sh"
if bash "$SYNC" --check > "$TMPROOT/check.out" 2>&1; then bad "B4b sync refuses a GATED_TOOLS mismatch" "exit 0"
else grep -q "GATED_TOOLS" "$TMPROOT/check.out" && ok "B4b sync refuses a GATED_TOOLS mismatch" || bad "B4b message" "$(cat "$TMPROOT/check.out")"; fi
cp "$A/wrapper.good" "$A/harness-adapters/agy/agy-hook.sh"
rm -f "$A/wrapper.good"

# The generated command runs the wrapper. Execute it the way a shell would.
gen_cmd=$(jq -r '.apexyard.PreToolUse[0].hooks[0].command' "$H")
OUT=$(cd / && printf '%s' "$(p_run "echo deny-me" "$A")" | bash -c "$gen_cmd" 2>/dev/null)
RC=$?
printf '%s\n' "$OUT" >> "$ALL_OUT"
expect_decision "B5 generated command from another cwd reaches the gate" deny "refuses deny-me"

bash "$SYNC" --check > "$TMPROOT/check.out" 2>&1 && ok "B6 --check passes on a fresh install" \
  || bad "B6 --check fresh" "$(cat "$TMPROOT/check.out")"
jq '.apexyard.PreToolUse[0].hooks[0].timeout = 5' "$H" > "$A/h.tmp" && mv "$A/h.tmp" "$H"
if bash "$SYNC" --check > "$TMPROOT/check.out" 2>&1; then bad "B7 --check fails after a manual edit" "exit 0"
else grep -q "DRIFT" "$TMPROOT/check.out" && ok "B7 --check fails after a manual edit" || bad "B7 drift message" "$(cat "$TMPROOT/check.out")"; fi
bash "$SYNC" >/dev/null 2>&1
jq '.hooks.PreToolUse[1].hooks[0].timeout = 9' "$A/.claude/settings.json" > "$A/s.tmp" && mv "$A/s.tmp" "$A/.claude/settings.json"
if bash "$SYNC" --check >/dev/null 2>&1; then bad "B8 --check fails after a settings.json change" "exit 0"; else ok "B8 --check fails after a settings.json change"; fi
write_settings_a
rm -f "$H"
if bash "$SYNC" --check > "$TMPROOT/check.out" 2>&1; then bad "B9 --check fails when hooks.json is missing" "exit 0"
else grep -q "missing" "$TMPROOT/check.out" && ok "B9 --check fails when hooks.json is missing" || bad "B9 message" "$(cat "$TMPROOT/check.out")"; fi

# The generator leaves .agents/skills alone.
mkdir -p "$A/.agents/skills/status"
printf 'codex skill\n' > "$A/.agents/skills/status/SKILL.md"
bash "$SYNC" >/dev/null 2>&1
[ "$(cat "$A/.agents/skills/status/SKILL.md")" = "codex skill" ] && ok "B10 sync does not touch .agents/skills" \
  || bad "B10 .agents/skills" "changed"

# A Codex sync and a Codex --clean keep .agents/hooks.json.
mkdir -p "$A/.claude/skills/status"
printf -- '---\nname: status\ndescription: s\n---\nbody\n' > "$A/.claude/skills/status/SKILL.md"
bash "$A/bin/sync-codex-adapter.sh" > "$TMPROOT/codex.out" 2>&1 || bad "B11 codex sync runs" "$(cat "$TMPROOT/codex.out")"
[ -f "$H" ] && ok "B11 Codex sync keeps .agents/hooks.json" || bad "B11 Codex sync" "hooks.json deleted"
mkdir -p "$A/.agents/skills/stale"
printf 'stale\n' > "$A/.agents/skills/stale/SKILL.md"
bash "$A/bin/sync-codex-adapter.sh" --clean > "$TMPROOT/codex.out" 2>&1 || bad "B12 codex --clean runs" "$(cat "$TMPROOT/codex.out")"
[ -f "$H" ] && [ -f "$A/.agents/skills/status/SKILL.md" ] && [ -f "$A/.codex/hooks.json" ] \
  && [ ! -e "$A/.agents/skills/stale" ] \
  && ok "B12 Codex --clean keeps .agents/hooks.json and regenerates its own output" \
  || bad "B12 Codex --clean" "$(ls -R "$A/.agents" "$A/.codex" 2>&1 | head -20)"
bash "$SYNC" --check >/dev/null 2>&1 && ok "B13 agy --check still passes after Codex --clean" || bad "B13 agy --check after codex" "drift"
bash "$A/bin/sync-codex-adapter.sh" --check >/dev/null 2>&1 && ok "B14 Codex --check ignores .agents/hooks.json" || bad "B14 codex --check" "drift"

# Refuse to overwrite a hooks.json that the generator does not own.
printf '{"mine": {"PreToolUse": []}}\n' > "$H"
if bash "$SYNC" > "$TMPROOT/sync.out" 2>&1; then bad "B15 sync refuses a foreign hooks.json" "exit 0"
else grep -q '"mine"' "$H" && ok "B15 sync refuses a foreign hooks.json" || bad "B15 foreign file changed" "$(cat "$H")"; fi
rm -f "$H"

# Refuse a symlinked output path.
ln -s "$TMPROOT/elsewhere.json" "$H"
if bash "$SYNC" >/dev/null 2>&1; then bad "B16 sync refuses a symlinked hooks.json" "exit 0"; else ok "B16 sync refuses a symlinked hooks.json"; fi
rm -f "$H"

# Fail loud on a PreToolUse group that reaches no routed agy tool.
jq '.hooks.PreToolUse += [{matcher: "Read|Grep", hooks: [{type: "command", command: "true"}]}]' \
  "$A/.claude/settings.json" > "$A/s.tmp" && mv "$A/s.tmp" "$A/.claude/settings.json"
if bash "$SYNC" > "$TMPROOT/sync.out" 2>&1; then bad "B17 sync fails on an unroutable PreToolUse group" "exit 0"
else grep -q "Read|Grep" "$TMPROOT/sync.out" && ok "B17 sync fails on an unroutable PreToolUse group" || bad "B17 message" "$(cat "$TMPROOT/sync.out")"; fi
write_settings_a
# A NotebookEdit-only group has no agy tool and is allowed.
jq '.hooks.PreToolUse += [{matcher: "NotebookEdit", hooks: [{type: "command", command: "true"}]}]' \
  "$A/.claude/settings.json" > "$A/s.tmp" && mv "$A/s.tmp" "$A/.claude/settings.json"
bash "$SYNC" >/dev/null 2>&1 && ok "B18 a NotebookEdit-only group is skipped" || bad "B18 NotebookEdit group" "sync failed"
write_settings_a
# A non-command handler fails generation.
jq '.hooks.PreToolUse[1].hooks += [{type:"prompt", prompt:"x"}]' "$A/.claude/settings.json" > "$A/s.tmp" \
  && mv "$A/s.tmp" "$A/.claude/settings.json"
if bash "$SYNC" >/dev/null 2>&1; then bad "B19 sync fails on a non-command handler" "exit 0"; else ok "B19 sync fails on a non-command handler"; fi
write_settings_a

# ==============================================================================
echo "== Part D: opt-in decision log"

DEFAULT_LOG="$A/.claude/session/agy-hooks.log"
rm -rf "$A/.claude/session"
run_wrapper "$A" PreToolUse "$(p_run "echo deny-me" "$A")"
if [ ! -e "$DEFAULT_LOG" ] && [ ! -d "$A/.claude/session" ]; then
  ok "D1 log is off by default: nothing written"
else
  bad "D1 log off by default" "$(ls -la "$A/.claude/session" 2>&1)"
fi

ENV_LOG="$TMPROOT/logs/env.log"
export APEXYARD_AGY_HOOK_LOG="$ENV_LOG"
run_wrapper "$A" PreToolUse "$(p_run "echo deny-me" "$A")"
unset APEXYARD_AGY_HOOK_LOG
expect_decision "D2 decision is unchanged with the env log on" deny "refuses deny-me"
if [ "$(wc -l < "$ENV_LOG" 2>/dev/null | tr -d ' ')" = 1 ] && jq -e --arg id "$CONV" '
    .event == "PreToolUse" and .agy_tool == "run_command" and .claude_tool == "Bash"
    and .conversation_id == $id and .decision == "deny" and .gate == "record-gate.sh"
    and (.reason | startswith("BLOCKED: record gate refuses deny-me"))
    and .command == "echo deny-me" and .target == null
    and (.duration_ms | type) == "number" and (.ts | test("^[0-9-]+T[0-9:]+Z$"))' "$ENV_LOG" >/dev/null; then
  ok "D3 env switch writes one JSON line with the decision fields"
else
  bad "D3 env log line" "$(cat "$ENV_LOG" 2>&1)"
fi

mkdir -p "$A/.claude/session"
: > "$A/.claude/session/agy-hook-log.enabled"
run_wrapper "$A" PreToolUse "$(p_write "$A/src/app.ts" "SECRET-FILE-CONTENT" "$A")"
expect_decision "D4 decision is unchanged with the file switch on" ask
if jq -e --arg p "$A/src/app.ts" '.agy_tool == "write_to_file" and .claude_tool == "Write" and .decision == "ask"
    and .target == $p and .gate == null and .reason == null' "$DEFAULT_LOG" >/dev/null \
  && ! grep -q "SECRET-FILE-CONTENT" "$DEFAULT_LOG"; then
  ok "D5 file switch logs the target path and never the file content"
else
  bad "D5 file switch log" "$(cat "$DEFAULT_LOG" 2>&1)"
fi
jq -e '.arg_keys == null' "$DEFAULT_LOG" >/dev/null \
  && ok "D5b an ask line has no arg_keys" || bad "D5b ask arg_keys" "$(cat "$DEFAULT_LOG")"
run_wrapper "$A" PreToolUse "$(jq -cn --arg ws "$A" --arg id "$CONV" '{toolCall:{name:"apply_patch_file",args:{Path:"/x/y.ts",Patch:"SECRET-PATCH-VALUE"}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "D5c an unrouted tool stays denied" deny "'apply_patch_file' is not routed"
tail -n 1 "$DEFAULT_LOG" | jq -e '.agy_tool == "apply_patch_file" and .decision == "deny" and .arg_keys == ["Patch", "Path"]' >/dev/null \
  && ! grep -q "SECRET-PATCH-VALUE" "$DEFAULT_LOG" \
  && ok "D5d a deny line logs the sorted arg key names, never the values" || bad "D5d deny arg_keys" "$(tail -n 1 "$DEFAULT_LOG")"
run_wrapper "$A" SessionStart "$(p_session "$A")"
tail -n 1 "$DEFAULT_LOG" | jq -e '.event == "SessionStart" and .decision == "inject" and (.inject_steps | type) == "number"' >/dev/null \
  && ok "D6 SessionStart calls are logged" || bad "D6 SessionStart log" "$(tail -n 1 "$DEFAULT_LOG")"
rm -f "$A/.claude/session/agy-hook-log.enabled"

: > "$TMPROOT/not-a-dir"
export APEXYARD_AGY_HOOK_LOG="$TMPROOT/not-a-dir/x.log"
run_wrapper "$A" PreToolUse "$(p_run "echo deny-me" "$A")"
expect_decision "D7 an unwritable log path leaves a deny a deny" deny "refuses deny-me"
run_wrapper "$A" PreToolUse "$(p_run "git status" "$A")"
expect_decision "D8 an unwritable log path leaves an ask an ask" ask
unset APEXYARD_AGY_HOOK_LOG

# A symlinked log path or log directory is skipped. The decision stays.
: > "$TMPROOT/log-target.txt"
ln -s "$TMPROOT/log-target.txt" "$TMPROOT/logs/link.log"
export APEXYARD_AGY_HOOK_LOG="$TMPROOT/logs/link.log"
run_wrapper "$A" PreToolUse "$(p_run "echo deny-me" "$A")"
expect_decision "D9 a symlinked log file leaves a deny a deny" deny "refuses deny-me"
[ ! -s "$TMPROOT/log-target.txt" ] && ok "D10 nothing is written through a symlinked log file" \
  || bad "D10 symlinked log file" "$(cat "$TMPROOT/log-target.txt")"
mkdir -p "$TMPROOT/real-log-dir"
ln -s "$TMPROOT/real-log-dir" "$TMPROOT/link-log-dir"
export APEXYARD_AGY_HOOK_LOG="$TMPROOT/link-log-dir/x.log"
run_wrapper "$A" PreToolUse "$(p_run "git status" "$A")"
expect_decision "D11 a symlinked log directory leaves an ask an ask" ask
[ ! -e "$TMPROOT/real-log-dir/x.log" ] && ok "D12 nothing is written through a symlinked log directory" \
  || bad "D12 symlinked log dir" "$(cat "$TMPROOT/real-log-dir/x.log")"
unset APEXYARD_AGY_HOOK_LOG

# With the log on, no payload value appears in a jq process argument. A
# recording jq shim first on PATH writes every argument it gets.
REAL_JQ=$(command -v jq)
ARGV_BIN="$TMPROOT/argv-bin"
ARGV_LOG="$TMPROOT/jq-argv.txt"
mkdir -p "$ARGV_BIN"
: > "$ARGV_LOG"
printf '#!/bin/bash\nfor a in "$@"; do printf "%%s\\n" "$a"; done >> "%s"\nexec "%s" "$@"\n' "$ARGV_LOG" "$REAL_JQ" > "$ARGV_BIN/jq"
chmod +x "$ARGV_BIN/jq"
ARGV_APP_LOG="$TMPROOT/logs/argv.log"
export APEXYARD_AGY_HOOK_LOG="$ARGV_APP_LOG"
OUT=$(printf '%s' "$(p_write "$A/src/argv.ts" "ARGV-SECRET-CONTENT" "$A")" | PATH="$ARGV_BIN:$PATH" bash "$A/harness-adapters/agy/agy-hook.sh" PreToolUse 2>/dev/null)
printf '%s\n' "$OUT" >> "$ALL_OUT"
OUT=$(printf '%s' "$(p_run "echo ARGV-SECRET-COMMAND" "$A")" | PATH="$ARGV_BIN:$PATH" bash "$A/harness-adapters/agy/agy-hook.sh" PreToolUse 2>/dev/null)
printf '%s\n' "$OUT" >> "$ALL_OUT"
unset APEXYARD_AGY_HOOK_LOG
if [ -s "$ARGV_LOG" ] && grep -q "ARGV-SECRET-COMMAND" "$ARGV_APP_LOG" \
    && ! grep -q "ARGV-SECRET" "$ARGV_LOG"; then
  ok "D13 with the log on, no payload value appears in a jq argument ($(wc -l < "$ARGV_LOG" | tr -d ' ') args recorded)"
else
  bad "D13 payload in argv" "$(grep -n "ARGV-SECRET" "$ARGV_LOG" | head -5) log=$(tail -n 1 "$ARGV_APP_LOG" 2>&1 | head -c 300)"
fi

# ==============================================================================
echo "== Part C: real .claude/hooks gates"

C="$TMPROOT/fork-c"
mkdir -p "$C"
git init -q "$C"
git -C "$C" commit -q --allow-empty -m init
: > "$C/.apexyard-fork"
: > "$C/onboarding.yaml"
printf 'projects: []\n' > "$C/apexyard.projects.yaml"
mkdir -p "$C/.claude/session" "$C/src"
cp -R "$ROOT/.claude/hooks" "$C/.claude/hooks"
rm -rf "$C/.claude/hooks/tests"
cp "$ROOT/.claude/settings.json" "$C/.claude/settings.json"
cp "$ROOT/.claude/project-config.defaults.json" "$C/.claude/project-config.defaults.json"
copy_adapter "$C"
C=$(cd "$C" && pwd -P)

run_wrapper "$C" PreToolUse "$(p_run "git add -A" "$C")"
expect_decision "C1 real gate: run_command git add -A gets deny from block-git-add-all.sh" deny "'git add -A', 'git add --all', and 'git add \.' are forbidden"
run_wrapper "$C" PreToolUse "$(p_run "git status" "$C")"
expect_decision "C2 real gate: run_command git status gets ask" ask
run_wrapper "$C" PreToolUse "$(p_run "git add -A" "$C" "src")"
expect_decision "C2b real gate: git add -A from a relative Cwd gets deny" deny "'git add -A', 'git add --all', and 'git add \.' are forbidden"
run_wrapper "$C" PreToolUse "$(p_run_top "git add -A" "$C" "$(jq -n --arg d "$C/src" '$d')")"
expect_decision "C2b2 real gate: git add -A with only a top-level cwd gets deny" deny "'git add -A', 'git add --all', and 'git add \.' are forbidden"
HOOKS_REL=".claude/hooks"
run_wrapper "$C" PreToolUse "$(p_run "rm -rf $HOOKS_REL" "$C" "$C/no-such-dir")"
expect_decision "C2c removing the hooks folder with a missing Cwd gets deny" deny "not an existing directory"
run_wrapper "$C" PreToolUse "$(p_run "rm -rf $HOOKS_REL" "$C" "$C")"
expect_decision "C2d removing the hooks folder with the fork as Cwd gets deny from the gates" deny "BLOCKED"

run_wrapper "$C" PreToolUse "$(p_write "$C/src/app.ts" "export const x = 1;" "$C")"
expect_decision "C3 real gate: write_to_file on a code path without a ticket gets deny" deny "BLOCKED: No active ticket set for this session"
run_wrapper "$C" PreToolUse "$(p_write "src/relative.ts" "export const r = 1;" "$C")"
expect_decision "C3b real gate: relative TargetFile on a code path without a ticket gets deny" deny "BLOCKED: No active ticket set for this session"
run_wrapper "$C" PreToolUse "$(p_write_file "$C/src/cli.ts" "export const c = 1;" "$C")"
expect_decision "C3c real gate: write_file on a code path without a ticket gets deny" deny "BLOCKED: No active ticket set for this session"
run_wrapper "$C" PreToolUse "$(p_write_file "$C/src/cli.ts" "export const c = 1;" "$C" true)"
expect_decision "C3d real gate: write_file with Append=true without a ticket gets deny" deny "BLOCKED: No active ticket set for this session"
printf 'repo=org/ops\nnumber=2\n' > "$(git -C "$C" rev-parse --absolute-git-dir)/apexyard-ticket"
run_wrapper "$C" PreToolUse "$(p_write_file "$C/.claude/settings.json" '{"hooks":{}}' "$C")"
expect_decision "C3e real gate: write_file to .claude/settings.json gets deny from the protected-target gate" deny "BLOCKED"
grep -q "BLOCKED: the edit target is live hook state" <<<"$(reason)" \
  && ok "C3f the settings.json deny comes from the protected-target gate" || bad "C3f protected reason" "$(reason | head -c 300)"
run_wrapper "$C" PreToolUse "$(p_write_file "$C/src/cli.ts" "export const c = 1;" "$C" true)"
expect_decision "C3g real gate: write_file with Append=true and an active ticket gets ask" ask
run_wrapper "$C" PreToolUse "$(jq -cn --arg ws "$C" --arg id "$CONV" '{toolCall:{name:"read_file",args:{Path:"README.md"}}, conversationId:$id, workspacePaths:[$ws]}')"
expect_decision "C3h read_file gets ask" ask
run_wrapper "$C" PreToolUse "$(p_edit_file "$C/.claude/settings.json" '"hooks"' '"nohooks"' "$C")"
expect_decision "C3h2 real gate: edit_file on .claude/settings.json gets deny" deny "BLOCKED: the edit target is live hook state"
printf 'export const e = 1;\n' > "$C/src/edit-me.ts"
run_wrapper "$C" PreToolUse "$(p_edit_file "$C/src/edit-me.ts" "e = 1" "e = 2" "$C")"
expect_decision "C3h3 real gate: edit_file on a code path with an active ticket gets ask" ask

# agy must not switch off its own gates.
run_wrapper "$C" PreToolUse "$(p_write_file "$C/.agents/hooks.json" '{}' "$C")"
expect_decision "C3h4 real gate: write_file to .agents/hooks.json gets deny" deny "BLOCKED: the edit target is live hook state"
run_wrapper "$C" PreToolUse "$(p_edit_file "$C/harness-adapters/agy/agy-hook.sh" "deny" "ask" "$C")"
expect_decision "C3h5 real gate: edit_file on the agy wrapper gets deny" deny "BLOCKED: the edit target is live hook state"
run_wrapper "$C" PreToolUse "$(p_run_top "rm -f harness-adapters/agy/agy-hook.sh" "$C" "$(jq -n --arg d "$C" '$d')")"
expect_decision "C3h6 real gate: run_command rm of the agy wrapper gets deny" deny "BLOCKED"
run_wrapper "$C" PreToolUse "$(p_run_top "rm -f .agents/hooks.json" "$C" "$(jq -n --arg d "$C" '$d')")"
expect_decision "C3h7 real gate: run_command rm of .agents/hooks.json gets deny" deny "BLOCKED"
run_wrapper "$C" PreToolUse "$(p_write_file "$C/.agents/plugins/sibling/hooks.json" '{}' "$C")"
expect_decision "C3h9 real gate: write_file of a sibling agy plugin hooks.json gets deny" deny "BLOCKED: the edit target is live hook state"
run_wrapper "$C" PreToolUse "$(p_write_file "$C/.agents/plugins.json" '{}' "$C")"
expect_decision "C3h10 real gate: write_file to .agents/plugins.json gets deny" deny "BLOCKED: the edit target is live hook state"
run_wrapper "$C" PreToolUse "$(p_edit_file "$C/bin/sync-agy-adapter.sh" "set -euo pipefail" "exit 0" "$C")"
expect_decision "C3h11 real gate: edit_file on the agy generator gets deny" deny "BLOCKED: the edit target is live hook state"
run_wrapper "$C" PreToolUse "$(p_run_top "rm -rf .agents/plugins" "$C" "$(jq -n --arg d "$C" '$d')")"
expect_decision "C3h12 real gate: run_command removing .agents/plugins gets deny" deny "BLOCKED"
# agy reads nested .agents/ hook config, so agy must not create one.
for rel in docs/.agents/hooks.json docs/.agents/plugins.json docs/.agents/plugins/x/hooks.json docs/.AGENTS/Hooks.JSON; do
  run_wrapper "$C" PreToolUse "$(p_write_file "$C/$rel" '{}' "$C")"
  expect_decision "C3h13 real gate: write_file to nested $rel gets deny" deny "BLOCKED: the edit target is live hook state"
  run_wrapper "$C" PreToolUse "$(p_edit_file "$C/$rel" "a" "b" "$C")"
  expect_decision "C3h14 real gate: edit_file on nested $rel gets deny" deny "BLOCKED: the edit target is live hook state"
  run_wrapper "$C" PreToolUse "$(p_run_top "echo {} > $rel" "$C" "$(jq -n --arg d "$C" '$d')")"
  expect_decision "C3h15 real gate: run_command redirect into nested $rel gets deny" deny "BLOCKED"
done
for rel in docs/agents/hooks.json docs/.agents/skills/x.md .claude/worktrees/wt/docs/.agents/hooks.json; do
  run_wrapper "$C" PreToolUse "$(p_write_file "$C/$rel" '{}' "$C")"
  expect_decision "C3h16 real gate: write_file to $rel stays ask" ask
  run_wrapper "$C" PreToolUse "$(p_run_top "echo {} > $rel" "$C" "$(jq -n --arg d "$C" '$d')")"
  expect_decision "C3h17 real gate: run_command redirect into $rel stays ask" ask
done

# permissions.deny from the real .claude/settings.json, applied literally.
p_args() { # <tool> <args JSON>
  jq -cn --arg t "$1" --argjson a "$2" --arg ws "$C" --arg id "$CONV" \
    '{toolCall:{name:$t, args:$a}, conversationId:$id, workspacePaths:[$ws], cwd:$ws}'
}
read_case() { # <label> <path> <want> [rule ERE]
  run_wrapper "$C" PreToolUse "$(p_args read_file "$(jq -cn --arg p "$2" '{Path:$p}')")"
  expect_decision "$1" "$3" "${4:-}"
}
read_case "P1 read_file .env gets deny" "$C/.env" deny 'permissions\.deny rule Read\(//\*\*/\.env\)'
read_case "P2 read_file relative .env gets deny" ".env" deny 'Read\(//\*\*/\.env\)'
read_case "P3 read_file config/.env.local gets deny" "$C/config/.env.local" deny 'Read\(//\*\*/\.env\.\*\)'
read_case "P4 read_file src/env.ts gets ask" "$C/src/env.ts" ask
read_case "P5 read_file .envrc-notes.md gets ask" "$C/.envrc-notes.md" ask
read_case "P6 read_file .envrc gets ask (.env.* needs a dot after env)" "$C/.envrc" ask
read_case "P7 read_file a private-key.pem gets deny" "$C/keys/app.private-key.pem" deny 'Read\(//\*\*/\*\.private-key\.pem\)'
read_case "P8 read_file .config/apexyard/*.pem gets deny" "$TMPROOT/h/.config/apexyard/app.pem" deny 'Read\(//\*\*/\.config/apexyard/\*\.pem\)'
read_case "P9 read_file .mcp.json gets deny" "$C/.mcp.json" deny 'Read\(//\*\*/\.mcp\.json\)'
read_case "P10 read_file src/../.env gets deny (lexical form)" "$C/src/../.env" deny 'Read\(//\*\*/\.env\)'
read_case "P11 read_file .ENV gets deny (case-insensitive)" "$C/.ENV" deny 'Read\(//\*\*/\.env\)'
printf 'SECRET=1\n' > "$C/.env"
ln -s "$C/.env" "$C/innocent.txt"
read_case "P12 read_file of a symlink to .env gets deny (physical form)" "$C/innocent.txt" deny 'Read\(//\*\*/\.env\)'
rm -f "$C/innocent.txt"
# A chain of symlinks resolves to its end. A loop fails closed.
ln -s "$C/.env" "$C/link-two"
ln -s "$C/link-two" "$C/link-one"
read_case "P12b read_file of a two-level symlink chain to .env gets deny" "$C/link-one" deny 'Read\(//\*\*/\.env\)'
ln -s "$C/loop-b" "$C/loop-a"
ln -s "$C/loop-a" "$C/loop-b"
read_case "P12c read_file of a symlink loop gets deny (fails closed)" "$C/loop-a" deny "symlink chain that loops"
rm -f "$C/.env"
read_case "P12d read_file of a dangling symlink chain to .env gets deny" "$C/link-one" deny 'Read\(//\*\*/\.env\)'
ln -s "$C/no-such-dir/data.txt" "$C/dangling-plain"
read_case "P12e read_file of a dangling symlink to a plain name gets ask" "$C/dangling-plain" ask
rm -f "$C/link-one" "$C/link-two" "$C/loop-a" "$C/loop-b" "$C/dangling-plain"
run_wrapper "$C" PreToolUse "$(p_args view_file "$(jq -cn --arg p "$C/.env" '{AbsolutePath:$p}')")"
expect_decision "P13 view_file (IDE name) of .env gets deny" deny 'Read\(//\*\*/\.env\)'
run_wrapper "$C" PreToolUse "$(p_args grep_search '{"Query":"SECRET","SearchPath":"."}')"
expect_decision "P14 grep_search over the fork gets deny as unrouted (it reads .env content)" deny "'grep_search' is not routed"
run_wrapper "$C" PreToolUse "$(p_args list_dir "$(jq -cn --arg p "$C/src" '{DirectoryPath:$p}')")"
expect_decision "P15 list_dir of src gets ask" ask
bash_case() { # <label> <command> <want> [rule ERE]
  run_wrapper "$C" PreToolUse "$(p_args run_command "$(jq -cn --arg c "$2" '{CommandLine:$c}')")"
  expect_decision "$1" "$3" "${4:-}"
}
bash_case "P16 gh auth token gets deny" "gh auth token" deny 'rule Bash\(gh auth token\)'
bash_case "P17 gh auth token with arguments gets deny" "gh auth token --hostname github.com" deny 'rule Bash\(gh auth token:\*\)'
bash_case "P18 gh auth token with spaces around gets deny" "  gh auth token  " deny 'Bash\(gh auth token\)'
bash_case "P19 printenv gets deny" "printenv" deny 'rule Bash\(printenv\)'
bash_case "P20 printenv with an argument gets deny" "printenv HOME" deny 'rule Bash\(printenv:\*\)'
bash_case "P21 env gets deny" "env" deny 'rule Bash\(env\)'
bash_case "P22 env FOO=1 cmd still reaches the gates" "env FOO=1 true" ask
bash_case "P23 gh auth status still reaches the gates" "gh auth status" ask
bash_case "P24 printenvx is not a printenv prefix match" "printenvx" ask
# Known limit (AgDR-0267): literal matching does not see a chained or
# wrapped command. This case pins the documented behaviour.
bash_case "P25 known limit: a chained printenv is not caught" "true && printenv" ask
bash_case "P26 known limit: sh -c printenv is not caught" "sh -c printenv" ask

# agy opened in a subfolder of the fork must still protect <fork>/.claude/.
mkdir -p "$C/docs"
run_wrapper "$C" PreToolUse "$(p_write_file "$C/.claude/settings.json" '{"hooks":{}}' "$C/docs")"
expect_decision "C3i subfolder workspace: write_file to the fork's .claude/settings.json gets deny" deny "BLOCKED: the edit target is live hook state"
HOOKS_UP="../.claude/hooks"
run_wrapper "$C" PreToolUse "$(p_run "rm -rf $HOOKS_UP" "$C/docs")"
expect_decision "C3j subfolder workspace: removing the fork's hooks folder gets deny" deny "BLOCKED"
# agy runs in its top-level cwd. With workspace=<fork>/docs and cwd=<fork>,
# a relative path could mean either folder, so it gets a deny.
p_top() { # <tool> <args JSON> <workspace> <top-level cwd>
  jq -cn --arg t "$1" --argjson a "$2" --arg ws "$3" --arg top "$4" --arg id "$CONV" \
    '{toolCall:{name:$t, args:$a}, conversationId:$id, workspacePaths:[$ws], cwd:$top}'
}
run_wrapper "$C" PreToolUse "$(p_top write_file '{"Path":".claude/settings.json","Content":"{}"}' "$C/docs" "$C")"
expect_decision "C3l relative write_file Path with cwd != workspace gets deny" deny "argument Path is a relative path, and the agy cwd differs from the workspace"
run_wrapper "$C" PreToolUse "$(p_top edit_file '{"Path":".claude/hooks/dispatch-bash.sh","Target":"a","Replacement":"b"}' "$C/docs" "$C")"
expect_decision "C3m relative edit_file Path with cwd != workspace gets deny" deny "argument Path is a relative path, and the agy cwd differs from the workspace"
run_wrapper "$C" PreToolUse "$(p_top write_to_file '{"TargetFile":"src/x.ts","CodeContent":"x"}' "$C/docs" "$C")"
expect_decision "C3n relative TargetFile with cwd != workspace gets deny" deny "argument TargetFile is a relative path"
run_wrapper "$C" PreToolUse "$(p_top run_command '{"CommandLine":"git status","Cwd":"src"}' "$C/docs" "$C")"
expect_decision "C3o relative args.Cwd with cwd != workspace gets deny" deny "argument Cwd is a relative path"
run_wrapper "$C" PreToolUse "$(p_top write_file "$(jq -cn --arg p "$C/.claude/settings.json" '{Path:$p, Content:"{}"}')" "$C/docs" "$C")"
expect_decision "C3p absolute Path with cwd != workspace still reaches the gates" deny "BLOCKED: the edit target is live hook state"
run_wrapper "$C" PreToolUse "$(p_top write_file '{"Path":"src/rel.ts","Content":"x"}' "$C" "$C")"
expect_decision "C3q relative Path with cwd == workspace keeps working" ask
run_wrapper "$C" PreToolUse "$(p_top edit_file '{"Path":".claude/settings.json","Target":"a","Replacement":"b"}' "$C" "$C")"
expect_decision "C3r relative Path with cwd == workspace resolves under the fork and is denied by the gate" deny "BLOCKED: the edit target is live hook state"
run_wrapper "$C" PreToolUse "$(p_top run_command '{"CommandLine":"git status","Cwd":"src"}' "$C" "$C")"
expect_decision "C3s relative args.Cwd with cwd == workspace keeps working" ask

SNAP_DIR="$APEXYARD_OPS_PIN_DIR/gate-session-$CONV"
mkdir -p "$SNAP_DIR"
jq -n --arg p "$C/docs" '{ops_root:"", project_dir:$p, settings:{}}' > "$SNAP_DIR/snapshot.json"
run_wrapper "$C" PreToolUse "$(p_write_file "$C/src/x.ts" "x" "$C")"
expect_decision "C3k a session snapshot that protects a subfolder gets deny" deny "Start a new agy conversation"
rm -rf "$SNAP_DIR"
run_wrapper "$C" PreToolUse "$(p_write "$C/src/app.ts" "export const x = 1;" "$C")"
expect_decision "C4 real gate: write_to_file with an active ticket gets ask" ask

if bash "$C/bin/sync-agy-adapter.sh" > "$TMPROOT/sync-c.out" 2>&1 && bash "$C/bin/sync-agy-adapter.sh" --check >/dev/null 2>&1; then
  ok "C5 sync and --check pass on the real settings.json"
else
  bad "C5 real settings sync" "$(cat "$TMPROOT/sync-c.out")"
fi
want_budget=$(bash "$C/harness-adapters/agy/agy-hook.sh" --budget PreToolUse Write)
jq -e --argjson t "$want_budget" '.apexyard.PreToolUse[0].matcher == ".*" and .apexyard.PreToolUse[0].hooks[0].timeout == $t and $t > 30' \
  "$C/.agents/hooks.json" >/dev/null \
  && ok "C6 catch-all timeout is the Write budget (${want_budget} s), above the 30 s agy default" || bad "C6 timeout" "$(cat "$C/.agents/hooks.json")"
run_wrapper "$C" PreToolUse "$(p_tool send_command_input "$C")"
expect_decision "C6b real fork: send_command_input gets deny" deny "keystrokes"

start=$SECONDS
run_wrapper "$C" SessionStart "$(p_session "$C")"
elapsed=$((SECONDS - start))
if printf '%s' "$OUT" | jq -e '(keys == ["injectSteps"]) and ([.injectSteps[] | keys[0]] | all(. == "systemMessage"))
    and (.injectSteps | all((.systemMessage | type) == "object" and (.systemMessage.systemMessage | type) == "string"))' >/dev/null; then
  ok "C7 real SessionStart dispatcher returns injectSteps with no error step (${elapsed}s)"
else
  bad "C7 real SessionStart" "$(printf '%s' "$OUT" | head -c 600) stderr: $(head -c 400 "$TMPROOT/stderr")"
fi

# ==============================================================================
echo "== Part F: recorded-shape agy payload fixtures (real gates, fork C)"

# fixtures/agy-payloads/ holds agy CLI 1.5.14 key shapes with synthetic
# values (see its README). /work/fork becomes this test's fork C. The ticket
# marker from Part C is still active, so a code-path write passes the gates.
FIX="$ROOT/.claude/hooks/tests/fixtures/agy-payloads"
fixture() { # <file> -> payload on stdout, /work/fork replaced by fork C
  jq -c --arg ws "$C" 'walk(if type == "string" then gsub("/work/fork"; $ws) else . end)' "$FIX/$1"
}
[ -f "$FIX/README.md" ] && ok "F0 the fixture folder has a README" || bad "F0 fixture README" "missing $FIX/README.md"
run_wrapper "$C" SessionStart "$(fixture session_start.json)"
printf '%s' "$OUT" | jq -e '(.injectSteps | type) == "array" and ([.injectSteps[] | keys[0]] | all(. == "systemMessage"))
    and (.injectSteps | all(.systemMessage.systemMessage | type == "string"))' >/dev/null \
  && ok "F1 session_start.json returns nested systemMessage steps" || bad "F1 session_start fixture" "$(printf '%s' "$OUT" | head -c 300)"
while IFS='|' read -r file want rx; do
  [ -n "$file" ] || continue
  run_wrapper "$C" PreToolUse "$(fixture "$file")"
  expect_decision "F2 fixture $file" "$want" "$rx"
done <<'TABLE'
run_command.json|ask|
run_command-git-add-all.json|deny|'git add -A', 'git add --all', and 'git add \.' are forbidden
run_command-daemon.json|ask|
write_file.json|ask|
write_file-append.json|ask|
write_file-settings.json|deny|BLOCKED: the edit target is live hook state
edit_file.json|ask|
edit_file-settings.json|deny|BLOCKED: the edit target is live hook state
read_file.json|ask|
read_file-env.json|deny|permissions\.deny rule Read\(//\*\*/\.env\)
run_command-printenv.json|deny|permissions\.deny rule Bash\(printenv\)
manage_task-list.json|ask|
manage_task-kill.json|ask|
manage_task-status.json|ask|
manage_task-send_input.json|deny|Action send_input is always denied. It types keystrokes
unknown-tool.json|deny|'invoke_subagent' is not routed
TABLE
fixture_count=$(find "$FIX" -name '*.json' | wc -l | tr -d ' ')
[ "$fixture_count" = 17 ] && ok "F3 every fixture file is covered (17 files)" || bad "F3 fixture count" "found $fixture_count json files; update the table"
if grep -rlE '/Users/|/home/[a-z]|@[a-z0-9.-]+\.[a-z]{2,}' "$FIX" >/dev/null 2>&1; then
  bad "F4 fixtures hold no home path or email" "$(grep -rnE '/Users/|/home/[a-z]|@[a-z0-9.-]+\.[a-z]{2,}' "$FIX" | head -3)"
else
  ok "F4 fixtures hold no home path or email"
fi

# ==============================================================================
if grep -Eq 'auto_approve|"decision":"(allow|force_ask)"' "$ALL_OUT"; then
  bad "Z1 no wrapper output is allow, force_ask, or auto_approve" "$(grep -E 'auto_approve|"decision":"(allow|force_ask)"' "$ALL_OUT" | head -3)"
else
  ok "Z1 no wrapper output is allow, force_ask, or auto_approve ($(wc -l < "$ALL_OUT" | tr -d ' ') outputs)"
fi
# Every emit path in the wrapper source names ask or deny. agy treats allow
# as "Automatically allow", which would skip agy's own permission prompt.
emit_lines=$(grep -nE 'decision"?[[:space:]]*:[[:space:]]*"' "$WRAPPER_SRC" | grep -vE '^[0-9]+:[[:space:]]*#')
emit_count=$(printf '%s\n' "$emit_lines" | grep -c .)
bad_emits=$(printf '%s\n' "$emit_lines" | grep -vE 'decision"?[[:space:]]*:[[:space:]]*"(ask|deny)"')
if [ "$emit_count" -ge 4 ] && [ -z "$bad_emits" ]; then
  ok "Z3 every decision emit path in the wrapper source is ask or deny ($emit_count paths)"
else
  bad "Z3 emit paths" "count=$emit_count bad=$bad_emits"
fi
bad_lines=$(grep -v '^$' "$ALL_OUT" | while IFS= read -r line; do
  printf '%s' "$line" | jq -e '(.decision == "ask" and (keys == ["decision"]))
    or (.decision == "deny" and (keys == ["decision", "reason"]) and (.reason | type) == "string")
    or ((keys == ["injectSteps"]) and (.injectSteps | type) == "array")' >/dev/null 2>&1 || printf '%s\n' "$line"
done)
[ -z "$bad_lines" ] && ok "Z2 every wrapper output is one ask, deny, or injectSteps object" || bad "Z2 output shapes" "$bad_lines"

echo
echo "agy adapter: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed:%s\n' "$FAILED" | tr '|' '\n' >&2
  exit 1
fi
exit 0
