#!/bin/bash
# Edit CLASS: CONTROL. Bash CLASS: BACKSTOP. Applies to every caller.
set -o pipefail
export LC_ALL=C
HOOK_DIR=$(cd "$(dirname "$0")" && pwd -P)
INPUT=$(cat)
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-fail-closed-json.sh" || exit 2
if ! command -v jq >/dev/null 2>&1 || ! jq -e 'type=="object"' >/dev/null 2>&1 <<<"$INPUT"; then
  if ! raw_payload_tool_matches "$INPUT" Bash || raw_payload_tool_matches "$INPUT" '(Edit|Write|MultiEdit|NotebookEdit)' || raw_payload_command_matches "$INPUT" '(>|tee|rm|mv|cp|sed|python|git|\.claude|ops-root-|CLAUDE_)'; then
    echo 'BLOCKED: cannot parse the protected-target check.' >&2; exit 2
  fi
  exit 0
fi
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-protected-state.sh" || exit 2
pt_init "$INPUT" || pt_block 'cannot read the session snapshot or the pin differs from it.'
PT_CWD=$(jq -r '.cwd // .tool_input.cwd // empty' <<<"$INPUT")
PT_CWD=${PT_CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}
PT_CWD=$(pt_physical "$PT_CWD") || pt_block 'cannot resolve the effective directory.'
PT_FALLBACK=${PT_OPS:-${PT_PROJECT:-$PT_CWD}}
tool=$(jq -r '.tool_name // "Bash"' <<<"$INPUT")
if [ "$tool" != Bash ]; then
  target=$(jq -er '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$INPUT") || pt_block 'missing edit target.'
  pt_protected "$target" && pt_block 'the edit target is live hook state. Use an isolated worktree.'
  exit 0
fi
cmd=$(jq -er '.tool_input.command' <<<"$INPUT") || pt_block 'missing Bash command.'
cwd="$PT_CWD"
# Each protected-form test ignores letter case (pt_nocase).
pt_token() { pt_nocase pt_token_nocase "$@"; }
pt_token_nocase() {
  local text="$1" token
  text=$(printf '%s' "$text" | sed -e 's://*:/:g' -e 's:/\./:/:g')
  for token in '.claude/settings.local.json' '.claude/settings.json' '.claude/hooks' "$PT_PIN_DIR/resolve-cache-" "$PT_PIN_DIR/projctx" '.claude/apexyard/resolve-cache-' '.claude/apexyard/projctx' APEXYARD_OPS_PIN_DIR ops-root- gate-session- CLAUDE_CONFIG_DIR CLAUDE_ENV_FILE session-env/ shell-snapshots/; do
    case "$text" in *"$token"*) return 0 ;; esac
  done
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then case "$text" in *"$CLAUDE_CONFIG_DIR"*) return 0 ;; esac; fi
  return 1
}
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-protected-shell-tokens.sh" || pt_block 'the shell tokenizer is missing.'
[ -n "${PT_TOKENS_AWK:-}" ] || pt_block 'the shell tokenizer is empty.'
# Remove only the named source operand occurrence from the token view.
PT_TOKEN_VIEW=$(printf '%s' "$cmd" | awk -v source_view=1 "$PT_TOKENS_AWK") || pt_block 'cannot parse sourced-library operands.'

