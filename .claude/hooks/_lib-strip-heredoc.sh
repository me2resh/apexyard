#!/bin/bash
# Heredoc-body stripping — an ADDITIVE-refinement helper, never a gate filter.
#
# Not a hook itself (prefixed `_lib-`). Sourced by `_lib-extract-push-ref.sh`
# via `. "$(dirname "$0")/_lib-strip-heredoc.sh"`.
#
# WHY THIS EXISTS, AND WHY IT IS ITS OWN FILE (me2resh/apexyard#1066)
# --------------------------------------------------------------------
# A heredoc body (a commit message, a PR body, review prose written via
# `cat > file <<EOF ... EOF`) is literal payload, not a command. Scanning
# the WHOLE raw command text for `git push` / `git commit` — as
# `is_tag_push` / `extract_push_ref` originally did — matches prose that
# merely *mentions* a git command before the real invocation. This function
# strips CONFIRMED heredoc bodies so the ref-extraction / tag-push-exemption
# questions in `_lib-extract-push-ref.sh` see the real command, not prose.
#
# It was split into its own file (rather than living inline in
# `_lib-extract-push-ref.sh`) because it is a genuinely standalone parsing
# primitive with more than one consumer: `_lib-extract-push-ref.sh` uses it
# today, and `verify-commit-refs.sh`'s `resolve_commit_workdir()` (added in
# #1073) parses the same kind of raw-command-text shape (`git -C <path>`,
# `cd <path> &&`) and is a natural second adopter, per the coordinator's
# review. See docs/agdr/AgDR-0113-heredoc-stripper-additive-only.md for the
# full three-way design record and — critically — the governance rule
# below, which every adopter of this file MUST follow.
#
# ============================================================================
# GOVERNANCE — READ BEFORE USING THIS FUNCTION ANYWHERE NEW
# ============================================================================
# `strip_heredoc_bodies` is a SUBTRACTIVE pre-filter: it decides what a
# caller is even ALLOWED to see. That is fundamentally different from
# `extract_push_ref`, which is ADDITIVE: it tries to answer "what is the
# ref", and if it gets that wrong, the caller still has the raw command and
# an independent local-state fallback to fall back on — the failure is
# local and visible.
#
# A bug in a SUBTRACTIVE filter is silent and global: if this function ever
# over-strips (removes text that was actually a real, executing command),
# and a caller used its OUTPUT to decide "is there even a git push/commit
# command here at all", that caller's gate silently never fires. This is
# not hypothetical — it is exactly the bug a security review caught in the
# first version of the #1066 fix (me2resh/apexyard#1075): both
# `validate-branch-name.sh` and `block-main-push.sh` ran their presence
# checks (`grep -qE 'git push'` / `'git commit'`) against text this
# function had already filtered, so eight distinct malformed-heredoc shapes
# (see the AgDR) made the filter eat the real command, and the gate exited
# 0 without ever asking whether a push was happening.
#
# THE RULE: use `strip_heredoc_bodies` (directly, or via `extract_push_ref` /
# `is_tag_push` in `_lib-extract-push-ref.sh`) ONLY to refine an ADDITIVE
# question — "given that a real git operation is independently known (from
# RAW, unfiltered text) to be happening, which ref / is it exempt" — and
# NEVER to decide whether a gate should fire at all. The presence check
# that answers "is there a push/commit here" MUST always run against the
# raw, unfiltered command string. If you are about to write
# `if echo "$STRIPPED_TEXT" | grep -q 'git push'` as a gating condition,
# stop — that is exactly the mistake this comment exists to prevent.
#
# ONE EXCEPTION (AgDR-0262, #1780): the dispatcher uses `quoted` mode for
# push and commit routing. That mode strips a body only when the whole
# command is exactly one simple command that is an allow-listed data sink
# (see _shq_sinks_ok), and the start line splits into words that show one
# heredoc operator and one quoted delimiter word (see _shq_single_sink).
# Anything else, and any parse doubt, returns the raw command, so the gates
# see the body. A body that a shell runs is a command, not data.
# #1833 (AgDR-0270): `git commit -m "$(cat <<'X'` ... `)"` is a sink too
# (see _shq_subst_sink). The gate visitor in _lib-git-global.sh also reads
# the `quoted` mode text for its structure parse only (alias check, cd
# chain, -C). The gate bodies still read the raw command.
# A second exception (AgDR-0263, #1810) is local to validate-commit-format.sh.
#
# Strips heredoc BODY text (and the heredoc's own start/terminator lines)
# from a command string, but ONLY for heredocs that are CONFIRMED — both:
#
#   1. ANCHORED: after the delimiter word, the rest of that line (trimmed of
#      leading whitespace) is empty, a `#` comment, or a plain output
#      redirection (`>`, `>>`, an fd redirect like `2>`, or `&>`) — nothing
#      else. A `<<` sitting inside a quoted string, an arithmetic
#      expression (`$((1 << N))`), or followed by `&&` / `||` / `;` / a
#      pipe / another `<<` fails this check and is never treated as a
#      heredoc start. This is what makes `"shift with << N" && git push
#      origin main` and `X=$((1 << N)); git push origin main` and `git
#      commit -m "use a << b shift"` all leave the real command untouched.
#
#   2. TERMINATED: scanning forward from the candidate start, some later
#      line — after tab-stripping for `<<-` — exactly equals the delimiter.
#      If no such line exists anywhere in the rest of the command, the
#      candidate is REJECTED: nothing is stripped for it, and the command
#      from that point on is returned UNCHANGED. An unterminated heredoc
#      (or one whose delimiter this parser can't compute exactly — a
#      backslash-escaped delimiter like `<<E\OF`, a quoted multi-word
#      delimiter like `<<'E O F'`, a delimiter containing a `.` like
#      `<<END.OF`) will therefore never find its (differently-shaped) real
#      terminator line and is safely left un-stripped rather than eating
#      the remainder of the command looking for a terminator that will
#      never arrive. See the AgDR for the deliberate residue this leaves:
#      those exotic delimiter shapes are recognised as *heredoc-like* but
#      never actually stripped, which is safe (nothing is hidden) but means
#      a LEGITIMATE use of one of those shapes doesn't get the "prose is
#      hidden from presence checks" nicety either. Given presence checks
#      never consult this function's output (per the governance rule
#      above), that residue has no safety impact — only a minor UX one.
#
# A line containing a here-STRING (`<<<`) is never treated as a heredoc
# start, so `wc -l <<< "$var"` is left untouched.
#
# Returns: prints the command with CONFIRMED heredoc bodies removed. Always
# exits 0.
#
# Optional second argument:
#   all     (default) — strip every confirmed heredoc
#   quoted  — strip only heredocs whose delimiter is quoted (`<<'EOF'` /
#             `<<"EOF"`). Used by the dispatcher for push/commit routing
#             (#1780 / AgDR-0262). Unquoted heredocs and here-strings keep
#             today's checks. A body is stripped only when the whole
#             command is one allow-listed data sink with nothing before or
#             after it (_shq_sinks_ok). Otherwise the raw command is
#             returned unchanged.

