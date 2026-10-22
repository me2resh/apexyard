#!/bin/bash
# Shared git global-option matcher for the dispatcher and the commit/push gates.
#
# dispatch-bash.sh already routes `git -C <dir> commit` and `git -c name=value
# push` (#1527). The gates used to require the verb in the next word after
# `git`, so those forms skipped the check (#1730, #1731).
#
# Presence checks stay on the raw command. Do not strip quotes or heredoc
# bodies before asking whether a commit or push is present (AgDR-0113).
# #1772: a redirection before the verb is skipped like the shell does.
#
# Not a hook. Hooks source this file.

if [ -n "${_LIB_GIT_GLOBAL_LOADED:-}" ]; then
  return 0
fi
_LIB_GIT_GLOBAL_LOADED=1

# Share this expression with the dispatcher and the gates.
# #1748: escaped pairs and quoted values belong to a single option word.
_git_opt_val='(\\.|"[^"]*"|'"'"'[^'"'"']*'"'"'|\$\([^)]*\)|`[^`]*`|[^[:space:];&|"'"'"']+)+'
# #1816 G1/G4: command word may be quoted and may use another letter case.
# Keep double quotes out of ${...} inside double-quoted strings.
# The regex vars intentionally hold literal " characters and must stay
# unquoted at use sites (concatenated into larger ERE strings).
# shellcheck disable=SC2089
_git_q='("|'\'')*'
# shellcheck disable=SC2089
_git_cmd_word=${_git_q}'\\?[Gg]'${_git_q}'\\?[Ii]'${_git_q}'\\?[Tt]'${_git_q}
# #1772 / #1805: a redirection before the verb is not the verb. Skip it the
# same way the shell does. Longer operators come first (left-first ERE).
# Use `[|]` for a literal pipe so ERE `|` does not break the group.
# Target is required so `git > push` does not treat `push` as the verb.
# #1805 B2: the target is one full shell word. A quoted part may hold
# spaces, and a substitution may hold spaces (one level, no parens inside).
# _git_redir_hides_verb fails closed for a target this unit cannot match.
_git_redir_word='(\\.|"([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"'|\$\([^()]*\)|`[^`]*`|[^[:space:];&|<>()"'"'"'`\\])+'
# #1772 N2: the Bash tool can run zsh. The zsh clobber forms (`>!`, `>>|`,
# `&>!`, `>&|` and the append forms) are operators too. A named descriptor
# (`{name}>`) can come before an operator, as a digit can.
_git_redir_fd='([0-9]*|[{][A-Za-z_][A-Za-z0-9_]*[}])'
_git_redir_op='(&>>[|!]?|&>[|!]?|>>&[|!]?|>>[|!]?|>&[|!]?|>[|!]|>|<<<|<<-|<<|<&|<)'
_git_redir="${_git_redir_fd}${_git_redir_op}"'[[:space:]]*'"${_git_redir_word}"
# Spaces plus a unit, or a redirection glued to `git` (`git>file`).
_git_sub_opts='(([[:space:]]+((-[Cc]|--(git-dir|work-tree|namespace|super-prefix|config-env|attr-source))[[:space:]]+'"${_git_opt_val}"'|--(git-dir|work-tree|namespace|super-prefix|config-env|attr-source)='"${_git_opt_val}"'|--?[A-Za-z][A-Za-z-]*(='"${_git_opt_val}"')?|'"${_git_redir}"')|'"${_git_redir}"'))*[[:space:]]+'
_git_sub_re='(^|[^[:alnum:]_.-])'${_git_cmd_word}${_git_sub_opts}

# Letter-quoted literal for a verb. Reuses the same quote grammar as the
# alias word decoder (#1816 G5). Keeps the verb's letter case.
_git_quoted_literal() {
  local s="$1" out="" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      \\|'.'|'['|']'|'('|')'|'*'|'+'|'?'|'{'|'}'|'|'|'^'|'$')
        c="\\$c"
        ;;
    esac
    out+="${_git_q}\\\\?${c}"
  done
  printf '%s' "${out}${_git_q}"
}

# Regex for `git [global options] <sub>` on raw text.
# The match may include one leading boundary character.
git_subcommand_re() {
  printf '%s%s([^[:alnum:]_.-]|$)' "$_git_sub_re" "$(_git_quoted_literal "$1")"
}

# One push invocation, including global options, through the first separator.
# The match may include one leading boundary character.
git_push_segment_re() {
  printf '%s%s([^|;&[:alnum:]_.-][^|;&]*)?' "$_git_sub_re" "$(_git_quoted_literal push)"
}

# 0 when the raw command contains `git [global options] <sub>`.
command_has_git_subcommand() {
  printf '%s\n' "$1" | LC_ALL=C grep -qE "$(git_subcommand_re "$2")"
}

# 0 when a shell token is the git command word (#1816 G1/G4).
git_token_is_cmd_word() {
  local flat
  flat=$(printf '%s' "$1" | tr -d "'\"\\\\")
  case "$flat" in
    [Gg][Ii][Tt]) return 0 ;;
  esac
  return 1
}

# 0 when a shell token decodes to the given verb (#1816 G5).
git_token_is_verb() {
  local want="$2" saved="$_GIT_SCAN" word
  _GIT_SCAN="$1"
  if _git_take_value; then
    word="$_GIT_TAKEN"
  else
    word=$(printf '%s' "$1" | tr -d "'\"\\\\")
  fi
  _GIT_SCAN="$saved"
  [ "$word" = "$want" ]
}

# 0 when the text runs a nested shell or a directory-stack change at a
# command position (#1816 G7, #1748 round 4). A nested shell counts when it
# gets a command string (-c) or a stdin script (-s). The shell word can sit
# behind any wrapper, so this form needs only a word boundary. A nested shell
# also counts at a command position when a heredoc, a redirection or a pipe
# feeds its script. A shell word in prose, in a heredoc body line that does
# not start a command, or a script-file run does not count.
_git_text_has_nested_shell() {
  local text="$1" word_re="(^|[^[:alnum:]_.-])(pushd|popd|eval|sh|bash|zsh|dash|ksh)([[:space:];&|<>'\")]|$)"
  # No fork when no candidate word is present.
  [[ "$text" =~ $word_re ]] || return 1
  local at='(^|[;&|(){}!`]|\$\(|[[:space:]]-(exec|execdir|ok|okdir)[[:space:]])[[:space:]]*'
  local wrap='((exec|command|builtin|time|nohup|nice|sudo|xargs|env|timeout|then|do|else|if|while|until)([[:space:]]+[^[:space:];&|()]+)*[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*[[:space:]]+)*'
  local shell="${_git_q}([^[:space:];&|()<>\`]*/)?(sh|bash|zsh|dash|ksh)${_git_q}"
  # A separate option value can precede -c (for example a shell option name).
  local opts="([[:space:]]+((-[oO]|--rcfile|--init-file)[[:space:]]+${_git_opt_val}|[-+][^[:space:];&|<>()]*))*"
  local stack="${at}${wrap}(pushd|popd|${_git_q}eval${_git_q})([[:space:];&|)]|$)"
  local cmdstr="(^|[^[:alnum:]_.-])${shell}${opts}[[:space:]]+-[A-Za-z]*[cs][A-Za-z]*([[:space:];&|<>)'\"]|$)"
  local fed="${at}${wrap}${shell}([[:space:]]+[-+][^[:space:];&|<>()]*)*[[:space:]]*([;&|<>)]|$)"
  printf '%s\n' "$text" | LC_ALL=C grep -qE "${stack}|${cmdstr}|${fed}"
}

# 0 when quotes or backslashes in one literal match can hide a real
# `git push` or `git commit` (#1748 round 4).
# The match is: optional boundary, command word, spaces, verb, optional tail.
# A quote or backslash inside a word splits it: hidden.
# Spaces inside one quoted string join both words into one shell word. That
# word is prose or a pattern, not a command: not hidden.
# Quotes only at the edges of two separate words: hidden (fail closed).
_git_match_hides_words() {
  local m="$1" i c state="" phase=0 letters=0 want=3 split=0 marks=0 quoted_ws=0
  for ((i = 0; i < ${#m}; i++)); do
    c="${m:i:1}"
    case "$c" in
      \"|\'|\\)
        if [ "$phase" = 1 ] || [ "$phase" = 4 ]; then
          split=1
          break
        fi
        marks=1
        if [ "$c" != \\ ]; then
          if [ -z "$state" ]; then state="$c"; elif [ "$state" = "$c" ]; then state=""; fi
        fi
        ;;
      [[:space:]])
        if [ "$phase" = 2 ]; then
          [ -z "$state" ] || quoted_ws=1
          phase=3
        fi
        ;;
      [[:alnum:]])
        case "$phase" in
          0) phase=1; letters=1 ;;
          1) letters=$((letters + 1)); [ "$letters" -lt "$want" ] || phase=2 ;;
          3)
            phase=4; letters=1
            case "$c" in c|C) want=6 ;; *) want=4 ;; esac
            ;;
          4) letters=$((letters + 1)); [ "$letters" -lt "$want" ] || break ;;
        esac
        ;;
    esac
  done
  [ "$split" = 0 ] || return 0
  [ "$quoted_ws" = 0 ] || return 1
  [ "$marks" = 0 ] && return 1
  return 0
}

