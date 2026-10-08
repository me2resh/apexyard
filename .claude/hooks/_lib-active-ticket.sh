#!/bin/bash
# Shared active-ticket marker resolver.
#
# The active ticket for a working tree lives in that tree's own git dir, in a
# file named apexyard-ticket:
#
#   <repo>/.git/apexyard-ticket                    main clone
#   <repo>/.git/worktrees/<id>/apexyard-ticket     linked worktree
#
# One tree has one ticket. `git worktree remove` deletes the marker with the
# worktree. Both gates (require-active-ticket.sh and require-migration-ticket.sh)
# and every other reader call this library, so no two readers can disagree
# about which marker governs a path.
#
# TRANSITION (dual read). A regular apexyard-ticket file in the git dir of a
# validated tree decides. When there is none, or the tree fails validation,
# the lookup runs the old-layout resolution from before the move (the _atd_
# functions below). That resolution reads <ops>/.claude/session/tickets/ and
# current-ticket with the old rules, so every target that had a ticket before
# still has one. A failed validation only stops the new marker from being
# trusted. It is never a block on its own.
#
# DISCOVERY RUNS NO GIT PROCESS. The lookup reads the same files git reads
# (.git, <gitdir>/commondir, <gitdir>/gitdir) with shell builtins only. No
# GIT_* variable and no git config can steer it. Once the context is filled,
# the lookup of a new marker makes 0 forks and 0 execs. The first lookup in a workspace clone
# may resolve the registry path once per process, and that step can fork. A
# static test (test_active_ticket_process_budget.sh) fails when a
# lookup function gains a command substitution, a pipe, a subshell or an
# external command. The functions that fork on purpose are
# active_ticket_init, active_ticket_marker_single_link, the writers and the
# old-layout resolution (_atd_*).
#
# VALIDATION (docs/agdr/AgDR-0222-ticket-marker-in-worktree-git-dir.md):
#   - the git dir must belong to the ops fork or to a registered clone, matched
#     fresh on every validated path. A registered clone sits under the
#     workspace dir with its registry name, or at the workspace: path of its
#     registry entry
#   - a linked worktree must be listed by its common dir, and both back
#     pointers must agree
#   - no symlink may sit between the target and the tree root
#   - the git dir and the common dir must be owned by the current user
# Any failure sets REPLY to empty and returns 1. AT_REASON names the cause.
#
# This is a process gate. Anyone with write access to the git dir can forge a
# marker. It is not an authorization boundary.
#
# The library keeps its context in internal names (_AT_*) that it clears on
# the first source in a process. It never reads OPS_ROOT, WORKSPACE_DIR or
# the registry path from the environment. Hooks pass them with
# active_ticket_set_context. Every other caller uses active_ticket_init.
# SC2034: AT_REASON, AT_GITDIR, AT_TREE, AT_LEGACY_FILE, AT_LEGACY_WHY and the
# AT_REG_* names are output variables that callers read.
# shellcheck disable=SC2088,SC2034

# ---------------------------------------------------------------------------
# Path helpers (builtins only)
# ---------------------------------------------------------------------------

# Physical path of a directory, or of a file or missing leaf under an existing
# directory. Sets REPLY. Saves and restores PWD and OLDPWD. When the restore
# fails because the working directory is gone, it sets AT_REASON and returns 1.
_at_rp() {
  local o="$PWD" oo="${OLDPWD:-}" had="${OLDPWD+x}" p="$1" leaf=""
  REPLY=""
  [ -n "$p" ] || return 1
  if [ ! -d "$p" ]; then
    leaf="${p##*/}"
    p="${p%/*}"
    [ -n "$p" ] || p=/
  fi
  CDPATH='' builtin cd -P -- "$p" 2>/dev/null || return 1
  REPLY="$PWD"
  if ! CDPATH='' builtin cd -- "$o" 2>/dev/null; then
    REPLY=""
    AT_REASON="cwd unavailable"
    return 1
  fi
  if [ -n "$had" ]; then OLDPWD="$oo"; else unset OLDPWD; fi
  [ -z "$leaf" ] || REPLY="${REPLY%/}/$leaf"
  [ -n "$REPLY" ]
}