# --- quoted mode: single-command data sinks (#1780, AgDR-0262) ------------
# CEO decision, 2026-10-20: narrow to single-command sinks after 5 review
# rounds. Strip a quoted body only when the whole Bash command, without
# that body, is exactly ONE simple command that is a data sink, with
# nothing before or after it. These helpers share state through dynamic
# scope with _shq_sinks_ok. Each one returns 1 on any doubt.

# Split $1 into words in _SHQ_W, with a flag per word in _SHQ_Q: 0 for a
# plain word, 1 for a word with quotes (removed), 2 for an operator (`>`,
# `>>`, `|`, `<<`, `<<-`). _SHQ_ONE is 1 for a word that is exactly one
# quoted part with a matching quote at each end, else 0. A `#` at the start
# of a word ends the text. Return 1 on an open quote, on `$`, a backquote or
# a backslash in double quotes, on a `<` that does not start `<<`, on
# `<<<`, and on any character outside quotes that is not on a short safe
# list. That list leaves out `\ $ ` ( ) { } ; & * ? [ ~` and all control
# characters.
# #1829 B4: the caller splits the whole start line, the heredoc marker
# included. Thus each quote in the marker pairs as bash pairs it.
_shq_words() {
  local s="$1" i=0 n c w="" inw=0 q=0 parts=0 qparts=0 plain=0
  _SHQ_W=()
  _SHQ_Q=()
  _SHQ_ONE=()
  n=${#s}
  [ "$n" -le 4096 ] || return 1
  while [ "$i" -lt "$n" ]; do
    c="${s:i:1}"
    case "$c" in
      ' '|"$_shq_tab")
        _shq_end_word
        ;;
      \')
        inw=1; q=1; plain=0; parts=$((parts + 1)); qparts=$((qparts + 1))
        i=$((i + 1))
        while [ "$i" -lt "$n" ] && [ "${s:i:1}" != \' ]; do
          w+="${s:i:1}"; i=$((i + 1))
        done
        [ "$i" -lt "$n" ] || return 1
        ;;
      \")
        inw=1; q=1; plain=0; parts=$((parts + 1)); qparts=$((qparts + 1))
        i=$((i + 1))
        while [ "$i" -lt "$n" ] && [ "${s:i:1}" != \" ]; do
          case "${s:i:1}" in '$'|'`'|\\) return 1 ;; esac
          w+="${s:i:1}"; i=$((i + 1))
        done
        [ "$i" -lt "$n" ] || return 1
        ;;
      '>'|'|')
        _shq_end_word
        if [ "$c" = '>' ] && [ "${s:i+1:1}" = '>' ]; then
          c='>>'; i=$((i + 1))
        fi
        _SHQ_W+=("$c"); _SHQ_Q+=(2); _SHQ_ONE+=(0)
        ;;
      '<')
        # Only a heredoc operator. A here-string or a plain `<` is a doubt.
        _shq_end_word
        [ "${s:i+1:1}" = '<' ] && [ "${s:i+2:1}" != '<' ] || return 1
        c='<<'; i=$((i + 1))
        if [ "${s:i+1:1}" = '-' ]; then
          c='<<-'; i=$((i + 1))
        fi
        _SHQ_W+=("$c"); _SHQ_Q+=(2); _SHQ_ONE+=(0)
        ;;
      '#')
        [ "$inw" -eq 1 ] || break
        _shq_plain_char
        ;;
      [A-Za-z0-9._/=:@%+,^!-]) _shq_plain_char ;;
      *) return 1 ;;
    esac
    i=$((i + 1))
  done
  _shq_end_word
  return 0
}

