#!/bin/bash
# Shared git global-option matcher for the dispatcher and the commit/push gates.
#
# dispatch-bash.sh already routes `git -C <dir> commit` and `git -c name=value
# push` (#1527). The gates used to require the verb in the next word after
# `git`, so those forms skipped the check (#1730, #1731).
#
# Presence checks stay on the raw command. Do not strip quotes or heredoc
# bodies before asking whether a commit or push is present (AgDR-0113).
#
# Not a hook. Hooks source this file.

if [ -n "${_LIB_GIT_GLOBAL_LOADED:-}" ]; then
  return 0
fi
_LIB_GIT_GLOBAL_LOADED=1

# Share this expression with the dispatcher and the gates.
_git_opt_val='("[^"]*"|'"'"'[^'"'"']*'"'"'|\$\([^)]*\)|`[^`]*`|[^[:space:];&|"'"'"']+)+'
_git_sub_re='(^|[^[:alnum:]_.-])git([[:space:]]+((-[Cc]|--(git-dir|work-tree|namespace|super-prefix|config-env))[[:space:]]+'"${_git_opt_val}"'|--(git-dir|work-tree|namespace|super-prefix|config-env)='"${_git_opt_val}"'|--?[A-Za-z][A-Za-z-]*(=[^[:space:];&|]+)?))*[[:space:]]+'

# Regex for `git [global options] <sub>` on raw text.
# The match may include one leading boundary character.
git_subcommand_re() {
  printf '%s%s([^[:alnum:]_.-]|$)' "$_git_sub_re" "$1"
}

# One push invocation, including global options, through the first separator.
# The match may include one leading boundary character.
git_push_segment_re() {
  printf '%s%s([^|;&[:alnum:]_.-][^|;&]*)?' "$_git_sub_re" "push"
}

# 0 when the raw command contains `git [global options] <sub>`.
command_has_git_subcommand() {
  printf '%s\n' "$1" | LC_ALL=C grep -qE "$(git_subcommand_re "$2")"
}

# JSON-string pattern for raw_payload_command_matches.
# Stays inside a JSON string. Covers the same global-option forms.
git_subcommand_payload_pattern() {
  local sub="$1"
  printf '%s' 'git([[:space:]]+((-[Cc]|--(git-dir|work-tree|namespace|super-prefix|config-env))[[:space:]]+(\\.|[^"\\[:space:]])+|--?[A-Za-z][A-Za-z-]*(=(\\.|[^"\\[:space:]])+)?))*[[:space:]]+'"$sub"'([^[:alnum:]_.-]|$)'
}

# 2 when the token takes the next token as its value.
# 1 when the token is one global option.
# 0 when the token is not a global option.
git_global_option_width() {
  case "$1" in
    -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env)
      printf '2'
      ;;
    --*|-?)
      printf '1'
      ;;
    *)
      printf '0'
      ;;
  esac
}

# Read one shell word from $_GIT_SCAN into $_GIT_TAKEN.
# Quoted words keep their contents and lose the quotes.
_git_take_value() {
  _GIT_SCAN="${_GIT_SCAN#"${_GIT_SCAN%%[![:space:]]*}"}"
  local original="$_GIT_SCAN" char quote="" taken="" i
  for ((i=0; i<${#_GIT_SCAN}; i++)); do
    char="${_GIT_SCAN:i:1}"
    if [ -n "$quote" ]; then
      if [ "$char" = "$quote" ]; then quote=""; else taken+="$char"; fi
      continue
    fi
    case "$char" in
      \"|\') quote="$char" ;;
      [[:space:]]|';'|'&'|'|') break ;;
      *) taken+="$char" ;;
    esac
  done
  [ -z "$quote" ] || return 1
  _GIT_SCAN="${_GIT_SCAN:i}"
  _GIT_TAKEN="$taken"
  case "$original" in
    \"*|\'*)
      # shellcheck disable=SC2088
      case "$_GIT_TAKEN" in
        '~'|'~/'*) _GIT_TAKEN="./$_GIT_TAKEN" ;;
      esac
      ;;
  esac
  [ -n "$_GIT_TAKEN" ]
}