# Lexical normalisation: no link is resolved. A relative path is anchored at
# the physical working directory. A path that starts with ~user, ~+ or ~-
# returns 1, because its expansion depends on state this library cannot see.
_at_lex() {
  local p="$1" rest seg out=""
  REPLY=""
  case "$p" in
    '') return 1 ;;
    '~') p="$HOME" ;;
    '~/'*) p="$HOME/${p#\~/}" ;;
    '~'*) return 1 ;;
  esac
  case "$p" in
    /*) ;;
    *)
      _at_rp "$PWD" || { [ -n "$AT_REASON" ] || AT_REASON="cwd unavailable"; return 1; }
      p="$REPLY/$p"
      ;;
  esac
  rest="$p"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
    case "$seg" in
      ''|.) ;;
      ..)
        # Popping a component hides a link in it, so refuse the link.
        if [ -L "$out" ]; then _at_fail "symlink in marker path: $out"; return 1; fi
        out="${out%/*}"
        ;;
      *) out="$out/$seg" ;;
    esac
  done
  REPLY="${out:-/}"
}

# The one place that decides ownership. Tests override it to return false.
# It is defined on every source and never guarded.
_at_owned() { [ -O "$1" ]; }

_at_fail() {
  AT_REASON="$1"
  return 1
}

# Strip a trailing CR and trailing blanks, as git does.
_at_trim() {
  local v="$1"
  v="${v%$'\r'}"
  while :; do
    case "$v" in
      *' '|*$'\t') v="${v%?}" ;;
      *) break ;;
    esac
  done
  REPLY="$v"
}

# First line of a file, trimmed, into REPLY.
_at_readfirst() {
  local l
  IFS= read -r l < "$1" || [ -n "$l" ] || return 1
  _at_trim "$l"
  [ -n "$REPLY" ]
}

# A .git file: line 1 must start with "gitdir: ", and no later line may hold
# text. Git accepts only that shape, and the gate must see the same tree.
_at_gitfile() {
  local l1="" l n=0
  while IFS= read -r l || [ -n "$l" ]; do
    n=$((n + 1))
    if [ "$n" = 1 ]; then
      l1="$l"
    else
      _at_trim "$l"
      [ -z "$REPLY" ] || return 1
    fi
  done < "$1"
  _at_trim "$l1"
  case "$REPLY" in
    'gitdir: '?*) REPLY="${REPLY#gitdir: }" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Registry scan (builtins only)
# ---------------------------------------------------------------------------

# The portfolio library sets _PP_GUARD to the process id when it is sourced.
# Its outputs are trusted only then, so an inherited _PP_WS or _PP_REG is
# never used.
_at_pp_trusted() {
  [ "${_PP_GUARD[1]:-}" = "$$" ]
}

# The registry path comes from the portfolio resolver. A relative value is
# relative to the ops root, as for every portfolio path. Without a trusted
# resolver the path stays unknown, and the lookup fails closed.
_at_fill_reg() {
  [ -z "$_AT_REG" ] || return 0
  _at_pp_trusted || return 0
  if [ -z "${_PP_REG:-}" ] && command -v portfolio_resolve_registry_into_var >/dev/null 2>&1; then
    portfolio_resolve_registry_into_var
  fi
  case "${_PP_REG:-}" in
    '') ;;
    /*) _AT_REG="$_PP_REG" ;;
    *) [ -z "$_AT_OPS" ] || _AT_REG="$_AT_OPS/${_PP_REG#./}" ;;
  esac
  return 0
}

# True when <item> is in <set>, a string of items that each start and end with
# a space. The comparison ignores case, because repo slugs do.
_at_member() {
  local was=1 r=1
  shopt -q nocasematch && was=0
  shopt -s nocasematch
  case "$1" in
    *" $2 "*) r=0 ;;
  esac
  [ "$was" = 0 ] || shopt -u nocasematch
  return "$r"
}

# Adds one repo slug to the entry's set. Reads the caller's locals.
_at_reg_add() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  v="${v#[\"\']}"
  v="${v%[\"\']}"
  [ -z "$v" ] || ent_set="$ent_set$v "
}

# Records the entry that has just ended. Reads the caller's locals.
_at_reg_flush() {
  AT_REG_REPOS="$AT_REG_REPOS${ent_set# }"
  if [ -n "$want" ] && [ "$ent_name" = "$want" ]; then
    found=0
    AT_REG_REPO="$ent_repo"
    AT_REG_REPO_SET="$ent_set"
  fi
  if [ -n "$ent_name" ] && [ -n "$ent_ws" ]; then
    AT_REG_WS_ENTRIES="$AT_REG_WS_ENTRIES$ent_name"$'\t'"$ent_ws"$'\n'
  fi
  if [ -n "$want_repo" ] && [ -z "$AT_REG_NAME_FOR_REPO" ] && [ -n "$ent_repo" ] && [ "$ent_repo" = "$want_repo" ]; then
    AT_REG_NAME_FOR_REPO="$ent_name"
  fi
  ent_name=""
  ent_repo=""
  ent_ws=""
  ent_set=" "
  in_repos=0
}

# Scan the registry for the project <name>. Sets AT_REG_REPO to its repo: value
# and AT_REG_REPO_SET to every slug of that entry: repo:, each repos: item and
# primary:. AT_REG_REPOS holds the slugs of every entry. Each slug is followed
# by a space. Keys count only at the indent of an entry's first key, so a
# nested repo: key in a sub-map never matches. Returns 0 when <name> is
# registered. An empty <name> only collects AT_REG_REPOS and returns 1.
# AT_REG_WS_ENTRIES holds one "<name><TAB><workspace>" line for each entry
# with a workspace: key, as written in the registry. With a second argument,
# AT_REG_NAME_FOR_REPO is the name of the first entry whose repo: value
# equals it exactly.
_at_reg_scan() {
  local want="$1" want_repo="${2:-}" raw line lead rest sp k v item eind="" eset=0 kind="" in_proj=0 found=1
  local ent_name="" ent_repo="" ent_ws="" ent_set=" " in_repos=0
  AT_REG_REPO=""
  AT_REG_REPO_SET=" "
  AT_REG_REPOS=" "
  AT_REG_WS_ENTRIES=""
  AT_REG_NAME_FOR_REPO=""
  [ -n "${_AT_REG:-}" ] && [ -r "$_AT_REG" ] || return 1
  while IFS= read -r raw || [ -n "$raw" ]; do
    raw="${raw%$'\r'}"
    line="${raw%%#*}"
    case "$line" in
      *[![:space:]]*) ;;
      *) continue ;;
    esac
    case "$line" in
      projects:*) in_proj=1; continue ;;
      [![:space:]-]*)
        [ "$in_proj" = 0 ] || _at_reg_flush
        in_proj=0
        continue ;;
    esac
    [ "$in_proj" = 1 ] || continue
    lead="${line%%[![:space:]]*}"
    line="${line#"$lead"}"
    if [ "$in_repos" = 1 ]; then
      case "$line" in
        '-'*)
          if [ "${#lead}" -ge "${#kind}" ]; then
            rest="${line#-}"
            _at_reg_add "$rest"
            continue
          fi
          ;;
      esac
      in_repos=0
    fi
    case "$line" in
      '-'*)
        rest="${line#-}"
        sp="${rest%%[![:space:]]*}"
        if [ "$eset" = 0 ]; then eind="$lead"; eset=1; fi
        [ "$lead" = "$eind" ] || continue
        _at_reg_flush
        kind="$lead $sp"
        line="${rest#"$sp"}"
        ;;
      *)
        [ "$lead" = "$kind" ] || continue
        ;;
    esac
    k="${line%%:*}"
    v="${line#*:}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    case "$k" in
      name)
        v="${v#[\"\']}"
        v="${v%[\"\']}"
        ent_name="$v"
        ;;
      repo)
        v="${v#[\"\']}"
        v="${v%[\"\']}"
        ent_repo="$v"
        _at_reg_add "$v"
        ;;
      primary) _at_reg_add "$v" ;;
      workspace)
        v="${v#[\"\']}"
        v="${v%[\"\']}"
        ent_ws="$v"
        ;;
      repos)
        if [ -z "$v" ]; then
          in_repos=1
        else
          v="${v#\[}"
          v="${v%\]}"
          while [ -n "$v" ]; do
            item="${v%%,*}"
            case "$v" in
              *,*) v="${v#*,}" ;;
              *) v="" ;;
            esac
            _at_reg_add "$item"
          done
        fi
        ;;
    esac
  done < "$_AT_REG"
  [ "$in_proj" = 0 ] || _at_reg_flush
  return "$found"
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

# Forget the per-process validation memo. Tests call it between fixtures.
_at_memo_clear() {
  _AT_MKEY=""
  _AT_MG=""
  _AT_MC=""
  _AT_MT=""
  _AT_MK=""
  _AT_MN=""
  _AT_MOK=1
  _AT_MWHY=""
}

# One-time state reset. It runs only on the first source in a process.
_at_reset_state() {
  _AT_OPS=""
  _AT_WS=""
  _AT_REG=""
  _AT_HOME=""
  _AT_DWS=""
  export -n _AT_OPS _AT_WS _AT_REG _AT_HOME _AT_DWS
  AT_SOURCE=""
  AT_REG_WS_ENTRIES=""
  AT_REG_NAME_FOR_REPO=""
  AT_VALIDATIONS=0
  AT_REASON=""
  AT_GITDIR=""
  AT_TREE=""
  AT_PROJECT=""
  AT_LEGACY_FILE=""
  AT_LEGACY_WHY=""
  AT_REG_REPO=""
  AT_REG_REPO_SET=" "
  AT_REG_REPOS=" "
  _at_memo_clear
}

_AT_LIBDIR=""
case "${BASH_SOURCE[0]:-}" in
  */*) _at_rp "${BASH_SOURCE[0]%/*}" && _AT_LIBDIR="$REPLY" ;;
esac

# The guard value is the process id held in element 1 of an indexed array.
# Bash cannot import an array from the environment, so a parent process cannot
# plant it. A child bash has a new $$, so it always resets. Function
# definitions above are never skipped.
case "${_AT_GUARD[1]:-}" in
  "$$") ;;
  *)
    unset _AT_GUARD
    _at_reset_state
    _AT_GUARD=(x "$$")
    ;;