# Helpers of _shq_words. They read and set its locals through dynamic scope.
_shq_plain_char() {
  if [ "$plain" -eq 0 ]; then
    parts=$((parts + 1))
    plain=1
  fi
  w+="$c"
  inw=1
}
_shq_end_word() {
  if [ "$inw" -eq 1 ]; then
    _SHQ_W+=("$w"); _SHQ_Q+=("$q")
    if [ "$parts" -eq 1 ] && [ "$qparts" -eq 1 ]; then
      _SHQ_ONE+=(1)
    else
      _SHQ_ONE+=(0)
    fi
  fi
  w=""; inw=0; q=0; parts=0; qparts=0; plain=0
}

# Check one file target word. This is an allow-list (#1829 A1, N2): the
# target must be a plain relative or absolute path of the characters
# A-Z a-z 0-9 . _ + % @ , = / -. It must not start with `-` or end with `/`.
# It must not be in /dev, /proc or /sys. No part of it may be `..`, `.git`
# (or start with `.git`), `.husky`, `hooks`, `.hooks` or `githooks` (any
# case). The file must not be a symbolic link. Its directory must resolve.
# The resolved path must not be a home-directory dot file or inside a dot
# directory (this includes $HOME/.config), inside $XDG_CONFIG_HOME, inside
# the git dir of its repo, or inside a configured hooks path of its repo or
# of the current repo. $HOME must be set. Any doubt returns 1.
_shq_target() {
  local t="$1" b d lc part rd gd hr xr
  case "$t" in /dev/null|/dev/stdout|/dev/stderr) return 1 ;; esac
  [[ "$t" =~ ^[A-Za-z0-9._+%@,=/-]+$ ]] || return 1
  case "$t" in -*|*/) return 1 ;; esac
  lc="$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')"
  local IFS=/
  for part in $lc; do
    case "$part" in
      ..|.git|.git?*|.husky|hooks|.hooks|githooks) return 1 ;;
    esac
  done
  unset IFS
  case "$lc" in /dev/*|/proc/*|/sys/*) return 1 ;; esac
  b="${t##*/}"
  case "$b" in ''|.|..) return 1 ;; esac
  d="."
  case "$t" in */*) d="${t%/*}"; [ -n "$d" ] || d=/ ;; esac
  rd="$(cd -P -- "$d" 2>/dev/null && pwd -P)" || return 1
  [ -n "$rd" ] || return 1
  [ ! -L "$rd/$b" ] || return 1
  # Home-directory dot files and dot directories hold config that other
  # programs read by an implicit name (#1829 N2).
  [ -n "${HOME:-}" ] || return 1
  hr="$(cd -P -- "$HOME" 2>/dev/null && pwd -P)" || return 1
  [ -n "$hr" ] || return 1
  case "$rd/$b" in "$hr"/.*) return 1 ;; esac
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    xr="$(cd -P -- "$XDG_CONFIG_HOME" 2>/dev/null && pwd -P)" || xr="$XDG_CONFIG_HOME"
    case "$rd/" in "${xr%/}"/*) return 1 ;; esac
  fi
  if gd="$(git -C "$rd" rev-parse --absolute-git-dir 2>/dev/null)" && [ -n "$gd" ]; then
    gd="$(cd -P -- "$gd" 2>/dev/null && pwd -P)" || return 1
    case "$rd/" in "$gd"/*) return 1 ;; esac
  fi
  # #1829 A3: check the hooks path of the target's repo and of the current
  # repo.
  _shq_hooks_ok "$rd" "$rd" || return 1
  _shq_hooks_ok "$rd" . || return 1
  return 0
}

# 0 when the core.hooksPath that git reads in repo dir $2 is unset, or
# resolves to a directory that does not hold resolved directory $1. A
# hooks path that is set but does not resolve returns 1 (fail closed).
# `--type=path` expands a leading `~`. A relative path is relative to the
# top of the work tree.
_shq_hooks_ok() {
  local rd="$1" r="$2" hp rc=0 top
  hp="$(git -C "$r" config --type=path --get core.hooksPath 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || return 1
  [ -n "$hp" ] || return 0
  case "$hp" in
    /*) ;;
    *)
      top="$(git -C "$r" rev-parse --show-toplevel 2>/dev/null)" || return 1
      [ -n "$top" ] || return 1
      hp="$top/$hp"
      ;;
  esac
  [ -d "$hp" ] || return 1
  hp="$(cd -P -- "$hp" 2>/dev/null && pwd -P)" || return 1
  [ -n "$hp" ] || return 1
  case "$rd/" in "$hp"/*) return 1 ;; esac
  return 0
}

# Arguments of git or gh in _SHQ_W from index $1. Every word must be a word,
# not an operator. $2 lists the option letters that a single-dash cluster
# must not hold. $3 lists long options that must not appear (alone or with
# `=value`). $4 lists the options that take `-` (stdin) as the body value;
# one of them must do so.
_shq_cli_ok() {
  local k="$1" letters="$2" deny="$3" opts="$4" n=${#_SHQ_W[@]} tok prev="" o stdin=0
  while [ "$k" -lt "$n" ]; do
    [ "${_SHQ_Q[k]}" != 2 ] || return 1
    tok="${_SHQ_W[k]}"
    case "$tok" in
      --*)
        for o in $deny; do
          case "$tok" in "$o"|"$o"=*) return 1 ;; esac
        done
        ;;
      -?*)
        case "${tok#-}" in *["$letters"]*) return 1 ;; esac
        ;;
    esac
    for o in $opts; do
      if { [ "$prev" = "$o" ] && [ "$tok" = - ]; } || [ "$tok" = "$o=-" ]; then
        stdin=1
      fi
    done
    prev="$tok"
    k=$((k + 1))
  done
  [ "$stdin" -eq 1 ]
}

# 0 when start line $1 holds exactly one heredoc operator outside quotes,
# the next word is one quoted word with matching quotes whose value is
# terminator $2, and the line without those two words is one allow-listed
# data sink. $3 is 1 for `<<-`, else 0 (#1829 B4). The sinks (this is the
# full list; the code below is the authority):
#   cat > file | cat >> file   (the heredoc can come before or after)
#   cat <<'X' | tee [-a|--append] file   (the heredoc right after `cat`)
#   tee [-a|--append] file     (exactly one file)
#   git commit ...             stdin form: -F - | -F=- | --file - | --file=-
#   git notes add|append ...   stdin form: as for git commit
#   gh pr|issue|release create|comment|edit ...
#                              stdin form: --body-file - | --body-file=- |
#                              -F - | -F=-
# git and gh: no operator word after the subcommand. For git, no
# single-dash word may hold the letter c, e, C or t (-c, -e, -C, -t), and no
# word may be --edit, --editor or --template (alone or with =value). For
# gh, no single-dash word may hold e or w (-e, -w), and no word may be
# --editor or --web. Each `file` must pass _shq_target.
_shq_single_sink() {
  local line="$1" term="$2" op='<<' n k h=-1 idx
  local -a ws=() qs=()
  [ "$3" != 1 ] || op='<<-'
  _shq_words "$line" || return 1
  n=${#_SHQ_W[@]}
  for ((idx = 0; idx < n; idx++)); do
    if [ "${_SHQ_Q[idx]}" = 2 ]; then
      case "${_SHQ_W[idx]}" in
        '<<'|'<<-')
          # A second heredoc operator on the line is a doubt.
          [ "$h" -lt 0 ] || return 1
          h=$idx
          ;;
      esac
    else
      # A `<` inside a quoted word can hide where bash sees the operator.
      case "${_SHQ_W[idx]}" in *'<'*) return 1 ;; esac
    fi
  done
  [ "$h" -ge 0 ] && [ "${_SHQ_W[h]}" = "$op" ] || return 1
  k=$((h + 1))
  [ "$k" -lt "$n" ] || return 1
  [ "${_SHQ_Q[k]}" = 1 ] && [ "${_SHQ_ONE[k]}" = 1 ] || return 1
  [ "${_SHQ_W[k]}" = "$term" ] || return 1
  # Drop the operator and the delimiter word. Check the rest as one sink.
  for ((idx = 0; idx < n; idx++)); do
    if [ "$idx" -ne "$h" ] && [ "$idx" -ne "$k" ]; then
      ws+=("${_SHQ_W[idx]}"); qs+=("${_SHQ_Q[idx]}")
    fi
  done
  [ "${#ws[@]}" -ge 2 ] || return 1
  _SHQ_W=("${ws[@]}")
  _SHQ_Q=("${qs[@]}")
  n=${#_SHQ_W[@]}
  [ "$n" -ge 2 ] && [ "${_SHQ_Q[0]}" = 0 ] && [ "${_SHQ_Q[1]}" != 1 ] || return 1
  case "${_SHQ_W[0]}" in
    cat)
      case "$n:${_SHQ_W[1]}:${_SHQ_Q[1]}" in
        '3:>:2'|'3:>>:2')
          [ "${_SHQ_Q[2]}" = 0 ] || return 1
          _shq_target "${_SHQ_W[2]}"
          return
          ;;
      esac
      # The pipe form: the heredoc operator comes right after `cat`.
      [ "$h" -eq 1 ] || return 1
      [ "${_SHQ_W[1]}" = '|' ] && [ "${_SHQ_Q[1]}" = 2 ] || return 1
      [ "${_SHQ_W[2]-}" = tee ] && [ "${_SHQ_Q[2]-}" = 0 ] || return 1
      k=3
      ;;
    tee) k=1 ;;
    git)
      case "${_SHQ_W[1]}" in
        commit) k=2 ;;
        notes)
          case "${_SHQ_W[2]-}:${_SHQ_Q[2]-}" in add:0|append:0) k=3 ;; *) return 1 ;; esac
          ;;
        *) return 1 ;;
      esac
      _shq_cli_ok "$k" 'ceCt' '--edit --editor --template' '-F --file'
      return
      ;;
    gh)
      case "${_SHQ_W[1]}" in pr|issue|release) ;; *) return 1 ;; esac
      case "${_SHQ_W[2]-}:${_SHQ_Q[2]-}" in create:0|comment:0|edit:0) ;; *) return 1 ;; esac
      _shq_cli_ok 3 'ew' '--editor --web' '--body-file -F'
      return
      ;;
    *) return 1 ;;
  esac
  # tee [-a] file, alone or after `cat <<'X' |`.
  case "${_SHQ_W[k]-}:${_SHQ_Q[k]-}" in -a:0|--append:0) k=$((k + 1)) ;; esac
  [ "$((k + 1))" -eq "$n" ] && [ "${_SHQ_Q[k]}" = 0 ] || return 1
  _shq_target "${_SHQ_W[k]}"
}

# #1833 (AgDR-0270): 0 when start line $1 is `git commit ... -m "$(cat <<'X'`
# (or `--message`) with nothing after the delimiter word. The caller checked
# that the only other visible line is `)"`. The substitution runs only a
# plain `cat` of the quoted heredoc, so its output is data: the message.
# The text after `"$(` must split into exactly `cat`, the heredoc operator
# and one quoted delimiter word whose value is terminator $2 ($3 is 1 for
# `<<-`). The words before `"$(` must pass the git commit rules of
# _shq_single_sink, and the last of them must be `-m` or `--message`.
_shq_subst_sink() {
  local line="$1" term="$2" op='<<' head tail n idx
  [ "$3" != 1 ] || op='<<-'
  case "$line" in *'"$('*) ;; *) return 1 ;; esac
  head="${line%%'"$('*}"
  tail="${line#*'"$('}"
  # A `#` at the start of a word makes the rest of the line a comment.
  case "$head" in '#'*|*[[:space:]]'#'*) return 1 ;; esac
  _shq_words "$tail" || return 1
  [ "${#_SHQ_W[@]}" -eq 3 ] || return 1
  [ "${_SHQ_W[0]}:${_SHQ_Q[0]}" = cat:0 ] || return 1
  [ "${_SHQ_W[1]}:${_SHQ_Q[1]}" = "$op:2" ] || return 1
  [ "${_SHQ_Q[2]}" = 1 ] && [ "${_SHQ_ONE[2]}" = 1 ] || return 1
  [ "${_SHQ_W[2]}" = "$term" ] || return 1
  _shq_words "$head" || return 1
  n=${#_SHQ_W[@]}
  [ "$n" -ge 3 ] || return 1
  for ((idx = 0; idx < n; idx++)); do
    case "${_SHQ_W[idx]}" in *'<'*) return 1 ;; esac
  done
  [ "${_SHQ_W[0]}:${_SHQ_Q[0]}" = git:0 ] || return 1
  [ "${_SHQ_W[1]}:${_SHQ_Q[1]}" = commit:0 ] || return 1
  case "${_SHQ_W[n - 1]}:${_SHQ_Q[n - 1]}" in -m:0|--message:0) ;; *) return 1 ;; esac
  # The substitution is the message value. A `-` word stands in for it, so
  # the stdin rule of _shq_cli_ok holds for this value.
  _SHQ_W+=(-); _SHQ_Q+=(0)
  _shq_cli_ok 2 'ceCt' '--edit --editor --template' '-m --message'
}

# 0 when the command is one stripped quoted heredoc that feeds a single
# allow-listed data sink, and every other visible line is blank. Reads the
# arrays of strip_heredoc_bodies through dynamic scope. Fails closed
# (returns 1) on any doubt.
# #1833: one `)"` line after the terminator closes `"$(cat <<'X'`. Then
# the start line must pass _shq_subst_sink.
_shq_sinks_ok() {
  local LC_ALL=C
  local _shq_tab start=-1 close=-1 idx
  _shq_tab="$(printf '\t')"
  for ((idx = 0; idx < n; idx++)); do
    [ "${skip[idx]}" -eq 0 ] || continue
    if [ "${is_start[idx]}" -eq 1 ]; then
      [ "$start" -lt 0 ] || return 1
      start=$idx
      continue
    fi
    if [ "${lines[idx]}" = ')"' ] && [ "$start" -ge 0 ] && [ "$close" -lt 0 ]; then
      close=$idx
      continue
    fi
    # Any other visible text (a second command, a continuation, a second
    # heredoc) keeps the raw command.
    case "${lines[idx]}" in *[![:space:]]*) return 1 ;; esac
  done
  [ "$start" -ge 0 ] || return 1
  if [ "$close" -ge 0 ]; then
    _shq_subst_sink "${lines[start]}" "${hterm[start]}" "${htabs[start]}"
    return
  fi
  # #1829 B4: split the whole start line, the marker included.
  _shq_single_sink "${lines[start]}" "${hterm[start]}" "${htabs[start]}"
}

strip_heredoc_bodies() {
  local cmd="$1"
  local mode="${2:-all}"
  local stripped_any=0
  local -a lines=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
  done <<< "$cmd"

  local n=${#lines[@]}
  local -a skip=()
  local -a is_start=()
  local -a prefix=()
  local -a hterm=()
  local -a htabs=()
  local idx
  for ((idx = 0; idx < n; idx++)); do
    skip[idx]=0
    is_start[idx]=0
    prefix[idx]=""
    hterm[idx]=""
    htabs[idx]=0
  done

  local tab
  tab="$(printf '\t')"

  local i=0 q_seen=0
  while [ "$i" -lt "$n" ]; do
    if [ "${skip[i]}" -eq 1 ]; then
      i=$((i + 1))
      continue
    fi

    # #1844 S1: in quoted mode, a second visible line that holds text makes
    # the result the raw command (_shq_sinks_ok permits one start line and
    # blank lines only). Return it at that line, so the scan stays linear.
    # #1833: a `)"` line can close `"$(cat <<'X'`. _shq_sinks_ok checks it.
    if [ "$mode" = quoted ]; then
      case "${lines[i]}" in
        ')"') ;;
        *[![:space:]]*)
          if [ "$q_seen" -eq 1 ]; then
            printf '%s' "$cmd"
            return 0
          fi
          q_seen=1
          ;;
      esac
    fi

    local cur="${lines[i]}"
    local marker=""
    case "$cur" in
      *'<<<'*) marker="" ;; # here-string on this line — never a heredoc start
      *'<<'*)
        marker=$(echo "$cur" \
          | grep -oE '<<-?[[:space:]]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?' \
          | head -1)
        ;;
    esac

    if [ -z "$marker" ]; then
      i=$((i + 1))
      continue
    fi

    # #1780: routing may ask for quoted delimiters only.
    if [ "$mode" = quoted ]; then
      case "$marker" in
        *\'*|*\") ;;
        *) i=$((i + 1)); continue ;;
      esac
    fi

    # #1805 B1: in quoted mode, an earlier `<<` on this line is a heredoc
    # whose delimiter the pattern did not match (a digit or an escaped
    # name). Its body and the text up to the marker would be lost, so
    # return the raw command (fail closed).
    # #1829 B1b: check the logical line. Join each earlier line that ends
    # in a backslash, because bash removes a backslash-newline before it
    # reads operators.
    if [ "$mode" = quoted ]; then
      local lpre="${cur%%"$marker"*}" pj=$((i - 1))
      while [ "$pj" -ge 0 ] && [ "${skip[pj]}" -eq 0 ]; do
        case "${lines[pj]}" in
          *\\) lpre="${lines[pj]%\\}$lpre" ;;
          *) break ;;
        esac
        pj=$((pj - 1))
      done
      case "$lpre" in
        *'<<'*) printf '%s' "$cmd"; return 0 ;;
      esac
    fi

    # --- Anchor check -------------------------------------------------
    # Everything after the matched delimiter word, on the SAME line, must
    # be empty / a comment / a plain redirection. Anything else (a closing
    # quote followed by more text, `&&`, `||`, `;`, a bare pipe, another
    # `<<`) means this `<<` was not actually in redirect position.
    local rest rest_trimmed anchor_ok
    rest="${cur#*"$marker"}"
    rest_trimmed="${rest#"${rest%%[![:space:]]*}"}"
    anchor_ok=0
    case "$rest_trimmed" in
      '') anchor_ok=1 ;;
      '#'*) anchor_ok=1 ;;
      '>'*) anchor_ok=1 ;;
      '&>'*) anchor_ok=1 ;;
      [0-9]'>'*) anchor_ok=1 ;;
      # quoted mode: `cat <<'EOF' | tee f`. _shq_sinks_ok checks the rest.
      '|'*) [ "$mode" != quoted ] || anchor_ok=1 ;;
    esac

    if [ "$anchor_ok" -ne 1 ]; then
      i=$((i + 1))
      continue
    fi

    # --- Compute the delimiter word -----------------------------------
    local strip_tabs terminator
    strip_tabs=0
    case "$marker" in
      '<<-'*) strip_tabs=1 ;;
    esac
    terminator="${marker#<<}"
    terminator="${terminator#-}"
    terminator="${terminator#"${terminator%%[![:space:]]*}"}"
    case "$terminator" in
      \"*\") terminator="${terminator#\"}"; terminator="${terminator%\"}" ;;
      \'*\') terminator="${terminator#\'}"; terminator="${terminator%\'}" ;;
    esac

    # --- Confirm termination by scanning FORWARD ----------------------
    local j found check_line
    found=0
    for ((j = i + 1; j < n; j++)); do
      check_line="${lines[j]}"
      if [ "$strip_tabs" -eq 1 ]; then
        while [ "${check_line:0:1}" = "$tab" ]; do
          check_line="${check_line:1}"
        done
      fi
      if [ "$check_line" = "$terminator" ]; then
        found=1
        break
      fi
    done

    if [ "$found" -ne 1 ]; then
      # Unterminated (or a delimiter shape we can't compute exactly, so it
      # will never match) — do NOT strip. Move past just this candidate;
      # everything from here on is left completely untouched.
      i=$((i + 1))
      continue
    fi

    # Confirmed: lines i+1..j are body+terminator — drop them. Line i keeps
    # only whatever precedes the heredoc operator (it may hold a real
    # command, e.g. `cd foo && cat > x.txt <<EOF`).
    # In quoted mode the prefix ends at the matched marker (#1805 B1).
    if [ "$mode" = quoted ]; then
      prefix[i]="${cur%%"$marker"*}"
    else
      prefix[i]="${cur%%<<*}"
    fi
    hterm[i]="$terminator"
    htabs[i]="$strip_tabs"
    is_start[i]=1
    stripped_any=1
    local k
    for ((k = i + 1; k <= j; k++)); do
      skip[k]=1
    done
    i=$((j + 1))
  done

  local out=""
  for ((idx = 0; idx < n; idx++)); do
    if [ "${skip[idx]}" -eq 1 ]; then
      continue
    fi
    if [ "${is_start[idx]}" -eq 1 ]; then
      out+="${prefix[idx]}"$'\n'
    else
      out+="${lines[idx]}"$'\n'
    fi
  done

  # #1780 / #1805 (AgDR-0262): in quoted mode, keep the stripped text only
  # when the whole command is one allow-listed data sink. Anything else,
  # or any parse doubt, returns the raw command (fail closed).
  if [ "$mode" = quoted ] && [ "$stripped_any" -eq 1 ]; then
    if ! _shq_sinks_ok; then
      printf '%s' "$cmd"
      return 0
    fi
  fi

  printf '%s' "$out"
}
