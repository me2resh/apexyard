#!/bin/bash
# CLASS: CONTROL — limits edit-channel writes by a review-class agent to the
# review-body folder (me2resh/apexyard#1840, AgDR-0266).
#
# WHY THIS EXISTS
# A review agent posts its review with tracker_review_submit, which reads the
# review body from a file. A Bash heredoc cannot write that file: the review
# body quotes push, commit, alias and redirect text as evidence, and the Bash
# gates read that quoted text as commands (#1840). The review agents now have
# the Write tool. This hook limits that tool to one sanctioned folder:
#
#   <ops-root>/.claude/session/reviews/bodies/
#
# The folder is under .claude/session/, which git ignores. The merge gates do
# not read it. review_body_path in _lib-review-markers.sh builds a file name
# in it.
#
# WHO IS LIMITED
# A caller that review_caller_class reports as `reviewer`: a typed review
# agent (code-reviewer, security-reviewer, solution-architect, or a configured
# extra review type), or an untyped sub-agent while this session has an
# active-reviewer marker. The lock does not need a marker for a typed review
# agent. The orchestrator and build agents are never limited by this hook.
#
# WHAT IS BLOCKED
# Every Edit, Write or MultiEdit target of a review agent that is not a file
# under the body folder: repository files, hook files, settings files, review
# markers and any other path. A relative path, a `.` or `..` segment, and a
# symbolic link at the target are also blocked. A review agent still writes
# its approval marker in Bash through review_write_rex_approved, as before.
#
# The hook reads the structured file_path field. It does not parse shell
# text. It is a guardrail against honest mistakes (AgDR-0115). It fails
# closed: when it cannot tell the caller or the target, it blocks a payload
# that names a review agent.

set -u

INPUT=$(cat)
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)

# Built-in review types. This list must equal REVIEW_AGENT_SLUGS in
# _lib-review-markers.sh. It is used only when that library is missing.
LRW_BUILTIN_RE='code-reviewer|security-reviewer|solution-architect'

lrw_block() {
  echo "BLOCKED: $1" >&2
  exit 2
}

# A payload that is not a JSON object: block it only when it names a review
# agent, so that a broken payload from another caller is not a false block.
if ! command -v jq >/dev/null 2>&1 || ! printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  if printf '%s' "$INPUT" | grep -qE "\"agent_type\"[[:space:]]*:[[:space:]]*\"(${LRW_BUILTIN_RE})\""; then
    lrw_block "cannot parse the edit payload of a review-class agent."
  fi
  exit 0
fi

if [ -f "$HOOK_DIR/_lib-review-markers.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-review-markers.sh"
fi
if [ -f "$HOOK_DIR/_lib-path-resolve.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-path-resolve.sh"
fi

# The hook copy that runs is the ops root the wrapper resolved (pin first).
HOOK_ROOT=$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd -P) || HOOK_ROOT=""

CALLER_CLASS=main
if command -v review_caller_class >/dev/null 2>&1; then
  CALLER_CLASS=$(review_caller_class "$INPUT" "$HOOK_ROOT")
else
  _lrw_type=$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || true)
  if printf '%s' "$_lrw_type" | grep -qxE "$LRW_BUILTIN_RE"; then
    CALLER_CLASS=reviewer
  fi
fi
case "$CALLER_CLASS" in
  reviewer|unparsable) ;;
  *) exit 0 ;;
esac

# Physical path. The final component is not followed, so a link there is
# checked separately below.
lrw_real_path() {
  if command -v _resolve_real_path >/dev/null 2>&1; then
    _resolve_real_path "$1"
    return
  fi
  local dir tail=""
  dir="$1"
  while [ -n "$dir" ] && [ "$dir" != / ] && [ ! -e "$dir" ]; do
    if [ -z "$tail" ]; then tail=$(basename "$dir"); else tail=$(basename "$dir")/$tail; fi
    dir=$(dirname "$dir")
  done
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 0
  if [ -z "$tail" ]; then printf '%s' "$dir"
  elif [ "$dir" = / ]; then printf '/%s' "$tail"
  else printf '%s/%s' "$dir" "$tail"
  fi
}

# Candidate ops roots: the root of this hook copy, and the ops root that
# _lib-ops-root.sh resolves from the working directory of the call.
lrw_roots() {
  local cwd ops=""
  [ -n "$HOOK_ROOT" ] && printf '%s\n' "$HOOK_ROOT"
  cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
  [ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"
  if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
    ops=$(
      # shellcheck source=/dev/null
      . "$HOOK_DIR/_lib-ops-root.sh" 2>/dev/null || exit 0
      command -v resolve_ops_root >/dev/null 2>&1 || exit 0
      resolve_ops_root "$cwd" 2>/dev/null
    )
  fi
  [ -n "$ops" ] && (cd "$ops" 2>/dev/null && pwd -P)
  return 0
}

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)
BODY_HINT="<ops-root>/.claude/session/reviews/bodies/"
[ -n "$HOOK_ROOT" ] && BODY_HINT="$HOOK_ROOT/.claude/session/reviews/bodies/"
DENY="a review-class agent may use ${TOOL:-this tool} only to write its review body under $BODY_HINT. Do not change repository files, hooks, settings or review markers. Report findings to the orchestrator."

[ -n "$TARGET" ] || lrw_block "the edit has no target path. $DENY"
case "$TARGET" in
  /*) ;;
  *) lrw_block "use an absolute path. $DENY" ;;
esac
case "/$TARGET/" in
  */../*|*/./*) lrw_block "the path has a . or .. segment. $DENY" ;;
esac

RESOLVED=$(lrw_real_path "$TARGET")
[ -n "$RESOLVED" ] || lrw_block "cannot resolve the target path. $DENY"
if [ -L "$TARGET" ] || [ -L "$RESOLVED" ]; then
  lrw_block "the target is a symbolic link. $DENY"
fi

while IFS= read -r root; do
  [ -n "$root" ] || continue
  case "$RESOLVED" in
    "$root/.claude/session/reviews/bodies/"?*) exit 0 ;;
  esac
done < <(lrw_roots)

lrw_block "$DENY"