# 0 when a redirection target between the git command word and the verb is
# a shell word that _git_redir_word cannot match, or is not closed, and a
# push or commit word follows (#1772 / #1805 B2). The matcher cannot see
# past that target, so the caller fails closed.
# #1772 N1: a quote or a substitution that is not closed on its line goes on
# to the next line. Then a push or commit word on a later line also counts.
# #1772 N3: the scan is linear in the text length for words separated by
# blanks. It is quadratic for a long run with no blank and for many targets
# that hold a quoted blank. The dispatcher time limit then blocks (fail
# closed). AgDR-0264 Decision 8 records this accepted residual.
# - Lines after the last push or commit word cannot give a result. The scan
#   stops before them.
# - Each line is split into pieces at each space and tab. A word step works
#   on one piece, not on the full rest of the line. A word that is still
#   open at the end of its piece is read again from the rest of the line.
# - Each walk records the points where it reads a word. A walk that comes to
#   a recorded point stops, because the rest of that walk is the same as the
#   earlier walk from that point.
_git_redir_hides_verb() {
  local text="$1" line tline rest m t0 flat re word_re op_re verb_re key
  local idx=-1 last=-1 np pi wpi pos norm tsep us nov
  local -a walked pieces endp
  case "$text" in *'>'*|*'<'*) ;; *) return 1 ;; esac
  verb_re='(^|[^[:alnum:]_.-])(push|commit)([^[:alnum:]_.-]|$)'
  flat=$(printf '%s\n' "$text" | tr -d "'\"\\\\")
  [[ "$flat" =~ $verb_re ]] || return 1
  # Find the last line that holds a push or commit word.
  while IFS= read -r line; do
    idx=$((idx + 1))
    if [[ "$line" =~ $verb_re ]]; then
      last=$idx
    fi
  done <<EOF_REDIR_VERBS
$flat
EOF_REDIR_VERBS
  re='(^|[^[:alnum:]_.-])'${_git_cmd_word}
  word_re='^'"${_git_redir_word}"'$'
  op_re='^'"${_git_redir_fd}${_git_redir_op}"
  # Each space or tab becomes a unit separator, so each one ends a piece.
  # Text that holds a unit separator is not split.
  us=$'\037'
  case "$text" in
    *"$us"*) tsep="" ;;
    *) tsep=$(printf '%s\n' "$text" | tr ' \t' '\037\037') ;;
  esac
  idx=-1
  while IFS= read -r line <&3; do
    tline=""
    [ -z "$tsep" ] || IFS= read -r tline <&4 || tline=""
    idx=$((idx + 1))
    [ "$idx" -le "$last" ] || break
    case "$line" in *'>'*|*'<'*) ;; *) continue ;; esac
    if [ -n "$tsep" ]; then
      # A final x keeps an empty last piece. Remove it after the read.
      IFS="$us" read -r -a pieces <<EOF_REDIR_PIECES