pt_dir_is_sensitive() { pt_nocase pt_dir_is_sensitive_nocase "$@"; }
pt_dir_is_sensitive_nocase() {
  local root
  # Isolated worktrees live under .claude/worktrees. Hook work happens there
  # (AgDR-0261 D13), so they are not protected state. A live path that a
  # command names from a worktree is still judged as an operand.
  for root in ${PT_ROOTS[@]+"${PT_ROOTS[@]}"}; do case "$1" in "$root/.claude/worktrees"|"$root/.claude/worktrees/"*) ;; "$root/.claude"|"$root/.claude/"*) return 0 ;; esac; done
  # The pin tree is state only for the pin and gate state files (AgDR-0261,
  # #1858). Other files under it, such as private briefs, are not state.
  case "$1" in "$PT_PIN_DIR"|"$PT_PIN_DIR"/ops-root-*|"$PT_PIN_DIR"/gate-session-*|"$PT_PIN_DIR"/resolve-cache-*|"$PT_PIN_DIR"/projctx|"$PT_PIN_DIR"/projctx/*) return 0 ;; "$PT_PIN_DIR/"*) return 1 ;; esac
  for root in "$PT_USER" "$PT_HOME_CONFIG"; do case "$1" in "$root"|"$root/"*) return 0 ;; esac; done
  return 1
}
pt_in_sensitive_dir() {
  local dir
  pt_dir_is_sensitive "$PT_CWD" && return 0
  for dir in ${PT_ALTS[@]+"${PT_ALTS[@]}"}; do pt_dir_is_sensitive "$dir" && return 0; done
  if [ "${PT_OR_ACTIVE:-0}" = 1 ]; then
    for dir in ${PT_PENDING[@]+"${PT_PENDING[@]}"}; do pt_dir_is_sensitive "$dir" && return 0; done
  fi
  return 1
}
PT_RAW_TOKEN=0
pt_token "$PT_TOKEN_VIEW" && PT_RAW_TOKEN=1
pt_token_context() { [ "$PT_RAW_TOKEN" = 1 ] || pt_in_sensitive_dir; }
# Literal variable values from this command only. Never use eval.
PT_ASSIGN_NAMES=(); PT_ASSIGN_VALUES=()
PT_NAMES=(HOME CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR CLAUDE_CODE_SESSION_ID APEXYARD_OPS_PIN_DIR CLAUDE_ENV_FILE)
PT_VALUES=("$HOME" "${CLAUDE_PROJECT_DIR:-}" "${CLAUDE_CONFIG_DIR:-}" "${CLAUDE_CODE_SESSION_ID:-}" "${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}" "${CLAUDE_ENV_FILE:-}")
pt_expand() {
  local value="$1" n name old pass default
  # shellcheck disable=SC2088
  case "$value" in '~') value="$HOME" ;; '~/'*) value="$HOME/${value#\~/}" ;; esac
  # The one supported default expansion has a fixed variable name.
  if [[ "$value" == *'${APEXYARD_OPS_PIN_DIR:-'* ]]; then
    old=${value#*'${APEXYARD_OPS_PIN_DIR:-'}; default=${old%%\}*}
    old='${APEXYARD_OPS_PIN_DIR:-'"$default"'}'
    value=${value//"$old"/${APEXYARD_OPS_PIN_DIR:-$default}}
  fi
  # shellcheck disable=SC2034
  for pass in 1 2 3; do
    for n in "${!PT_NAMES[@]}"; do
      name=${PT_NAMES[$n]}
      old='${'"$name"'}'; value=${value//"$old"/${PT_VALUES[$n]}}
      # Expand a plain variable only at its name boundary.
      while [[ "$value" =~ \$([a-zA-Z_][a-zA-Z_0-9]*) ]]; do
        [ "${BASH_REMATCH[1]}" = "$name" ] || break
        old='$'"$name"; value=${value//"$old"/${PT_VALUES[$n]}}
        break
      done
    done
  done
  printf '%s' "$value"
}
# An unresolved operand that names protected state blocks.
pt_unresolved_nocase() {
  case "$1" in *settings.json*|*settings.local.json*|*.claude/hooks*|*.claude/apexyard*|*ops-root-*|*gate-session-*|*session-env/*|*shell-snapshots/*) pt_block 'unresolved protected operand.' ;; esac
  if [ "$2" = 1 ]; then case "$1" in */.claude) pt_block 'unresolved protected ancestor.' ;; esac; fi
  return 0
}
pt_judge() {
  local value role="${2:-0}" index name
  if [[ "$1" =~ ^\$\{?([a-zA-Z_][a-zA-Z_0-9]*)\}?$ ]]; then
    name=${BASH_REMATCH[1]}
    for index in "${!PT_ASSIGN_NAMES[@]}"; do
      if [ "${PT_ASSIGN_NAMES[$index]}" = "$name" ]; then
        case "${PT_ASSIGN_VALUES[$index]}" in *'$'*|*'`'*) pt_token "${PT_ASSIGN_VALUES[$index]}" && pt_block 'computed bare-variable target names protected state.' ;; esac
      fi
    done
  fi
  value=$(pt_expand "$1") || pt_block 'cannot expand a write operand.'
  [ -n "$value" ] || return 0
  case "$value" in *'$'*|*'`'*|*'{}'*)
    pt_nocase pt_unresolved_nocase "$value" "$role"
    case "$value" in *'{}'*) pt_token_context && pt_block 'unextractable protected operand.' ;; esac
    return 0 ;;
  esac
  pt_protected "$value" "$role" && pt_block "protected target: $value. Use Edit for a non-live file."
  return 0
}
if [ ! -r "$HOOK_DIR/_lib-detect-bash-write.sh" ]; then
  pt_token "$cmd" && pt_block 'write detector is missing.'
else
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-detect-bash-write.sh" || exit 2
fi
if [ -r "$HOOK_DIR/_lib-git-global.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-git-global.sh" || exit 2
  # Alias checks are narrowed to live roots in the command scanner below.
else
  case "$cmd" in *git*) pt_live "$PT_CWD" && pt_block 'git matcher is missing.' ;; esac
fi
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-command-scrub.sh" || exit 2
PT_SCRUBBED=$(scrub_bash_command "$cmd") || pt_block 'cannot scrub command.'
# The state directory is only a cache. The gate works without it.
PT_STATE_DIR=$(mktemp -d 2>/dev/null) || PT_STATE_DIR=""
[ -z "$PT_STATE_DIR" ] || trap 'rm -rf "$PT_STATE_DIR"' EXIT

