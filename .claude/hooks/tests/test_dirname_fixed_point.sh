#!/bin/bash
# Fixed-point dirname results must not hang hook path walks.
set -eu
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/existing"
export FIXED_DIR="$WORK/existing"
export REAL_DIRNAME
REAL_DIRNAME=$(command -v dirname)
cat > "$WORK/bin/dirname" <<'SHIM'
#!/bin/bash
case "$1" in
  /\\*|C:|"$FIXED_DIR"|"$FIXED_DIR-link") printf '%s\n' "$1" ;;
  *) exec "$REAL_DIRNAME" "$@" ;;
esac
SHIM
chmod +x "$WORK/bin/dirname"
export PATH="$WORK/bin:$PATH"
# Cap each child at 20 seconds without requiring a timeout utility.
run_bounded() {
  local pid timer rc
  "$@" >"$WORK/output" 2>&1 &
  pid=$!
  (
    sleep 20
    if kill -0 "$pid" 2>/dev/null; then
      touch "$WORK/timed-out"
      kill "$pid" 2>/dev/null || true
    fi
  ) &
  timer=$!
  rc=0
  wait "$pid" || rc=$?
  kill "$timer" 2>/dev/null || true
  wait "$timer" 2>/dev/null || true
  if [ -f "$WORK/timed-out" ]; then
    echo 'FAIL: dirname walk exceeded 20 seconds'
    return 1
  fi
  [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]
}
command_text="grep -n x notes.md | sed 's/<br>/\\n    /g'"
jq -n --arg command "$command_text" \
  '{tool_name:"Bash",tool_input:{command:$command}}' > "$WORK/input"
run_bounded bash "$ROOT/.claude/hooks/require-active-ticket.sh" < "$WORK/input"
# The symlink walk must inspect an existing fixed point before stopping.
sed -n '/^_ratc_path_has_symlink_component() {/,/^}/p' \
  "$ROOT/.claude/hooks/require-active-ticket.sh" > "$WORK/functions"
ln -s "$WORK/existing" "$FIXED_DIR-link"
cat > "$WORK/symlinks" <<'SYMLINKS'
source "$1"
_ratc_path_has_symlink_component "$FIXED_DIR" && exit 1
_ratc_path_has_symlink_component "$FIXED_DIR-link" || exit 1
SYMLINKS
run_bounded bash "$WORK/symlinks" "$WORK/functions" "$WORK"
# Exercise a second independent climb directly, with its not-found verdict.
cat > "$WORK/second" <<'SECOND'
source "$1/.claude/hooks/_lib-ticket-path-exemptions.sh"
result=$(_ticket_path_existing_dir 'C:') || true
[ -z "$result" ] || exit 1
[ "$(_ticket_path_existing_dir "$FIXED_DIR")" = "$FIXED_DIR" ] || exit 1
SECOND
run_bounded bash "$WORK/second" "$ROOT"
echo 'PASS: dirname fixed points terminate'