${tline}${us}x
EOF_REDIR_PIECES
      unset "pieces[$((${#pieces[@]} - 1))]"
    else
      pieces=("$line")
    fi
    np=${#pieces[@]}
    # The end of each piece in the line. One character separates two pieces.
    norm="$line"
    # Loop with "for p in", because a bash 3.2 array lookup by index walks
    # the array from its start.
    endp=()
    pos=-1
    for rest in ${pieces[@]+"${pieces[@]}"}; do
      pos=$((pos + 1 + ${#rest}))
      endp[${#endp[@]}]=$pos
    done
    walked=()
    nov=-1
    pi=-1
    for rest in ${pieces[@]+"${pieces[@]}"}; do
      pi=$((pi + 1))
      # Every git command word holds a g. A glob test is fast.
      case "$rest" in *[Gg]*) ;; *) continue ;; esac
      while [[ "$rest" =~ $re ]]; do
        m="${BASH_REMATCH[0]}"
        rest="${rest#*"$m"}"
        wpi=$pi
        _GIT_SCAN="$rest"
        while :; do
          _GIT_SCAN="${_GIT_SCAN#"${_GIT_SCAN%%[![:space:]]*}"}"
          if [ -z "$_GIT_SCAN" ]; then
            wpi=$((wpi + 1))
            [ "$wpi" -lt "$np" ] || break
            _GIT_SCAN="${pieces[wpi]}"
            continue
          fi
          # #1772 R2-1: `&>` and its zsh forms are operators, not a
          # separator. Let them through to the operator test below.
          case "$_GIT_SCAN" in '&>'*) ;; [\;\&\|]*) break ;; esac
          # The point in the line names the rest of this walk.
          key=$((endp[wpi] - ${#_GIT_SCAN}))
          [ -z "${walked[key]:-}" ] || break
          walked[key]=1
          if [[ "$_GIT_SCAN" =~ $op_re ]]; then
            _GIT_SCAN="${_GIT_SCAN:${#BASH_REMATCH[0]}}"
            _GIT_SCAN="${_GIT_SCAN#"${_GIT_SCAN%%[![:space:]]*}"}"
            while [ -z "$_GIT_SCAN" ] && [ $((wpi + 1)) -lt "$np" ]; do
              wpi=$((wpi + 1))
              _GIT_SCAN="${pieces[wpi]}"
              _GIT_SCAN="${_GIT_SCAN#"${_GIT_SCAN%%[![:space:]]*}"}"
            done
            case "$_GIT_SCAN" in ''|[\;\&\|]*) break ;; esac
            if [[ "$_GIT_SCAN" =~ ^([0-9]+|-)([[:space:];&|]|$) ]]; then
              _GIT_SCAN="${_GIT_SCAN:${#BASH_REMATCH[1]}}"
              continue
            fi
            pos=$((endp[wpi] - ${#_GIT_SCAN}))
            if _git_redir_take_word && [[ "$_GIT_TAKEN" =~ $word_re ]]; then
              continue
            fi
            if [ "$_GIT_RAW_OPEN" = 1 ] && [ "$idx" -lt "$last" ]; then
              return 0
            fi
            # A target starts after an operator or a blank. Thus when the
            # rest of the line from one target has no push or commit word,
            # the rest from a later target has none too.
            if [ "$nov" -lt 0 ] || [ "$pos" -lt "$nov" ]; then
              t0=$(printf '%s\n' "${norm:pos}" | tr -d "'\"\\\\")
              if [[ "$t0" =~ $verb_re ]]; then
                return 0
              fi
              nov=$pos
            fi
            break
          fi
          _git_redir_take_word || break
        done
      done
    done
  done 3<<EOF_REDIR_LINES 4<<EOF_REDIR_SPLIT
$text
EOF_REDIR_LINES
$tsep
EOF_REDIR_SPLIT
  return 1
}

# Read one raw word for _git_redir_hides_verb from piece $wpi (#1772 N3).
# $_GIT_SCAN holds the rest of that piece. A word that is still open at the
# end of the piece, or that ends in an escape, is read again from the rest
# of $norm. On success, $wpi and $_GIT_SCAN name the point after the word.
_git_redir_take_word() {
  local at rc=0 lo hi mid
  at=$((endp[wpi] - ${#_GIT_SCAN}))
  _git_take_raw_word || rc=$?
  [ $((wpi + 1)) -lt "$np" ] || return "$rc"
  case "$rc:$_GIT_RAW_OPEN" in
    0:2|1:1) ;;
    *) return "$rc" ;;
  esac
  _GIT_SCAN="${norm:at}"
  _git_take_raw_word || return 1
  at=$((${#norm} - ${#_GIT_SCAN}))
  # Find the first piece that ends at or after this point (binary search).
  lo=$wpi
  hi=$((np - 1))
  while [ "$lo" -lt "$hi" ]; do
    mid=$(((lo + hi) / 2))
    if [ "${endp[mid]}" -lt "$at" ]; then
      lo=$((mid + 1))
    else
      hi=$mid
    fi
  done
  wpi=$lo
  _GIT_SCAN="${pieces[wpi]}"
  _GIT_SCAN="${_GIT_SCAN:$((${#_GIT_SCAN} - (endp[wpi] - at)))}"
  return 0
}

# Git's own dashed programs have no literal git verb to parse. Route them
# to the protected gates (#1825). Three forms count, and only at a command
# position (after any assignment, wrapper or redirection):
#   F1 a command word whose last path part is the dashed push or commit name,
#      with quotes or escapes allowed inside the name and any letter case;
#   F2 a last path part that starts with the dashed prefix and then holds a
#      quote, a backslash, a glob character, a brace or an expansion;
#   F3 a path from an exec-path expansion whose last part starts with an
#      expansion, a glob character or a brace.
# Inside a nested shell the body is command text, so a word boundary is
# enough there. The same name in an argument or in data text does not count.
# A name built only from variables, with no literal dashed prefix, stays open
# (AgDR-0253 R3). No command text is ever executed.
_git_text_has_dashed_protected() {
  local text="$1" lead_re strict loose
  # A dashed prefix needs a hyphen and a letter t; cheap guard before a fork.
  case "$text" in *-*) ;; *) return 1 ;; esac
  local sub='\$\([^()]*\)|`[^`]*`'
  local plain='[^[:space:];&|<>()`]'
  local dirp="((${sub}|${plain})*/)?"
  local gq
  gq="$(_git_quoted_literal 'git-')"
  local names
  names="$(_git_quoted_literal push)|$(_git_quoted_literal commit)"
  local delim='([[:space:];&|<>)`]|$)'
  # A quote counts only when more word text follows it. A closing quote does not.
  local special='(\\|\$|`|[*?[{]|["'"'"'][[:alnum:]_"'"'"'\\$])'
  local f1="${dirp}${gq}(${names})${delim}"
  local f2="${dirp}${gq}[[:alnum:]_.-]*${special}"
  local xp='(exec-path|EXEC_PATH)'
  local f3="(${sub}|${plain})*(\\\$\\([^()]*${xp}[^()]*\\)|\`[^\`]*${xp}[^\`]*\`|${xp})(${sub}|${plain})*/[\"']*${special}"
  local asg='[A-Za-z_][A-Za-z0-9_]*=([^[:space:];&|()`"'"'"']|\$\([^()]*\)|"([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"'|`[^`]*`)*[[:space:]]+'
  local kw='(exec|command|builtin|time|nohup|nice|sudo|xargs|env|timeout|then|do|else|if|while|until)[[:space:]]+((-[^[:space:];&|()]+([[:space:]]+[^-[:space:];&|()][^[:space:];&|()]*)?|[0-9]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|()]*)[[:space:]]+)*'
  local wrap="(${asg}|${kw}|${_git_redir}[[:space:]]+)*"
  strict='(^|[;&|(){}!`]|\$\(|[[:space:]]-(exec|execdir|ok|okdir)[[:space:]])[[:space:]]*'"${wrap}"
  loose='(^|[^[:alnum:]_.-])'
  lead_re="$strict"
  _git_text_has_nested_shell "$text" && lead_re="$loose"
  printf '%s\n' "$text" | LC_ALL=C grep -qiE "${lead_re}(${f1}|${f2})|${lead_re}${f3}"
}

# #1816 G2/G3: an expansion hides the command word or the verb, and the rest
# of the simple command can still be a push or a commit.
# #1805 B2: so can a redirection target that the matcher cannot consume.
git_uncertain_protected_shape() {
  local text="$1"
  if _git_redir_hides_verb "$text"; then
    return 0
  fi
  _git_text_has_dashed_protected "$text" && return 0
  local push_re commit_re exp_tok
  push_re="$(_git_quoted_literal push)"
  commit_re="$(_git_quoted_literal commit)"
  local literal_match direct_re
  direct_re='(^|[^[:alnum:]_.-])'${_git_cmd_word}'[[:space:]]+'
  literal_match=$(printf '%s\n' "$text" | LC_ALL=C grep -oE "${direct_re}(${push_re}|${commit_re})([^[:alnum:]_.-]|$)" || :)
  # Obscured protected words need no further argument interpretation.
  # One quoted string that holds both words is one shell word, not a command.
  case "$literal_match" in
    *'"'*|*"'"*|*'\'*)
      local one_match
      while IFS= read -r one_match; do
        _git_match_hides_words "$one_match" && return 0
      done <<EOF_LITERAL_MATCHES
$literal_match
EOF_LITERAL_MATCHES
      ;;
  esac
  # Unknown shell words can occupy the command or verb position.
  local word_part='[[:alnum:]_./"'"'"'-]*'
  exp_tok='('"${word_part}"'(\$[A-Za-z_][A-Za-z0-9_]*|\$[{][^}]*[}]|\$\([^)]*\)|`[^`]*`|\$'"'"'[^'"'"']*'"'"'|[{][^}]*[}])'"${word_part}"')'
  # #1837: a redirection before the verb uses the shared unit, as in
  # _git_sub_opts, spaced or glued to the command word.
  local uncertain_opts='(([[:space:]]+((-[Cc]|--(git-dir|work-tree|namespace|super-prefix|config-env|attr-source))[[:space:]]+'"${_git_opt_val}"'|--[A-Za-z-]+='"${_git_opt_val}"'|--(no-pager|paginate|bare|no-replace-objects|literal-pathspecs|glob-pathspecs|noglob-pathspecs|icase-pathspecs|no-optional-locks|no-lazy-fetch)|-[pP]|'"${_git_redir}"')|'"${_git_redir}"'))*[[:space:]]+'
  local exp_cmd="(^|[;|&(){}!][[:space:]]*|[[:space:]]*(exec|command|env|time|if|while)[[:space:]]+([^;|&]*[[:space:]]+)?)([A-Za-z_][A-Za-z0-9_]*=[^[:space:];|&]*[[:space:]]+)*${exp_tok}"
  if printf '%s\n' "$text" | LC_ALL=C grep -qE "${exp_cmd}${uncertain_opts}(${push_re}|${commit_re})([^[:alnum:]_.-]|$)"; then
    return 0
  fi
  local git_then_exp="(^|[^[:alnum:]_.-])${_git_cmd_word}${uncertain_opts}${exp_tok}"
  if printf '%s\n' "$text" | LC_ALL=C grep -qE "${git_then_exp}([[:space:]]+[^[:space:];|&]|[[:space:]]*$)"; then
    # A bare variable verb with no arguments has no protected evidence.
    [[ "$text" =~ \$[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$ ]] && ! [[ "$text" = *'"'* || "$text" = *"'"* || "$text" = *--* || "$text" = *' -C '* || "$text" = *' -c '* ]] && return 1
    return 0
  fi
  return 1
}

# JSON-string pattern for raw_payload_command_matches.
# Stays inside a JSON string. Covers the same global-option and redirect forms.
git_subcommand_payload_pattern() {
  local sub="$1" lit
  # #1748: a JSON-escaped double-quoted value (-C \"a b\") or a single-quoted
  # value (-C 'a b') is one option word. Single quotes need no JSON escape.
  # #1816: command word may be quoted / another case; verb may be letter-quoted.
  # #1772: redirections before the verb match the shared grammar.
  # A complex $sub (alias no-jq alternation) stays raw.
  # #1805 B2: one full JSON-escaped shell word, as in _git_redir_word.
  # #1772 N2: the same operator units as _git_redir.
  local jredir="${_git_redir_fd}${_git_redir_op}"'[[:space:]]*(\\"([^"\\]|\\[^"])*\\"|'"'"'[^'"'"']*'"'"'|\$\([^()"]*\)|`[^`"]*`|\\.|[^"'"'"'\\[:space:];&|<>()`])+'
  local _git_payload_val='(\\"([^"\\]|\\[^"])*\\"|'"'"'[^'"'"']*'"'"'|\\.|[^"'"'"'\\[:space:]])+'
  if [[ "$sub" =~ ^[a-z0-9-]+$ ]]; then
    lit=$(_git_quoted_literal "$sub")
  else
    lit=$sub
  fi
  # shellcheck disable=SC2090
  printf '%s' ${_git_cmd_word}'(([[:space:]]+((-[Cc]|--(git-dir|work-tree|namespace|super-prefix|config-env|attr-source))[[:space:]]+'"${_git_payload_val}"'|--?[A-Za-z][A-Za-z-]*(='"${_git_payload_val}"')?|'"${jredir}"')|'"${jredir}"'))*[[:space:]]+'${lit}'([^[:alnum:]_.-]|$)'
}

# JSON-string pattern for the no-jq path (#1825): a dashed push or commit
# name, or a dashed prefix followed by a quote, a backslash, a glob
# character, a brace or an expansion. The no-jq path cannot see the command
# position or a word start, so it blocks on the name alone (fail closed).
git_dashed_payload_pattern() {
  printf '%s' '([Gg][Ii][Tt]-([Pp][Uu][Ss][Hh]|[Cc][Oo][Mm][Mm][Ii][Tt])([^[:alnum:]_.-]|$)|[Gg][Ii][Tt]-[[:alnum:]_.-]*(\\\\|\\"|\$|`|[*?[{]))'
}

# JSON-string pattern for the no-jq path (#1805 B2): a git command word,
# then a redirection whose target starts with a quote or an expansion, then
# a push or commit word. The no-jq path cannot consume that target, so it
# blocks (fail closed).
git_redir_uncertain_payload_pattern() {
  # #1772 N2: a zsh operator can end in `&`, `|` or `!` before the target.
  # shellcheck disable=SC2090
  printf '%s' ${_git_cmd_word}'([^"\\]|\\.)*[<>][&|!]*[[:space:]]*(\\"|'"'"'|\$|`)([^"\\]|\\.)*(push|commit)([^[:alnum:]_.-]|$)'
}

# 2 when the token takes the next token as its value.
# 1 when the token is one global option.
# 0 when the token is not a global option.
git_global_option_width() {
  case "$1" in
    -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env|--attr-source)
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
      \\|'$'|'`') return 1 ;; # Unresolved shell words fail closed.
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

# Read one shell word from $_GIT_SCAN into $_GIT_TAKEN without decoding it
# (#1805 B2). Quoted parts, ${...}, $(...) (nested) and backquotes belong to
# the word. Returns 1 when the word is empty or not closed. Sets
# $_GIT_RAW_OPEN to 1 when a quote or a substitution is open at the end of
# the text (#1772 N1), to 2 when the word ends in a backslash that escapes
# the character after the text, and to 0 in all other cases.
_git_take_raw_word() {
  local s="$_GIT_SCAN" r c nc stack="" top run used=0 step re re_sq re_dq re_top
  _GIT_RAW_OPEN=0
  # #1772 N3: skip a run of plain characters in one step. A loop over each
  # character of a long line is slow in bash, and so is a ${r%%[...]*}
  # pattern on a long line in a UTF-8 locale. A regex match is fast.
  re_sq="^[^']*"
  re_dq='^[^\\"`$]*'
  re_top='^[^\\'"'"'"`$()}'$'\t'' ;&|<>]*'
  r="$s"
  while [ -n "$r" ]; do
    top="${stack: -1}"
    case "$top" in
      "'") re=$re_sq ;;
      '"'|'`') re=$re_dq ;;
      *) re=$re_top ;;
    esac
    # A failed match (for example on bytes that are not valid in the
    # locale) leaves an empty run. Then the loop reads one character.
    run=""
    if [[ "$r" =~ $re ]]; then
      run="${BASH_REMATCH[0]}"
    fi
    if [ -n "$run" ]; then
      used=$((used + ${#run}))
      r="${r:${#run}}"
      [ -n "$r" ] || break
    fi
    c="${r:0:1}"
    nc="${r:1:1}"
    step=1
    case "$top" in
      "'")
        [ "$c" != "'" ] || stack="${stack%?}"
        ;;
      '"'|'`')
        case "$c" in
          \\) step=2 ;;
          "$top") stack="${stack%?}" ;;
          '`') stack+='`' ;;
          '$') case "$nc" in '('|'{') stack+="$nc"; step=2 ;; esac ;;
        esac
        ;;
      *)
        case "$c" in
          \\) step=2 ;;
          "'"|'"'|'`') stack+="$c" ;;
          '$') case "$nc" in '('|'{') stack+="$nc"; step=2 ;; esac ;;
          '(')
            [ -n "$stack" ] || return 1
            stack+='('
            ;;
          ')')
            if [ "$top" = '(' ]; then
              stack="${stack%?}"
            elif [ -z "$stack" ]; then
              break
            else
              return 1
            fi
            ;;
          '}') [ "$top" != '{' ] || stack="${stack%?}" ;;
          ' '|$'\t'|';'|'&'|'|'|'<'|'>') [ -n "$stack" ] || break ;;
        esac
        ;;
    esac
    used=$((used + step))
    r="${r:step}"
  done
  if [ -n "$stack" ]; then
    # A quote or a substitution is still open at the end of the text.
    _GIT_RAW_OPEN=1
    return 1
  fi
  if [ "$used" -gt "${#s}" ]; then
    # A backslash at the end escapes the character after the text.
    used=${#s}
    _GIT_RAW_OPEN=2
  fi
  [ "$used" -gt 0 ] || return 1
  _GIT_TAKEN="${s:0:used}"
  _GIT_SCAN="${s:used}"
  return 0
}

