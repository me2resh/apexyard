#!/usr/bin/env bash
# agy-hook.sh: route Google Antigravity CLI (agy) hook events to the
# unmodified ApexYard gates in .claude/hooks/. Decision record: AgDR-0314.
#
# The wrapper is a transport. Bash gates own every decision. The wrapper:
#   1. reads the agy hook payload from stdin,
#   2. maps the agy tool call to the Claude Code tool name and tool_input,
#   3. reads the PreToolUse or SessionStart handlers from .claude/settings.json
#      at run time, so the gate list cannot drift,
#   4. runs each matching handler command unchanged, with Claude-Code-shaped
#      stdin, and
#   5. prints one agy decision object on stdout.
#
# Contract: agy's bundled hooks reference, agy CLI 1.5.14
# (~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md).
# PreToolUse decisions are allow ("Automatically allow the tool execution"),
# ask ("Prompt the user for permission", respects "Always Allow"), force_ask,
# and deny. The public hooks page reads allow differently and lists
# auto_approve. The wrapper prints only ask or deny under either reading:
# never allow, force_ask, or auto_approve. ask requests agy's own permission
# check. Whether agy then prompts depends on agy's own settings (AgDR-0314).
#
# Usage (agy calls the first two forms through .agents/hooks.json):
#   agy-hook.sh PreToolUse     < agy payload   -> {"decision":"ask"|"deny",...}
#   agy-hook.sh SessionStart   < agy payload   -> {"injectSteps":[...]}
#   agy-hook.sh --budget PreToolUse <ClaudeTool>  -> seconds (generator use)
#   agy-hook.sh --budget SessionStart             -> seconds (generator use)
#
# Fail-closed contract for PreToolUse:
#   - exit 2 from any gate                  -> deny, reason = gate stderr
#   - gate timeout (wrapper watchdog)       -> deny
#   - gate exit 126/127 (cannot run)        -> deny
#   - other non-zero exit, onFailure=block  -> deny
#   - other non-zero exit, no onFailure     -> continue (Claude Code semantics)
#   - every gate passes                     -> ask
#   - malformed stdin, missing jq, unexpected argument shape, missing gate
#     script, wrapper error                 -> deny
#   - workspace that resolves to no fork or to another fork -> deny
# Tool policy (hooks.json routes every agy tool here): the gated tools run
# the gates, a short read-only allowlist gets ask at once, keystroke tools
# and every other tool get deny. See apply_tool_policy below.
# It always exits 0, because agy's behaviour on a non-zero exit is not
# documented.
#
# Shell parsing: the wrapper does not parse the agent's command. It passes
# the command text to the gates as tool_input.command. jq does every JSON
# translation.

set -u
set -o pipefail

DEFAULT_HANDLER_TIMEOUT=30
WRAPPER_MARGIN=15

