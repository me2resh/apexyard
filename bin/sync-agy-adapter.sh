#!/usr/bin/env bash
# Generate .agents/hooks.json for the Google Antigravity CLI (agy).
# Decision record: AgDR-0320.
#
# .claude/settings.json stays the source of truth. The generated file holds
# one catch-all agy PreToolUse entry (matcher ".*") and one SessionStart
# entry. Each entry runs harness-adapters/agy/agy-hook.sh. The wrapper
# applies the tool policy: it gates the write and run tools, prints ask for
# a short read-only list, and denies every other tool. The wrapper reads the gate list from
# .claude/settings.json at run time. This generator derives the hook
# timeouts, and it fails when a PreToolUse matcher group cannot reach agy.
#
# One catch-all entry, not one entry for each tool: if agy runs every
# matching entry, a catch-all next to per-tool entries would run the gates
# twice for a gated tool.
#
# The generator writes only .agents/hooks.json. It never touches
# .agents/skills/, which bin/sync-codex-adapter.sh owns.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CHECK=0

usage() {
  cat <<'USAGE'
Usage: bin/sync-agy-adapter.sh [--check] [--root <path>]

Generate .agents/hooks.json for agy from .claude/settings.json. Every entry
runs harness-adapters/agy/agy-hook.sh, which runs the unmodified gates.

Options:
  --check      Do not write. Exit non-zero when .agents/hooks.json is missing
               or differs from the generated output.
  --root PATH  Fork root to use instead of this script's parent.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --root)
      [ "$#" -ge 2 ] || { echo "ERROR: --root requires a path" >&2; exit 2; }
      ROOT="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

ROOT="$(cd "$ROOT" && pwd -P)"
SETTINGS="$ROOT/.claude/settings.json"
WRAPPER="$ROOT/harness-adapters/agy/agy-hook.sh"
OUT_DIR="$ROOT/.agents"
OUT="$OUT_DIR/hooks.json"
HOOK_NAME="apexyard"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
[ -f "$SETTINGS" ] || { echo "ERROR: $SETTINGS not found" >&2; exit 1; }
[ -f "$WRAPPER" ] || { echo "ERROR: $WRAPPER not found" >&2; exit 1; }
jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 || { echo "ERROR: $SETTINGS is not valid JSON" >&2; exit 1; }

for path in "$OUT_DIR" "$OUT"; do
  if [ -L "$path" ]; then
    echo "ERROR: refusing agy adapter output through symlink: $path" >&2
    exit 1
  fi
done

# agy tool name -> Claude Code tool name. Keep this table in step with the
# mapping in harness-adapters/agy/agy-hook.sh.
AGY_TOOLS=(run_command write_to_file write_file replace_file_content multi_replace_file_content edit_file)
CLAUDE_TOOLS=(Bash Write Write Edit MultiEdit Edit)
# Claude Code tools that agy has no equivalent for. A PreToolUse group that
# names only these tools is skipped with a note. Any other group that
# reaches no routed tool stops the generator.
NO_AGY_EQUIVALENT=(NotebookEdit)

wrapper_gated=$(sed -n 's/^GATED_TOOLS="\(.*\)"$/\1/p' "$WRAPPER")
if [ "$wrapper_gated" != "${AGY_TOOLS[*]}" ]; then
  echo "ERROR: GATED_TOOLS in $WRAPPER ($wrapper_gated) does not match AGY_TOOLS in this script (${AGY_TOOLS[*]})." >&2
  exit 1
fi

routed_json=$(printf '%s\n' "${CLAUDE_TOOLS[@]}" | jq -R . | jq -sc .)
skipped_json=$(printf '%s\n' "${NO_AGY_EQUIVALENT[@]}" | jq -R . | jq -sc .)

# Fail loud on a silent gate hole: every PreToolUse matcher group must reach
# a routed tool, or name only tools that agy lacks.
unroutable=$(jq -r --argjson routed "$routed_json" --argjson skipped "$skipped_json" '
  def hits($m; $names): [ $names[] | select($m == "" or $m == "*" or test("^(" + $m + ")$")) ];
  (.hooks.PreToolUse // [])[]
  | (.matcher // "") as $m
  | select((hits($m; $routed) | length) == 0 and (hits($m; $skipped) | length) == 0)
  | $m
' "$SETTINGS")
if [ -n "$unroutable" ]; then
  echo "ERROR: these .claude/settings.json PreToolUse matcher groups reach no agy tool:" >&2
  printf '  %s\n' "$unroutable" >&2
  echo "ERROR: add the agy tool mapping to harness-adapters/agy/agy-hook.sh and this script, or list the tool in NO_AGY_EQUIVALENT." >&2
  exit 1
fi

# The wrapper runs only command handlers and Tool(glob) predicates. Fail at
# generation time instead of at the first agy tool call.
bad_handlers=$(jq -r --argjson routed "$routed_json" '
  def hits($m; $names): [ $names[] | select($m == "" or $m == "*" or test("^(" + $m + ")$")) ];
  ( ((.hooks.PreToolUse // [])[] | select((hits(.matcher // ""; $routed) | length) > 0))
    , (.hooks.SessionStart // [])[] )
  | (.hooks // [])[]
  | select(((.type // "command") != "command")
           or ((.command // "") == "")
           or (has("if") and ((.if | tostring) | test("^[^()]+\\(.*\\)$") | not)))
  | tojson
' "$SETTINGS")
if [ -n "$bad_handlers" ]; then
  echo "ERROR: the agy wrapper cannot run these handlers (it needs type command, a command, and an if of the form Tool(glob)):" >&2
  printf '  %s\n' "$bad_handlers" >&2
  exit 1
fi

budget() { bash "$WRAPPER" --budget "$@"; }

# The catch-all entry must outlast the slowest gated tool. A tool with no
# gates still needs the wrapper, so the floor is the agy default.
MIN_PRETOOLUSE_TIMEOUT=30

generate() {
  local claude secs max_secs="$MIN_PRETOOLUSE_TIMEOUT" session_secs command_pre command_session
  command_pre="bash $(printf '%s' "$WRAPPER" | jq -Rr @sh) PreToolUse"
  command_session="bash $(printf '%s' "$WRAPPER" | jq -Rr @sh) SessionStart"
  for claude in "${CLAUDE_TOOLS[@]}"; do
    secs=$(budget PreToolUse "$claude")
    case "$secs" in ''|*[!0-9]*) echo "ERROR: cannot compute the hook budget for $claude" >&2; return 1 ;; esac
    [ "$secs" -gt "$max_secs" ] && max_secs="$secs"
  done
  session_secs=$(budget SessionStart)
  case "$session_secs" in ''|*[!0-9]*) echo "ERROR: cannot compute the SessionStart hook budget" >&2; return 1 ;; esac
  jq -n --arg name "$HOOK_NAME" --arg cp "$command_pre" --argjson tp "$max_secs" \
    --arg cs "$command_session" --argjson ts "$session_secs" '
    { ($name): (
        {PreToolUse: [{matcher: ".*", hooks: [{type: "command", command: $cp, timeout: $tp}]}]}
        + (if $ts > 0 then {SessionStart: [{type: "command", command: $cs, timeout: $ts}]} else {} end)
      ) }'
}

TMP_OUT=$(mktemp "${TMPDIR:-/tmp}/agy-hooks.XXXXXX")
trap 'rm -f "$TMP_OUT"' EXIT
generate > "$TMP_OUT"

if [ "$CHECK" = 1 ]; then
  if [ ! -f "$OUT" ]; then
    echo "DRIFT: .agents/hooks.json is missing; run bin/sync-agy-adapter.sh" >&2
    exit 1
  fi
  if ! diff -q "$TMP_OUT" "$OUT" >/dev/null 2>&1; then
    echo "DRIFT: .agents/hooks.json differs from the generated output; run bin/sync-agy-adapter.sh" >&2
    diff "$TMP_OUT" "$OUT" >&2 || true
    exit 1
  fi
  exit 0
fi

# Do not overwrite an agy hooks file that this generator does not own.
if [ -e "$OUT" ] && ! jq -e --arg name "$HOOK_NAME" 'type == "object" and keys == [$name]' "$OUT" >/dev/null 2>&1; then
  echo "ERROR: $OUT exists and holds hooks that bin/sync-agy-adapter.sh did not generate." >&2
  echo "ERROR: rename or remove that file, then run this script again." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
cp "$TMP_OUT" "$OUT.tmp.$$"
mv -f "$OUT.tmp.$$" "$OUT"

not_routed=$(jq -r '.hooks | to_entries[] | select(.key != "PreToolUse" and .key != "SessionStart")
  | "\(.key) (\([.value[].hooks[]] | length) handler(s))"' "$SETTINGS")
echo "Generated agy adapter from .claude/settings.json:"
echo "  .agents/hooks.json"
if [ -n "$not_routed" ]; then
  echo "Not routed to agy (advisory under agy, see docs/harnesses/agy.md):"
  printf '  %s\n' "$not_routed"
fi