# Consume one redirection from $_GIT_SCAN (#1772).
# Returns 1 when the next token is not a redirection.
# Returns 2 when the target is not one closed shell word (#1805 B2). The
# caller then fails closed.
_git_take_redir() {
  # #1772 N2: the zsh forms and a named descriptor use the shared units.
  local re='^'"${_git_redir_fd}${_git_redir_op}"
  [[ "$_GIT_SCAN" =~ $re ]] || return 1
  _GIT_SCAN="${_GIT_SCAN:${#BASH_REMATCH[0]}}"
  # #1772 R2-2: an operator that ends in `!`, followed by a blank, has two
  # readings. Zsh reads the operator and then the next word as the target.
  # Bash reads `>` (or `>>`, `&>`, `>&`) with the target `!`, and the next
  # word is an argument. The two readings can give different options or a
  # different verb. Fail closed.
  case "${BASH_REMATCH[0]}" in
    *'!')
      case "$_GIT_SCAN" in
        [[:space:]]*) return 2 ;;
      esac
      ;;
  esac
  _GIT_SCAN="${_GIT_SCAN#"${_GIT_SCAN%%[![:space:]]*}"}"
  # A bare operator with no target is still a redirection token.
  [ -n "$_GIT_SCAN" ] || return 0
  case "$_GIT_SCAN" in
    [\;\&\|]|[\;\&\|]*) return 0 ;;
  esac
  # Digit-only target for >&1 / <&0 / >&- forms.
  # The target must end at a word boundary. A digit that runs into more text
  # is one file name, so the raw-word reader takes the whole word.
  if [[ "$_GIT_SCAN" =~ ^([0-9]+|-)([[:space:];&|]|$) ]]; then
    _GIT_SCAN="${_GIT_SCAN:${#BASH_REMATCH[1]}}"
    return 0
  fi
  _git_take_raw_word || return 2
  return 0
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
    --git-dir[[:space:]]*|--work-tree[[:space:]]*|--namespace[[:space:]]*|--super-prefix[[:space:]]*|--config-env[[:space:]]*|--attr-source[[:space:]]*)
      name="${_GIT_SCAN%%[[:space:]]*}"
      _GIT_SCAN="${_GIT_SCAN#"$name"}"
      _git_take_value || return 1
      case "$name" in
        --git-dir) _GIT_RAW_GIT_DIR="$_GIT_TAKEN" ;;
        --work-tree) _GIT_RAW_WORK_TREE="$_GIT_TAKEN" ;;
      esac
      ;;
    --git-dir=*|--work-tree=*|--namespace=*|--super-prefix=*|--config-env=*|--attr-source=*)
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

# Strip a matched git command word (quoted / any case) from the start of $1.
# Leaves the remainder in $_GIT_SCAN. Returns 1 when the word is not git.
_git_strip_cmd_word() {
  local s="$1" re
  # Do not double-quote $_git_cmd_word; it holds literal " characters.
  re='^'${_git_cmd_word}
  if [[ "$s" =~ $re ]]; then
    _GIT_SCAN="${s:${#BASH_REMATCH[0]}}"
    return 0
  fi
  # Match may include one leading boundary character from grep -oE.
  s="${s#?}"
  if [[ "$s" =~ $re ]]; then
    _GIT_SCAN="${s:${#BASH_REMATCH[0]}}"
    return 0
  fi
  return 1
}

# Walk global options and redirections in $_GIT_SCAN until <sub>.
# On success, $_GIT_SCAN is the text after that subcommand.
# #1772: skip redirections the same way the shell does.
# #1816 G5: decode a quoted or partly quoted verb with _git_take_value.
# Keep the trailing-boundary case so a match like `git push` (with a closing
# backtick) still finds the verb.
_git_scan_globals() {
  local sub="$1" saved word rrc
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
    # Glued or spaced redirection before the verb (#1772).
    rrc=0
    _git_take_redir || rrc=$?
    if [ "$rrc" -eq 0 ]; then
      continue
    fi
    # #1805 B2: an unclosed target hides what follows. Fail closed.
    [ "$rrc" -eq 1 ] || return 1
    saved="$_GIT_SCAN"
    if _git_take_value; then
      word="$_GIT_TAKEN"
      if [ "$word" = "$sub" ]; then
        return 0
      fi
      _GIT_SCAN="$saved"
    fi
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
  _git_strip_cmd_word "$inv" || return 1
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
  _git_strip_cmd_word "$segment" || return 0
  if _git_scan_globals push; then
    printf '%s' "$_GIT_SCAN"
  fi
}

# Print the words after `git [global options] push`, one on each line
# (#1831). $1 starts at the git command word and goes to the end of its line.
# Skip each redirection as the shell does. Stop at the `;`, `&`, `|` or `)`
# that ends the command. A word keeps its quotes.
# Return 1 when $1 holds no push verb. Return 2 when the push arguments
# cannot be read: a redirection target is not one closed word, an operator
# has two readings, or a word is not closed on its line and the invocation
# holds a redirection. Also return 2 when the arguments hold a unit
# separator byte (0x1F), because the walk uses that byte to split the line
# into pieces. The caller then fails closed.
# A word that is not closed on its line in an invocation with no redirection
# ends the walk. Then print the rest split at blanks, as before #1831.
# Linear for words separated by blanks: each word step reads one piece, as
# in _git_redir_hides_verb.
git_push_ref_words() {
  local inv="$1" norm saw=0 us tsep np wpi pos rest op op_re
  local -a pieces endp
  _git_strip_cmd_word "$inv" || return 1
  _git_scan_globals push || return 2
  norm="$_GIT_SCAN"
  # The text before the arguments. A suffix pattern is slow on a long line.
  case "${inv:0:$((${#inv} - ${#norm}))}" in *'<'*|*'>'*) saw=1 ;; esac
  op_re='^'"${_git_redir_fd}${_git_redir_op}"
  us=$'\037'
  # #1831 B1: the walk cannot split text that already holds the separator
  # byte. A real push does not hold it. Fail closed.
  case "$norm" in *"$us"*) return 2 ;; esac
  tsep=$(printf '%s\n' "$norm" | tr ' \t' '\037\037')
  IFS="$us" read -r -a pieces <<EOF_PUSH_PIECES
