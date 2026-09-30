#!/bin/bash
# CLASS: CONTROL — blocks repository-mutating git commands while a sanctioned
# review-class agent is active (me2resh/apexyard#1233, AgDR-0145). Worktree
# creation remains available for a path outside the ops fork and managed
# workspace so a reviewer can provision an isolated checkout after the
# active-reviewer marker is set (AgDR-0147, AgDR-0205 / #1509).
#
# The active-reviewer marker is written by the review skill immediately before
# Rex, Hakim, or Tariq is spawned. It is a narrow session signal: when present,
# review-class work is in flight, so Bash git mutations must be rejected before
# they can alter the reviewed branch or working tree. Read-only git commands
# remain available for evidence gathering and review submission.
#
# SESSION-SCOPED marker (me2resh/apexyard#1376): the marker path is keyed on
# CLAUDE_CODE_SESSION_ID via active_reviewer_marker_path (_lib-review-markers.sh),
# so this hook only ever sees the marker THIS session's own review wrote. A
# review running in a different session (a different worktree, a different
# terminal, on the same ops fork) can no longer block — or, on the overwrite
# race the fixed shared path used to have, fail to block — this session.

set -u

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
if [ -f "$HOOK_DIR/_lib-review-markers.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-review-markers.sh"
fi
if [ -f "$HOOK_DIR/_lib-path-resolve.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-path-resolve.sh"
fi

# True when PATH is exactly BASE or a file under BASE.
_brrm_path_under() {
  local path="$1" base="$2"
  [ -n "$path" ] && [ -n "$base" ] || return 1
  case "$path" in
    "$base"|"$base"/*) return 0 ;;
  esac
  return 1
}

# First non-option path argument of one `git worktree add` segment. Empty on
# failure. Only fully spelled options from a fixed list are accepted. Git
# also reads grouped short options (-fb) and long-option prefixes (--reas),
# which would make this parser read the wrong word, so any other option
# fails the check (review of PR #1518).
_brrm_worktree_add_path_arg() {
  local seg="$1" rest skip=0
  rest=$(printf '%s' "$seg" | sed -E 's/^.*[[:space:]]worktree[[:space:]]+add([[:space:]]+|$)//')
  # The strict segment shape below allows no quotes or globbing characters.
  # shellcheck disable=SC2086
  set -f; set -- $rest; set +f
  while [ "$#" -gt 0 ]; do
    if [ "$skip" -eq 1 ]; then
      # An option value that looks like an option is ambiguous: fail.
      case "$1" in -*) return 1 ;; esac
      skip=0; shift; continue
    fi
    case "$1" in
      -b|-B|--reason) skip=1 ;;
      -f|--force|--detach|--checkout|--no-checkout|--lock|-q|--quiet|--track|--no-track|--guess-remote|--no-guess-remote|--orphan) ;;
      -*) return 1 ;;
      *) printf '%s' "$1"; return 0 ;;
    esac
    shift
  done
  return 1
}

# Physical path for ABS, whose tail may not exist yet. Empty on failure.
_brrm_real_path() {
  local abs="$1" dir tail="" parent
  if command -v _resolve_real_path >/dev/null 2>&1; then
    _resolve_real_path "$abs"
    return
  fi
  dir="$abs"
  while [ -n "$dir" ] && [ "$dir" != / ] && [ ! -d "$dir" ]; do
    if [ -z "$tail" ]; then tail=$(basename "$dir"); else tail=$(basename "$dir")/$tail; fi
    dir=$(dirname "$dir")
  done
  parent=$(cd "$dir" 2>/dev/null && pwd -P) || return 0
  if [ "$parent" = / ]; then printf '/%s' "$tail"; else printf '%s/%s' "$parent" "${tail:+$tail}"; fi
}

# Governed trees a review worktree must not land in: the ops fork, its
# workspace/, and the configured portfolio workspace (split-portfolio mode).
_brrm_governed_roots() {
  local root="$1" ws
  (cd "$root" 2>/dev/null && pwd -P) || printf '%s\n' "$root"
  printf '%s\n' "$root/workspace"
  ws=$(
    cd "$root" 2>/dev/null || exit 0
    # shellcheck source=/dev/null
    . "$root/.claude/hooks/_lib-read-config.sh" 2>/dev/null || exit 0
    # shellcheck source=/dev/null
    . "$root/.claude/hooks/_lib-portfolio-paths.sh" 2>/dev/null || exit 0
    portfolio_workspace_dir 2>/dev/null
  )
  [ -n "$ws" ] && printf '%s\n' "$ws"
}

# Check one `git worktree add` segment. BASE is the directory a relative path
# resolves against (empty when unknown). Return 0 when the new path is outside
# every governed tree; print the reason and return 2 otherwise.
_brrm_check_worktree_add_segment() {
  local seg="$1" root="$2" base="$3" path cdir abs resolved gov gov_real
  path=$(_brrm_worktree_add_path_arg "$seg") || path=""
  if [ -z "$path" ]; then
    echo "BLOCKED: review-class agent cannot alter worktrees during an active review (no literal worktree path found)." >&2
    return 2
  fi
  cdir=$(printf '%s' "$seg" | sed -nE 's/^[[:space:]]*git[[:space:]]+-C[[:space:]]+([^[:space:]]+)[[:space:]].*/\1/p')
  if [ -n "$cdir" ]; then
    case "$cdir" in /*) base="$cdir" ;; *) [ -n "$base" ] && base="$base/$cdir" ;; esac
  fi
  case "$path" in
    /*) abs="$path" ;;
    *)
      if [ -z "$base" ]; then
        echo "BLOCKED: review-class agent cannot resolve this worktree path during an active review. Use an absolute path." >&2
        return 2
      fi
      abs="$base/$path"
      ;;
  esac
  resolved=$(_brrm_real_path "$abs")
  if [ -z "$resolved" ]; then
    echo "BLOCKED: review-class agent cannot resolve this worktree path during an active review." >&2
    return 2
  fi
  while IFS= read -r gov; do
    [ -n "$gov" ] || continue
    gov_real=$(_brrm_real_path "$gov")
    for g in "$gov" "$gov_real"; do
      [ -n "$g" ] || continue
      if _brrm_path_under "$resolved" "$g" || { case "$abs" in *..*) false ;; *) _brrm_path_under "$abs" "$g" ;; esac; }; then
        echo "BLOCKED: review-class agent cannot create a worktree inside the ops fork or a managed workspace during an active review." >&2
        return 2
      fi
    done
  done < <(_brrm_governed_roots "$root")
  return 0
}

# Validate every `git worktree add` segment in CMD. Print CMD with each of
# those segments replaced by `true`, so the checks after this still read every
# other segment. Return 2 after a message on any doubt (me2resh/apexyard#1509,
# AgDR-0205). A segment must be a literal, single-line `git [-C dir] worktree
# add ...` with no quotes, expansions, environment prefix or other git global
# option: `-c core.hooksPath=...` or a GIT_CONFIG_* prefix can run code on
# checkout.
_brrm_scope_worktree_adds() {
  local cmd="$1" root="$2" rest seg sep out="" base="$PWD" target
  local split_re='^([^;&|]*)(&&|\|\||;|\||&)(.*)$'
  local wt_re='(^|[[:space:]])worktree[[:space:]]+add([[:space:]]|$)'
  local shape_re='^[[:space:]]*git([[:space:]]+-C[[:space:]]+[A-Za-z0-9_./@:+-]+)?[[:space:]]+worktree[[:space:]]+add([[:space:]]+[A-Za-z0-9_./@:^+=-]+)*[[:space:]]*$'
  local cd_re='^[[:space:]]*cd[[:space:]]+([A-Za-z0-9_./@:+-]+)[[:space:]]*$'
  case "$cmd" in
    *$'\n'*)
      echo "BLOCKED: review-class agent must run git worktree add as a single-line command during an active review." >&2
      return 2
      ;;
  esac
  rest="$cmd"
  while :; do
    if [[ $rest =~ $split_re ]]; then
      seg=${BASH_REMATCH[1]} sep=${BASH_REMATCH[2]} rest=${BASH_REMATCH[3]}
    else
      seg=$rest sep="" rest=""
    fi
    if [[ $seg =~ $wt_re ]]; then
      if ! [[ $seg =~ $shape_re ]]; then
        echo "BLOCKED: review-class agent may run only a literal 'git [-C dir] worktree add <path> <commit>' during an active review." >&2
        return 2
      fi
      _brrm_check_worktree_add_segment "$seg" "$root" "$base" || return 2
      seg=" true "
    elif [[ $seg =~ $cd_re ]]; then
      target=${BASH_REMATCH[1]}
      # `cd -` returns to the previous directory, which this parser does not
      # track, so the base becomes unknown (review of PR #1518).
      case "$target" in -*) base="" ;; /*) base="$target" ;; *) [ -n "$base" ] && base="$base/$target" ;; esac
    elif [[ $seg =~ ^[[:space:]]*cd([[:space:]]|$) ]]; then
      base=""
    fi
    # Rebuild with ` ; ` between segments. The later checks recognise `;`
    # before git, but not a lone `&` (background), so keeping `&` would hide
    # the next segment from them (review of PR #1518).
    if [ -n "$sep" ]; then out="$out$seg ; "; else out="$out$seg"; break; fi
  done
  printf '%s' "$out"
}

# If the hook cannot parse the tool payload, do not invent a block when there
# is no active review. With an active marker, fail closed for payloads that
# visibly contain a git mutation.
ROOT="${APEXYARD_REVIEW_OPS_ROOT:-}"
if [ -z "$ROOT" ] || [ ! -d "$ROOT/.claude/session" ]; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  while [ -n "$ROOT" ] && [ "$ROOT" != / ]; do
    if [ -f "$ROOT/.apexyard-fork" ] || { [ -f "$ROOT/onboarding.yaml" ] && [ -f "$ROOT/apexyard.projects.yaml" ]; }; then
      break
    fi
    ROOT=$(dirname "$ROOT")
  done
fi

[ -n "$ROOT" ] || exit 0
if command -v active_reviewer_marker_path >/dev/null 2>&1; then
  ACTIVE=$(active_reviewer_marker_path "$ROOT")
else
  # Defensive fallback if the lib is missing — pre-#1376 fixed path, so a
  # broken install fails no worse than it did before this change.
  ACTIVE="$ROOT/.claude/session/active-reviewer"
fi

# ADVISORY ONLY (me2resh/apexyard#1400 security re-review, LOW 3): a session
# with an id resolves ACTIVE to the session-suffixed path and never falls
# back to the bare legacy path once that id exists (AgDR-0166). A caller that
# still writes the literal `.claude/session/active-reviewer` string — a
# prompt or doc that predates the #1376 fix, or a stale write left over from
# before an upgrade — arms no lock for this session: this hook silently
# never reads that file, so a reviewing session's own git mutations are not
# blocked, without any message saying why. This warning names that state on
# stderr. It does not gate on the legacy file — the session-scoped check
# above and below remains the only thing that blocks.
LEGACY_ACTIVE="$ROOT/.claude/session/active-reviewer"
SID="${CLAUDE_CODE_SESSION_ID:-}"

# Remove confirmed heredoc bodies before inspecting command text. Review prose
# often mentions git verbs; only the command portion should be classified.
if [ -f "$HOOK_DIR/_lib-strip-heredoc.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-strip-heredoc.sh"
  COMMAND=$(strip_heredoc_bodies "$COMMAND")
fi

# A git subcommand is mutating when it can change the index, worktree, refs, or
# remote. The command-position anchor avoids matching quoted review prose such
# as `echo 'git commit is forbidden'`. Options such as `git -C repo commit` are
# accepted by the middle token span.
MUTATING='add|commit|push|restore|reset|stash|clean|checkout|checkout-index|switch|mv|rm|rebase|cherry-pick|merge|tag|update-ref|fetch|apply|revert|am|bisect|replace|filter-branch|gc|init|repack|prune|fast-import|pull|read-tree|write-tree|commit-tree|update-index|hash-object|index-pack|pack-refs|mktag|mktree|clone|init-db|stage|subtree|replay'

# ADVISORY ONLY (me2resh/apexyard#1400, narrowed in #1408): when this session
# resolves a scoped marker path but only a legacy shared file exists on disk,
# mutations are not blocked. Name that fail-open state on stderr, but only when
# the Bash payload is a git mutation — read-only commands such as `ls` must
# stay silent (the legacy file is irrelevant to them).
if [ ! -f "$ACTIVE" ] && [ -n "$SID" ] && [ "$ACTIVE" != "$LEGACY_ACTIVE" ] && [ -f "$LEGACY_ACTIVE" ]; then
  _legacy_advise=0
  if [ -z "$COMMAND" ]; then
    if printf '%s' "$INPUT" | grep -qE '(^|[^[:alnum:]_-])git[[:space:]]+([^;&|]*[[:space:]])?(add|commit|push|restore|reset|stash|clean|checkout|switch|mv|rm|rebase|cherry-pick|merge|tag|branch)([[:space:];|&]|$)'; then
      _legacy_advise=1
    fi
  elif printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?(${MUTATING})([[:space:];|&]|$)"; then
    _legacy_advise=1
  fi
  if [ "$_legacy_advise" -eq 1 ]; then
    echo "ADVISORY: a legacy shared active-reviewer marker exists at $LEGACY_ACTIVE, but this session ($SID) reads only $ACTIVE. A writer that used the bare legacy path arms no mutation lock for this session. Resolve the marker path through active_reviewer_marker_path instead of the literal string." >&2
  fi
  exit 0
fi

[ -f "$ACTIVE" ] || exit 0

if [ -z "$COMMAND" ]; then
  if printf '%s' "$INPUT" | grep -qE '(^|[^[:alnum:]_-])git[[:space:]]+([^;&|]*[[:space:]])?(add|commit|push|restore|reset|stash|clean|checkout|switch|mv|rm|rebase|cherry-pick|merge|tag|branch)([[:space:];|&]|$)'; then
    echo "BLOCKED: review-class agent cannot mutate the repository while an active review is in flight; use read-only git commands and report findings." >&2
    exit 2
  fi
  exit 0
fi

# `git remote get-url` and `git remote -v` are read-only operations used to
# resolve the review host. Block only remote subcommands that change remotes.
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?remote[[:space:]]+(add|remove|set-url|rename|prune|update|set-branches|set-head)([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent is read-only while an active review is in flight. Do not mutate repository remotes; report the finding to the orchestrator." >&2
  exit 2
fi

# These commands have read-only subcommands that reviewers use for evidence;
# block their write-capable forms while preserving the read forms.
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?branch([[:space:]]|$)" && \
   ! printf '%s' "$COMMAND" | grep -qE "git[[:space:]]+branch([[:space:]]*$|[[:space:]]+(-a|--all|--show-current|--list|-l|-r|--remotes|-v|-vv|--verbose|--contains|--merged|--no-merged|--points-at|--format=|--sort=|--column|--color))"; then
  echo "BLOCKED: review-class agent cannot create or alter branches during an active review." >&2
  exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?config([[:space:]]|$)" && \
   ! printf '%s' "$COMMAND" | grep -qE "git([^;&|]*[[:space:]])config[[:space:]]+(-{1,2}(get|get-all|get-regexp|list|show-origin|show-scope|name-only|includes|null)([[:space:]]|$)|-l([[:space:]]|$))"; then
  echo "BLOCKED: review-class agent cannot change Git configuration during an active review." >&2
  exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?reflog([[:space:]]|$)([^;&|]*[[:space:]])?(expire|delete|drop)([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent cannot alter reflogs during an active review." >&2
  exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?notes([[:space:]]|$)([^;&|]*[[:space:]])?(add|append|copy|edit|merge|prune|remove|rewrite|strip)([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent cannot alter Git notes during an active review." >&2
  exit 2
fi
# `git worktree add` may provision an isolated checkout outside the ops fork
# and managed workspace (AgDR-0147, AgDR-0205 / #1509). The MUTATING list below
# would otherwise treat `worktree add` as `git add`, so this branch must handle
# every worktree-add form before that catch-all. Paths inside ROOT or
# ROOT/workspace stay blocked. Lock, move, prune, remove, repair, and unlock
# remain blocked because they alter existing worktree state.
if printf '%s' "$COMMAND" | grep -qE '(^|&&|\|\||;|\|)[[:space:]]*([[:alnum:]_]+=[^[:space:];|&]+[[:space:]]+)*git[[:space:]]+([^;&|]*[[:space:]])?worktree[[:space:]]+add([[:space:];|&]|$)'; then
  COMMAND=$(_brrm_scope_worktree_adds "$COMMAND" "$ROOT") || exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?worktree([[:space:]]|$)([^;&|]*[[:space:]])?(lock|move|prune|remove|repair|unlock)([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent cannot alter worktrees during an active review." >&2
  exit 2
fi

if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?submodule([[:space:]]|$)" && \
   ! printf '%s' "$COMMAND" | grep -qE "git([^;&|]*[[:space:]])submodule[[:space:]]+(status|summary)([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent cannot change submodules during an active review." >&2
  exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?sparse-checkout([[:space:]]|$)" && \
   ! printf '%s' "$COMMAND" | grep -qE "git([^;&|]*[[:space:]])sparse-checkout[[:space:]]+list([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent cannot change sparse-checkout state during an active review." >&2
  exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?format-patch([[:space:]]|$)" && \
   ! printf '%s' "$COMMAND" | grep -qE "git([^;&|]*[[:space:]])format-patch([^;&|]*[[:space:]])--stdout([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent cannot write patch files during an active review." >&2
  exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?rerere([[:space:]]|$)([^;&|]*[[:space:]])?(forget|clear)([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent cannot alter rerere state during an active review." >&2
  exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?maintenance([[:space:]]|$)([^;&|]*[[:space:]])?(run|start|stop|register|unregister|start)([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent cannot alter maintenance state during an active review." >&2
  exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?fast-export([^;&|]*[[:space:]])--export-marks(=|[[:space:]])"; then
  echo "BLOCKED: review-class agent cannot write fast-export marks during an active review." >&2
  exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?archive([^;&|]*[[:space:]])(-o=|-o[^[:space:];|&]+|-o[[:space:]]|--output=|--output[[:space:]])"; then
  echo "BLOCKED: review-class agent cannot write archive output during an active review." >&2
  exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\\|\\||;|\\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?(${MUTATING})([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent is read-only while an active review is in flight. Do not stage, commit, push, restore, stash, or otherwise mutate the repository; report the finding to the orchestrator." >&2
  exit 2
fi

exit 0