esac

# Context for a caller that already resolved the ops root and workspace dir.
# The optional third and fourth values serve the old-layout resolution: the
# directory that holds .claude/session/ (default: the ops root) and the
# workspace dir as the hook resolved it before (default: the second value).
active_ticket_set_context() {
  _AT_OPS="${1:-}"
  _AT_WS="${2:-}"
  _AT_HOME="${3:-}"
  _AT_DWS="${4:-}"
  return 0
}

# ---------------------------------------------------------------------------
# Validation of one tree (steps 2 to 5)
# ---------------------------------------------------------------------------

# Validates the tree rooted at W. Sets the _AT_M* memo on success.
_at_validate_w_body() {
  local W="$1" G C T p ws="" name="" ops=0 wsm=0 wslink=0
  [ -n "$_AT_OPS" ] && [ -n "$_AT_WS" ] || { _at_fail "resolver context missing"; return 1; }
  if [ -L "$W/.git" ]; then _at_fail "symlink in marker path: $W/.git"; return 1; fi
  _at_rp "$W" || return 1
  T="$REPLY"
  if [ -d "$W/.git" ]; then
    if [ -e "$W/.git/commondir" ]; then _at_fail "not a git tree (commondir in a main git dir)"; return 1; fi
    _at_rp "$W/.git" || return 1
    G="$REPLY"
    C="$G"
  elif [ -f "$W/.git" ]; then
    _at_gitfile "$W/.git" || { _at_fail "not a git tree (malformed .git file)"; return 1; }
    p="$REPLY"
    case "$p" in
      /*) ;;
      *) p="$W/$p" ;;
    esac
    _at_rp "$p" || return 1
    G="$REPLY"
    if [ -f "$G/commondir" ]; then
      _at_readfirst "$G/commondir" || { _at_fail "not a git tree (empty commondir)"; return 1; }
      p="$REPLY"
      case "$p" in
        /*) ;;
        *) p="$G/$p" ;;
      esac
      _at_rp "$p" || return 1
      C="$REPLY"
    else
      C="$G"
    fi
  else
    _at_fail "not a git tree"
    return 1
  fi
  if [ ! -f "$G/HEAD" ] || [ ! -d "$C/objects" ] || [ ! -d "$C/refs" ]; then
    _at_fail "not a git tree (missing HEAD, objects or refs)"
    return 1
  fi
  if ! _at_owned "$G" || ! _at_owned "$C"; then
    _at_fail "not owned by current user ($G). git's safe.directory setting does not apply to this gate. Run the session as the owner of the repo, or change its owner."
    return 1
  fi

  # An ops .git that is a link could alias a project, so it is refused for
  # every tree.
  if [ -L "$_AT_OPS/.git" ]; then
    _at_fail "symlink in marker path: $_AT_OPS/.git"
    return 1
  fi
  if [ -d "$_AT_OPS/.git" ] && _at_rp "$_AT_OPS/.git" && [ "$C" = "$REPLY" ]; then
    ops=1
  fi
  [ ! -L "$_AT_WS" ] || wslink=1
  if _at_rp "$_AT_WS"; then
    ws="$REPLY"
    case "$C" in
      "$ws"/*/.git)
        name="${C#"$ws"/}"
        name="${name%/.git}"
        # A name that fails a check here is not a match. A registry entry's
        # workspace: path may still claim the clone below.
        case "$name" in
          */*|.|..|'') name="" ;;
        esac
        if [ -n "$name" ] && [ "$wslink" = 1 ]; then _at_fail "symlink in marker path: $_AT_WS"; return 1; fi
        [ -z "$name" ] || [[ $name =~ $_AT_NAME_RE ]] || name=""
        if [ -n "$name" ]; then
          _at_fill_reg
          _at_reg_scan "$name" || name=""
        fi
        if [ -n "$name" ]; then
          if [ -L "$_AT_WS/$name" ] || [ -L "$_AT_WS/$name/.git" ]; then
            _at_fail "symlink in marker path: $_AT_WS/$name"
            return 1
          fi
          _at_rp "$_AT_WS/$name/.git" || return 1
          [ "$REPLY" = "$C" ] || name=""
        fi
        if [ -n "$name" ]; then
          _at_rp "$_AT_WS/$name" || return 1
          [ "${REPLY%/*}" = "$ws" ] || name=""
        fi
        [ -z "$name" ] || wsm=1
        ;;
    esac
  fi
  # A registry entry may name its clone with a workspace: path, absolute or
  # relative to the ops root. Its .git must resolve to C. The same link and
  # name rules apply as for a clone under the workspace dir.
  _at_entry_match "$C" || return 1
  if [ -n "$REPLY" ]; then
    if [ "$ops" = 1 ]; then _at_fail "ambiguous common dir"; return 1; fi
    if [ "$wsm" = 1 ] && [ "$REPLY" != "$name" ]; then _at_fail "ambiguous common dir"; return 1; fi
    name="$REPLY"
    wsm=1
  fi
  if [ $((ops + wsm)) = 2 ]; then _at_fail "ambiguous common dir"; return 1; fi
  if [ $((ops + wsm)) = 0 ]; then
    # A tree that sits under a linked workspace entry resolves outside the
    # workspace, so name the link instead of the registry.
    case "$W" in
      "$_AT_WS"/*)
        name="${W#"$_AT_WS"/}"
        name="${name%%/*}"
        if [ -L "$_AT_WS/$name" ]; then _at_fail "symlink in marker path: $_AT_WS/$name"; return 1; fi
        ;;
    esac
    _at_fail "unregistered common dir"
    return 1
  fi
  [ "$ops" = 0 ] || name=""

  if [ "$G" = "$C" ]; then
    [ "$T" = "${C%/*}" ] || { _at_fail "worktree not listed"; return 1; }
    _AT_MK=main
  else
    [ "${G%/*}" = "$C/worktrees" ] || { _at_fail "worktree not listed"; return 1; }
    _at_readfirst "$G/gitdir" || { _at_fail "worktree not listed"; return 1; }
    p="$REPLY"
    case "$p" in
      /*) ;;
      *) p="$G/$p" ;;
    esac
    _at_rp "$p" || { _at_fail "worktree not listed"; return 1; }
    [ "$REPLY" = "$T/.git" ] || { _at_fail "worktree not listed"; return 1; }
    _AT_MK=linked
  fi
  _AT_MG="$G"
  _AT_MC="$C"
  _AT_MT="$T"
  _AT_MN="$name"
  return 0
}

_AT_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

# Sets REPLY to the name of the registry entry whose workspace: path holds the
# common dir C, or to empty when no entry does. Returns 1, with AT_REASON set,
# when the match is reached through a link or when two entries match.
_at_entry_match() {
  local C="$1" en ew p hit="" lines
  REPLY=""
  _at_fill_reg
  [ -n "$_AT_REG" ] || return 0
  _at_reg_scan "" || true
  lines="$AT_REG_WS_ENTRIES"
  while [ -n "$lines" ]; do
    en="${lines%%$'\n'*}"
    lines="${lines#*$'\n'}"
    ew="${en#*$'\t'}"
    en="${en%%$'\t'*}"
    [[ $en =~ $_AT_NAME_RE ]] || continue
    case "$ew" in
      '') continue ;;
      '~'*) continue ;;
      /*) p="$ew" ;;
      *) [ -n "$_AT_OPS" ] || continue; p="$_AT_OPS/${ew#./}" ;;
    esac
    p="${p%/}"
    [ -n "$p" ] || continue
    _at_rp "$p/.git" || continue
    [ "$REPLY" = "$C" ] || continue
    if [ -L "$p" ] || [ -L "$p/.git" ]; then
      REPLY=""
      _at_fail "symlink in marker path: $p"
      return 1
    fi
    if [ -n "$hit" ] && [ "$hit" != "$en" ]; then
      REPLY=""
      _at_fail "ambiguous common dir"
      return 1
    fi
    hit="$en"
  done
  REPLY="$hit"
  return 0
}

# Memoised wrapper. The memo key covers the tree and the context.
_at_validate_w() {
  local W="$1"
  AT_VALIDATIONS=$((AT_VALIDATIONS + 1))
  AT_REASON=""
  _at_memo_clear
  _AT_MKEY="$W|$_AT_OPS|$_AT_WS"
  if _at_validate_w_body "$W"; then
    _AT_MOK=0
    return 0
  fi
  _AT_MG=""
  _AT_MOK=1
  _AT_MWHY="${AT_REASON:-git dir failed validation}"
  # A missing working directory belongs to the caller, not to the tree.
  [ "$AT_REASON" != "cwd unavailable" ] || _AT_MKEY=""
  return 1
}

# Steps 1 to 6: from a path to the validated git dir. Sets AT_GITDIR, AT_TREE
# and D (the nearest existing directory) for the caller through _AT_LD.
_at_resolve_g() {
  local D W p key
  REPLY=""
  AT_REASON=""
  AT_GITDIR=""
  AT_TREE=""
  AT_PROJECT=""
  AT_LEGACY_FILE=""
  AT_LEGACY_WHY=""
  _at_lex "$1" || { [ -n "$AT_REASON" ] || AT_REASON="unresolvable path"; return 1; }
  D="$REPLY"
  if [ ! -d "$D" ]; then
    D="${D%/*}"
    while [ -n "$D" ] && [ ! -d "$D" ]; do D="${D%/*}"; done
  fi
  [ -n "$D" ] || { _at_fail "not a git tree"; return 1; }
  W="$D"
  while [ -n "$W" ] && [ ! -e "$W/.git" ] && [ ! -L "$W/.git" ]; do W="${W%/*}"; done
  [ -n "$W" ] || { _at_fail "not a git tree"; return 1; }
  key="$W|$_AT_OPS|$_AT_WS"
  if [ "$key" != "$_AT_MKEY" ]; then
    _at_validate_w "$W" || true
  fi
  if [ "$_AT_MOK" != 0 ]; then
    AT_REASON="$_AT_MWHY"
    return 1
  fi
  # Link walk on the lexical path, from the directory up to the tree root.
  p="$D"
  while :; do
    if [ -L "$p" ]; then _at_fail "symlink in marker path: $p"; return 1; fi
    [ "$p" != "$W" ] || break
    p="${p%/*}"
    [ -n "$p" ] || { _at_fail "not a git tree"; return 1; }
  done
  if [ -L "$_AT_MG/apexyard-ticket" ]; then
    _at_fail "symlink in marker path: $_AT_MG/apexyard-ticket"
    return 1
  fi
  for p in "$_AT_MG"/apexyard-ticket.tmp.*; do
    if [ -L "$p" ]; then _at_fail "symlink in marker path: $p"; return 1; fi
  done
  AT_GITDIR="$_AT_MG"
  AT_TREE="$_AT_MT"
  AT_PROJECT="$_AT_MN"
  return 0
}

# ---------------------------------------------------------------------------
# The old-layout resolution (the floor during the transition)
# ---------------------------------------------------------------------------
#
# When no validated tree holds an apexyard-ticket file, the lookup runs the
# resolution that the hooks used before markers moved into the git dir. It
# reads, in order:
#
#   <home>/.claude/session/tickets/<project>/<safe-branch>   linked worktree
#   <home>/.claude/session/tickets/<project>
#   <home>/.claude/session/current-ticket
#
# <project> comes from the path under the workspace dir (or <ops>/workspace).
# The branch tier applies when CLAUDE_WORKTREE_BRANCH is set or git reports a
# linked worktree. An empty target reads current-ticket only. A target that
# is not empty but cannot be resolved, such as ~user/x, reads no marker.
#
# These functions keep the old cost: they may run git and the path resolver.
# They run only when the new marker is absent or not trusted, so the lookup of
# a new marker makes no fork. Their names start with _atd_, so the static fork
# scan of the lookup path does not cover them.

# The old lexical normalisation: drop empty and "." segments, pop on "..".
_atd_lexical() {
  local rest="$1" seg out=""
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
    case "$seg" in
      ''|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  REPLY="${out:-/}"
}

_atd_resolve_path() {
  local target="$1" resolved=""
  REPLY=""
  [ -n "$target" ] || return 0
  case "$target" in
    '~') target="$HOME" ;;
    '~/'*) target="$HOME/${target#\~/}" ;;
    '~'*) return 0 ;;
  esac
  case "$target" in
    /*) ;;
    *)
      _at_rp "$PWD" || { REPLY=""; return 0; }
      target="$REPLY/$target"
      ;;
  esac
  _atd_lexical "$target"
  if command -v _resolve_real_path >/dev/null 2>&1; then
    resolved=$(_resolve_real_path "$REPLY")
  fi
  [ -n "$resolved" ] || resolved="$REPLY"
  case "$resolved" in
    //*) resolved="/${resolved#//}" ;;
  esac
  REPLY="$resolved"
}

_atd_anchor() {
  local raw="$1" resolved=""
  REPLY=""
  [ -n "$raw" ] || return 0
  if command -v _resolve_real_path >/dev/null 2>&1; then
    resolved=$(_resolve_real_path "$raw")
  fi
  REPLY="${resolved:-$raw}"
}

_atd_project_for_resolved_path() {
  local path="$1" project="" tail ws ops
  _atd_anchor "${_AT_DWS:-$_AT_WS}"
  ws="$REPLY"
  _atd_anchor "$_AT_OPS"
  ops="$REPLY"
  if [ -n "$ws" ]; then
    case "$path" in
      "$ws"/*) tail="${path#"$ws"/}"; project="${tail%%/*}" ;;
    esac
  fi
  if [ -z "$project" ] && [ -n "$ops" ]; then
    case "$path" in
      "$ops"/workspace/*) tail="${path#"$ops"/workspace/}"; project="${tail%%/*}" ;;
    esac
  fi
  REPLY="$project"
}

# dirname for an absolute, normalised path.
_atd_dirname() {
  case "$1" in
    /) REPLY=/ ;;
    */*) REPLY="${1%/*}"; [ -n "$REPLY" ] || REPLY=/ ;;
    *) REPLY=. ;;
  esac
}