${tsep}${us}x
EOF_PUSH_PIECES
  unset "pieces[$((${#pieces[@]} - 1))]"
  np=${#pieces[@]}
  endp=()
  pos=-1
  for rest in ${pieces[@]+"${pieces[@]}"}; do
    pos=$((pos + 1 + ${#rest}))
    endp[${#endp[@]}]=$pos
  done
  [ "$np" -gt 0 ] || return 0
  wpi=0
  _GIT_SCAN="${pieces[0]}"
  while :; do
    if [ -z "$_GIT_SCAN" ]; then
      wpi=$((wpi + 1))
      [ "$wpi" -lt "$np" ] || break
      _GIT_SCAN="${pieces[wpi]}"
      continue
    fi
    case "$_GIT_SCAN" in '&>'*) ;; [\;\&\|\)]*) break ;; esac
    case "$_GIT_SCAN" in
      *[\\\'\"\`\$\(\)\<\>\;\&\|]*) ;;
      *)
        # A plain word fills the rest of the piece.
        printf '%s\n' "$_GIT_SCAN"
        _GIT_SCAN=""
        continue
        ;;
    esac
    op=""
    case "$_GIT_SCAN" in
      [0-9\{\<\>\&]*) [[ "$_GIT_SCAN" =~ $op_re ]] && op="${BASH_REMATCH[0]}" ;;
    esac
    if [ -n "$op" ]; then
      _GIT_SCAN="${_GIT_SCAN:${#op}}"
      saw=1
      # #1772 R2-2: a `!` operator and then a blank has two readings.
      case "$op" in *'!') [ -n "$_GIT_SCAN" ] || return 2 ;; esac
      while [ -z "$_GIT_SCAN" ] && [ $((wpi + 1)) -lt "$np" ]; do
        wpi=$((wpi + 1))
        _GIT_SCAN="${pieces[wpi]}"
      done
      case "$_GIT_SCAN" in ''|[\;\&\|]*) break ;; esac
      if [[ "$_GIT_SCAN" =~ ^([0-9]+|-)([;&|]|$) ]]; then
        _GIT_SCAN="${_GIT_SCAN:${#BASH_REMATCH[1]}}"
        continue
      fi
      _git_redir_take_word || return 2
      continue
    fi
    rest="$_GIT_SCAN"
    if _git_redir_take_word; then
      printf '%s\n' "$_GIT_TAKEN"
      continue
    fi
    [ "$saw" -eq 0 ] || return 2
    # No redirection: split the rest at blanks, up to a separator. A failed
    # read can leave the rest of the line in $_GIT_SCAN. Start again from
    # the current piece.
    _GIT_SCAN="$rest"
    while :; do
      rest="${_GIT_SCAN%%[;&|]*}"
      [ -z "$rest" ] || printf '%s\n' "$rest"
      [ "$rest" = "$_GIT_SCAN" ] || break
      wpi=$((wpi + 1))
      [ "$wpi" -lt "$np" ] || break
      _GIT_SCAN="${pieces[wpi]}"
    done
    break
  done
  return 0
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

# #1833 (AgDR-0270): the text for the structure parse (alias check, cd
# chain, -C). It strips a quoted heredoc body only when the whole command is
# one allow-listed data sink (`quoted` mode, AgDR-0262). Any other shape, or
# a stripper that cannot load or fails, gives the raw command. The gate
# bodies still read the raw command for their own checks.
_git_structure_text() {
  local text="$1" out
  case "$text" in *'<<'*) ;; *) printf '%s' "$text"; return 0 ;; esac
  if ! declare -F strip_heredoc_bodies >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "$(dirname "${BASH_SOURCE[0]}")/_lib-strip-heredoc.sh" 2>/dev/null || true
  fi
  if declare -F strip_heredoc_bodies >/dev/null 2>&1 \
    && out=$(strip_heredoc_bodies "$text" quoted 2>/dev/null); then
    printf '%s' "$out"
  else
    printf '%s' "$text"
  fi
}