# Builtins only before the jq check, so a missing jq still yields a deny.
_src="${BASH_SOURCE[0]}"
case "$_src" in */*) ADAPTER_DIR="${_src%/*}" ;; *) ADAPTER_DIR=. ;; esac
ADAPTER_DIR=$(cd "$ADAPTER_DIR" 2>/dev/null && pwd -P) || ADAPTER_DIR=""
OPS_ROOT=""
if [ -n "$ADAPTER_DIR" ]; then
  OPS_ROOT=$(cd "$ADAPTER_DIR/../.." 2>/dev/null && pwd -P) || OPS_ROOT=""
fi
SETTINGS="$OPS_ROOT/.claude/settings.json"

EVENT="${1:-}"

# Fixed-text outputs for the paths where jq is not available. The text must
# be JSON-safe: no quote, backslash, or control character.
deny_fixed() {
  printf '{"decision":"deny","reason":"%s"}\n' "$1"
  exit 0
}

# agy's SessionStart steps are nested objects (bundled contract, agy CLI
# 1.5.14): {"systemMessage":{"systemMessage":"..."}} and
# {"errorMessage":{"userMessage":"..."}}. A plain string never reaches agy.
session_error_fixed() {
  printf '{"injectSteps":[{"errorMessage":{"userMessage":"%s"}}]}\n' "$1"
  exit 0
}

fail_fixed() {
  if [ "$EVENT" = "SessionStart" ]; then session_error_fixed "$1"; fi
  deny_fixed "$1"
}

if ! command -v jq >/dev/null 2>&1; then
  if [ "$EVENT" = "--budget" ]; then
    echo "ERROR: jq is required" >&2
    exit 1
  fi
  fail_fixed "ApexYard agy adapter: jq is not installed, so no gate can run. Install jq and retry. The adapter denies every tool call until then."
fi

# jq filter that selects the handlers for one event, filtered by matcher.
# A matcher is an anchored regular expression. The generator applies the
# same test. A missing or invalid timeout uses DEFAULT_HANDLER_TIMEOUT.
# shellcheck disable=SC2016  # jq variables, not shell variables.
JQ_HANDLERS='
  (.hooks[$ev] // [])[]
  | select((.matcher // "") as $m
           | $m == "" or $m == "*" or ($subject | test("^(" + $m + ")$")))
  | (.hooks // [])[]
  | . + { timeout: ((.timeout // $dflt)
                    | if type == "number" and . > 0 then ceil else $dflt end) }
'

# --budget: total wrapper time for one routed tool or for SessionStart. The
# generator writes this value as the agy hook timeout. It includes a margin,
# so the wrapper watchdog acts before agy's own timeout.
if [ "$EVENT" = "--budget" ]; then
  ev="${2:-}" subject="${3:-}"
  [ "$ev" = "SessionStart" ] && subject="startup"
  [ -f "$SETTINGS" ] || { echo "ERROR: $SETTINGS not found" >&2; exit 1; }
  jq -r --arg ev "$ev" --arg subject "$subject" --argjson dflt "$DEFAULT_HANDLER_TIMEOUT" \
    --argjson margin "$WRAPPER_MARGIN" \
    "[ $JQ_HANDLERS | .timeout ] | (add // 0) | if . > 0 then . + \$margin else 0 end" \
    "$SETTINGS" || exit 1
  exit 0
fi

# Opt-in decision log, off by default. The env variable names a log path.
# The switch file enables the default path, for the case where agy does not
# pass the caller's environment to hooks. The log is written after the
# decision is printed, in a subshell with every error ignored, so a logging
# failure cannot change the decision.
AGY_LOG=""
if [ -n "${APEXYARD_AGY_HOOK_LOG:-}" ]; then
  AGY_LOG="$APEXYARD_AGY_HOOK_LOG"
elif [ -n "$OPS_ROOT" ] && [ -f "$OPS_ROOT/.claude/session/agy-hook-log.enabled" ]; then
  AGY_LOG="$OPS_ROOT/.claude/session/agy-hooks.log"
fi

now_ms() {
  perl -MTime::HiRes=time -e 'printf("%d\n", time() * 1000)' 2>/dev/null \
    || printf '%s000\n' "$(date +%s)"
}

START_MS=""
if [ -n "$AGY_LOG" ]; then START_MS=$(now_ms); fi

# note_meta <key> <value>: record one log field from inside main. A no-op
# when the log is off. Errors are ignored.
note_meta() {
  [ -n "$AGY_LOG" ] && [ -n "${META:-}" ] || return 0
  printf '%s\n' "$2" > "$META.$1" 2>/dev/null || true
  return 0
}

deny() {
  jq -cn --arg r "$1" '{decision:"deny", reason:$r}' 2>/dev/null \
    || deny_fixed "ApexYard agy adapter: could not encode the deny reason."
  exit 0
}

# ask: the call passed every ApexYard check. agy still prompts the user,
# unless the call is on agy's "Always Allow" list.
ask() {
  printf '%s\n' '{"decision":"ask"}'
  exit 0
}

fail() {
  if [ "$EVENT" = "SessionStart" ]; then
    jq -cn --arg r "$1" '{injectSteps:[{errorMessage:{userMessage:$r}}]}' 2>/dev/null \
      || session_error_fixed "ApexYard agy adapter: SessionStart failed."
    exit 0
  fi
  deny "$1"
}

# handlers_for <event> <subject>: NUL-separated records of command, timeout
# seconds, onFailure, if, and type.
handlers_for() {
  jq -j --arg ev "$1" --arg subject "$2" --argjson dflt "$DEFAULT_HANDLER_TIMEOUT" "
    $JQ_HANDLERS"'
    | ((.command // "") | tostring), "\u0000",
      (.timeout | tostring), "\u0000",
      ((.onFailure // "") | tostring), "\u0000",
      ((.if // "") | tostring), "\u0000",
      ((.type // "command") | tostring), "\u0000"
  ' "$SETTINGS"
}

# Build the Claude-Code-shaped gate payload. jq error() text becomes the
# deny reason. Accept args as an object or as a JSON-encoded object string.
build_pretooluse_payload() {
  jq -c --arg sid "$SESSION_ID" --arg ws "$WORKSPACE" --arg cwd_differs "$CWD_DIFFERS" '
    def nonempty_string: type == "string" and length > 0;
    # agy runs in its top-level cwd. When that differs from the workspace,
    # the bundled contract does not say which folder a relative path uses.
    # So a relative path is denied then, instead of a guess.
    def no_relative_when_cwd_differs($v; $k):
      if $cwd_differs == "1" and ($v | startswith("/") | not) then
        error("argument \($k) is a relative path, and the agy cwd differs from the workspace. The adapter cannot tell which folder agy resolves it against, so it fails closed. Use an absolute path")
      else $v end;
    def need_string($a; $k):
      if ($a[$k] | type) == "string" then $a[$k]
      else error("argument \($k) is missing or is not a string") end;
    # The gates assume an absolute file_path, as Claude Code sends. A
    # relative TargetFile resolves against the workspace. The file need not
    # exist, because write_to_file creates new files.
    # A path field with a control character is denied before any shell
    # substitution sees it. A shell substitution drops trailing newlines,
    # so the gates could judge a path other than the one agy uses.
    def has_control: test("[\u0000-\u001f\u007f]");
    def need_path_key($a; $k):
      if ($a[$k] | nonempty_string) | not then error("argument \($k) is missing or empty")
      elif ($a[$k] | has_control) then error("argument \($k) contains a control character")
      elif ($a[$k] | startswith("/")) then $a[$k]
      else no_relative_when_cwd_differs($a[$k]; $k) | $ws + "/" + . end;
    def need_path($a): need_path_key($a; "TargetFile");
    # agy sends a top-level cwd: the agent working directory, where its
    # commands run by default (bundled contract, agy CLI 1.5.14). It is the
    # run_command directory when args.Cwd is absent, with the same checks.
    def check_dir($v; $k):
      if ($v | type) != "string" then error("\($k) is not a string")
      elif ($v | has_control) then error("\($k) contains a control character")
      else $v end;
    . as $root
    | (.toolCall // error("toolCall is missing")) as $t
    | (if ($t | type) == "object" then $t else error("toolCall is not an object") end)
    | ($t.name // "") as $name
    | ($t.args // {}) as $raw
    | (if ($raw | type) == "string" then ($raw | fromjson) else $raw end) as $a
    | (if ($a | type) == "object" then $a else error("toolCall.args is not an object") end)
    | (if $name == "run_command" then
         # RequestedTerminalID and a true RunPersistent run the command in an
         # existing terminal. That terminal can sit in another directory, for
         # example after an earlier cd, so the gates would judge the wrong
         # Cwd. agy CLI 1.5.14 does not declare these keys. The keys stay on
         # the key list only so that this reason is specific.
         (if ($a | has("RequestedTerminalID")) then
            error("run_command with RequestedTerminalID runs in an existing terminal whose directory the gates cannot see")
          elif ($a | has("RunPersistent")) and $a.RunPersistent != false then
            error("run_command with RunPersistent runs in an existing terminal whose directory the gates cannot see")
          # The repo enforces, not agy: agy keeps its terminal sandbox.
          elif ($a | has("BypassSandbox")) and $a.BypassSandbox != false then
            error("run_command with BypassSandbox asks agy to run outside its terminal sandbox; ApexYard does not allow agy to drop its sandbox")
          else . end)
         | (if ($a.CommandLine | nonempty_string) then . else error("argument CommandLine is missing or empty") end)
         | (if ($a.Cwd != null and $a.Cwd != "") then [(check_dir($a.Cwd; "argument Cwd") | no_relative_when_cwd_differs(.; "Cwd")), "args"]
            elif ($root.cwd != null and $root.cwd != "") then [check_dir($root.cwd; "the top-level cwd"), "top"]
            else [$ws, "workspace"] end) as $dir
         | { tool_name: "Bash",
             tool_input: { command: $a.CommandLine },
             cwd: $dir[0],
             cwd_source: $dir[1] }
       elif $name == "write_to_file" then
         { tool_name: "Write",
           tool_input: { file_path: need_path($a), content: need_string($a; "CodeContent") },
           cwd: $ws }
       elif $name == "write_file" then
         # Observed agy CLI name (live check 2026-11-21, agy CLI 1.5.14).
         # Append=true maps to Write too, so every Write gate still runs.
         { tool_name: "Write",
           tool_input: { file_path: need_path_key($a; "Path"), content: need_string($a; "Content") },
           cwd: $ws }
       elif $name == "edit_file" then
         # agy CLI 1.5.14 tool list: edit_file replaces every match of Target.
         { tool_name: "Edit",
           tool_input: { file_path: need_path_key($a; "Path"),
                         old_string: need_string($a; "Target"),
                         new_string: need_string($a; "Replacement"),
                         replace_all: true },
           cwd: $ws }
       elif $name == "replace_file_content" then
         { tool_name: "Edit",
           tool_input: { file_path: need_path($a),
                         old_string: need_string($a; "TargetContent"),
                         new_string: need_string($a; "ReplacementContent"),
                         replace_all: ($a.AllowMultiple == true) },
           cwd: $ws }
       elif $name == "multi_replace_file_content" then
         ($a.ReplacementChunks // error("argument ReplacementChunks is missing")) as $rc
         # A string would hide its keys from the duplicate and case scans.
         | (if ($rc | type) == "string" then error("argument ReplacementChunks is a string, not an array") else $rc end) as $chunks
         | (if ($chunks | type) == "array" and ($chunks | length) > 0 then .
            else error("ReplacementChunks is not a non-empty array") end)
         | { tool_name: "MultiEdit",
             tool_input: { file_path: need_path($a),
                           edits: [ $chunks[]
                                    | if type == "object"
                                         and (.TargetContent | type) == "string"
                                         and (.ReplacementContent | type) == "string"
                                      then { old_string: .TargetContent,
                                             new_string: .ReplacementContent,
                                             replace_all: (.AllowMultiple == true) }
                                      else error("a ReplacementChunks item does not have string TargetContent and ReplacementContent")
                                      end ] },
             cwd: $ws }
       else
         error("tool \($name | tostring) has no ApexYard mapping")
       end)
    | { session_id: $sid, cwd: .cwd, hook_event_name: "PreToolUse",
        tool_name: .tool_name, tool_input: .tool_input }
      + (if .cwd_source then {apexyard_cwd_source: .cwd_source} else {} end)
  ' "$WORK/input"
}

# run_handler <command> <timeout seconds>: runs one settings.json command
# with the gate payload on stdin. Sets H_RC and H_TIMED_OUT. Each run gets
# its own process group, so the watchdog can stop the whole process tree.
run_handler() {
  local cmd="$1" secs="$2" pid wd
  : > "$WORK/out"
  : > "$WORK/err"
  rm -f "$WORK/timed-out"
  set -m
  (
    unset CLAUDE_CODE_SESSION_ID
    export APEXYARD_SESSION_ID="$SESSION_ID"
    # The protected-state library protects the pinned ops root and
    # CLAUDE_PROJECT_DIR. No pin exists under agy, because the pin needs
    # CLAUDE_CODE_SESSION_ID. So CLAUDE_PROJECT_DIR is the fork root, not the
    # workspace: agy opened in <fork>/docs must still protect
    # <fork>/.claude/. The gates still run in the workspace, so the resolver
    # walk starts where agy works.
    export CLAUDE_PROJECT_DIR="$OPS_ROOT"
    cd "$WORKSPACE" || exit 126
    exec bash -c "$cmd"
  ) < "$WORK/payload" > "$WORK/out" 2> "$WORK/err" &
  pid=$!
  (
    sleep "$secs"
    : > "$WORK/timed-out"
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
  ) > /dev/null 2>&1 &
  wd=$!
  set +m
  H_RC=0
  wait "$pid" 2>/dev/null || H_RC=$?
  kill -KILL -- "-$wd" 2>/dev/null || kill -KILL "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null || true
  H_TIMED_OUT=0
  if [ -f "$WORK/timed-out" ]; then H_TIMED_OUT=1; fi
  return 0
}

# Name of the gate script in a settings.json command, from the resolver
# shim's literal exec form. Empty when the command has another shape.
gate_script_of() {
  local re='/\.claude/hooks/([A-Za-z0-9._-]+\.sh)'
  if [[ "$1" =~ $re ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
}

# if_matches <if> <tool_name>: Claude Code handler-level predicate, compiled
# the same way as bin/sync-codex-adapter.sh. Tool(glob) needs an equal tool
# name and a bash glob match of tool_input.command. Returns 2 when the
# predicate does not parse.
if_matches() {
  local pred="$1" tool="$2" re='^([^()]+)\((.*)\)$' ptool glob cmd
  [[ "$pred" =~ $re ]] || return 2
  ptool="${BASH_REMATCH[1]}"
  glob="${BASH_REMATCH[2]}"
  [ "$ptool" = "$tool" ] || return 1
  # The sentinel keeps trailing newlines, which a substitution would drop.
  cmd=$(jq -r '(.tool_input.command // "") + "."' "$WORK/payload" 2>/dev/null) || return 2
  cmd=${cmd%.}
  # shellcheck disable=SC2053  # The glob is a pattern on purpose.
  [[ "$cmd" == $glob ]] || return 1
  return 0
}

# check_handler_runnable <command> <type>: fail when a handler cannot run.
check_handler_runnable() {
  local cmd="$1" type="$2" script
  [ "$type" = "command" ] \
    || fail "ApexYard agy adapter: a $EVENT handler has type '$type'. The adapter runs only command handlers, so it fails closed."
  [ -n "$cmd" ] || fail "ApexYard agy adapter: a $EVENT handler in .claude/settings.json has an empty command."
  script=$(gate_script_of "$cmd")
  if [ -n "$script" ] && [ ! -f "$OPS_ROOT/.claude/hooks/$script" ]; then
    fail "ApexYard agy adapter: gate .claude/hooks/$script is missing, so the adapter fails closed."
  fi
}

# compute_cwd_differs: CWD_DIFFERS=1 when the payload has a top-level cwd
# that is not the workspace, compared as physical paths. A relative cwd
# resolves against the workspace, as for the run directory. A cwd that
# cannot be resolved counts as different, so the check fails closed.
compute_cwd_differs() {
  local top real
  CWD_DIFFERS=0
  top=$(jq -r '.cwd | if type == "string" and (test("[\u0000-\u001f\u007f]") | not) then . elif . == null then "" else "!invalid" end' "$WORK/input" 2>/dev/null) || top="!invalid"
  [ -n "$top" ] || return 0
  if [ "$top" = "!invalid" ]; then CWD_DIFFERS=1; return 0; fi
  case "$top" in
    /*) ;;
    *) top="$WORKSPACE/$top" ;;
  esac
  real=$(CDPATH='' cd -- "$top" 2>/dev/null && pwd -P) || real=""
  if [ -z "$real" ] || [ "$real" != "$WORKSPACE" ]; then CWD_DIFFERS=1; fi
  return 0
}

run_pretooluse() {
  local payload tool cmd secs onfail pred type script rc reason
  compute_cwd_differs
  if ! payload=$(build_pretooluse_payload 2>"$WORK/map-err"); then
    reason=$(sed -e 's/^jq: error ([^)]*): //' -e 's/^jq: error: //' "$WORK/map-err" | head -n 3)
    deny "ApexYard agy adapter: cannot map this agy tool call, so it fails closed. ${reason:-unknown mapping error}"
  fi
  printf '%s\n' "$payload" > "$WORK/payload"
  tool=$(jq -r '.tool_name' "$WORK/payload")

  # The gates judge a command against the payload cwd. A cwd where the
  # command cannot run would let a gate judge the wrong directory. So the
  # run_command Cwd must be an existing directory. A relative Cwd resolves
  # against the workspace. The gates get the physical path. The gates still
  # run with the workspace as their working directory, so the resolver
  # finds this fork.
  if [ "$tool" = "Bash" ]; then
    local raw_cwd real_cwd cwd_source
    raw_cwd=$(jq -r '.cwd' "$WORK/payload") || deny "ApexYard agy adapter: cannot read the mapped Cwd, so it fails closed."
    cwd_source=$(jq -r '.apexyard_cwd_source // "workspace"' "$WORK/payload") || cwd_source=""
    case "$raw_cwd" in
      /*) ;;
      *) raw_cwd="$WORKSPACE/$raw_cwd" ;;
    esac
    real_cwd=$(CDPATH='' cd -- "$raw_cwd" 2>/dev/null && pwd -P) && [ -n "$real_cwd" ] \
      || deny "ApexYard agy adapter: run_command Cwd '$raw_cwd' is not an existing directory, so the gates cannot judge the command. It fails closed."
    # A top-level cwd is agy's own working directory, so it must stay inside
    # the fork. An explicit args.Cwd outside the fork stays allowed, as
    # before: the gates judge the command there.
    case "$cwd_source" in
      args|workspace) ;;
      top)
        case "$real_cwd/" in
          "$OPS_ROOT/"*) ;;
          *) deny "ApexYard agy adapter: the top-level cwd '$real_cwd' is outside the ApexYard fork $OPS_ROOT, so it fails closed." ;;
        esac
        ;;
      *) deny "ApexYard agy adapter: cannot tell where the run_command directory came from, so it fails closed." ;;
    esac
    jq -c --arg c "$real_cwd" '.cwd = $c | del(.apexyard_cwd_source)' "$WORK/payload" > "$WORK/payload.cwd" \
      && mv -f "$WORK/payload.cwd" "$WORK/payload" \
      || deny "ApexYard agy adapter: cannot store the resolved Cwd, so it fails closed."
  fi

  if [ -n "$AGY_LOG" ]; then
    note_meta claude_tool "$tool"
    note_meta command "$(jq -r '.tool_input.command // empty' "$WORK/payload" 2>/dev/null | head -c 200)"
    note_meta target "$(jq -r '.tool_input.file_path // empty' "$WORK/payload" 2>/dev/null)"
  fi

  # The permissions.deny rules apply before any gate runs.
  check_gated_denies "$tool"

  if [ -n "$AGY_LOG" ]; then
    note_meta claude_tool "$tool"
    note_meta command "$(jq -r '.tool_input.command // empty' "$WORK/payload" 2>/dev/null | head -c 200)"
    note_meta target "$(jq -r '.tool_input.file_path // empty' "$WORK/payload" 2>/dev/null)"
  fi

  handlers_for PreToolUse "$tool" > "$WORK/handlers" 2>"$WORK/handlers-err" \
    || deny "ApexYard agy adapter: cannot read the PreToolUse handlers from .claude/settings.json. $(head -n 1 "$WORK/handlers-err")"

  while IFS= read -r -d '' cmd && IFS= read -r -d '' secs && IFS= read -r -d '' onfail \
    && IFS= read -r -d '' pred && IFS= read -r -d '' type; do
    note_meta gate "$(gate_script_of "$cmd")"
    check_handler_runnable "$cmd" "$type"
    if [ -n "$pred" ]; then
      rc=0
      if_matches "$pred" "$tool" || rc=$?
      [ "$rc" = 2 ] && deny "ApexYard agy adapter: cannot evaluate the handler predicate '$pred', so it fails closed."
      [ "$rc" = 0 ] || continue
    fi
    script=$(gate_script_of "$cmd")
    script=${script:-settings.json command}
    note_meta gate "$script"
    run_handler "$cmd" "$secs"
    cat "$WORK/err" >&2
    if [ "$H_TIMED_OUT" = 1 ]; then
      deny "ApexYard agy adapter: gate $script did not finish in ${secs}s, so the adapter fails closed. Retry the action."
    fi
    if [ "$H_RC" = 2 ]; then
      reason=$(cat "$WORK/err")
      [ -n "$reason" ] || reason="Blocked by ApexYard gate $script."
      deny "$reason"
    fi
    if [ "$H_RC" = 126 ] || [ "$H_RC" = 127 ]; then
      deny "ApexYard agy adapter: gate $script could not run (exit $H_RC), so the adapter fails closed. $(head -n 3 "$WORK/err")"
    fi
    if [ "$H_RC" != 0 ] && [ "$onfail" = "block" ]; then
      deny "ApexYard agy adapter: gate $script failed with exit $H_RC and sets onFailure=block. $(head -n 3 "$WORK/err")"
    fi
  done < "$WORK/handlers"
  ask
}

run_sessionstart() {
  local cmd secs onfail pred type script errors=""
  jq -cn --arg sid "$SESSION_ID" --arg ws "$WORKSPACE" \
    '{session_id:$sid, cwd:$ws, hook_event_name:"SessionStart", source:"startup"}' > "$WORK/payload" \
    || fail "ApexYard agy adapter: cannot build the SessionStart payload."
  handlers_for SessionStart startup > "$WORK/handlers" 2>/dev/null \
    || fail "ApexYard agy adapter: cannot read the SessionStart handlers from .claude/settings.json."
  : > "$WORK/context"
  while IFS= read -r -d '' cmd && IFS= read -r -d '' secs && IFS= read -r -d '' onfail \
    && IFS= read -r -d '' pred && IFS= read -r -d '' type; do
    check_handler_runnable "$cmd" "$type"
    script=$(gate_script_of "$cmd")
    script=${script:-settings.json command}
    run_handler "$cmd" "$secs"
    cat "$WORK/out" >> "$WORK/context"
    cat "$WORK/err" >&2
    if [ "$H_TIMED_OUT" = 1 ]; then
      errors="${errors}SessionStart hook $script did not finish in ${secs}s. "
    elif [ "$H_RC" != 0 ]; then
      errors="${errors}SessionStart hook $script exited $H_RC. "
    fi
  done < "$WORK/handlers"
  jq -cn --rawfile ctx "$WORK/context" --arg errors "$errors" '
    {injectSteps: (
      (if ($ctx | test("\\S")) then [{systemMessage: {systemMessage: $ctx}}] else [] end)
      + (if $errors != "" then [{errorMessage: {userMessage: ("ApexYard agy adapter: " + $errors)}}] else [] end)
    )}' || session_error_fixed "ApexYard agy adapter: cannot encode the SessionStart output."
  exit 0
}

# Tool policy for agy tool names (AgDR-0314). hooks.json routes every agy
# tool to this wrapper with a catch-all matcher. The wrapper then sorts the
# tool into one of four classes:
#   - GATED_TOOLS run the settings.json gates (see build_pretooluse_payload).
#   - READ_ONLY_TOOLS get ask at once, before settings.json is read. Each
#     one reads state or asks the user. None runs a command or writes a file.
#   - KEYSTROKE_TOOLS are always denied. They type keystrokes into a running
#     shell, and no gate can inspect keystrokes.
#   - manage_task is decided by its Action argument. list, kill, and status
#     manage agy's background tasks and get ask. send_input types into a
#     running shell and gets the keystroke deny. Any other Action, or none,
#     gets deny.
#   - Every other tool is denied: subagent, schedule, browser, image, message
#     and mcp_* tools, and any tool that agy adds later.
# To extend: add a read-only tool to READ_ONLY_TOOLS only after you confirm
# that it cannot run a command or write a file. Add a tool that writes or
# runs commands only with a mapping in build_pretooluse_payload, the same
# entry in bin/sync-agy-adapter.sh, and a test.
# The documented names (write_to_file, view_file, ...) may be the IDE's
# names. The agy CLI 1.5.14 used write_file and read_file instead. Both
# sets stay listed.
GATED_TOOLS="run_command write_to_file write_file replace_file_content multi_replace_file_content edit_file"
KEYSTROKE_TOOLS="send_command_input"
# agy CLI 1.5.14: "Valid actions: list, kill, status, send_input".
MANAGE_TASK_SAFE_ACTIONS="list kill status"
# grep_search is not on the list: it reads the content of every file under a
# folder, .env files included, so a path-based Read(...) rule cannot see what
# it reads. agy CLI 1.5.14 does not declare it, so it is denied as unrouted.
# view_file reads only the path it names, which check_read_denies checks.
# read_terminal and command_status read the output of commands that the
# gates already judged. find_by_name and list_dir return names, not content.
READ_ONLY_TOOLS="read_file view_file list_dir find_by_name search_web read_url_content command_status read_terminal ask_question ask_permission list_permissions"

# Argument-shape checks (AgDR-0314). jq keeps the last of two duplicate keys
# and matches key case exactly. agy is a Go binary, and Go's encoding/json
# matches struct fields case-insensitively. So a duplicate or case-variant key
# could make the wrapper judge one value while agy acts on another. The
# wrapper denies duplicate keys in any object, case-variant keys in toolCall
# and its args, and any args key outside the tool's allowlist.
#
# JQ_DUPS reads `jq --stream` events, which keep duplicate keys that a parsed
# object hides. It counts how often the value of each (object, key) pair
# completes. A [path, leaf] event completes the value at path. A [path]
# closing event completes the container at path minus its last element. A
# count above one is a duplicate key. It prints the duplicated keys, or
# nothing.
# shellcheck disable=SC2016  # jq variables, not shell variables.
JQ_DUPS='
  reduce inputs as $e ({};
    (if ($e | length) == 2 then $e[0] else $e[0][0:-1] end) as $c
    | if ($c | length) == 0 or (($c[-1]) | type) != "string" then .
      else ([$c[0:-1], $c[-1]] | tojson) as $id | .[$id] += 1 end)
  | to_entries | map(select(.value > 1) | .key | fromjson | .[1]) | unique | map(tojson) | join(", ")'

# Allowed args keys for each tool, case-sensitive. The agy CLI 1.5.14 keys
# come from the live check, the binary's json tags, and agy's own tool list
# (read_file, write_file, edit_file). The documented
# tools keep their documented keys. A tool not listed here has no key list:
# it is read-only or denied by the tool policy.
# shellcheck disable=SC2016  # jq variables, not shell variables.
JQ_ARG_KEYS='{
  "run_command": ["CommandLine", "Cwd", "WaitMsBeforeAsync", "RunPersistent", "RequestedTerminalID", "IsDaemon", "BypassSandbox", "toolSummary"],
  "write_file": ["Path", "Content", "Append", "Overwrite", "ArtifactMetadata", "toolSummary"],
  "edit_file": ["Path", "Target", "Replacement", "ArtifactMetadata", "toolSummary"],
  "read_file": ["Path", "StartLine", "EndLine", "ByteOffset", "toolSummary"],
  "manage_task": ["Action", "TaskId", "toolSummary"],
  "write_to_file": ["TargetFile", "Overwrite", "CodeContent", "Description", "toolSummary"],
  "replace_file_content": ["TargetFile", "Instruction", "Description", "AllowMultiple", "TargetContent", "ReplacementContent", "StartLine", "EndLine", "toolSummary"],
  "multi_replace_file_content": ["TargetFile", "ReplacementChunks", "toolSummary"]
}'

# Allowed keys in one multi_replace_file_content ReplacementChunks item.
JQ_CHUNK_KEYS='["TargetContent", "ReplacementContent", "AllowMultiple", "StartLine", "EndLine"]'
# Allowed keys in the write_file and edit_file ArtifactMetadata object.
JQ_ARTIFACT_KEYS='["Summary", "UserFacing", "RequestFeedback"]'

# keystroke_first: a keystroke call gets the keystroke deny, whatever its
# other keys, before the shape checks. jq compares the exact strings.
keystroke_first() {
  local verdict
  verdict=$(jq -r --arg ks "$KEYSTROKE_TOOLS" '
    (.toolCall.name? // "") as $n
    | (.toolCall.args? // {}) as $raw
    | ((if ($raw | type) == "string" then ($raw | try fromjson catch {}) else $raw end)) as $a
    | if ($n | type) == "string" and ([$ks | splits(" ")] | index($n)) != null then "tool"
      elif $n == "manage_task" and ($a | type) == "object" and $a.Action == "send_input" then "action"
      else "" end
  ' "$WORK/input" 2>/dev/null) || verdict=""
  case "$verdict" in
    tool)
      deny "ApexYard agy adapter: $(jq -r '.toolCall.name' "$WORK/input") is always denied. It types keystrokes into a running shell, and no ApexYard gate can inspect keystrokes. Use run_command, so the gates can check the command."
      ;;
    action)
      deny "ApexYard agy adapter: manage_task with Action send_input is always denied. It types keystrokes into a running shell, and no ApexYard gate can inspect keystrokes. Use run_command, so the gates can check the command."
      ;;
  esac
  return 0
}

# check_arg_shape: deny on a duplicate key, a case-variant key, or an args
# key outside the tool's allowlist.
check_arg_shape() {
  local dups reason
  dups=$(jq -n --stream -r "$JQ_DUPS" "$WORK/input" 2>/dev/null) \
    || deny "ApexYard agy adapter: cannot scan the hook payload for duplicate keys, so it fails closed."
  [ -z "$dups" ] || deny "ApexYard agy adapter: the hook payload repeats the key(s) $dups. agy and the wrapper could read different values, so it fails closed."
  if jq -e '(.toolCall.args? | type) == "string"' "$WORK/input" >/dev/null 2>&1; then
    jq -j '.toolCall.args' "$WORK/input" > "$WORK/args-string" 2>/dev/null \
      || deny "ApexYard agy adapter: cannot read toolCall.args, so it fails closed."
    dups=$(jq -n --stream -r "$JQ_DUPS" "$WORK/args-string" 2>/dev/null) \
      || deny "ApexYard agy adapter: toolCall.args is a string that is not valid JSON, so it fails closed."
    [ -z "$dups" ] || deny "ApexYard agy adapter: toolCall.args repeats the key(s) $dups. agy and the wrapper could read different values, so it fails closed."
  fi
  reason=$(jq -r --argjson allowed "$JQ_ARG_KEYS" --argjson chunk_keys "$JQ_CHUNK_KEYS" \
    --argjson artifact_keys "$JQ_ARTIFACT_KEYS" '
    (.toolCall // {}) as $t
    | ($t.args // {}) as $raw
    | (if ($raw | type) == "string" then ($raw | fromjson) else $raw end) as $a
    | ([($t | objects), ($a | .. | objects)]
       | map(keys | group_by(ascii_downcase) | map(select(length > 1))[])
       | .[0]) as $variant
    | if $variant != null then
        "the keys \($variant | map(tojson) | join(" and ")) differ only in case"
      elif ($t | type) == "object" and ($a | type) == "object" and (($t.name | type) == "string")
           and ($allowed[$t.name] != null) then
        ([$a | keys[] | select(. as $k | $allowed[$t.name] | index($k) | not)] | .[0]) as $unknown
        | if $unknown != null then "agy tool \($t.name | tojson) has the args key \($unknown | tojson), which is not on its key list"
          elif ($a | has("ArtifactMetadata")) and ($a.ArtifactMetadata | type) != "object" then
            "ArtifactMetadata is not an object"
          elif ($a | has("ArtifactMetadata"))
               and ([$a.ArtifactMetadata | keys[] | select(. as $k | $artifact_keys | index($k) | not)] | length) > 0 then
            "ArtifactMetadata has the key \([$a.ArtifactMetadata | keys[] | select(. as $k | $artifact_keys | index($k) | not)][0] | tojson), which is not on its key list"
          elif $t.name == "multi_replace_file_content" and ($a.ReplacementChunks | type) == "array" then
            ([$a.ReplacementChunks[] | objects | keys[]
              | select(. as $k | $chunk_keys | index($k) | not)] | .[0]) as $bad_chunk
            | if $bad_chunk != null then "a ReplacementChunks item has the key \($bad_chunk | tojson), which is not on the chunk key list"
              else "" end
          else "" end
      else "" end
  ' "$WORK/input" 2>/dev/null) \
    || deny "ApexYard agy adapter: cannot check the toolCall.args keys, so it fails closed."
  [ -z "$reason" ] || deny "ApexYard agy adapter: $reason. It fails closed."
  return 0
}

# permissions.deny (AgDR-0314). Claude Code applies the permissions.deny
# rules in .claude/settings.json itself. agy does not read them, so the
# wrapper applies them, read at run time like the gates. Matching is literal:
#   Read(<glob>)          any string argument of a read-only tool, as a path
#   Edit(<glob>)          the file path of Write, Edit, and MultiEdit calls
#   Write(<glob>)         the file path of Write calls
#   Bash(<cmd>)           a run_command whose trimmed CommandLine is <cmd>
#   Bash(<prefix>:*)      ... is <prefix>, or starts with "<prefix> "
# Glob: a leading // is an absolute path, ~/ is the home folder, a leading /
# is the fork root, and a pattern with neither matches anywhere under the
# fork. ** is any depth, including none, * is one path segment, and ? is one
# character. Paths match without case, so the rules over-match on purpose.
# There is no shell parser: pipes, chains, wrapped commands, and absolute
# command paths are not caught (AgDR-0267). Any other
# rule type, such as WebFetch(...), is not applied.

# load_perm_rules: compile the rules once into $WORK/perm-rules.json. A
# settings file that cannot be read gets deny, so no rule is skipped.
load_perm_rules() {
  [ -s "$WORK/perm-rules.json" ] && return 0
  [ -n "$OPS_ROOT" ] && [ -f "$SETTINGS" ] \
    || deny "ApexYard agy adapter: cannot read permissions.deny from .claude/settings.json, so it fails closed."
  jq -c --arg ops "$OPS_ROOT" --arg home "${HOME:-/nonexistent}" '
    def esc: gsub("(?<c>[.+^${}()|\\[\\]\\\\])"; "\\\(.c)");
    def glob_re:
      esc
      | gsub("\\*\\*/"; "\u0001") | gsub("\\*\\*"; "\u0002")
      | gsub("\\*"; "[^/]*") | gsub("\\?"; "[^/]")
      | gsub("\u0001"; "(.*/)?") | gsub("\u0002"; ".*");
    def rooted:
      if startswith("//") then .[1:]
      elif startswith("~/") then $home + .[1:]
      elif startswith("/") then $ops + .
      elif startswith("./") then $ops + "/" + .[2:]
      else $ops + "/**/" + . end;
    (.permissions.deny // [])
    | if type != "array" then error("permissions.deny is not an array") else . end
    | [ .[] | select(type == "string") | . as $rule
        | ( (capture("\\A(?<kind>Read|Edit|Write)\\((?<glob>.+)\\)\\z")
             | {rule: $rule, kind: .kind, re: ("^" + (.glob | rooted | glob_re) + "$")})
          // (capture("\\ABash\\((?<cmd>.+)\\)\\z") | {rule: $rule, kind: "Bash", cmd: .cmd})
          // empty ) ]
  ' "$SETTINGS" > "$WORK/perm-rules.json" 2>/dev/null && [ -s "$WORK/perm-rules.json" ] \
    || deny "ApexYard agy adapter: cannot read permissions.deny from .claude/settings.json, so it fails closed."
  return 0
}

# perm_lexical <path>: the path with ".", "..", and repeated slashes removed.
perm_lexical() {
  printf '%s\n' "$1" | awk -F/ '{n=0; for(i=1;i<=NF;i++){if($i==""||$i==".")continue;if($i==".."){if(n)n--;continue} a[++n]=$i} p="";for(i=1;i<=n;i++)p=p "/" a[i];print (p==""?"/":p)}'
}

# PERM_LINK_DEPTH: the most symlinks perm_physical follows in one chain.
PERM_LINK_DEPTH=40

# perm_physical <path>: the path with every symlink in its chain followed,
# and its folder resolved through symlinks. A loop, a chain longer than
# PERM_LINK_DEPTH, or an unreadable link prints "!unresolvable", and the
# caller fails closed. A dangling link resolves to its missing target. Nothing
# is printed when the final folder does not exist. readlink without options
# keeps this bash 3.2 and macOS safe.
perm_physical() {
  local p="$1" link dir n=0
  while [ -L "$p" ]; do
    n=$((n + 1))
    if [ "$n" -gt "$PERM_LINK_DEPTH" ]; then
      printf '%s\n' '!unresolvable'
      return 0
    fi
    link=$(readlink "$p" 2>/dev/null) || { printf '%s\n' '!unresolvable'; return 0; }
    [ -n "$link" ] || { printf '%s\n' '!unresolvable'; return 0; }
    case "$link" in /*) p="$link" ;; *) p="${p%/*}/$link" ;; esac
  done
  dir=$(CDPATH='' cd -- "${p%/*}/" 2>/dev/null && pwd -P) || return 0
  printf '%s/%s\n' "${dir%/}" "${p##*/}"
}

# perm_path_rule <kinds> <path>...: print the first rule of <kinds> that
# matches any path in its given, lexical, or physical form, or nothing.
perm_path_rule() {
  local kinds="$1" p
  shift
  : > "$WORK/perm-paths"
  for p in "$@"; do
    {
      printf '%s\n' "$p"
      perm_lexical "$p"
      perm_physical "$p"
    } >> "$WORK/perm-paths"
  done
  if grep -qx '!unresolvable' "$WORK/perm-paths" 2>/dev/null; then
    printf '%s' '!unresolvable'
    return 0
  fi
  jq -R -s -r --slurpfile rules "$WORK/perm-rules.json" --arg kinds "$kinds" '
    (split("\n") | map(select(. != ""))) as $paths
    | [ $rules[0][] | select(.kind as $k | ($kinds | split(" ") | index($k)) != null)
        | . as $r | select(any($paths[]; test($r.re; "i"))) | .rule ] | (.[0] // "")
  ' "$WORK/perm-paths" 2>/dev/null || printf '%s' "!error"
}

perm_deny() { # <rule>
  deny "ApexYard agy adapter: the call matches the permissions.deny rule $1 in .claude/settings.json, so it is denied."
}

# check_read_denies: apply Read(...) rules to every string argument of a
# read-only tool, as an absolute path or relative to the workspace and the
# top-level cwd.
check_read_denies() {
  local rule bad v base
  local -a paths=() bases=()
  bad=$(jq -r '[(.toolCall.args? // {}) | if type == "string" then (try fromjson catch {}) else . end
      | .. | strings | select(test("[\u0000-\u001f\u007f]"))] | length' "$WORK/input" 2>/dev/null) || bad=1
  [ "$bad" = 0 ] || deny "ApexYard agy adapter: a read-only tool argument contains a control character, so it fails closed."
  while IFS= read -r base; do
    [ -n "$base" ] && bases[${#bases[@]}]="$base"
  done < <(jq -r '[(.workspacePaths[0]? // empty), (.cwd? // empty)] | .[]
      | select(type == "string" and startswith("/") and (test("[\u0000-\u001f\u007f]") | not))' "$WORK/input" 2>/dev/null)
  [ "${#bases[@]}" -gt 0 ] || bases[0]="$OPS_ROOT"
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case "$v" in
      /*) paths[${#paths[@]}]="$v" ;;
      \~/*) paths[${#paths[@]}]="${HOME:-/nonexistent}/${v#\~/}" ;;
      *) for base in "${bases[@]}"; do paths[${#paths[@]}]="$base/$v"; done ;;
    esac
  done < <(jq -r '(.toolCall.args? // {}) | if type == "string" then (try fromjson catch {}) else . end | .. | strings' "$WORK/input" 2>/dev/null)
  # A call with no string argument names no path, so no Read rule applies.
  [ "${#paths[@]}" -gt 0 ] || return 0
  load_perm_rules
  rule=$(perm_path_rule "Read" "${paths[@]}")
  [ "$rule" != "!error" ] || deny "ApexYard agy adapter: cannot match permissions.deny rules, so it fails closed."
  [ "$rule" != "!unresolvable" ] || deny "ApexYard agy adapter: a path argument is a symlink chain that loops, runs longer than $PERM_LINK_DEPTH links, or cannot be read. The permissions.deny rules cannot judge it, so it fails closed."
  [ -z "$rule" ] || perm_deny "$rule"
  return 0
}

# check_gated_denies <tool>: apply Edit(...) and Write(...) rules to a file
# path, and Bash(...) rules to a command, of a mapped gated call.
check_gated_denies() {
  local tool="$1" kinds="" file rule
  load_perm_rules
  if [ "$tool" = "Bash" ]; then
    # Trim, then collapse each run of spaces and tabs to one space, so
    # "gh  auth token" matches as "gh auth token". This can only add denies.
    rule=$(jq -r --slurpfile rules "$WORK/perm-rules.json" '
      (.tool_input.command | gsub("\\A\\s+|\\s+\\z"; "") | gsub("[ \\t]+"; " ")) as $c
      | [ $rules[0][] | select(.kind == "Bash")
          | select(if (.cmd | endswith(":*")) then (.cmd[:-2]) as $p | ($c == $p or ($c | startswith($p + " ")))
                   else $c == .cmd end) | .rule ] | (.[0] // "")' "$WORK/payload" 2>/dev/null) || rule="!error"
  else
    case "$tool" in
      Write) kinds="Edit Write" ;;
      Edit|MultiEdit) kinds="Edit" ;;
    esac
    file=$(jq -r '.tool_input.file_path // ""' "$WORK/payload" 2>/dev/null) || file=""
    [ -n "$kinds" ] && [ -n "$file" ] || return 0
    rule=$(perm_path_rule "$kinds" "$file")
  fi
  [ "$rule" != "!error" ] || deny "ApexYard agy adapter: cannot match permissions.deny rules, so it fails closed."
  [ "$rule" != "!unresolvable" ] || deny "ApexYard agy adapter: a path argument is a symlink chain that loops, runs longer than $PERM_LINK_DEPTH links, or cannot be read. The permissions.deny rules cannot judge it, so it fails closed."
  [ -z "$rule" ] || perm_deny "$rule"
  return 0
}

in_list() { # <word> <space-separated list>
  local w
  for w in $2; do [ "$w" = "$1" ] && return 0; done
  return 1
}

# apply_tool_policy <tool name>: ask, deny, or return 0 for a gated tool.
apply_tool_policy() {
  local tool="$1"
  case "$tool" in
    '') deny "ApexYard agy adapter: the hook payload has no toolCall.name, so it fails closed." ;;
    '!invalid') deny "ApexYard agy adapter: toolCall.name holds characters outside [A-Za-z0-9_.:-], so it fails closed." ;;
  esac
  in_list "$tool" "$GATED_TOOLS" && return 0
  if in_list "$tool" "$READ_ONLY_TOOLS"; then
    check_read_denies
    ask
  fi
  if in_list "$tool" "$KEYSTROKE_TOOLS"; then
    deny "ApexYard agy adapter: $tool is always denied. It types keystrokes into a running shell, and no ApexYard gate can inspect keystrokes. Use run_command, so the gates can check the command."
  fi
  if [ "$tool" = "manage_task" ]; then
    # jq compares the exact Action string. A shell substitution would drop a
    # trailing newline, so "list\n" must not become "list".
    local verdict
    verdict=$(jq -r --arg safe "$MANAGE_TASK_SAFE_ACTIONS" '
      (.toolCall.args // {}) as $raw
      | (if ($raw | type) == "string" then ($raw | fromjson) else $raw end) as $a
      | if ($a | type) != "object" or ($a.Action | type) != "string" then "bad"
        elif $a.Action == "send_input" then "keystrokes"
        elif ([$safe | splits(" ")] | index($a.Action)) != null then "safe"
        else "bad" end
    ' "$WORK/input" 2>/dev/null) || verdict="bad"
    if [ "$verdict" = "keystrokes" ]; then
      deny "ApexYard agy adapter: manage_task with Action send_input is always denied. It types keystrokes into a running shell, and no ApexYard gate can inspect keystrokes. Use run_command, so the gates can check the command."
    fi
    if [ "$verdict" = "safe" ]; then
      ask
    fi
    deny "ApexYard agy adapter: manage_task needs a string Action of list, kill, or status. A missing or unknown Action is denied (fail closed)."
  fi
  deny "ApexYard agy adapter: agy tool '$tool' is not routed by the ApexYard adapter, so it is denied (fail closed). See docs/harnesses/agy.md for the tool policy."
}

# walk_root <start dir>: print the fork root that the settings.json resolver
# finds from <start dir>, as a physical path. The rule is the same as the
# resolver's walk: the nearest ancestor with .apexyard-fork or
# onboarding.yaml and a .claude/hooks directory. Print nothing for no root.
walk_root() {
  local r="$1"
  while [ -n "$r" ] && [ "$r" != / ]; do
    { [ -f "$r/.apexyard-fork" ] || [ -f "$r/onboarding.yaml" ]; } && [ -d "$r/.claude/hooks" ] && break
    r=${r%/*}
  done
  [ -d "$r/.claude/hooks" ] || return 0
  (cd "$r" 2>/dev/null && pwd -P)
}

# check_session_snapshot: the SessionStart snapshot fixes the protected
# project root for the whole conversation (_lib-protected-state.sh). A
# snapshot written with another project root, for example a subfolder,
# would leave <fork>/.claude/ unprotected for that conversation. So a
# snapshot whose project_dir is not the fork root gets a deny, and the user
# starts a new agy conversation.
check_session_snapshot() {
  local snap="${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/gate-session-$SESSION_ID/snapshot.json" proj real
  [ -e "$snap" ] || return 0
  proj=$(jq -r '.project_dir | if type == "string" and (test("[\u0000-\u001f\u007f]") | not) then . else "" end' "$snap" 2>/dev/null) || proj=""
  real=""
  [ -n "$proj" ] && real=$(CDPATH='' cd -- "$proj" 2>/dev/null && pwd -P)
  if [ -z "$real" ] || [ "$real" != "$OPS_ROOT" ]; then
    fail "ApexYard agy adapter: this conversation's session snapshot protects '$proj', not the fork root $OPS_ROOT. So .claude/ could be unprotected. It fails closed. Start a new agy conversation."
  fi
  return 0
}

# check_nested_agents: agy reads .agents/ hook and plugin config in folders
# between its directory and the fork root. A nested hooks.json, plugins.json,
# or plugins/ can add or replace hooks, and so override the fork's gates. The
# walk starts at the top-level cwd and at workspacePaths[0], in lexical and
# physical form. It checks each ancestor up to, but not including, the fork
# root, whose .agents/ is the real wiring. It never reads a subfolder, so the
# cost is a few stat calls per call. A start outside the fork walks nothing.
# The workspace checks below deny it for a gated tool.
check_nested_agents() {
  [ -n "$OPS_ROOT" ] || return 0
  local ws top start form d
  ws=$(jq -r '.workspacePaths | if type == "array" and length > 0 and (.[0] | type) == "string"
      and (.[0] | test("[\u0000-\u001f\u007f]") | not) then .[0] else "" end' "$WORK/input" 2>/dev/null) || ws=""
  top=$(jq -r '.cwd | if type == "string" and (test("[\u0000-\u001f\u007f]") | not) then . else "" end' "$WORK/input" 2>/dev/null) || top=""
  case "$ws" in /*) ;; *) ws="" ;; esac
  case "$top" in
    ''|/*) ;;
    *) if [ -n "$ws" ]; then top="$ws/$top"; else top=""; fi ;;
  esac
  for start in "$top" "$ws"; do
    [ -n "$start" ] || continue
    for form in "$(perm_lexical "$start")" "$(CDPATH='' cd -- "$start" 2>/dev/null && pwd -P)"; do
      d="$form"
      while [ -n "$d" ]; do
        case "$d/" in "$OPS_ROOT/"?*) ;; *) break ;; esac
        if [ -e "$d/.agents/hooks.json" ] || [ -L "$d/.agents/hooks.json" ] \
          || [ -e "$d/.agents/plugins.json" ] || [ -L "$d/.agents/plugins.json" ] \
          || [ -e "$d/.agents/plugins" ] || [ -L "$d/.agents/plugins" ]; then
          fail "ApexYard agy adapter: a nested .agents hook or plugin config at $d/.agents can override the fork's hooks; remove it from the live fork."
        fi
        d=${d%/*}
      done
    done
  done
  return 0
}

main() {
  case "$EVENT" in
    PreToolUse|SessionStart) ;;
    *) deny "ApexYard agy adapter: unknown event argument '$EVENT'. Regenerate .agents/hooks.json with bin/sync-agy-adapter.sh." ;;
  esac

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-agy.XXXXXX" 2>/dev/null) \
    || fail "ApexYard agy adapter: cannot create a temporary directory."
  trap 'rm -rf "$WORK"' EXIT

  printf '%s' "$INPUT" > "$WORK/input" \
    || fail "ApexYard agy adapter: cannot store the hook payload."
  jq -e 'type == "object"' "$WORK/input" >/dev/null 2>&1 \
    || fail "ApexYard agy adapter: the hook payload on stdin is not a JSON object."

  # Before the tool policy, so a read-only tool and SessionStart are covered.
  check_nested_agents

  # The tool policy runs before settings.json is read, so a read-only tool
  # gets ask even when the fork is broken.
  if [ "$EVENT" = "PreToolUse" ]; then
    keystroke_first
    check_arg_shape
    # jq checks the name. A shell substitution would drop a trailing
    # newline, so "view_file\n" must not become view_file.
    apply_tool_policy "$(jq -r '.toolCall.name? // "" | tostring
      | if . == "" or test("\\A[A-Za-z0-9_.:-]+\\z") then . else "!invalid" end' "$WORK/input" 2>/dev/null)"
  fi

  [ -n "$OPS_ROOT" ] && [ -d "$OPS_ROOT/.claude/hooks" ] && [ -f "$SETTINGS" ] \
    || fail "ApexYard agy adapter: cannot find .claude/hooks and .claude/settings.json above $ADAPTER_DIR."
  [ -f "$OPS_ROOT/.apexyard-fork" ] || [ -f "$OPS_ROOT/onboarding.yaml" ] \
    || fail "ApexYard agy adapter: $OPS_ROOT has no .apexyard-fork or onboarding.yaml, so the gates cannot resolve the fork. Run /setup first."
  jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 \
    || fail "ApexYard agy adapter: $SETTINGS is not valid JSON."

  # jq validates both fields before a shell substitution can drop a
  # trailing newline from them.
  SESSION_ID=$(jq -r '.conversationId | if type == "string" and test("\\A[A-Za-z0-9_-]+\\z") then . else "" end' "$WORK/input" 2>/dev/null) || SESSION_ID=""
  case "$SESSION_ID" in
    ''|*[!A-Za-z0-9_-]*)
      fail "ApexYard agy adapter: conversationId is missing or holds characters outside [A-Za-z0-9_-]."
      ;;
  esac

  WORKSPACE=$(jq -r '.workspacePaths | if type == "array" and length > 0 and (.[0] | type) == "string"
      and (.[0] | test("[\u0000-\u001f\u007f]") | not) then .[0] else "" end' "$WORK/input" 2>/dev/null) || WORKSPACE=""
  case "$WORKSPACE" in
    /*) ;;
    *) fail "ApexYard agy adapter: workspacePaths[0] is missing or is not an absolute path." ;;
  esac
  WORKSPACE=$(cd "$WORKSPACE" 2>/dev/null && pwd -P) \
    || fail "ApexYard agy adapter: workspacePaths[0] is not a directory."
  case "$WORKSPACE/" in
    "$OPS_ROOT/"*) ;;
    *) fail "ApexYard agy adapter: workspace $WORKSPACE is outside the ApexYard fork $OPS_ROOT. Open agy in the fork that holds this .agents/hooks.json." ;;
  esac

  # The settings.json commands run with cwd=$WORKSPACE and re-resolve the
  # fork by walking up from there. They exit 0 (pass) when they find none.
  # So the walk must find exactly this wrapper's fork. A nearer nested anchor
  # between the workspace and the fork would run another fork's gates.
  local walked
  walked=$(walk_root "$WORKSPACE")
  if [ -z "$walked" ]; then
    fail "ApexYard agy adapter: workspace $WORKSPACE resolves to no ApexYard fork, so the gates would not run. It fails closed."
  fi
  if [ "$walked" != "$OPS_ROOT" ]; then
    fail "ApexYard agy adapter: workspace $WORKSPACE resolves to a different ApexYard fork ($walked) than the adapter's fork ($OPS_ROOT). It fails closed. Open agy in $OPS_ROOT."
  fi

  check_session_snapshot

  if [ "$EVENT" = "PreToolUse" ]; then
    run_pretooluse
  else
    run_sessionstart
  fi
}

# Read stdin in the parent shell, so the subshell below gets the bytes.
INPUT=$(cat 2>/dev/null) || INPUT=""

# Output guard. main runs in a subshell, and its stdout goes to a file. The
# guard re-encodes that output. A crash, an unset variable, or output other
# than one ask or deny object becomes a deny. So for PreToolUse the
# wrapper prints only {"decision":"ask"} or {"decision":"deny",...}. Any
# other decision, allow included, becomes a deny here.
GUARD=$(mktemp "${TMPDIR:-/tmp}/apexyard-agy-out.XXXXXX" 2>/dev/null) \
  || fail_fixed "ApexYard agy adapter: cannot create a temporary file."
META="$GUARD.meta"
( main ) > "$GUARD"
main_rc=$?
FINAL=""
if [ "$EVENT" = "SessionStart" ]; then
  # Each step must have agy's nested shape. Anything else becomes an error step.
  if jq -se 'length == 1 and (.[0].injectSteps | type) == "array"
      and (.[0].injectSteps | all(
            ((keys == ["systemMessage"]) and (.systemMessage | type) == "object" and (.systemMessage.systemMessage | type) == "string")
            or ((keys == ["errorMessage"]) and (.errorMessage | type) == "object" and (.errorMessage.userMessage | type) == "string")))' \
      "$GUARD" >/dev/null 2>&1; then
    FINAL=$(jq -c '{injectSteps: .injectSteps}' "$GUARD" 2>/dev/null) || FINAL=""
  fi
  [ -n "$FINAL" ] || FINAL=$(jq -cn --arg rc "$main_rc" '{injectSteps: [{errorMessage: {userMessage: ("ApexYard agy adapter: SessionStart internal error (exit " + $rc + ").")}}]}')
else
  decision=$(jq -rs 'if length == 1 and (.[0] | type) == "object" then (.[0].decision // "") else "" end' "$GUARD" 2>/dev/null) || decision=""
  case "$decision" in
    ask)
      FINAL='{"decision":"ask"}'
      ;;
    deny)
      FINAL=$(jq -c '{decision: "deny", reason: ((.reason // "Blocked by an ApexYard gate.") | tostring)}' "$GUARD" 2>/dev/null) || FINAL=""
      [ -n "$FINAL" ] || FINAL='{"decision":"deny","reason":"ApexYard agy adapter: cannot encode the deny reason."}'
      ;;
    *)
      FINAL=$(jq -cn --arg rc "$main_rc" '{decision: "deny", reason: ("ApexYard agy adapter: internal error (exit " + $rc + "), so it fails closed.")}')
      ;;
  esac
fi
rm -f "$GUARD"
printf '%s\n' "$FINAL"

# write_log: append one JSON line to AGY_LOG. It runs only after the decision
# is on stdout, in a subshell whose output and errors are discarded. It logs
# the command text and the target path, never file content. The payload and
# every value taken from it reach jq on stdin or through --rawfile, never as
# a process argument: an argument shows in ps, and a large one fails with
# E2BIG.
write_log() {
  local end_ms key
  end_ms=$(now_ms)
  for key in claude_tool command target gate; do
    [ -f "$META.$key" ] || : > "$META.$key"
  done
  printf '%s' "$FINAL" > "$META.final"
  # Skip the write when the log path or its parent directory is a symlink,
  # so the log cannot be redirected to another file.
  local parent="${AGY_LOG%/*}"
  [ -n "$parent" ] || parent=/
  [ -L "$AGY_LOG" ] && return 0
  [ -L "$parent" ] && return 0
  mkdir -p "$parent"
  [ -L "$parent" ] && return 0
  printf '%s' "$INPUT" | jq -cRs \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg event "$EVENT" \
    --rawfile final "$META.final" \
    --rawfile claude_tool "$META.claude_tool" \
    --rawfile command "$META.command" \
    --rawfile target "$META.target" \
    --rawfile gate "$META.gate" \
    --arg start "$START_MS" --arg end "$end_ms" '
    def nz: (rtrimstr("\n")) | if . == "" then null else . end;
    (. | try fromjson catch null) as $in
    | ($final | fromjson) as $out
    | { ts: $ts,
        event: $event,
        agy_tool: (if ($in | type) == "object" then ($in.toolCall.name? // null) else null end),
        claude_tool: ($claude_tool | nz),
        conversation_id: (if ($in | type) == "object" then ($in.conversationId // null) else null end),
        decision: (if $event == "SessionStart" then "inject" else $out.decision end),
        gate: (if $out.decision == "deny" then ($gate | nz) else null end),
        reason: (if $out.decision == "deny" then ($out.reason | .[0:300]) else null end),
        command: ($command | nz),
        target: ($target | nz),
        # Key names only, never values: they show the shape of a denied
        # tool, for example an unrouted edit_file.
        arg_keys: (if $out.decision == "deny" and ($in | type) == "object" then
                     ($in.toolCall.args? // null)
                     | (if type == "string" then (try fromjson catch null) else . end)
                     | if type == "object" then (keys | .[0:50] | map(.[0:64])) else null end
                   else null end),
        duration_ms: ((($end | tonumber) - ($start | tonumber)) // null) }
    | if $event == "SessionStart" then . + {inject_steps: ($out.injectSteps | length)} else . end
  ' >> "$AGY_LOG"
}

if [ -n "$AGY_LOG" ]; then
  ( write_log ) > /dev/null 2>&1 || true
fi
rm -f "$META".* 2>/dev/null || true
exit 0