# The marker path for <raw>, or empty, in REPLY.
_atd_marker_for_path() {
  local raw="$1" resolved="" project="" marker="" wt="" safe dir gd gcd
  local home="${_AT_HOME:-$_AT_OPS}"
  REPLY=""
  [ -n "$home" ] || return 0
  _atd_resolve_path "$raw"
  resolved="$REPLY"
  if [ -n "$resolved" ]; then
    _atd_project_for_resolved_path "$resolved"
    project="$REPLY"
  fi
  if [ -n "$project" ]; then
    wt="${CLAUDE_WORKTREE_BRANCH:-}"
    if [ -z "$wt" ]; then
      _atd_dirname "$resolved"
      dir="$REPLY"
      while [ -n "$dir" ] && [ "$dir" != "/" ] && [ ! -d "$dir" ]; do
        _atd_dirname "$dir"
        dir="$REPLY"
      done
      [ -d "$dir" ] || dir=""
      gd=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)
      gcd=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
      if [ -n "$gd" ] && [ "$gd" != "$gcd" ]; then
        wt=$(git -C "$dir" branch --show-current 2>/dev/null)
      fi
    fi
    if [ -n "$wt" ]; then
      safe="${wt//\//__}"
      marker="$home/.claude/session/tickets/$project/$safe"
      [ -f "$marker" ] || marker=""
    fi
  fi
  if [ -z "$marker" ] && [ -n "$project" ] && [ -f "$home/.claude/session/tickets/$project" ]; then
    marker="$home/.claude/session/tickets/$project"
  elif [ -z "$marker" ] && { [ -n "$resolved" ] || [ -z "$raw" ]; } \
    && [ -f "$home/.claude/session/current-ticket" ]; then
    marker="$home/.claude/session/current-ticket"
  fi
  REPLY="$marker"
}