# Resolve cd, then each -C, then repository paths for the selected invocation.
git_prepare_invocation() {
  local cmd="$1" sub="$2" cwd="${3:-$PWD}" dir raw base
  cmd=$(_git_structure_text "$cmd")
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
  cmd=$(_git_structure_text "$cmd")
  cwd=$(printf '%s' "$input" | jq -r '.cwd // .tool_input.cwd // empty' 2>/dev/null)
  if [ "$mode" = block ]; then
    git_alias_check "$@" || return 2
    # #1816 G2/G3: an expansion hides the command word or verb.
    if git_uncertain_protected_shape "$cmd"; then
      if _git_text_has_dashed_protected "$cmd"; then
        # #1825: name the program class, not an expansion or a redirection.
        echo "BLOCKED: this command runs git's own dashed push or commit program, or a program name that can become one. Use the normal git command word with a literal push or commit. If this is prose, write it to a file and pass -F or --body-file." >&2
      else
        echo "BLOCKED: a shell expansion or redirection hides the git command word or verb. Use a literal git push or git commit." >&2
      fi
      return 2
    fi
  fi
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

# Raw-text alias backstop. See AgDR-0253 for the exact scope and residuals.

_git_alias_block() { printf 'BLOCKED: %s\n' "$*" >&2; return 2; }
_git_alias_lower() {
  # Bash 3.2 has no ${value,,} expansion.
  _GA_LOWER="$1"
  local upper=ABCDEFGHIJKLMNOPQRSTUVWXYZ lower=abcdefghijklmnopqrstuvwxyz i
  for ((i=0; i<26; i++)); do
    _GA_LOWER="${_GA_LOWER//${upper:i:1}/${lower:i:1}}"
  done
}
_git_alias_builtin() {
  case "$1" in
    add|branch|checkout|cherry-pick|clone|commit|config|diff|fetch|init|log|ls-files|merge|mv|pull|push|remote|reset|rev-parse|rm|show|status|tag|worktree) return 0 ;;
    rebase|stash) [ "$_GA_EXEC_CHANGED" = 1 ] || return 0 ;;
  esac
  if [ "$_GA_SETUP" = 0 ]; then
    _GA_BUILTINS=$(git --list-cmds=builtins 2>/dev/null) || _GA_BUILTINS=""
    _GA_SETUP=1
  fi
  case $'\n'"$_GA_BUILTINS"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac
  return 1
}
# Read a word with the shared grammar when the literal scanner rejects escapes.
_git_alias_word() {
  local raw="$_GIT_SCAN" re="^${_git_opt_val}"
  if _git_take_value; then return 0; fi
  _GIT_SCAN="${raw#"${raw%%[![:space:]]*}"}"
  if [[ "$_GIT_SCAN" =~ $re ]]; then
    _GIT_TAKEN="${BASH_REMATCH[0]}"
    _GIT_SCAN="${_GIT_SCAN:${#_GIT_TAKEN}}"
    return 0
  fi
  return 1
}
# Decode a literal verb without changing the strict repository-path reader.
_git_alias_literal_verb() {
  local raw="$1" out="" quote="" char next i
  for ((i=0; i<${#raw}; i++)); do
    char="${raw:i:1}"
    if [ "$quote" = "'" ]; then
      if [ "$char" = "'" ]; then quote=""; else out+="$char"; fi
    elif [ "$char" = '\' ]; then
      i=$((i+1)); [ "$i" -lt "${#raw}" ] || return 1
      next="${raw:i:1}"
      if [ "$quote" = '"' ]; then
        case "$next" in
          '$'|'`'|'"'|'\') out+="$next" ;;
          $'\n') ;;
          *) out+="\\$next" ;;
        esac
      elif [ "$next" != $'\n' ]; then out+="$next"; fi
    elif [ -n "$quote" ]; then
      if [ "$char" = "$quote" ]; then quote=""; else out+="$char"; fi
    else
      case "$char" in
        \"|\') quote="$char" ;;
        '$'|'`'|'{'|'}') return 1 ;;
        *) out+="$char" ;;
      esac
    fi
  done
  [ -z "$quote" ] || return 1
  _GA_DECODED="$out"
}
# Parse options once. Retain literal inline config and target options.
_git_alias_parse() {
  local word raw name quote="" c i region="" before _GA_DECODED=""
  _GA_INLINE=() _GA_TARGET=() _GA_OPAQUE=0 _GA_UNREADABLE=0 _GA_VERB=""
  # #1816: accept a quoted or case-variant command word.
  if ! _git_strip_cmd_word "$1"; then
    _GA_OPAQUE=1
    _GA_VERB=""
    return 0
  fi
  while :; do
    _GIT_SCAN="${_GIT_SCAN#"${_GIT_SCAN%%[![:space:]]*}"}"
    before="$_GIT_SCAN"
    _git_alias_word || { _GA_OPAQUE=1; break; }
    word="$_GIT_TAKEN"
    region+="${before:0:${#before}-${#_GIT_SCAN}} "
    case "$word" in
      -c|--config-env|-C|--git-dir|--work-tree|--namespace|--super-prefix|--attr-source)
        name="$word"; raw="$_GIT_SCAN"
        if ! _git_take_value; then
          case "$name" in -c|--config-env) _GA_UNREADABLE=1 ;; *) _GA_OPAQUE=1 ;; esac
          _GIT_SCAN="$raw"
          _git_alias_word || { _GA_OPAQUE=1; break; }
        fi
        word="$_GIT_TAKEN"
        region+="${raw:0:${#raw}-${#_GIT_SCAN}} "
        case "$name" in
          -c) _GA_INLINE+=("$word") ;;
          --config-env) _GA_UNREADABLE=1 ;;
          -C) _GA_TARGET+=(-C "$word") ;;
          --git-dir|--work-tree) _GA_TARGET+=("$name=$word") ;;
        esac
        ;;
      --config-env=*) _GA_UNREADABLE=1 ;;
      --git-dir=*|--work-tree=*) _GA_TARGET+=("$word") ;;
      --*|-*) ;;
      *)
        _GA_VERB="$word"
        raw="${before:0:${#before}-${#_GIT_SCAN}}"
        if [[ "$raw" = *'\'* ]] && _git_alias_literal_verb "$raw"; then
          _GA_VERB="$_GA_DECODED"
        fi
        break ;;
    esac
  done
  for raw in ${_GA_INLINE[@]+"${_GA_INLINE[@]}"}; do
    case "$raw" in *'$'*|*'`'*|*'\'*) _GA_UNREADABLE=1 ;; esac
  done
  case "$_GA_VERB" in *'$'*|*'`'*|*'\'*) _GA_OPAQUE=1 ;; esac
  # Exact unquoted expansion set: $, backtick, {, }, *, ?, [, <, >.
  for ((i=0; i<${#region}; i++)); do
    c="${region:i:1}"
    if [ -n "$quote" ]; then
      [ "$c" != "$quote" ] || quote=""
    else
      case "$c" in
        \"|\') quote="$c" ;;
        '\') i=$((i+1)) ;;
        '$'|'`'|'{'|'}'|'*'|'?'|'['|'<'|'>') _GA_OPAQUE=1 ;;
      esac
    fi
  done
}
# Merge both git alias key forms without executing config values.
_git_alias_entry() {
  local key="$1" value="$2" slot name tail i
  _git_alias_lower "$key"; key="$_GA_LOWER"
  case "$key" in
    help.autocorrect) _GA_AUTO="$value"; return ;;
    alias.*) ;;
    *) return ;;
  esac
  name="${1#*.}"; tail="${key##*.}"
  if [ "$tail" = command ] && [[ "$name" = *.* ]]; then
    slot="E:${name%.*}"
  else
    _git_alias_lower "$name"; slot="I:$_GA_LOWER"
  fi
  for ((i=0; i<${#_GA_KEYS[@]}; i++)); do
    if [ "${_GA_KEYS[i]}" = "$slot" ]; then _GA_VALUES[i]="$value"; return; fi
  done
  _GA_KEYS+=("$slot"); _GA_VALUES+=("$value")
}
_git_alias_unknown() {
  local hop="$1"
  if [ "$_GA_DEFINITION" = 1 ]; then
    _git_alias_block "this command writes git config and runs git $_GA_ROOT. Run them as two commands. If this is prose, write it to a file and pass -F or --body-file."; return 2
  fi
  if [ "$_GA_CONDITION" = 1 ]; then
    _git_alias_block "an includeIf entry can change git config during this command. Run git $_GA_ROOT in a separate command."; return 2
  fi
  if [ "$hop" = 0 ]; then
    case "$_GA_AUTO" in ''|0|false|never|show) ;; *)
      _git_alias_block "help.autocorrect is set and git $_GA_ROOT is not a command. Type the full verb."; return 2 ;;
    esac
  fi
  return 0
}
_git_alias_external() {
  [ "$_GA_EXTERNAL_OFF" = 0 ] || return 1
  local dir file oldifs
  # List executable names once. Relative PATH entries depend on git's cwd.
  if [ "$_GA_EXTERNAL_SETUP" = 0 ]; then
    _GA_EXEC_PATH=$(git --exec-path 2>/dev/null) || _GA_EXEC_PATH=""
    _GA_EXTERNAL_SETUP=1
    oldifs="$IFS"; IFS=:
    for dir in "$_GA_EXEC_PATH" $PATH; do
      case "$dir" in /*) ;; *) continue ;; esac
      for file in "$dir"/git-*; do
        [ -x "$file" ] && [ ! -d "$file" ] || continue
        _GA_EXTERNAL_NAMES+="${file##*/git-}"$'\n'
      done
    done
    IFS="$oldifs"
  fi
  case $'\n'"$_GA_EXTERNAL_NAMES" in *$'\n'"$1"$'\n'*) return 0 ;; esac
  return 1
}
# Each recursive branch has its own inline entries. The shared view is immutable.
_git_alias_resolve() {
  local verb="$1" depth="$2" seen="$3" i value found=0 word key
  local -a values=() keys=(${_GA_KEYS[@]+"${_GA_KEYS[@]}"}) saved_values=(${_GA_VALUES[@]+"${_GA_VALUES[@]}"})
  _git_alias_lower "$verb"
  for ((i=0; i<${#_GA_KEYS[@]}; i++)); do
    if [ "${_GA_KEYS[i]}" = "I:$_GA_LOWER" ] || [ "${_GA_KEYS[i]}" = "E:$verb" ]; then
      values+=("${_GA_VALUES[i]}"); found=1
    fi
  done
  if [ "$found" = 0 ]; then
    _git_alias_external "$verb" && return 0
    _git_alias_unknown "$depth"; return $?
  fi
  if [ "$depth" -ge 10 ] || [[ "$seen" = *"|$verb|"* ]]; then
    _git_alias_block "git $_GA_ROOT has an alias loop or more than 10 alias hops. Run the real verb directly."; return 2
  fi
  for value in ${values[@]+"${values[@]}"}; do
    case "$value" in '!'*)
      _git_alias_block "git $_GA_ROOT is a shell alias. Run the alias body directly so the gates can check it."; return 2 ;;
    esac
    _GIT_SCAN="$value"
    while :; do
      _git_take_value || { _git_alias_block "git $_GA_ROOT has an unreadable alias expansion. Run the real verb directly."; return 2; }
      word="$_GIT_TAKEN"
      case "$value" in *'"'*|*"'"*|*'\'*|*'$'*|*'`'*)
        # Only text consumed up to the verb is relevant.
        local consumed="${value:0:${#value}-${#_GIT_SCAN}}"
        case "$consumed" in *'"'*|*"'"*|*'\'*|*'$'*|*'`'*)
          _git_alias_block "git $_GA_ROOT has an unreadable alias expansion. Run the real verb directly."; return 2 ;; esac ;;
      esac
      case "$word" in
        -p|--paginate) continue ;;
        -c)
          _git_take_value || return 2
          key="${_GIT_TAKEN%%=*}"; _git_alias_lower "$key"
          case "$_GA_LOWER" in
            include.*|includeif.*|core.fsmonitor|core.hookspath|core.pager|core.editor|sequence.editor|core.sshcommand|diff.external|gpg.program|credential.helper)
              _git_alias_block "git $_GA_ROOT is a shell alias. Run the alias body directly so the gates can check it."; return 2 ;;
          esac
          _git_alias_entry "$key" "${_GIT_TAKEN#*=}"; continue ;;
        -*) _git_alias_block "git $_GA_ROOT has an unsupported alias option. Run the real verb directly."; return 2 ;;
      esac
      break
    done
    if _git_alias_builtin "$word"; then
      case " $_GA_VERBS " in *" $word "*)
        _git_alias_block "git $_GA_ROOT is an alias for git $word. Run git $word directly so the gates can check it."; return 2 ;;
      esac
    else
      _git_alias_resolve "$word" "$((depth+1))" "$seen|$verb|" || return 2
    fi
    _GA_KEYS=(${keys[@]+"${keys[@]}"}); _GA_VALUES=(${saved_values[@]+"${saved_values[@]}"})
  done
  return 0
}

# Read one NUL-terminated config record from FD 3 into key and value.
# Git -z form is key, newline, value, NUL. Bash 3.2 cannot hold NUL in a
# variable from command substitution, so the caller must feed a temp file.
_git_alias_read_z_record() {
  local record
  IFS= read -r -d '' record <&3 || {
    [ -n "$record" ] || return 1
  }
  [ -n "$record" ] || return 1
  case "$record" in
    *$'\n'*)
      key="${record%%$'\n'*}"
      value="${record#*$'\n'}"
      ;;
    *)
      return 2
      ;;
  esac
  return 0
}

