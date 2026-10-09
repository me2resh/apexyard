#!/bin/bash
# inject-project-context.sh — PostToolUse hook. On the first Read/Glob/
# Grep/Edit/Write/MultiEdit that touches a registered managed project's
# workspace, injects that project's own CLAUDE.md, rules, skills and
# agents as additionalContext (me2resh/apexyard#1423).
#
# WHY: a managed project checkout can live outside the ops fork (split
# portfolio, or any layout where workspace/<project> isn't nested under
# this repo). Claude Code loads the session cwd's CLAUDE.md (and its
# parents); a project checked out elsewhere never gets its conventions
# loaded, so build agents write code Rex then has to catch, and Rex
# reviews against framework rules only.
# This hook reads the project's context LIVE from its own repo on every
# injection; nothing is copied or snapshotted, so
# it can't go stale the way projects/<name>/ docs can.
#
# FAIL-OPEN CONTRACT (mandatory — this is a PostToolUse hook, not a gate):
#   - exit 0 on every path, always. Never exit 2.
#   - jq / registry / any file missing → silent exit 0, no stderr noise.
#   - settings.json pins "timeout": 3 on this hook entry; Claude Code
#     discards the output on a timeout and the tool call is unaffected
#     either way (spike-verified: a hung hook body under `timeout: 3`
#     never delayed the Read it was attached to).
#   - The worktree fallback reads a `.git` file and starts no git process.
#
# DEDUPE: one injection per (session_id, agent_id-or-"main", project) —
# a marker file created exclusively (pending). After the context is
# emitted the claim becomes done (the file then holds `done`). A pending marker older than ~5 s (past the hook timeout) is
# treated as stale and reclaimed, so a SIGKILL mid-build cannot suppress
# later injections forever. A subagent has its own agent_id
# (spike-confirmed) and so gets its own injection.
#
# SCOPE: matched on Read|Glob|Grep|Edit|Write|MultiEdit in settings.json.
# Bash writes (`cat > workspace/x/foo.ts`) are NOT covered — see the
# ponytail note at the bottom.

[ "${APEXYARD_PROJCTX_DISABLE:-}" = 1 ] && exit 0

trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

# One jq call, NUL-separated so a newline inside a field cannot shift the rest.
{ IFS= read -r -d '' FILE_PATH; IFS= read -r -d '' CWD; IFS= read -r -d '' SESSION_ID; IFS= read -r -d '' AGENT_ID; } < <(printf '%s' "$INPUT" | jq -j '((.tool_input.file_path // .tool_input.path // ""), (.cwd // ""), (.session_id // ""), (.agent_id // "")) | tostring | gsub("\u0000"; "") + "\u0000"' 2>/dev/null)
[ -n "$FILE_PATH" ] || exit 0