# Runs the old-layout resolution for <raw>. Keeps AT_REASON and the tree
# fields that the validation set. On a miss, AT_LEGACY_FILE names an old file
# that exists but does not cover the target, for the block message.
_atd_lookup() {
  local why="$AT_REASON" home="${_AT_HOME:-$_AT_OPS}" f
  _atd_marker_for_path "$1"
  AT_REASON="$why"
  if [ -n "$REPLY" ]; then
    AT_SOURCE=legacy
    AT_LEGACY_FILE="$REPLY"
    AT_LEGACY_WHY=""
    return 0
  fi
  AT_SOURCE=""
  AT_LEGACY_FILE=""
  AT_LEGACY_WHY=""
  if [ -n "$home" ]; then
    if [ -f "$home/.claude/session/current-ticket" ]; then
      AT_LEGACY_FILE="$home/.claude/session/current-ticket"
    else
      for f in "$home/.claude/session/tickets"/*; do
        if [ -e "$f" ]; then AT_LEGACY_FILE="$f"; break; fi
      done
    fi
    [ -z "$AT_LEGACY_FILE" ] || AT_LEGACY_WHY="it does not cover this target"
  fi
  REPLY=""
  return 1
}

# ---------------------------------------------------------------------------
# Public lookup API. These functions set REPLY and write nothing to stderr.
# A marker in a validated tree is found with no fork. When there is none, the
# old-layout resolution above runs and may run git.
# ---------------------------------------------------------------------------

# True when <repo> belongs to the validated tree in AT_PROJECT and AT_GITDIR.
# A project clone takes only a repo of its own registry entry (repo:, repos:
# or primary:, compared without regard to case). The ops fork takes no repo of
# a registered project. In a project clone, a registry that cannot be read
# binds nothing. In the ops fork, an unknown registry path falls back to the
# fork's own apexyard.projects.yaml, the single-fork default, which is not
# taken from the environment. When that file does not exist either, no
# project is known and the marker is bound. Builtins only.
_at_bound() {
  local repo="$1"
  _at_fill_reg
  if [ -n "$AT_PROJECT" ]; then
    [ -n "$_AT_REG" ] && [ -r "$_AT_REG" ] || return 1
    _at_reg_scan "$AT_PROJECT" || return 1
    [ -n "$repo" ] || return 1
    _at_member "$AT_REG_REPO_SET" "$repo"
    return
  fi
  local _AT_REG="${_AT_REG:-${_AT_OPS:+$_AT_OPS/apexyard.projects.yaml}}"
  [ -n "$_AT_REG" ] || return 1
  [ -e "$_AT_REG" ] || return 0
  [ -r "$_AT_REG" ] || return 1
  _at_reg_scan "" || true
  [ -z "$repo" ] && return 0
  ! _at_member "$AT_REG_REPOS" "$repo"
}

# $1 is the path to validate. $2 is the target as the caller gave it, for the
# old-layout resolution. A marker whose repo= is not bound to its tree, such
# as one planted by hand or by an older writer, is not trusted.
_at_lookup_inner() {
  AT_SOURCE=""
  if _at_resolve_g "$1" && [ -f "$AT_GITDIR/apexyard-ticket" ]; then
    REPLY="$AT_GITDIR/apexyard-ticket"
    active_ticket_read_field "$REPLY" repo || REPLY=""
    if _at_bound "$REPLY"; then
      REPLY="$AT_GITDIR/apexyard-ticket"
      AT_SOURCE=tree
      return 0
    fi
    AT_REASON="marker repo is not bound to this tree"
  fi
  _atd_lookup "$2"
}

# REPLY is the marker path, or empty. Return 0 only when a marker governs the
# path. AT_SOURCE is "tree" for a marker in the git dir of a validated tree and
# "legacy" for an old-layout file. AT_REASON is empty when the tree is valid.
active_ticket_lookup() {
  _at_lookup_inner "$1" "$1" && return 0
  REPLY=""
  return 1
}

# The lookup for the physical working directory. It stands for a target that
# could not be extracted, so the old-layout resolution reads current-ticket
# only.
active_ticket_lookup_cwd() {
  if ! _at_rp "$PWD"; then
    AT_GITDIR=""
    AT_TREE=""
    AT_PROJECT=""
    AT_SOURCE=""
    AT_REASON="cwd unavailable"
    _atd_lookup "" && return 0
    REPLY=""
    return 1
  fi
  _at_lookup_inner "$REPLY" "" && return 0
  REPLY=""
  return 1
}

# REPLY is the validated git dir of the tree that holds <dir>, or empty.
active_ticket_gitdir() {
  _at_resolve_g "$1" && { REPLY="$AT_GITDIR"; return 0; }
  REPLY=""
  return 1
}


# REPLY is the clone path of the registered project <name>: the workspace:
# path of its registry entry (relative to the ops root when not absolute), or
# <workspace dir>/<name>. Returns 1 when <name> is not a valid project name.
# The path may not exist. The caller checks that. Builtins only.
active_ticket_project_clone() {
  local name="$1" lines en ew
  REPLY=""
  [[ $name =~ $_AT_NAME_RE ]] || return 1
  _at_fill_reg
  if [ -n "$_AT_REG" ] && [ -r "$_AT_REG" ]; then
    _at_reg_scan "" || true
    lines="$AT_REG_WS_ENTRIES"
    while [ -n "$lines" ]; do
      en="${lines%%$'\n'*}"
      lines="${lines#*$'\n'}"
      ew="${en#*$'\t'}"
      en="${en%%$'\t'*}"
      [ "$en" = "$name" ] || continue
      case "$ew" in
        /*) REPLY="${ew%/}"; return 0 ;;
        ''|'~'*) ;;
        *) [ -z "$_AT_OPS" ] || { REPLY="$_AT_OPS/${ew#./}"; REPLY="${REPLY%/}"; return 0; } ;;
      esac
    done
  fi
  [ -n "$_AT_WS" ] || return 1
  REPLY="$_AT_WS/$name"
}

# REPLY holds the marker file of every registered workspace clone and of each
# linked worktree of it, one path per line. A reader that must see every
# ticket in the portfolio, such as a guard that only adds blocks, uses this
# from the ops fork. Each clone is validated, so an unregistered repo is never
# read. Builtins only.
active_ticket_project_markers() {
  local d g m t s name out="" seen=$'\n' cands="" lines ew
  REPLY=""
  if [ -n "$_AT_WS" ] && [ -d "$_AT_WS" ]; then
    for d in "$_AT_WS"/*/; do
      d="${d%/}"
      [ -d "$d" ] || continue
      cands="$cands$d"$'\n'
    done
  fi
  # The clones that registry entries name with a workspace: path.
  _at_fill_reg
  if [ -n "$_AT_REG" ]; then
    _at_reg_scan "" || true
    lines="$AT_REG_WS_ENTRIES"
    while [ -n "$lines" ]; do
      ew="${lines%%$'\n'*}"
      lines="${lines#*$'\n'}"
      ew="${ew#*$'\t'}"
      case "$ew" in
        /*) cands="$cands$ew"$'\n' ;;
        ''|'~'*) ;;
        *) [ -z "$_AT_OPS" ] || cands="$cands$_AT_OPS/${ew#./}"$'\n' ;;
      esac
    done
  fi
  while [ -n "$cands" ]; do
    d="${cands%%$'\n'*}"
    cands="${cands#*$'\n'}"
    [ -d "$d" ] || continue
    active_ticket_gitdir "$d" || continue
    g="$AT_GITDIR"
    case "$seen" in *$'\n'"$g"$'\n'*) continue ;; esac
    seen="$seen$g"$'\n'
    if [ -f "$g/apexyard-ticket" ] && [ ! -L "$g/apexyard-ticket" ]; then out="$out$g/apexyard-ticket"$'\n'; fi
    for m in "$g"/worktrees/*/apexyard-ticket; do
      if [ -f "$m" ] && [ ! -L "$m" ]; then out="$out$m"$'\n'; fi
    done
  done
  # Old-layout files, until the legacy reader is removed. After an update,
  # every adopter has these and no new marker yet. They are returned even
  # where the legacy rule would refuse them for an edit, because a reader that
  # only adds blocks gains from seeing more tickets. A current-ticket file
  # counts whatever repo it names. A tickets/<name> file counts when <name> is
  # registered, and so does each file in a tickets/<name>/ directory (the old
  # per-branch form). This part goes away with the legacy reader.
  s="$_AT_OPS/.claude/session"
  if [ -n "$_AT_OPS" ] && [ ! -L "$s" ]; then
    if [ -f "$s/current-ticket" ] && [ ! -L "$s/current-ticket" ]; then out="$out$s/current-ticket"$'\n'; fi
    if [ -d "$s/tickets" ] && [ ! -L "$s/tickets" ]; then
      _at_fill_reg
      for t in "$s/tickets"/*; do
        name="${t##*/}"
        if [ -f "$t" ] && [ ! -L "$t" ]; then
          if _at_reg_scan "$name"; then out="$out$t"$'\n'; fi
        elif [ -d "$t" ] && [ ! -L "$t" ]; then
          # The per-branch form tickets/<name>/<branch>.
          if _at_reg_scan "$name"; then
            for m in "$t"/*; do
              if [ -f "$m" ] && [ ! -L "$m" ]; then out="$out$m"$'\n'; fi
            done
          fi
        fi
      done
    fi
  fi
  REPLY="$out"
  [ -n "$out" ]
}

# Compatibility wrapper for callers that use $( ). An empty argument is an
# unextractable write target. It is judged against the hook's working
# directory.
active_ticket_marker_for_path() {
  if [ -z "${1:-}" ]; then
    active_ticket_lookup_cwd
  else
    active_ticket_lookup "$1"
  fi
  printf '%s' "$REPLY"
}

# True when <path> names the marker file or its temporary file in the git dir
# of a registered tree. A symlink is refused. A hard link is not checked
# here: the link count needs stat, and this function cannot fork. The gate
# calls active_ticket_marker_single_link before it exempts the write.
active_ticket_is_marker_target() {
  local L P base T p G
  _at_lex "$1" || return 1
  L="$REPLY"
  base="${L##*/}"
  case "$base" in
    apexyard-ticket) ;;
    apexyard-ticket.tmp.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;;
    *) return 1 ;;
  esac
  P="${L%/*}"
  [ -n "$P" ] || return 1
  if [ -L "$P" ] || [ -L "$L" ]; then return 1; fi
  [ -d "$P" ] || return 1
  if [ -f "$P/commondir" ]; then
    _at_readfirst "$P/gitdir" || return 1
    p="$REPLY"
    case "$p" in
      /*) ;;
      *) p="$P/$p" ;;
    esac
    T="${p%/*}"
  else
    T="${P%/*}"
  fi
  [ -n "$T" ] || return 1
  _at_resolve_g "$T" || return 1
  G="$AT_GITDIR"
  _at_rp "$P" || return 1
  [ "$REPLY" = "$G" ]
}

# REPLY is the value of the first <key>= line in a marker file.
active_ticket_read_field() {
  local l k="$2"
  REPLY=""
  [ -f "$1" ] || return 1
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l%$'\r'}"
    case "$l" in
      "$k="*) REPLY="${l#"$k="}"; return 0 ;;
    esac
  done < "$1"
  return 1
}

# ---------------------------------------------------------------------------
# Functions that may fork (outside the lookup budget)
# ---------------------------------------------------------------------------

# 0 when <path> is missing or has exactly one link. 1 when the link count is
# above 1 or cannot be read. The marker-write exemption calls this so a hard
# link cannot stand in for the marker. A missing file is the first write and
# stays exempt. The count is GNU stat -c %h, then BSD stat -f %l, then
# find -links +1. Any of those may fork, so this stays outside the lookup
# budget. An unreadable count is a refusal.
active_ticket_marker_single_link() {
  local f n
  _at_lex "$1" || return 1
  f="$REPLY"
  if [ -L "$f" ]; then return 1; fi
  if [ ! -e "$f" ]; then return 0; fi
  n=$(stat -c %h "$f" 2>/dev/null) || n=""
  case "$n" in ''|*[!0-9]*) n=$(stat -f %l "$f" 2>/dev/null) || n="" ;; esac
  case "$n" in
    ''|*[!0-9]*)
      if ! n=$(find "$f" -prune -links +1 -print 2>/dev/null); then
        return 1
      fi
      [ -z "$n" ]
      return
      ;;
  esac
  [ "$n" = 1 ]
}

# Fill every empty context value once per process. A caller that has no
# resolved context uses this. The start directory defaults to the working
# directory.
active_ticket_init() {
  local start="${1:-$PWD}" dir
  if [ -n "$_AT_OPS" ] && [ -n "$_AT_WS" ] && [ -n "$_AT_REG" ]; then return 0; fi
  dir="$_AT_LIBDIR"
  [ -n "$dir" ] || dir="${_AT_OPS:+$_AT_OPS/.claude/hooks}"
  if [ -n "$dir" ]; then
    # Source unconditionally, so an inherited function of the same name is
    # replaced by the real definition.
    [ ! -f "$dir/_lib-ops-root.sh" ] || . "$dir/_lib-ops-root.sh"
    [ ! -f "$dir/_lib-read-config.sh" ] || . "$dir/_lib-read-config.sh"
    [ ! -f "$dir/_lib-portfolio-paths.sh" ] || . "$dir/_lib-portfolio-paths.sh"
  fi
  if [ -z "$_AT_OPS" ] && command -v resolve_ops_root >/dev/null 2>&1; then
    _AT_OPS=$(resolve_ops_root "$start")
    [ -n "$_AT_OPS" ] || _AT_OPS=$(resolve_ops_root "$PWD")
  fi
  if command -v portfolio_resolve_into_vars >/dev/null 2>&1; then
    portfolio_resolve_into_vars
  fi
  if _at_pp_trusted; then
    case "${_PP_WS:-}" in
      /*) [ -n "$_AT_WS" ] || _AT_WS="$_PP_WS" ;;
    esac
  fi
  [ -n "$_AT_WS" ] || [ -z "$_AT_OPS" ] || _AT_WS="$_AT_OPS/workspace"
  _at_fill_reg
  [ -n "$_AT_OPS" ] && [ -n "$_AT_WS" ]
}

# The only marker writer. Validates the tree of <dir>, then writes the marker
# atomically: mktemp, chmod and mv. It needs at most three external commands
# after init, plus date on a bash older than 4.2.
active_ticket_write() {
  local dir="$1" repo="$2" num="$3" title="$4" url="$5" branch="$6" G tmp ts="" hint=""
  if ! active_ticket_init "$dir"; then
    echo "apexyard: cannot write ticket marker in $dir: resolver context missing" >&2
    return 1
  fi
  _at_memo_clear
  if ! active_ticket_gitdir "$dir"; then
    echo "apexyard: cannot write ticket marker in $dir: ${AT_REASON:-git dir failed validation}" >&2
    return 1
  fi
  G="$REPLY"
  if [[ ! $repo =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "apexyard: cannot write ticket marker in $G: repo must be an owner/repo slug" >&2
    return 1
  fi
  # The marker must name a repo of the tree it lands in, or the lookup would
  # let it cover edits that the old resolution blocks.
  if ! _at_bound "$repo"; then
    if [ -n "$AT_PROJECT" ]; then
      echo "apexyard: cannot write ticket marker in $G: $repo is not a repo of project $AT_PROJECT. Run /start-ticket in that project's clone." >&2
    else
      echo "apexyard: cannot write ticket marker in $G: $repo belongs to a registered project, or the registry cannot be read. Run /start-ticket in that project's clone." >&2
    fi
    return 1
  fi
  if [[ ! $num =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "apexyard: cannot write ticket marker in $G: number must be a ticket id" >&2
    return 1
  fi
  title="${title//$'\r'/ }"; title="${title//$'\n'/ }"
  url="${url//$'\r'/ }"; url="${url//$'\n'/ }"
  branch="${branch//$'\r'/ }"; branch="${branch//$'\n'/ }"
  if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
    TZ=UTC printf -v ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  else
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  hint=" The sandbox may deny writes to the git dir. See AgDR-0222 for the allowlist."
  tmp=$(mktemp "$G/apexyard-ticket.tmp.XXXXXX" 2>/dev/null) || {
    echo "apexyard: cannot write ticket marker in $G: mktemp failed.$hint" >&2
    return 1
  }
  if [ -L "$tmp" ]; then
    rm -f "$tmp"
    echo "apexyard: cannot write ticket marker in $G: temporary file is a symlink" >&2
    return 1
  fi
  {
    printf 'repo=%s\n' "$repo"
    printf 'number=%s\n' "$num"
    printf 'title=%s\n' "$title"
    printf 'url=%s\n' "$url"
    printf 'suggested_branch=%s\n' "$branch"
    printf 'started_at=%s\n' "$ts"
  } > "$tmp" 2>/dev/null || {
    rm -f "$tmp"
    echo "apexyard: cannot write ticket marker in $G: write failed.$hint" >&2
    return 1
  }
  # mv would move the temporary file into a directory of that name and report
  # success, so refuse anything that is not a regular file.
  if [ -e "$G/apexyard-ticket" ] && [ ! -f "$G/apexyard-ticket" ]; then
    rm -f "$tmp"
    echo "apexyard: cannot write ticket marker in $G: apexyard-ticket exists and is not a regular file" >&2
    return 1
  fi
  if ! chmod 0644 "$tmp" 2>/dev/null || ! mv -f "$tmp" "$G/apexyard-ticket" 2>/dev/null; then
    rm -f "$tmp"
    echo "apexyard: cannot write ticket marker in $G: chmod or mv failed.$hint" >&2
    return 1
  fi
  REPLY="$G/apexyard-ticket"
  return 0
}

# The old-layout writer. During the transition /start-ticket and /fan-out
# write the old marker too, so a hook from before the move (after a rollback,
# or in a session that still runs the old hooks) sees the ticket. The path is
# the one the old /start-ticket chose:
#
#   tickets/<project>/<safe-branch>   the repo is registered, linked worktree
#   tickets/<project>                 the repo is registered
#   current-ticket                    otherwise
#
# <project> is the first registry entry whose repo: value equals <repo>. The
# worktree test is the old one: CLAUDE_WORKTREE_BRANCH, else git reports a
# linked worktree for <dir>. Prints a one-line note to stderr and returns 1
# when it cannot write. It never removes a file.
# REPLY is the old-layout marker path that the old /start-ticket would write
# for <repo> from the tree at <dir>. See active_ticket_write_legacy.
active_ticket_legacy_path() {
  local dir="$1" repo="$2" home project="" wt="" gd gcd
  REPLY=""
  AT_LEGACY_KIND=""
  if ! active_ticket_init "$dir"; then
    echo "apexyard: old-layout marker not written: no ops root for $dir" >&2
    return 1
  fi
  home="${_AT_HOME:-$_AT_OPS}"
  _at_fill_reg
  if [ -n "$_AT_REG" ]; then
    _at_reg_scan "" "$repo" || true
    project="$AT_REG_NAME_FOR_REPO"
  fi
  case "$project" in
    */*|.|..) project="" ;;
  esac
  if [ -n "$project" ]; then
    wt="${CLAUDE_WORKTREE_BRANCH:-}"
    if [ -z "$wt" ]; then
      gd=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)
      gcd=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
      if [ -n "$gd" ] && [ "$gd" != "$gcd" ]; then
        wt=$(git -C "$dir" branch --show-current 2>/dev/null)
      fi
    fi
    if [ -n "$wt" ]; then
      REPLY="$home/.claude/session/tickets/$project/${wt//\//__}"
      AT_LEGACY_KIND=worktree
    else
      REPLY="$home/.claude/session/tickets/$project"
      AT_LEGACY_KIND=project
    fi
  else
    REPLY="$home/.claude/session/current-ticket"
    AT_LEGACY_KIND=session
  fi
  return 0
}