# Caller supplies cmd and cwd in the parent shell. No command text is executed.
git_alias_check() {
  local LC_ALL=C
  local _GA_VERBS="$*" text positions rc pos prev rest candidate pattern seen=$'\n' count=0
  local _GA_SETUP=0 _GA_BUILTINS="" _GA_EXEC_CHANGED=0 _GA_EXTERNAL_OFF=0
  local _GA_EXTERNAL_SETUP=0 _GA_EXEC_PATH="" _GA_EXTERNAL_NAMES="" _GA_CHANNEL="" _GA_DEFINITION=0
  local _GA_CREATES_REPO=0 _GA_CREATION_SCANNED=0
  local _GA_CONDITION=0 _GA_AUTO="" _GA_ROOT="" _GA_OPAQUE=0 _GA_UNREADABLE=0 _GA_VERB=""
  local _GA_LOWER key value line target gitdir cachekey view index i dir token clean
  local -a _GA_INLINE=() _GA_TARGET=() _GA_KEYS=() _GA_VALUES=() cachekeys=() views=() candidates=() candidate_positions=() candidate_cwds=()
  local -a _GA_VIEWFILES=()
  _git_alias_cleanup_views() {
    local f
    for f in ${_GA_VIEWFILES[@]+"${_GA_VIEWFILES[@]}"}; do rm -f "$f"; done
  }
  trap '_git_alias_cleanup_views' RETURN
  local entry_re="$_git_cmd_word"
  [[ "${cmd:-}" =~ $entry_re ]] || return 0
  if ! command -v join_shell_continuations >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "$(dirname "${BASH_SOURCE[0]}")/_lib-awk-fallback.sh" || return 2
  fi
  text=$(join_shell_continuations "$cmd") || { _git_alias_block 'cannot join git command continuations.'; return 2; }
  # #1816: find quoted and case-variant command words too.
  # shellcheck disable=SC2090
  positions=$(printf '%s' "$text" | grep -aboE ${_git_cmd_word}'([[:space:]]|<|>)'); rc=$?
  [ "$rc" -le 1 ] || { _git_alias_block 'cannot scan git aliases.'; return 2; }
  local verb_word_re='(\\.|"[^"]*"|'"'"'[^'"'"']*'"'"'|\$\([^)]*\)|`[^`]*`|[^[:space:];&|"'"'"'()<>]+)+'
  pattern='^'${_git_cmd_word}${_git_sub_opts}${verb_word_re}
  # This is the no-option branch of the same anchored candidate grammar.
  # Compile the full option grammar only when this branch cannot match.
  local literal_re='^('${_git_cmd_word}' +[a-zA-Z0-9_.][a-zA-Z0-9_.-]*)([[:space:];&|()<>]|$)'
  local window="${text:0:512}" window_start=0 relative
  while IFS=: read -r pos rest; do
    [ -n "$pos" ] || continue
    relative=$((pos-window_start))
    if [ "$((relative+64))" -gt "${#window}" ]; then
      window_start=$((pos>0 ? pos-1 : 0))
      window="${text:window_start:512}"
      relative=$((pos-window_start))
    fi
    # Same boundary class as _git_sub_re: (^|[^[:alnum:]_.-]).
    # A path-qualified git (/usr/bin/git, ./git, ~/bin/git) must match.
    if [ "$pos" -gt 0 ]; then
      prev="${window:relative-1:1}"
      case "$prev" in [[:alnum:]_.-]) continue ;; esac
    fi
    # Try a short literal word first. Long or quoted words use the full grammar.
    rest="${window:relative:64}"
    case "$rest" in
      git'<'*|git'>'*|GIT'<'*|GIT'>'*|Git'<'*|Git'>'*)
        candidate="${rest:0:4}" ;;
      *) if [[ "$rest" =~ $literal_re ]] && { [ "${#BASH_REMATCH[1]}" -lt 64 ] || [ "$((${#text}-pos))" -le 64 ]; }; then candidate="${BASH_REMATCH[1]}"
         else
           rest="${text:pos}"
           if [[ "$rest" =~ $pattern ]]; then candidate="${BASH_REMATCH[0]}"
           else continue; fi
         fi ;;
    esac
    # Encode line separators before one deduplication pass. Escaping the
    # backslash first keeps this encoding injective for arbitrary text.
    token="$candidate"
    case "$token" in *'\'*|*$'\n'*)
      token="${candidate//\\/\\\\}"
      token="${token//$'\n'/\\n}" ;;
    esac
    seen+="$token"$'\n'
    candidates[count]="$candidate"; candidate_positions[count]="$pos"; count=$((count+1))
  done <<EOF_POSITIONS