case "$FILE_PATH" in
  /*) ABS_PATH="$FILE_PATH" ;;
  *)
    [ -n "$CWD" ] || exit 0
    ABS_PATH="$CWD/$FILE_PATH"
    ;;
esac

HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || exit 0

for lib in _lib-read-config.sh _lib-ops-root.sh _lib-portfolio-paths.sh _lib-multi-repo-trace.sh _lib-project-context.sh; do
  [ -f "$HOOK_DIR/$lib" ] || exit 0
  # shellcheck source=/dev/null
  . "$HOOK_DIR/$lib" 2>/dev/null || exit 0
done

# Collapse ".." and symlinks so "<ws>/../other/f" can't match <ws>.
ABS_PATH=$(_portfolio_canonicalize "$ABS_PATH" 2>/dev/null) || exit 0
[ -n "$ABS_PATH" ] || exit 0

[ -n "$SESSION_ID" ] || exit 0
export PROJCTX_SESSION_ID="$SESSION_ID"

PROJECT_LINE=$(projctx_resolve "$ABS_PATH" 2>/dev/null) || exit 0
[ -n "$PROJECT_LINE" ] || exit 0

PROJECT_NAME="${PROJECT_LINE%%$'\t'*}"
PROJECT_REST="${PROJECT_LINE#*$'\t'}"
PROJECT_WS="${PROJECT_REST%%$'\t'*}"
PROJECT_WT=""
case "$PROJECT_REST" in *$'\t'*) PROJECT_WT="${PROJECT_REST#*$'\t'}" ;; esac
[ -n "$PROJECT_NAME" ] && [ -n "$PROJECT_WS" ] || exit 0

# Already inside the project's own tree → Claude Code loads its CLAUDE.md
# natively; injecting again would duplicate it in context for free.
if [ -n "$CWD" ] && portfolio_path_under "$CWD" "$PROJECT_WS" 2>/dev/null; then
  exit 0
fi
[ -n "$AGENT_ID" ] || AGENT_ID="main"

MARKER_DIR=$(projctx_state_dir) || exit 0
SESS_KEY=$(printf '%s' "$SESSION_ID" | cksum 2>/dev/null | awk '{print $1}')
MARKER_KEY=$(printf '%s|%s' "$AGENT_ID" "$PROJECT_NAME" | cksum 2>/dev/null | awk '{print $1}')
[ -n "$SESS_KEY" ] && [ -n "$MARKER_KEY" ] || exit 0
MARKER="$MARKER_DIR/injected-$SESS_KEY-$MARKER_KEY"
# Pending markers older than this many seconds are stale (hook timeout is 3 s).
PROJCTX_PENDING_STALE_SECS="${PROJCTX_PENDING_STALE_SECS:-5}"
case "$PROJCTX_PENDING_STALE_SECS" in ''|0*|???????*|*[!0123456789]*) PROJCTX_PENDING_STALE_SECS=5 ;; esac

# Age of a path in seconds (portable macOS/BSD vs GNU stat). Empty on failure.
_projctx_path_age_secs() {
  local m now
  m=$(stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null) || return 1
  now=$(date +%s 2>/dev/null) || return 1
  printf '%s' $((now - m))
}

# Create file $1 holding $2, failing when it already exists. The noclobber
# redirect is an O_CREAT|O_EXCL open, which stays exclusive on hosts whose
# mkdir is not.
_projctx_create_excl() {
  ( set -C; printf '%s\n' "$2" > "$1" ) 2>/dev/null
}

# True when regular file $1 is older than the stale threshold.
_projctx_is_stale() {
  local age
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  age=$(_projctx_path_age_secs "$1") || return 1
  [ "$age" -ge "$PROJCTX_PENDING_STALE_SECS" ]
}

# Remove the reclaim lock only when it still holds this caller's token.
_projctx_release_lock() {
  local held=""
  IFS= read -r held < "$MARKER.reclaim" 2>/dev/null
  [ "$held" = "$PROJCTX_LOCK_TOKEN" ] && rm -f "$MARKER.reclaim" 2>/dev/null
  return 0
}

# Try to claim MARKER as a pending file. On conflict: done → give up; fresh
# pending → give up (a parallel caller owns it); stale pending → reclaim
# under a short lock file.
_projctx_claim_marker() {
  local line="" lock old claimed=1
  _projctx_create_excl "$MARKER" pending && return 0
  [ -f "$MARKER" ] && [ ! -L "$MARKER" ] || return 1
  IFS= read -r line < "$MARKER" 2>/dev/null
  [ "$line" = 'done' ] && return 1
  _projctx_is_stale "$MARKER" || return 1

  PROJCTX_LOCK_TOKEN="$$.$RANDOM"
  lock="$MARKER.reclaim"
  if ! _projctx_create_excl "$lock" "$PROJCTX_LOCK_TOKEN"; then
    # A stale lock belongs to a killed caller. Move it aside under a unique
    # name so only one caller handles it. A moved lock that proves fresh
    # has a live owner: drop it and give up.
    _projctx_is_stale "$lock" || return 1
    old="$lock.stale.$$"
    mv "$lock" "$old" 2>/dev/null || return 1
    if ! _projctx_is_stale "$old"; then
      rm -f "$old" 2>/dev/null
      return 1
    fi
    rm -f "$old" 2>/dev/null
    _projctx_create_excl "$lock" "$PROJCTX_LOCK_TOKEN" || return 1
  fi
  trap '_projctx_release_lock; exit 0' TERM INT HUP
  # Recheck under the lock: a prior caller may have replaced the marker.
  line=""
  IFS= read -r line < "$MARKER" 2>/dev/null
  if [ "$line" != 'done' ] && _projctx_is_stale "$MARKER"; then
    old="$MARKER.stale.$$"
    # Only the caller whose move succeeds may create the new claim.
    if mv "$MARKER" "$old" 2>/dev/null; then
      _projctx_create_excl "$MARKER" pending && claimed=0
      rm -f "$old" 2>/dev/null
    fi
  fi
  _projctx_release_lock
  trap - TERM INT HUP
  return "$claimed"
}

# Claim pending BEFORE building the text. Convert to done only after emit.
_projctx_claim_marker || exit 0
# Release a still-pending claim on TERM/INT/HUP (SIGKILL cannot be trapped;
# stale recovery above covers that path).
trap 'rm -f "$MARKER" 2>/dev/null; exit 0' TERM INT HUP

if ! CONTEXT=$(projctx_emit "$PROJECT_NAME" "$PROJECT_WS" "$PROJECT_WT" 2>/dev/null) || [ -z "$CONTEXT" ]; then
  rm -f "$MARKER" 2>/dev/null
  exit 0
fi

OUTPUT=$(jq -n --arg t "$CONTEXT" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $t
  }
}' 2>/dev/null) || { rm -f "$MARKER" 2>/dev/null; exit 0; }

# Pending → done. A lost write still leaves a directory that becomes stale.
printf 'done\n' > "$MARKER" 2>/dev/null || true
trap - TERM INT HUP

printf '%s\n' "$OUTPUT"
exit 0
# ponytail: two known ceilings, not bugs.
#   1. Compaction can drop this turn's additionalContext from the model's
#      working context, and the done marker stays written — the project
#      never gets re-injected in that session. Upgrade: clear
#      ${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/projctx/injected-* markers from a
#      SessionStart(compact) hook.
#   2. Bash tool calls are not matched (settings.json matcher stops at
#      Read|Glob|Grep|Edit|Write|MultiEdit), so `cat > workspace/x/f.ts`
#      injects nothing. Upgrade: key resolution on `.cwd` alone (no
#      tool_input path needed) so a Bash matcher entry can reuse
#      projctx_resolve unchanged.