# Consume one global option from $_GIT_SCAN.
# Record each -C and the last --git-dir and --work-tree values.
_git_take_global() {
  local name
  case "$_GIT_SCAN" in
    -C[[:space:]]*)
      _GIT_SCAN="${_GIT_SCAN:2}"
      _git_take_value || return 1
      _GIT_RAW_DASH_C="$_GIT_TAKEN"
      _GIT_RAW_C_CHAIN+=("$_GIT_TAKEN")
      ;;
    -c[[:space:]]*)
      _GIT_SCAN="${_GIT_SCAN:2}"
      _git_take_value || return 1
      ;;
    --git-dir[[:space:]]*|--work-tree[[:space:]]*|--namespace[[:space:]]*|--super-prefix[[:space:]]*|--config-env[[:space:]]*)
      name="${_GIT_SCAN%%[[:space:]]*}"
      _GIT_SCAN="${_GIT_SCAN#"$name"}"
      _git_take_value || return 1
      case "$name" in
        --git-dir) _GIT_RAW_GIT_DIR="$_GIT_TAKEN" ;;
        --work-tree) _GIT_RAW_WORK_TREE="$_GIT_TAKEN" ;;
      esac
      ;;
    --git-dir=*|--work-tree=*|--namespace=*|--super-prefix=*|--config-env=*)
      name="${_GIT_SCAN%%=*}"
      _GIT_SCAN="${_GIT_SCAN#"$name="}"
      _git_take_value || return 1
      # Keep a tilde literal after an option's equals sign.
      # shellcheck disable=SC2088
      case "$_GIT_TAKEN" in
        '~'*) _GIT_TAKEN="./$_GIT_TAKEN" ;;
      esac
      case "$name" in
        --git-dir) _GIT_RAW_GIT_DIR="$_GIT_TAKEN" ;;
        --work-tree) _GIT_RAW_WORK_TREE="$_GIT_TAKEN" ;;
      esac
      ;;
    --*|-*)
      _git_take_value || return 1
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# Walk global options in $_GIT_SCAN until <sub>.
# On success, $_GIT_SCAN is the text after that subcommand.
_git_scan_globals() {
  local sub="$1"
  _GIT_RAW_C_CHAIN=()
  _GIT_RAW_DASH_C=""
  _GIT_RAW_GIT_DIR=""
  _GIT_RAW_WORK_TREE=""
  while [ -n "$_GIT_SCAN" ]; do
    _GIT_SCAN="${_GIT_SCAN#"${_GIT_SCAN%%[![:space:]]*}"}"
    [ -n "$_GIT_SCAN" ] || break
    case "$_GIT_SCAN" in
      "$sub"|"$sub"[[:space:]]*|"$sub"[^[:alnum:]_.-]*)
        _GIT_SCAN="${_GIT_SCAN#"$sub"}"
        return 0
        ;;
    esac
    _git_take_global || return 1
  done
  return 1
}

# Load the selected invocation. Use the first match for direct helper calls.
_git_load_invocation() {
  local cmd="$1" sub="$2" inv
  _GIT_RAW_C_CHAIN=()
  _GIT_RAW_DASH_C=""
  _GIT_RAW_GIT_DIR=""
  _GIT_RAW_WORK_TREE=""
  if [ "${_GIT_VISIT_SUB:-}" = "$sub" ]; then
    inv="$_GIT_VISIT_PREFIX"
  else
    inv=$(printf '%s\n' "$cmd" | LC_ALL=C grep -oE "$(git_subcommand_re "$sub")" | head -1) || true
  fi
  [ -n "$inv" ] || return 1
  case "$inv" in
    git*) ;;
    *) inv="${inv#?}" ;;
  esac
  _GIT_SCAN="${inv#git}"
  _git_scan_globals "$sub"
}

# Print the raw -C value bound to the first <sub> invocation.
# Empty when that invocation has no -C. Does not resolve a relative path.
git_invocation_dash_c() {
  _git_load_invocation "$1" "$2" || true
  printf '%s' "${_GIT_RAW_DASH_C:-}"
}

# Print the argument text after `git [global options] push` in one segment.
git_push_args() {
  local segment="$1"
  case "$segment" in
    git*) ;;
    *) segment="${segment#?}" ;;
  esac
  _GIT_SCAN="${segment#git}"
  if _git_scan_globals push; then
    printf '%s' "$_GIT_SCAN"
  fi
}