$positions
EOF_POSITIONS
  count=$(printf '%s' "$seen" | awk 'NF && !seen[$0]++ { n++ } END { print n+0 }') || {
    _git_alias_block 'cannot deduplicate git alias candidates.'; return 2
  }
  [ "$count" -le 4000 ] || { _git_alias_block 'too many git mentions to check for aliases. Write the prose to a file and pass -F or --body-file.'; return 2; }
  [ "$count" -gt 0 ] || return 0
  clean="$text"
  for token in HOME XDG_CONFIG_HOME GIT_DIR GIT_COMMON_DIR PATH; do
    clean="${clean//'${'"$token"'}'/}"
    clean="${clean//'$'"$token"/}"
  done
  if [[ "$text" = *--exec-path* || "$text" = *GIT_EXEC_PATH* ]]; then _GA_EXEC_CHANGED=1; fi
  # Read forms were removed above; other literal environment names count.
  local channel_re='(^|[^[:alnum:]_])(HOME|XDG_CONFIG_HOME|GIT_DIR|GIT_COMMON_DIR|GIT_CONFIG[A-Za-z_0-9]*)([^[:alnum:]_]|$)'
  if [[ "$clean" =~ $channel_re ]]; then _GA_CHANNEL="${BASH_REMATCH[2]}"; fi
  case "$clean" in *--config-env*) _GA_CHANNEL="${_GA_CHANNEL:---config-env}" ;; esac
  if [[ "$clean" =~ (^|[^[:alnum:]_])PATH([^[:alnum:]_]|$)|GIT_EXEC_PATH|--exec-path|env[[:space:]]+(-i|-([[:space:]]|$)|-u|--unset|--ignore-environment)|exec[[:space:]]+-c ]]; then _GA_EXTERNAL_OFF=1; fi
  local include_channel_re='-c[[:space:]]+["'"'"']?([iI][nN][cC][lL][uU][dD][eE]\.|[iI][nN][cC][lL][uU][dD][eE][iI][fF]\.)'
  if [[ "$clean" =~ $include_channel_re ]]; then _GA_CHANNEL="${_GA_CHANNEL:-include}"; fi
  _git_alias_lower "$clean"; clean="$_GA_LOWER"
  case "$clean" in *alias.*|*include.*|*includeif.*|*'[alias'*|*'[include'*|*.gitconfig*|*git/config*|*config.worktree*) _GA_DEFINITION=1 ;; esac
  # #1816 G8: a config path write (including .git//config and .git/./config).
  # Distinct from inline -c alias.* which still resolves normally.
  local _GA_CONFIG_PATH_WRITE=0
  if [[ "$clean" =~ \.git[/./]*config ]] || [[ "$clean" = *.gitconfig* ]] || [[ "$clean" = *config.worktree* ]]; then
    _GA_DEFINITION=1
    _GA_CONFIG_PATH_WRITE=1
  fi
  # #1816 G7: repository path the resolver cannot follow statically.
  local _GA_HARD_UNRESOLVED=0
  if [[ "$text" =~ (^|[^[:alnum:]_.-])env[[:space:]]+(-C|--chdir)([[:space:]]|=) ]] \
    || [[ "$text" =~ \([[:space:]]*cd[[:space:]] ]] \
    || [[ "$text" =~ (^|[^[:alnum:]_.-])cd[[:space:]]+-P([[:space:]]|$) ]]; then
    _GA_HARD_UNRESOLVED=1
  fi
  if _git_text_has_nested_shell "$text" \
    || [[ "$text" =~ (^|[^[:alnum:]_.-])env[[:space:]].*(-C|--chdir)([[:space:]]|=) ]]; then
    _GA_HARD_UNRESOLVED=1
  fi
  # Walk the directory chain once. Unresolved changes block non-builtin verbs.
  local _GIT_TAKEN=""
  local segments segment chain_cwd="${cwd:-$PWD}" segment_start=0 segment_end prefix consumed=0 ci=0 chain_bad=0
  if [[ "$text" =~ (^|[^[:alnum:]_.-])(cd|pushd|popd)([[:space:]]|$) ]]; then
    segments=$(_git_chain_segments "$text") || return 2
    rest="$text"
    while IFS= read -r segment; do
      prefix="${rest%%"$segment"*}"
      segment_start=$((consumed+${#prefix}))
      segment_end=$((segment_start+${#segment}))
      rest="${rest#*"$segment"}"; consumed="$segment_end"
      local trimmed="${segment#"${segment%%[![:space:]]*}"}"
      case "$trimmed" in
        cd|cd[[:space:]]*)
          _GIT_TAKEN=""
          _GIT_SCAN="${trimmed#cd}"
          if [ -z "${_GIT_SCAN//[[:space:]]/}" ]; then _GIT_TAKEN="$HOME";
          elif ! _git_take_value; then chain_bad=1; fi
          if [ "${_GIT_TAKEN:-}" = -- ]; then _git_take_value || chain_bad=1; fi
          if [ "${_GIT_TAKEN:-}" = -P ]; then
            _GA_HARD_UNRESOLVED=1
            _git_take_value || chain_bad=1
          fi
          dir=$(_git_resolve_dir "${_GIT_TAKEN:-}" "$chain_cwd") && [ -d "$dir" ] && chain_cwd="$dir" || chain_bad=1
          local tail="${_GIT_SCAN#"${_GIT_SCAN%%[![:space:]]*}"}"
          if [ -n "$tail" ] && ! [[ "$tail" =~ ^\|\|[[:space:]]*(exit|return)([[:space:]]+[0-9]+)?[[:space:]]*$ ]]; then chain_bad=1; fi
          ;;
        *) [[ "$trimmed" =~ ^(pushd|popd|\([[:space:]]*cd)([[:space:]]|$) ]] && chain_bad=1 ;;
      esac
      for ((i=0; i<${#candidates[@]}; i++)); do
        pos="${candidate_positions[i]}"
        if [ "$pos" -ge "$segment_start" ] && [ "$pos" -lt "$segment_end" ]; then
          candidate_cwds[i]="$chain_cwd"
          [ "$chain_bad" = 0 ] || candidate_cwds[i]="${cwd:-$PWD}"
        fi
      done
    done <<EOF_SEGMENTS
$segments
EOF_SEGMENTS
  fi
  [ "$chain_bad" = 0 ] || _GA_HARD_UNRESOLVED=1
  local creation_re="${_git_sub_re}(init|clone|worktree)([^[:alnum:]_.-]|$)"
  if [[ "$text" =~ $creation_re ]]; then _GA_CREATES_REPO=1; fi
  local alias_free_payload=0 simple_re='^'${_git_cmd_word}'[[:space:]]+[^[:space:]-][^[:space:]]*$'
  for candidate in ${candidates[@]+"${candidates[@]}"}; do
    if [ "$alias_free_payload" = 1 ] && [[ "$candidate" =~ $simple_re ]]; then
      ci=$((ci+1)); continue
    fi
    if [ "${#candidate}" -gt 2048 ]; then
      _GA_OPAQUE=1; _GA_VERB='(opaque)'; _GA_INLINE=(); _GA_TARGET=(); _GA_UNREADABLE=0
    else
      _git_alias_parse "$candidate"
    fi
    target="${candidate_cwds[ci]:-${cwd:-$PWD}}"; ci=$((ci+1))
    _GA_ROOT="$_GA_VERB"
    if [ "$_GA_OPAQUE" = 0 ] && _git_alias_builtin "$_GA_VERB"; then continue; fi
    # #1816 G7: an alias (non-builtin) with a repository path we cannot follow.
    # A builtin still reaches the push/commit gates so they can report the
    # ordinary unresolvable -C message.
    if [ "$_GA_HARD_UNRESOLVED" = 1 ] && ! _git_alias_builtin "$_GA_VERB"; then
      _git_alias_block "cannot resolve the repository for this git alias. Use a literal directory change or -C path, then run the real verb. If this is prose, write it to a file and pass -F or --body-file."; return 2
    fi
    # #1816 G8: a config path write can replace an alias before git runs.
    if [ "$_GA_CONFIG_PATH_WRITE" = 1 ] && ! _git_alias_builtin "$_GA_VERB"; then
      _git_alias_block "this command writes git config and runs git $_GA_ROOT. Run them as two commands. If this is prose, write it to a file and pass -F or --body-file."; return 2
    fi
    if [ -n "$_GA_CHANNEL" ]; then
      _git_alias_block "this command changes git config ($_GA_CHANNEL) and runs git $_GA_ROOT. Run the real verb without the change. If this is prose, write it to a file and pass -F or --body-file."; return 2
    fi
    if [ "$_GA_UNREADABLE" = 1 ]; then
      _git_alias_block 'git cannot be checked with this -c value. Quote the -c value. Use a literal key and value with no $, backtick or backslash.'; return 2
    fi
    # A terminal inline alias decides the first hop without a config fork.
    # A chain that continues still needs the target view.
    if [ "$_GA_OPAQUE" = 0 ] && [ "${#_GA_INLINE[@]}" -gt 0 ]; then
      _GA_KEYS=(); _GA_VALUES=()
      for line in ${_GA_INLINE[@]+"${_GA_INLINE[@]}"}; do
        _git_alias_entry "${line%%=*}" "${line#*=}"
      done
      _git_alias_lower "$_GA_VERB"
      local inline_slot="$_GA_LOWER" inline_found=0 inline_terminal=1 first
      for ((i=0; i<${#_GA_KEYS[@]}; i++)); do
        if [ "${_GA_KEYS[i]}" = "I:$inline_slot" ] || [ "${_GA_KEYS[i]}" = "E:$_GA_VERB" ]; then
          inline_found=$((inline_found+1)); first="${_GA_VALUES[i]%%[[:space:]]*}"
          case "$first" in '! '*) ;; '!'*) ;; *)
            _git_alias_builtin "$first" || inline_terminal=0 ;;
          esac
        fi
      done
      if [ "$inline_found" -gt 0 ] && [ "$inline_terminal" = 1 ]; then
        _git_alias_resolve "$_GA_VERB" 0 '' || return 2
        # A harmless first hop still needs the other matching config slot.
        [ "$inline_found" -lt 2 ] || continue
      fi
    fi
    gitdir=""
    local candidate_unresolved=0
    for ((i=0; i<${#_GA_TARGET[@]}; i++)); do
      token="${_GA_TARGET[i]}"
      case "$token" in
        -C)
          i=$((i+1))
          if dir=$(_git_resolve_dir "${_GA_TARGET[i]}" "$target") && [ -d "$dir" ]; then
            target="$dir"
          else
            # #1816 G7: expansion or bad -C path — do not fall back for aliases.
            candidate_unresolved=1
            target="${cwd:-$PWD}"
          fi
          ;;
        --git-dir=*)
          gitdir="${token#*=}"
          case "$gitdir" in *'$'*|*'`'*|*'\\'*) candidate_unresolved=1 ;; esac ;;
      esac
    done
    # Unresolved target options cannot clear an alias in the payload repository.
    if [ "$candidate_unresolved" = 1 ] && ! _git_alias_builtin "$_GA_VERB"; then
      _git_alias_block "cannot resolve the repository for this git alias. Use a literal directory change or -C path, then run the real verb. If this is prose, write it to a file and pass -F or --body-file."; return 2
    fi
    cachekey="${#target}:$target${#gitdir}:$gitdir"; index=-1
    for ((i=0; i<${#cachekeys[@]}; i++)); do [ "${cachekeys[i]}" != "$cachekey" ] || index="$i"; done
    if [ "$index" -lt 0 ]; then
      [ "${#cachekeys[@]}" -lt 8 ] || { _git_alias_block 'too many git targets to check for aliases. Split the command.'; return 2; }
      local -a args=(-C "$target")
      [ -z "$gitdir" ] || args+=("--git-dir=$gitdir")
      # -z: key, newline, value, NUL. A newline in a value must not forge a
      # second line, and a space in a key must not split the record.
      view=$(mktemp) || { _git_alias_block "cannot read git config for $target. Fix the config and retry."; return 2; }
      _GA_VIEWFILES+=("$view")
      git ${args[@]+"${args[@]}"} config --includes -z --get-regexp '^(alias\..*|help\.autocorrect|include\..*|includeif\..*)$' >"$view" 2>/dev/null; rc=$?
      [ "$rc" -le 1 ] || { _git_alias_block "cannot read git config for $target. Fix the config and retry."; return 2; }
      index="${#cachekeys[@]}"; cachekeys+=("$cachekey"); views+=("$view")
    fi
    if [ ! -s "${views[index]}" ] && [ -z "$_GA_CHANNEL" ] && [ "$_GA_DEFINITION" = 0 ] &&
       [ "${#_GA_INLINE[@]}" = 0 ] && [ "${#_GA_TARGET[@]}" = 0 ] &&
       [ "$target" = "${cwd:-$PWD}" ] && [ -z "${segments:-}" ]; then
      alias_free_payload=1
    fi
    _GA_KEYS=(); _GA_VALUES=(); _GA_AUTO=""; _GA_CONDITION=0
    exec 3<"${views[index]}"
    while :; do
      _git_alias_read_z_record; rc=$?
      [ "$rc" = 0 ] || {
        exec 3<&-
        [ "$rc" = 1 ] || { _git_alias_block "cannot parse git config for $target. Fix the config and retry."; return 2; }
        break
      }
      _git_alias_entry "$key" "$value"
      case "$key" in
        includeif.onbranch:*|includeif.hasconfig:*) _GA_CONDITION=1 ;;
        includeif.gitdir:*|includeif.gitdir/i:*)
          if [ "$_GA_CREATES_REPO" = 0 ] && [ "$_GA_CREATION_SCANNED" = 0 ]; then
            # Quote concatenation can spell a builtin. Parse in a subshell
            # once, so this check cannot overwrite the current invocation.
            if (
              local creation_candidate
              for creation_candidate in ${candidates[@]+"${candidates[@]}"}; do
                [ "${#creation_candidate}" -le 2048 ] || continue
                _git_alias_parse "$creation_candidate"
                case "$_GA_VERB" in init|clone|worktree) exit 0 ;; esac
              done
              exit 1
            ); then _GA_CREATES_REPO=1; fi
            _GA_CREATION_SCANNED=1
          fi
          [ "$_GA_CREATES_REPO" = 0 ] || _GA_CONDITION=1 ;;

      esac
      case "$key" in include.*|includeif.*)
        token="${value##*/}"
        if [ -n "$token" ]; then
          _git_alias_lower "$token"; token="$_GA_LOWER"
          # Quote the basename as ERE data, not as an expression.
          local special
          for special in '\' '.' '[' ']' '(' ')' '*' '+' '?' '^' '$' '{' '}' '|'; do
            token="${token//"$special"/\\$special}"
          done
          local basename_re="(^|[^[:alnum:]_.-])${token}([^[:alnum:]_.-]|$)"
          if [[ "$clean" =~ $basename_re ]]; then _GA_DEFINITION=1; fi
        fi ;;

      esac
    done
    for line in ${_GA_INLINE[@]+"${_GA_INLINE[@]}"}; do _git_alias_entry "${line%%=*}" "${line#*=}"; done
    if [ "$_GA_OPAQUE" = 1 ]; then
      if ! _git_alias_unknown 0; then return 2; fi
      for key in ${_GA_KEYS[@]+"${_GA_KEYS[@]}"}; do
        if ! _git_alias_resolve "${key#*:}" 0 ''; then
          _git_alias_block 'an unquoted expansion, glob or redirection before the git verb can change the command. Quote the value.'; return 2
        fi
      done
    else
      _git_alias_resolve "$_GA_VERB" 0 '' || return 2
    fi
  done
  return 0
}


true