# REPLY holds every old-layout marker file under <home>/.claude/session/, one
# path per line: current-ticket, each tickets/<name> file and each
# tickets/<name>/<branch> file. A reader that only adds blocks uses this to see
# every ticket the old layout knew about. Builtins only.
active_ticket_legacy_markers() {
  local home="${_AT_HOME:-$_AT_OPS}" f out=""
  REPLY=""
  [ -n "$home" ] || return 1
  for f in "$home/.claude/session/current-ticket" "$home/.claude/session/tickets"/* "$home/.claude/session/tickets"/*/*; do
    [ -f "$f" ] || continue
    out="$out$f"$'\n'
  done
  REPLY="$out"
  [ -n "$out" ]
}

# REPLY is the session-level old-layout marker path, for messages.
active_ticket_legacy_fallback() {
  REPLY="${_AT_HOME:-${_AT_OPS:-.}}/.claude/session/current-ticket"
}

active_ticket_write_legacy() {
  local dir="$1" repo="$2" num="$3" title="$4" url="$5" branch="$6"
  local marker parent tmp ts=""
  if [[ ! $repo =~ ^[A-Za-z0-9._/-]+$ ]] || [[ ! $num =~ ^#?[A-Za-z0-9_-]+$ ]]; then
    echo "apexyard: old-layout marker not written: repo or number has an unexpected shape" >&2
    return 1
  fi
  active_ticket_legacy_path "$dir" "$repo" || return 1
  marker="$REPLY"
  parent="${marker%/*}"
  if [ -e "$parent" ] && [ ! -d "$parent" ]; then
    echo "apexyard: old-layout marker not written: $parent is a file, and the per-worktree marker needs a directory there" >&2
    return 1
  fi
  if [ -L "$marker" ] || { [ -e "$marker" ] && [ ! -f "$marker" ]; }; then
    echo "apexyard: old-layout marker not written: $marker exists and is not a regular file" >&2
    return 1
  fi
  if ! mkdir -p "$parent" 2>/dev/null; then
    echo "apexyard: old-layout marker not written: cannot create $parent" >&2
    return 1
  fi
  title="${title//$'\r'/ }"; title="${title//$'\n'/ }"
  url="${url//$'\r'/ }"; url="${url//$'\n'/ }"
  branch="${branch//$'\r'/ }"; branch="${branch//$'\n'/ }"
  if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
    TZ=UTC printf -v ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  else
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  tmp=$(mktemp "$parent/.apexyard-ticket.tmp.XXXXXX" 2>/dev/null) || {
    echo "apexyard: old-layout marker not written: mktemp failed in $parent" >&2
    return 1
  }
  if ! {
    printf 'repo=%s\n' "$repo"
    printf 'number=%s\n' "${num#\#}"
    printf 'title=%s\n' "$title"
    printf 'url=%s\n' "$url"
    printf 'suggested_branch=%s\n' "$branch"
    printf 'started_at=%s\n' "$ts"
  } > "$tmp" 2>/dev/null || ! chmod 0644 "$tmp" 2>/dev/null || ! mv -f "$tmp" "$marker" 2>/dev/null; then
    rm -f "$tmp"
    echo "apexyard: old-layout marker not written: write failed for $marker" >&2
    return 1
  fi
  REPLY="$marker"
  return 0
}

# active_ticket_pending_path <ops_root>: prints the path of the ticket fields
# file for this session, <ops>/.claude/session/start-ticket-<id>.pending, and
# sets REPLY to it. The id is CLAUDE_CODE_SESSION_ID with every character
# outside [A-Za-z0-9_-] removed. Each session has its own file, so two
# sessions that run /start-ticket at the same time cannot read each other's
# fields. Without a session id, the id is built from the process id and a
# random number. A second call then gives another path, so the caller passes
# the printed path on instead of calling this again.
active_ticket_pending_path() {
  local sid="${CLAUDE_CODE_SESSION_ID:-}"
  sid="${sid//[!A-Za-z0-9_-]/}"
  [ -n "$sid" ] || sid="nosession-$$-$RANDOM"
  REPLY="${1%/}/.claude/session/start-ticket-${sid}.pending"
  printf '%s\n' "$REPLY"
}

# active_ticket_write_from_file <tree> <file>: /start-ticket writes the ticket
# fields to <file> with the Write tool, one key=value line each (repo, number,
# title, url, suggested_branch), and then runs this with paths only. The issue
# title never reaches a command line, so a title with shell syntax in it
# cannot look like a write to the Bash write detector. Writes the marker into
# the tree's git dir when the tree validates, and always the old-layout
# marker. Returns 0 when at least one marker was written.
#
# <file> must be a start-ticket-<id>.pending file in a .claude/session
# directory, as active_ticket_pending_path names it. Any other path is
# refused and left in place, so this function never deletes an unrelated
# file. A file with that name is deleted after it is read, or when it is a
# symlink.
active_ticket_write_from_file() {
  local dir="$1" f="$2" l repo="" num="" title="" url="" branch="" wrote=1 id=""
  case "$f" in
    */.claude/session/start-ticket-*.pending)
      id="${f##*/start-ticket-}"
      id="${id%.pending}"
      case "$id" in
        *[!A-Za-z0-9_-]*) id="" ;;
      esac
      ;;
  esac
  if [ -z "$id" ]; then
    echo "apexyard: ticket fields not read: $f is not a start-ticket-<id>.pending file in .claude/session" >&2
    return 1
  fi
  if [ -L "$f" ] || [ ! -f "$f" ]; then
    echo "apexyard: ticket fields not read: $f is missing or is not a regular file" >&2
    [ -L "$f" ] && rm -f "$f"
    return 1
  fi
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l%$'\r'}"
    case "$l" in
      repo=*) [ -n "$repo" ] || repo="${l#repo=}" ;;
      number=*) [ -n "$num" ] || num="${l#number=}" ;;
      title=*) [ -n "$title" ] || title="${l#title=}" ;;
      url=*) [ -n "$url" ] || url="${l#url=}" ;;
      suggested_branch=*) [ -n "$branch" ] || branch="${l#suggested_branch=}" ;;
    esac
  done < "$f"
  rm -f "$f"
  if [ -z "$repo" ] || [ -z "$num" ]; then
    echo "apexyard: ticket fields not read: $f has no repo= or number= line" >&2
    return 1
  fi
  active_ticket_init "$dir" || true
  if active_ticket_gitdir "$dir"; then
    active_ticket_write "$dir" "$repo" "$num" "$title" "$url" "$branch" && wrote=0
  else
    echo "note: $dir failed validation (${AT_REASON:-unknown}). Only the old-layout marker is written." >&2
  fi
  active_ticket_write_legacy "$dir" "$repo" "$num" "$title" "$url" "$branch" && wrote=0
  return "$wrote"
}

# ---------------------------------------------------------------------------
# Path helpers for display only (project name for a path). They use the
# old-layout resolution and fork like it. They do not decide which marker
# governs a path.
# ---------------------------------------------------------------------------

active_ticket_resolve_path() {
  _atd_resolve_path "$1"
  printf '%s' "$REPLY"
}

active_ticket_project_for_path() {
  _atd_resolve_path "$1"
  [ -n "$REPLY" ] || return 0
  _atd_project_for_resolved_path "$REPLY"
  printf '%s' "$REPLY"
}