# Resolve a literal path. Do not evaluate shell substitutions.
_git_resolve_dir() {
  local dir="$1" cwd="${2:-$PWD}"
  # shellcheck disable=SC2088
  case "$dir" in
    *'$'*|*'`'*|*'\\'*|*'"'*|*"'"*) return 1 ;;
    '~') dir="$HOME" ;;
    '~/'*) dir="$HOME/${dir#??}" ;;
    '~'*) return 1 ;;
  esac
  case "$dir" in
    /*) ;;
    *) dir="${cwd%/}/$dir" ;;
  esac
  printf '%s' "$dir"
}

# Print chain segments. Keep separators inside quotes in the same segment.
_git_chain_segments() {
  local text="$1" part="" quote="" char i escaped=0
  for ((i=0; i<${#text}; i++)); do
    char="${text:i:1}"
    if [ "$escaped" -eq 1 ]; then
      part+="$char"
      escaped=0
      continue
    fi
    if [ "$char" = "\\" ] && [ "$quote" != "'" ]; then
      part+="$char"
      escaped=1
      continue
    fi
    if [ -n "$quote" ]; then
      part+="$char"
      [ "$char" != "$quote" ] || quote=""
      continue
    fi
    case "$char" in
      \"|\') quote="$char"; part+="$char" ;;
      '&')
        # Redirection ampersands stay inside the command segment.
        if [[ "${part: -1}" = '>' || "${part: -1}" = '<' || "${text:i+1:1}" = '>' ]]; then
          part+="$char"
          continue
        fi
        if [ "${text:i+1:1}" = '&' ]; then
          i=$((i + 1))
        else
          part+=' __git_background__'
        fi
        printf '%s\n' "$part"; part="" ;;
      ';'|$'\n') printf '%s\n' "$part"; part="" ;;
      *) part+="$char" ;;
    esac
  done
  printf '%s\n' "$part"
}

# Track literal cd commands before the selected invocation.
# Reject unresolved targets without executing command text.
_git_chain_cwd() {
  local cmd="$1" sub="$2" base="$3" segment path next changed=0 match remaining=1
  local segments matches prefix unquoted tail
  if [ "${_GIT_VISIT_SUB:-}" = "$sub" ]; then
    remaining="${_GIT_VISIT_INDEX:-1}"
  fi
  _GIT_CHAIN_CWD="$base"
  _GIT_CHAIN_CHANGED=0
  # Capture first. A POSIX-sourced lib must not use process substitution.
  # Read from fd 3 to keep commands from consuming the segment list.
  segments=$(_git_chain_segments "$cmd")
  while IFS= read -r segment <&3; do
    segment="${segment#"${segment%%[![:space:]]*}"}"
    prefix="$segment"
    matches=$(git_invocation_prefixes "$segment" "$sub")
    if [ -n "$matches" ]; then
      match="${matches%%$'\n'*}"
      prefix="${segment%%"$match"*}"
    fi
    # Remove quoted text before the directory-command check.
    unquoted=$(printf '%s\n' "$prefix" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")
    case "$segment" in
      cd|cd[[:space:]]*)
        _GIT_SCAN="${segment#cd}"
        if [ -z "${_GIT_SCAN//[[:space:]]/}" ]; then
          path="$HOME"
        else
          _git_take_value || return 1
          path="$_GIT_TAKEN"
        fi
        if [ "$path" = -- ]; then
          _git_take_value || return 1
          path="$_GIT_TAKEN"
        fi
        tail="${_GIT_SCAN#"${_GIT_SCAN%%[![:space:]]*}"}"
        if [ -n "$tail" ]; then
          printf '%s\n' "$tail" | grep -qE '^\|\|[[:space:]]*(exit|return)([[:space:]]+[0-9]+)?[[:space:]]*$' || return 1
        fi
        next=$(_git_resolve_dir "$path" "$_GIT_CHAIN_CWD") || return 1
        next=$(cd "$next" 2>/dev/null && pwd -P) || return 1
        changed=1
        _GIT_CHAIN_CWD="$next"
        ;;
      *)
        if printf '%s\n' "$unquoted" | grep -qE '(^|[^[:alnum:]_. /-])(cd|pushd|popd)([^[:alnum:]_.-]|$)|(^|[[:space:]])(cd|pushd|popd)([[:space:]]|$)'; then
          return 1
        fi
        ;;
    esac
    case "$prefix" in
      *__git_background__*) return 1 ;;
    esac
    matches=$(git_invocation_prefixes "$segment" "$sub")
    while IFS= read -r match <&3; do
      [ -n "$match" ] || continue
      remaining=$((remaining - 1))
    done 3<<EOF
$matches
EOF
    [ "$remaining" -gt 0 ] || break
  done 3<<EOF
$segments
EOF
  _GIT_CHAIN_CHANGED="$changed"
}

# Resolve cd, then each -C, then repository paths for the selected invocation.
git_prepare_invocation() {
  local cmd="$1" sub="$2" cwd="${3:-$PWD}" dir raw base
  GIT_REPLAY_ARGS=()
  GIT_DASH_C=""
  _git_load_invocation "$cmd" "$sub" || return 1
  _GIT_TARGET_KIND="cd"
  _git_chain_cwd "$cmd" "$sub" "${cwd:-$PWD}" || return 1
  _GIT_TARGET_KIND="git -C"
  base="$_GIT_CHAIN_CWD"
  cwd="$base"
  if [ "$_GIT_CHAIN_CHANGED" -eq 1 ]; then
    GIT_DASH_C="$base"
  fi
  for raw in ${_GIT_RAW_C_CHAIN[@]+"${_GIT_RAW_C_CHAIN[@]}"}; do
    dir=$(_git_resolve_dir "$raw" "$base") || return 1
    GIT_DASH_C="$dir"
    base="$dir"
    if [ "${_GIT_VALIDATE_TARGET:-0}" -eq 1 ]; then
      [ -d "$base" ] || return 1
    fi
  done
  if [ -n "$GIT_DASH_C" ]; then
    GIT_REPLAY_ARGS+=(-C "$GIT_DASH_C")
  elif [ -n "$cwd" ]; then
    GIT_REPLAY_ARGS+=(-C "$cwd")
  fi
  if [ -n "${_GIT_RAW_GIT_DIR:-}" ]; then
    dir=$(_git_resolve_dir "$_GIT_RAW_GIT_DIR" "$base") || return 1
    GIT_REPLAY_ARGS+=(--git-dir="$dir")
  fi
  if [ -n "${_GIT_RAW_WORK_TREE:-}" ]; then
    dir=$(_git_resolve_dir "$_GIT_RAW_WORK_TREE" "$base") || return 1
    GIT_REPLAY_ARGS+=(--work-tree="$dir")
  fi
  if [ "$_GIT_CHAIN_CHANGED" -eq 1 ]; then
    if [ "${#_GIT_RAW_C_CHAIN[@]}" -eq 0 ] &&
       [ -z "${_GIT_RAW_GIT_DIR:-}${_GIT_RAW_WORK_TREE:-}" ]; then
      _GIT_TARGET_KIND="cd"
    fi
    git_target rev-parse --git-dir >/dev/null 2>&1 || return 1
  fi
  return 0
}

# Preserve the trailing boundary for the next match.
git_invocation_prefixes() {
  local rest="$1" sub="$2" match tail
  while :; do
    match=$(printf '%s\n' "$rest" | LC_ALL=C grep -oE "$(git_subcommand_re "$sub")" | head -1) || true
    [ -n "$match" ] || break
    printf '%s\n' "$match"
    tail="${rest#*"$match"}"
    case "$match" in
      *"$sub") rest="$tail" ;;
      *) rest="${match: -1}$tail" ;;
    esac
    [ -n "$rest" ] || break
  done
}

# Check each raw invocation in a separate subshell. Keep the full command.
# Resolve the cd chain separately for each selected invocation.
git_visit_invocations() {
  local callback="$1" mode="$2" input="$3"
  shift 3
  local cmd cwd sub prefix rc count=0 arg index
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
  cwd=$(printf '%s' "$input" | jq -r '.cwd // .tool_input.cwd // empty' 2>/dev/null)
  local prefixes
  for sub in "$@"; do
    # Capture first. A POSIX-sourced lib must not use process substitution.
    prefixes=$(git_invocation_prefixes "$cmd" "$sub")
    index=0
    while IFS= read -r prefix; do
      [ -n "$prefix" ] || continue
      count=$((count + 1))
      index=$((index + 1))
      (
        _GIT_VALIDATE_TARGET=1
        _GIT_VISIT_INDEX="$index"
        _GIT_VISIT_SUB="$sub"
        _GIT_VISIT_PREFIX="$prefix"
        if ! git_prepare_invocation "$cmd" "$sub" "$cwd"; then
          if [ "$mode" = block ]; then
            echo "BLOCKED: cannot resolve the ${_GIT_TARGET_KIND:-git -C} target; use a literal path" >&2
            exit 2
          fi
          exit 0
        fi
        for arg in "${GIT_REPLAY_ARGS[@]}"; do
          case "$arg" in
            -C) continue ;;
            --git-dir=*|--work-tree=*) arg="${arg#*=}" ;;
          esac
          if [ ! -d "$arg" ]; then
            if [ "$mode" = block ]; then
              echo "BLOCKED: cannot resolve the ${_GIT_TARGET_KIND:-git -C} target; use a literal path" >&2
              exit 2
            fi
            exit 0
          fi
        done
        "$callback"
      ) </dev/null
      rc=$?
      if [ "$mode" = block ] && [ "$rc" -ne 0 ]; then
        return "$rc"
      fi
    done <<EOF
$prefixes
EOF
  done
  if [ "$count" -eq 0 ]; then
    ( "$callback" )
    return $?
  fi
  return 0
}

# Run git in the repository selected by git_prepare_invocation.
# Call plain git, as the gates did before. A caller can then replace git
# with a shell function, as the /scaffold scan shim does.
git_target() {
  case "${1:-}" in
    diff|log)
      local verb="$1"
      shift
      set -- -c core.fsmonitor=false "$verb" --no-ext-diff --no-textconv "$@"
      ;;
  esac
  if [ "${#GIT_REPLAY_ARGS[@]}" -gt 0 ]; then
    git "${GIT_REPLAY_ARGS[@]}" "$@"
  else
    git "$@"
  fi
}

true