pt_git() {
  local unresolved=0
  local i=1 arg verb tree="$PT_CWD" opts=0 first=1 raw="$cmd" gitcwd="$cwd"
  local -a paths=()
  while [ "$i" -lt "${#words[@]}" ]; do
    arg=${words[$i]}; i=$((i+1))
    case "$arg" in
      -C|--work-tree|--git-dir)
        arg=$(pt_expand "${words[$i]:-}"); i=$((i+1))
        case "$arg" in *'$'*|*'`'*) tree="$PT_FALLBACK"; unresolved=1 ;; *) case "$arg" in /*) tree="$arg" ;; *) tree="$tree/$arg" ;; esac ;; esac ;;
      --work-tree=*|--git-dir=*) arg=$(pt_expand "${arg#*=}"); case "$arg" in *'$'*) tree="$PT_FALLBACK"; unresolved=1 ;; /*) tree="$arg" ;; *) tree="$tree/$arg" ;; esac ;;
      -c|--config-env) i=$((i+1)) ;;
      -*) ;;
      *) verb="$arg"; break ;;
    esac
  done
  for arg in "${!PT_NAMES[@]}"; do
    case "${PT_NAMES[$arg]}" in GIT_WORK_TREE) tree=${PT_VALUES[$arg]} ;; GIT_DIR) tree=${PT_VALUES[$arg]%/.git} ;; esac
  done
  # The command is inspected before it runs. Reuse the same directory walk
  # for repeated git calls at one directory in this payload.
  if [ "$tree" = "${PT_GIT_TREE_KEY:-}" ]; then
    PT_CWD="$PT_GIT_TREE_CWD"; tree="$PT_GIT_TREE_ROOT"
  else
    PT_GIT_TREE_KEY="$tree"
    PT_CWD=$(pt_physical "$tree") || PT_CWD="$PT_FALLBACK"
    tree="$PT_CWD"
    while [ "$tree" != / ] && [ ! -e "$tree/.git" ]; do tree=$(dirname "$tree"); done
    PT_GIT_TREE_CWD="$PT_CWD"; PT_GIT_TREE_ROOT="$tree"
  fi
  case "$PT_CWD" in *'$'*) tree="$PT_FALLBACK"; PT_CWD="$tree" ;; esac
  if pt_live "$tree"; then
    cwd="$PT_CWD"; cmd="$raw"
    if declare -F git_alias_check >/dev/null; then
      # The check reads every git call in the whole command. Run it once for
      # each directory. A flag file keeps the result across subshell scopes.
      # Without a state directory, run the check on each call.
      local alias_key=""
      [ -z "$PT_STATE_DIR" ] || alias_key="$PT_STATE_DIR/alias-${PT_CWD//\//%}"
      if [ -z "$alias_key" ] || [ ! -e "$alias_key" ]; then
        git_alias_check checkout restore apply am checkout-index read-tree || exit 2
        [ -z "$alias_key" ] || : > "$alias_key" 2>/dev/null || true
      fi
    else pt_block 'git alias matcher is missing.'; fi
    cmd="$raw"; cwd="$gitcwd"
  fi
  if [ "$unresolved" = 1 ]; then
    case "${verb:-}" in checkout|restore|apply|am|checkout-index|read-tree) pt_block 'non-literal git work tree.' ;; esac
  fi
  case "${verb:-}" in
    apply)
      for arg in "${words[@]}"; do [ "$arg" != --unsafe-paths ] || pt_block 'git apply --unsafe-paths is not safe.'; done
      for arg in "${words[@]}"; do case "$arg" in --check|--stat) return 0 ;; esac; done
      pt_live "$tree" && pt_block 'patch application in a live root.'; return 0 ;;
    am|checkout-index) pt_live "$tree" && pt_block 'git writes a live root.'; return 0 ;;
    read-tree) for arg in "${words[@]}"; do [ "$arg" != -u ] || { pt_live "$tree" && pt_block 'read-tree writes a live root.'; }; done; return 0 ;;
    rm|mv) pt_operands "git $verb" "$i"; return 0 ;;
    checkout|restore) ;;
    log|show|diff|blame|ls-files|status) return 0 ;;
    archive)
      while [ "$i" -lt "${#words[@]}" ]; do
        arg=${words[$i]}; i=$((i+1))
        case "$arg" in -o|--output) pt_judge "${words[$i]:-}"; i=$((i+1)) ;; --output=*) pt_judge "${arg#*=}" ;; esac
      done
      return 0 ;;
    *)
      if pt_token_context; then
        for arg in "${words[@]:$i}"; do
          case "$arg" in -*) arg=${arg#*=}; [ "$arg" != "${arg#-}" ] && continue ;; esac
          pt_judge "$arg" 1
        done
      fi
      return 0 ;;
  esac
  while [ "$i" -lt "${#words[@]}" ]; do
    arg=${words[$i]}; i=$((i+1))
    if [ "$opts" = 0 ]; then
      case "$arg" in
        --) opts=1; continue ;;
        -b|-B|--orphan|-t|--track|-s|--source|--conflict) i=$((i+1)); continue ;;
        --pathspec-from-file*|--pathspec-file-nul) pt_live "$tree" && pt_block 'indirect live pathspec.'; continue ;;
        -*) continue ;;
      esac
    fi
    if [ "$verb" = checkout ] && [ "$opts" = 0 ] && [ "$first" = 1 ]; then
      first=0
      [ -e "$PT_CWD/$arg" ] || continue
    fi
    paths[${#paths[@]}]="$arg"
  done
  for arg in "${paths[@]}"; do
    if pt_live "$tree"; then case "$arg" in :*|*'*'*|*'?'*|*'['*) pt_block 'broad live pathspec.' ;; esac; fi
    pt_judge "$arg" 1
  done
  return 0
}
pt_operands() {
  local verb="$1" i="${2:-1}" arg target="" recursive=0 removing=0 dest role=0 inputs=() extract=0 cdirs=0 absolute=0 output="" in_place=0 tar_file=""
  while [ "$i" -lt "${#words[@]}" ]; do
    arg=${words[$i]}; i=$((i+1))
    case "$arg" in
      -t|--target-directory) target=${words[$i]:-}; i=$((i+1)); continue ;;
      --target-directory=*) target=${arg#*=}; continue ;;
      -d) if [ "$verb" = unzip ]; then target=${words[$i]:-}; i=$((i+1)); continue; fi ;;
      -C) if [ "$verb" = tar ]; then target=${words[$i]:-}; cdirs=$((cdirs+1)); i=$((i+1)); continue; fi ;;
      --remove-source-files|--remove-files) removing=1; continue ;;
      --absolute-names|-P) absolute=1; continue ;;
      -o|--output|-out) output=${words[$i]:-}; i=$((i+1)); continue ;;
      --output=*) output=${arg#*=}; continue ;;
      --file=*) [ "$verb" != tar ] || tar_file=${arg#*=}; continue ;;
      # Only tar takes a value after -f. For rm, cp and mv it is a plain flag.
      -f) if [ "$verb" = tar ]; then tar_file=${words[$i]:-}; i=$((i+1)); fi; continue ;;
      -e|--expression|-s|--size|-m|--mode|-in|-from|-to|-encoding|-name|-type)
        i=$((i+1)); continue ;;
      of=*) pt_judge "${arg#of=}"; continue ;;
      if=*) continue ;;
      -*)
        case "$arg" in -*[Rra]*) case "$verb" in cp|rsync) recursive=1 ;; esac ;; esac
        case "$arg" in -*f*) if [ "$verb" = tar ]; then tar_file=${words[$i]:-}; i=$((i+1)); fi ;; esac
        case "$arg" in -*P*) [ "$verb" != tar ] || absolute=1 ;; esac
        case "$arg" in -*x*) [ "$verb" != tar ] || extract=1 ;; esac
        case "$arg" in -*i*) in_place=1 ;; esac
        continue ;;
    esac
    inputs[${#inputs[@]}]="$arg"
  done
  [ -z "$output" ] || pt_judge "$output"
  case "$verb" in
    cp|mv|install|'git mv'|ln|link|rsync|ditto)
      [ "${#inputs[@]}" -gt 0 ] || return 0
      if [ -n "$target" ]; then dest="$target"; else dest=${inputs[${#inputs[@]}-1]}; unset 'inputs[${#inputs[@]}-1]'; fi
      case "$verb" in rsync|ditto) recursive=1 ;; ln|link) recursive=1 ;; esac
      if [ "$recursive" = 1 ]; then pt_judge "$dest" 1
      elif [ -n "$target" ] || [ -d "$(pt_expand "$dest")" ] || [ -d "$PT_CWD/$(pt_expand "$dest")" ]; then
        for arg in "${inputs[@]}"; do pt_judge "$dest/$(basename "$arg")"; done
      else pt_judge "$dest"; fi
      case "$verb" in mv|'git mv') removing=1 ;; esac
      if [ "$removing" = 1 ]; then for arg in "${inputs[@]}"; do pt_judge "$arg" 1; done; fi ;;
    tar)
      if [ "$extract" = 0 ] && [ -n "$tar_file" ]; then pt_judge "$tar_file"; fi
      if [ "$extract" = 1 ]; then
        if [ "$cdirs" = 1 ] && [ "$absolute" = 0 ]; then
          case "$target" in *'$'*|*'`'*) pt_token_context && pt_block 'unextractable archive destination.' ;; *) pt_judge "$target" 1 ;; esac
        else pt_token_context && pt_block 'unextractable archive write.'; fi
      elif [ "$removing" = 1 ]; then
        local tar_cwd="$PT_CWD"
        if [ -n "$target" ]; then
          target=$(pt_expand "$target")
          case "$target" in /*) PT_CWD="$target" ;; *'$'*|*'`'*) PT_CWD="$PT_FALLBACK" ;; *) PT_CWD="$PT_CWD/$target" ;; esac
        fi
        for arg in "${inputs[@]}"; do pt_judge "$arg" 1; done
        PT_CWD="$tar_cwd"
      fi ;;
    unzip) pt_judge "${target:-$PT_CWD}" 1 ;;
    cpio|pax) case "$segment" in *-i*|*-r*) pt_judge "$PT_CWD" 1 ;; esac ;;
    rm|rmdir|unlink|shred|'git rm'|chmod|chown|chgrp|chflags|chattr|xattr|setfacl)
      if [ "$verb" = xattr ]; then
        case " ${words[*]} " in *' -w '*|*' -d '*|*' -c '*|*' -cr '*) ;; *) return 0 ;; esac
      fi
      for arg in "${inputs[@]}"; do pt_judge "$arg" 1; done ;;
    perl|ruby|sed|gsed)
      [ "$in_place" = 1 ] || return 0
      for arg in "${inputs[@]}"; do pt_judge "$arg"; done ;;
    base64|openssl|iconv|uudecode) ;;
    plutil)
      [ -z "$output" ] || return 0
      case " ${words[*]} " in *' -convert ') ;; *' -convert '*|*' -insert '*|*' -remove '*|*' -replace '*) for arg in "${inputs[@]}"; do pt_judge "$arg"; done ;; esac ;;
    *) for arg in "${inputs[@]}"; do pt_judge "$arg"; done ;;
  esac
  return 0
}
pt_state_writer_nocase() {
  local val="$2"
  case "$1" in pin-ops-root.sh|write-session-snapshot.sh|record-subagent-start.sh|dispatch-session-start.sh)
    case "$val" in ''|*'$'*|*'`'*) pt_block 'state writers are harness-only.' ;; esac
    pt_protected "$val" 1 && pt_block 'state writer sandbox is protected.'
    [[ "$(pt_physical "$val")" != "$PT_PIN_DIR" ]] || pt_block 'state writer sandbox is the live pin tree.' ;;
  esac
  return 0
}
pt_simple() {
  local segment="$1" word verb i start=0 savecwd="$PT_CWD" arg name val expanded sandbox_pin=""
  local -a words=() filtered=() redirect_slots=()
  local record kind operator skip=0 here_string="" capture_string=0 redirect_input="" capture_input=0
  local here_refs="${2:-}" ref body_id body_fd wanted_fd=0 selected_body=""
  # Operators have a separate token kind. A quoted ">" is an ordinary word.
  while IFS= read -r -d '' record; do
    kind=${record:0:1}; word=${record:1}
    case "$kind" in D|H|P|S|E) continue ;; esac
    if [ "$skip" = 1 ]; then
      [ "$capture_string" = 0 ] || here_string="$word"
      [ "$capture_input" = 0 ] || redirect_input="$word"
      capture_input=0; capture_string=0; skip=0; continue
    fi
    if [ "$kind" = O ]; then
      operator="$word"
      while [[ "$operator" =~ ^[0-9] ]]; do operator=${operator:1}; done
      case "$operator" in
        # Zsh reads a trailing "!" as the clobber suffix. Bash and sh read it
        # as the first character of the target word, or as a file named "!"
        # when a space follows. The gate cannot know the shell, so it judges
        # each reading.
        '>!'|'>>!'|'&>!'|'&>>!'|'>&!'|'>>&!')
          redirect_slots[${#words[@]}]=2
          words[${#words[@]}]=""
          continue ;;
        '>'|'>>'|'>|'|'>&'|'&>'|'<>'|'>>|'|'>>&'|'&>>'|'&>|'|'&>>|'|'>&|'|'>>&|')
          redirect_slots[${#words[@]}]=1
          words[${#words[@]}]=""
          continue ;;
        '<'|'<<'|'<<-'|'<<<')
          case "$operator" in '<<<') capture_string=1 ;; '<') capture_input=1 ;; esac
          skip=1; continue ;;
        ';') continue ;;
      esac
    fi
    words[${#words[@]}]="$word"
  done < <(printf '%s\n' "$segment" | awk "$PT_TOKENS_AWK")
  for i in "${!words[@]}"; do
    word=${words[$i]}
    if [ "$skip" = 2 ] || [ "$skip" = 3 ]; then
      case "$word" in [0-9]|-) ;; *) pt_judge "$word" ;; esac
      if [ "$skip" = 3 ]; then pt_judge "!$word"; pt_judge '!'; fi
      skip=0; continue
    fi
    if [ "${redirect_slots[$i]:-0}" = 1 ]; then skip=2; continue; fi
    if [ "${redirect_slots[$i]:-0}" = 2 ]; then skip=3; continue; fi
    filtered[${#filtered[@]}]="$word"
  done
  # A "!" operator at the end of the segment writes a file named "!" in bash.
  [ "$skip" != 3 ] || pt_judge '!'
  words=("${filtered[@]}")
  [ "${#words[@]}" -gt 0 ] || return 0
  local prefix="" need_duration=0
  while [ "$start" -lt "${#words[@]}" ]; do
    word=${words[$start]}
    case "$word" in xargs) pt_token_context && pt_block 'xargs has unextractable write operands.'; start=$((start+1)); continue ;; esac
    # Options of a prefix command. Skip each option value, so the value is
    # not taken as the command word.
    if [ -n "$prefix" ]; then
      case "$word" in
        --) prefix=""; start=$((start+1)); continue ;;
        -*)
          case "$prefix:$word" in
            env:-u|env:-C|env:--unset|env:--chdir|sudo:-u|sudo:-g|sudo:-h|sudo:-p|sudo:-C|sudo:-D|sudo:-r|sudo:-t|sudo:-U|sudo:-T|nice:-n|time:-f|time:-o|timeout:-s|timeout:-k|exec:-a|stdbuf:-i|stdbuf:-o|stdbuf:-e|ionice:-c|ionice:-n)
              start=$((start+2)) ;;
            env:-S|env:--split-string)
              ( pt_scan "${words[$((start+1))]:-}" ) || exit 2; start=$((start+2)) ;;
            env:-S*|env:--split-string=*)
              arg=${word#--split-string=}; arg=${arg#-S}
              ( pt_scan "$arg" ) || exit 2; start=$((start+1)) ;;
            *) start=$((start+1)) ;;
          esac
          continue ;;
      esac
      # timeout takes a duration before the command.
      if [ "$need_duration" = 1 ]; then need_duration=0; start=$((start+1)); continue; fi
    fi
    case "$word" in
      env|command|exec|sudo|nice|nohup|time|timeout|gtimeout|stdbuf|ionice)
        prefix=$word; [ "$prefix" != gtimeout ] || prefix=timeout
        [ "$prefix" != timeout ] || need_duration=1
        start=$((start+1)); continue ;;
    esac
    case "$word" in export|if|then|else|while|until|do|elif|'!'|'{') start=$((start+1)); continue ;; esac
    if [[ "$word" =~ ^[a-zA-Z_][a-zA-Z_0-9]*= ]]; then
      name=${word%%=*}; val=$(pt_expand "${word#*=}")
      for i in "${!PT_NAMES[@]}"; do [ "${PT_NAMES[$i]}" != "$name" ] || { unset 'PT_NAMES[i]'; unset 'PT_VALUES[i]'; }; done
      PT_NAMES=("${PT_NAMES[@]}"); PT_VALUES=("${PT_VALUES[@]}")
      [ "$name" != APEXYARD_OPS_PIN_DIR ] || sandbox_pin="$val"
      PT_ASSIGN_NAMES[${#PT_ASSIGN_NAMES[@]}]="$name"; PT_ASSIGN_VALUES[${#PT_ASSIGN_VALUES[@]}]="$val"
      case "$val" in *'$'*|*'`'*) ;; *) PT_NAMES[${#PT_NAMES[@]}]="$name"; PT_VALUES[${#PT_VALUES[@]}]="$val" ;; esac
      start=$((start+1)); continue
    fi
    case "$word" in -*) start=$((start+1)); continue ;; esac
    break
  done
  [ "$start" -lt "${#words[@]}" ] || return 0
  words=("${words[@]:$start}"); verb=${words[0]##*/}
  # State writers may run only with a literal sandbox assignment.
  for word in "${words[@]}"; do pt_nocase pt_state_writer_nocase "${word##*/}" "$sandbox_pin"; done
  case "$verb" in
    cd|pushd)
      # Skip cd options such as -P and -L. The first operand is the directory.
      i=1
      while [ "$i" -lt "${#words[@]}" ]; do case "${words[$i]}" in --) i=$((i+1)); break ;; -?*) i=$((i+1)) ;; *) break ;; esac; done
      arg=$(pt_expand "${words[$i]:-$HOME}")
      [ "$verb" != pushd ] || PT_DIR_STACK[${#PT_DIR_STACK[@]}]="$PT_CWD"
      # Keep the old directory. It stays in effect if the cd fails.
      PT_PENDING[${#PT_PENDING[@]}]="$PT_CWD"
      case "$arg" in -|*'$'*|*'`'*) PT_CWD="$PT_FALLBACK" ;; /*) PT_CWD=$(pt_physical "$arg") ;; *) PT_CWD=$(pt_physical "$PT_CWD/$arg") ;; esac
      { [ -d "$PT_CWD" ] && [ -x "$PT_CWD" ]; } || PT_CWD="$PT_FALLBACK"
      return 0 ;;
    popd)
      PT_PENDING[${#PT_PENDING[@]}]="$PT_CWD"
      if [ "${#PT_DIR_STACK[@]}" -gt 0 ]; then PT_CWD=${PT_DIR_STACK[${#PT_DIR_STACK[@]}-1]}; unset 'PT_DIR_STACK[${#PT_DIR_STACK[@]}-1]'; else PT_CWD="$PT_FALLBACK"; fi; return 0 ;;
    eval)
      # eval runs its joined operands as a command in this shell.
      [ "${#words[@]}" -lt 2 ] || pt_scan "${words[*]:1}"
      return 0 ;;
    bash|sh|zsh)
      # Parse the option clusters. Any cluster with "c" makes the first
      # operand the program text, as in "-c", "-ec" and "-lc".
      local cflag=0 script="" have_script=0
      i=1
      while [ "$i" -lt "${#words[@]}" ]; do
        arg=${words[$i]}; i=$((i+1))
        case "$arg" in
          --) [ "$i" -ge "${#words[@]}" ] || { script=${words[$i]}; have_script=1; }; break ;;
          -o|+o|-O|+O|--rcfile|--init-file) i=$((i+1)); continue ;;
          --*) continue ;;
          -|+) continue ;;
          -*|+*) case "$arg" in -*c*) cflag=1 ;; esac; continue ;;
        esac
        script="$arg"; have_script=1; break
      done
      if [ "$cflag" = 1 ]; then
        [ "$have_script" = 0 ] || { ( pt_scan "$script" ) || exit 2; }
        return 0
      fi
      case "$script" in /dev/stdin|/dev/fd/*|-) have_script=0 ;; esac
      if [ "$have_script" = 0 ] && [ -z "$here_string" ] && [ -z "$here_refs" ]; then
        # The shell reads its program from a pipe or a redirect. The gate
        # cannot see that text.
        pt_token_context && pt_block 'the shell program is not visible and the command names protected state.'
      fi
      if [ -n "$here_string" ]; then
        arg=$(pt_expand "$here_string")
        case "$arg" in *'$'*|*'`'*) pt_token_context && pt_block 'unextractable shell stdin program.' ;; *) ( pt_scan "$arg" ) || exit 2 ;; esac
      fi
      for ref in $here_refs; do
        body_id=${ref%%:*}; body_fd=${ref#*:}
        [ "$body_fd" != 0 ] || selected_body="$body_id"
      done
      if [ -n "$selected_body" ]; then ( pt_scan "${PT_HERE_BODIES[$selected_body]}" ) || exit 2; fi
      return 0 ;;
    source|.)
      arg=$(pt_expand "${words[1]:-}")
      # No operand means process substitution or a redirect. The gate cannot
      # see that program text.
      if [ -z "$arg" ] || { case "$arg" in /dev/stdin|/dev/fd/*|/proc/self/fd/*) true ;; *) false ;; esac && [ -z "$here_string" ] && [ -z "$here_refs" ]; }; then
        pt_token_context && pt_block 'the sourced program is not visible and the command names protected state.'
      fi
      case "$arg" in /dev/stdin|/dev/fd/[0-9]*|/proc/self/fd/[0-9]*)
        case "$arg" in /dev/stdin) wanted_fd=0 ;; *) wanted_fd=${arg##*/} ;; esac
        [ -z "$here_string" ] || pt_scan "$here_string"
        for ref in $here_refs; do
          body_id=${ref%%:*}; body_fd=${ref#*:}
          [ "$body_fd" != "$wanted_fd" ] || selected_body="$body_id"
        done
        [ -z "$selected_body" ] || pt_scan "${PT_HERE_BODIES[$selected_body]}" ;;
      esac
      return 0 ;;
    git)
      # The scrubber keeps executable git verbs and removes data-only mentions.
      case "$PT_SCRUBBED" in *git*) pt_git; PT_CWD="$savecwd" ;; esac; return 0 ;;
    find)
      for i in "${!words[@]}"; do
        case "${words[$i]}" in
          -delete) for arg in "${words[@]:1}"; do case "$arg" in -*) break ;; *) pt_judge "$arg" 1 ;; esac; done ;;
          -fprint|-fprint0|-fprintf|-fls) pt_judge "${words[$((i+1))]:-}" ;;
        esac
      done
      for i in "${!words[@]}"; do
        case "${words[$i]}" in -exec|-execdir|-ok|-okdir)
          # A read-only verb cannot write a find root. Judge the roots and the
          # operands only for a mutating or an unknown verb.
          case "${words[$((i+1))]:-}" in cat|grep|rg|jq|ls|diff|cmp|head|tail|wc|stat|file|readlink|realpath|shasum|sha256sum|md5|md5sum|du|shellcheck|test|'['|printf|echo|true|false|pwd) continue ;; esac
          for arg in "${words[@]:1:$((i-1))}"; do case "$arg" in -*) ;; *) pt_judge "$arg" 1 ;; esac; done; words=("${words[@]:$((i+1))}"); pt_token_context && pt_block 'find has an unextractable mutation operand.'; return 0 ;; esac
      done; return 0 ;;
    patch) pt_patch; return 0 ;;
    cp|mv|install|dd|ln|link|rsync|ditto|rm|rmdir|unlink|shred|chmod|chown|chgrp|chflags|chattr|xattr|setfacl|touch|mkdir|truncate|tar|unzip|cpio|pax|perl|ruby|gsed|sed|ed|ex|vi|vim|sponge|tee|base64|openssl|iconv|plutil|uudecode|gzip|gunzip|bzip2|bunzip2|xz|unxz)
      pt_operands "$verb"; ;;
    cat|grep|rg|jq|ls|diff|cmp|head|tail|wc|stat|file|readlink|realpath|shasum|sha256sum|test|'['|printf|echo|true|false|exit|return|pwd) ;;
    *)
      for word in "${words[@]:1}"; do
        expanded=$(pt_expand "$word")
        case "$expanded" in ''|-*|*'$'*|*'`'*) continue ;; esac
        pt_token_context && pt_protected "$expanded" 1 && pt_block 'unknown verb has a live protected operand.'
      done ;;
  esac
  # Interpreter heredocs need the complete body, not just the header segment.
  case "$verb" in python*|node|ruby|perl|php)
    case "$segment" in *'<<'*)
      if declare -F bash_command_appears_to_write >/dev/null && bash_command_appears_to_write "$cmd" && bash_command_has_unextractable_write "$cmd"; then
        pt_token_context && pt_block 'interpreter heredoc names protected state.'
      fi ;;
    esac ;;
  esac
  # Literal read-only commands need no write-detector subprocesses. Redirects
  # were judged above. Keep substitutions on the detector path.
  case "$verb" in
    cat|grep|rg|jq|ls|diff|cmp|head|tail|wc|stat|file|readlink|realpath|shasum|sha256sum|test|'['|printf|echo|true|false|exit|return|pwd|fi|done|break|continue)
      case "$segment" in *'$('*|*'`'*) ;; *) return 0 ;; esac ;;
  esac
  # Interpreter writes and other unextractable writes use the additive rule.
  case "$verb" in tar|cp|mv|install|dd|ln|link|rsync|ditto|rm|rmdir|unlink|shred|chmod|chown|chgrp|chflags|chattr|xattr|setfacl|touch|mkdir|truncate|base64|openssl|iconv|plutil|uudecode|gzip|gunzip|bzip2|bunzip2|xz|unxz|tee|sponge) return 0 ;; esac
  if declare -F bash_command_appears_to_write >/dev/null && bash_command_appears_to_write "$verb ${words[*]:1}"; then
    case "$verb" in python*|node|perl|ruby|php|deno|bun|go)
      pt_token_context && pt_block 'unextractable write names protected state. Use Edit for a non-live file.' ;;
      *)
        local extracted
        extracted=$(bash_extract_write_targets "$verb ${words[*]:1}") || pt_block 'cannot extract write operands.'
        if bash_command_has_unextractable_write "$verb ${words[*]:1}"; then pt_token_context && pt_block 'unextractable write names protected state.'; fi
        while IFS= read -r target; do [ -z "$target" ] || pt_judge "$target"; done <<<"$extracted" ;;
    esac
  fi
  return 0
}
pt_patch() {
  local i=1 arg file="${redirect_input:-}" output="" inputs=() tree path header
  file=$(pt_expand "$file")
  case "$file" in ''|/*) ;; *) file="$PT_CWD/$file" ;; esac
  for arg in "${words[@]}"; do [ "$arg" != --dry-run ] || return 0; done
  while [ "$i" -lt "${#words[@]}" ]; do
    arg=${words[$i]}; i=$((i+1))
    case "$arg" in
      -d|--directory) arg=$(pt_expand "${words[$i]:-}"); i=$((i+1)); case "$arg" in /*) PT_CWD="$arg" ;; *'$'*) PT_CWD="$PT_FALLBACK" ;; *) PT_CWD="$PT_CWD/$arg" ;; esac ;;
      -i|--input|'<') file=${words[$i]:-}; i=$((i+1)) ;;
      -o|--output) output=${words[$i]:-}; i=$((i+1)) ;;
      --output=*) output=${arg#*=} ;;
      -p|-F|-E) i=$((i+1)) ;;
      -*) ;;
      *) inputs[${#inputs[@]}]="$arg" ;;
    esac
  done
  tree=$(pt_physical "$PT_CWD")
  while [ "$tree" != / ] && [ ! -e "$tree/.git" ]; do tree=$(dirname "$tree"); done
  pt_live "$tree" && pt_block 'patch writes a live work tree.'
  [ -z "$output" ] || pt_judge "$output"
  if [ "${#inputs[@]}" -gt 0 ]; then pt_judge "${inputs[0]}"; fi
  if [ "${#inputs[@]}" -gt 1 ]; then file=${inputs[1]}; fi
  file=$(pt_expand "$file")
  case "$file" in /*) ;; '') ;; *) file="$PT_CWD/$file" ;; esac
  if [ -n "$file" ] && [ -r "$file" ]; then
    while IFS= read -r header; do
      path=${header#????}; path=${path%%$'\t'*}
      # A tab separates a timestamp. Spaces can be part of the file name.
      case "$path" in /*|../*|*/../*) pt_judge "$path" ;; esac
      path=${path%% *}
      case "$path" in /*|../*|*/../*) pt_judge "$path" ;; esac
    done < <(grep -E '^(---|\+\+\+) ' "$file")
  else pt_token_context && pt_block 'non-literal patch input names protected state.'; fi
  return 0
}
# Check literal shell scopes in Bash subshells. All inspection state, including
# variable assignments and the directory stack, then has the same scope.
pt_list_end() {
  # At the end of an and-or list, a failed cd from that list can leave its
  # old directory in effect for every later command.
  local alt
  for alt in ${PT_PENDING[@]+"${PT_PENDING[@]}"}; do PT_ALTS[${#PT_ALTS[@]}]="$alt"; done
  PT_PENDING=(); PT_OR_ACTIVE=0
}
pt_walk_tokens() {
  local first="$1" last="$2" i j k depth token kind segment="" pipeline=0 here_refs="" list_start=1
  for ((i=first;i<=last;i++)); do
    if [ "$list_start" = 1 ]; then
      list_start=0
      # "a && b &" runs the whole and-or list in the background, in a
      # subshell. Find the list terminator at this depth first.
      depth=0; k=$i
      while [ "$k" -le "$last" ]; do
        case "${tokens[$k]}" in
          'O(') depth=$((depth+1)) ;;
          'O)') depth=$((depth-1)) ;;
          'O;'|'O;;'|'O;&'|'O;;&'|'O&') [ "$depth" != 0 ] || break ;;
        esac
        k=$((k+1))
      done
      if [ "$k" -le "$last" ] && [ "${tokens[$k]}" = 'O&' ] && [ "$k" -gt "$i" ]; then
        ( pt_walk_tokens "$i" "$((k-1))" ) || exit 2
        i=$k; list_start=1; continue
      fi
    fi
    token=${tokens[$i]}; kind=${token:0:1}; token=${token:1}
    if [ "$kind" = D ]; then here_refs="$here_refs $token"; continue; fi
    # Case headers and patterns are syntax, not commands.
    [ "$kind" != P ] || continue
    # A command substitution runs in a subshell with the current directory.
    if [ "$kind" = S ]; then ( pt_scan "$token" ) || exit 2; continue; fi
    if [ "$kind" = W ]; then
      token=${token//\'/\'\\\'\'}
      segment="$segment '$token'"
      continue
    fi
    case "$token" in
      '(')
        [ -z "$segment" ] || pt_simple "$segment" "$here_refs"
        segment=""; here_refs=""; depth=1; j=$((i+1))
        while [ "$j" -le "$last" ]; do
          case "${tokens[$j]}" in 'O(') depth=$((depth+1)) ;; 'O)') depth=$((depth-1)) ;; esac
          [ "$depth" != 0 ] || break
          j=$((j+1))
        done
        [ "$depth" = 0 ] || pt_block 'unclosed shell scope.'
        ( pt_walk_tokens "$((i+1))" "$((j-1))" ) || exit 2
        i="$j" ;;
      ')') pt_block 'unmatched shell scope.' ;;
      '|')
        [ -z "$segment" ] || { ( pt_simple "$segment" "$here_refs" ) || exit 2; }
        segment=""; here_refs=""; pipeline=1 ;;
      '&')
        [ -z "$segment" ] || { ( pt_simple "$segment" "$here_refs" ) || exit 2; }
        segment=""; here_refs=""; pipeline=0; pt_list_end; list_start=1 ;;
      ';'|';;'|';&'|';;&'|'&&'|'||')
        if [ -n "$segment" ]; then
          if [ "$pipeline" = 1 ]; then ( pt_simple "$segment" "$here_refs" ) || exit 2; else pt_simple "$segment" "$here_refs"; fi
        fi
        segment=""; here_refs=""; pipeline=0
        case "$token" in
          '&&') ;;
          '||')
            # "cd x || exit" stops on a failed cd. Any other right side can
            # run in the old directory.
            case "${tokens[$((i+1))]:-}" in Wexit|Wreturn) PT_PENDING=() ;; *) PT_OR_ACTIVE=1 ;; esac ;;
          *) pt_list_end; list_start=1 ;;
        esac ;;
      *) segment="$segment $token" ;;
    esac
  done
  if [ -n "$segment" ]; then
    if [ "$pipeline" = 1 ]; then ( pt_simple "$segment" "$here_refs" ) || exit 2; else pt_simple "$segment" "$here_refs"; fi
  fi
  return 0
}
pt_scan() {
  local text="$1" token body_id body_record complete=0
  local -a tokens=() PT_HERE_BODIES=()
  # The tokenizer prints an end record only when it reads the whole text.
  # A missing end record means a syntax error or a tokenizer failure.
  while IFS= read -r -d '' token; do
    case "$token" in
      E) complete=1 ;;
      H*) body_record=${token:1}; body_id=${body_record%%:*}; PT_HERE_BODIES[$body_id]=${body_record#*:} ;;
      *) tokens[${#tokens[@]}]="$token" ;;
    esac
  done < <(printf '%s\n' "$text" | awk "$PT_TOKENS_AWK")
  [ "$complete" = 1 ] || pt_block 'cannot tokenize Bash.'
  pt_walk_tokens 0 "$((${#tokens[@]}-1))"
}
PT_DIR_STACK=(); PT_ALTS=(); PT_PENDING=(); PT_OR_ACTIVE=0
pt_scan "$cmd"
exit 0
