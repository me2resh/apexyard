#!/bin/bash

# PreToolUse hook on `git commit`: validates the commit message subject line
# against the conventional commit format defined in
# .claude/rules/git-conventions.md:
#
#   type: subject
#
# Where type is one of: feat, fix, refactor, test, docs, chore, style, perf
#
# Note: the PR *title* format is `type(TICKET): description` (with scope in
# parens) — that's enforced by validate-pr-create.sh. Commit messages use
# the simpler `type: subject` form without the scope because commits often
# don't correspond 1:1 to tickets.
#
# Multi-line -m messages are handled by flattening newlines before parsing
# (same pattern as verify-commit-refs.sh). Interactive commits (no -m / -F)
# are skipped.
#
# ApexYard also accepts the scoped form `type(scope): subject` as a valid
# superset — if a project wants to use scopes in commits, that's fine, but
# the scope is not required.

# #1810 / AgDR-0263: print $1 without the body of each quoted heredoc that
# only feeds a file write, and return 0. The shell does not expand such a
# body, and cat or tee only copies it to the file. Thus it is data, not a
# command. A heredoc qualifies only when all of these are true:
#   - Its start line ends in `cat > F <<'X'`, `cat <<'X' > F` (also `>>`)
#     or `tee [-a] F <<'X'`. The delimiter has single or double quotes.
#   - That command starts the line, or follows `&&`, `||` or `;`.
#   - The line before the start line does not end in a backslash.
#   - A later line is the delimiter (`<<-` removes leading tabs first).
# Return 1 with no output when no heredoc qualifies, when another line
# outside a stripped body holds `<<` and is not a qualifying start line, or
# when a line after a stripped body names the file of that heredoc (a later
# command can run the file).
_fmt_strip_file_heredocs() {
  local cmd="$1" line term dash target base n i j k tab check
  local word='[A-Za-z0-9._/~+%@,=:-]+'
  local delim="('[A-Za-z_][A-Za-z0-9_]*'|\"[A-Za-z_][A-Za-z0-9_]*\")"
  local lead='^(.*(&&|\|\||;))?[[:space:]]*'
  local re_before="${lead}(cat[[:space:]]*>>?[[:space:]]*|tee[[:space:]]+(-a[[:space:]]+)?)(${word})[[:space:]]+<<(-?)[[:space:]]*${delim}[[:space:]]*\$"
  local re_after="${lead}cat[[:space:]]+<<(-?)[[:space:]]*${delim}[[:space:]]*>>?[[:space:]]*(${word})[[:space:]]*\$"
  local -a lines=() keep=() names=() ends=()
  tab="$(printf '\t')"
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
    keep+=(1)
  done <<< "$cmd"
  n=${#lines[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    line="${lines[i]}"
    case "$line" in
      *'<<'*) ;;
      *) i=$((i + 1)); continue ;;
    esac
    if [[ "$line" =~ $re_before ]]; then
      target="${BASH_REMATCH[5]}"; dash="${BASH_REMATCH[6]}"; term="${BASH_REMATCH[7]}"
    elif [[ "$line" =~ $re_after ]]; then
      dash="${BASH_REMATCH[3]}"; term="${BASH_REMATCH[4]}"; target="${BASH_REMATCH[5]}"
    else
      return 1
    fi
    case "${BASH_REMATCH[1]}" in *'<<'*) return 1 ;; esac
    if [ "$i" -gt 0 ]; then
      case "${lines[i - 1]}" in *\\) return 1 ;; esac
    fi
    term="${term:1:${#term}-2}"
    j=-1
    for ((k = i + 1; k < n; k++)); do
      check="${lines[k]}"
      if [ "$dash" = - ]; then
        while [ "${check:0:1}" = "$tab" ]; do check="${check:1}"; done
      fi
      if [ "$check" = "$term" ]; then j=$k; break; fi
    done
    [ "$j" -ge 0 ] || return 1
    for ((k = i + 1; k <= j; k++)); do keep[k]=0; done
    names+=("${target##*/}")
    ends+=("$j")
    i=$((j + 1))
  done
  for ((k = 0; k < ${#names[@]}; k++)); do
    base="${names[k]}"
    for ((i = ends[k] + 1; i < n; i++)); do
      [ "${keep[i]}" -eq 1 ] || continue
      case "${lines[i]}" in *"$base"*) return 1 ;; esac
    done
  done
  [ "${#names[@]}" -gt 0 ] || return 1
  for ((i = 0; i < n; i++)); do
    [ "${keep[i]}" -eq 1 ] && printf '%s\n' "${lines[i]}"
  done
  return 0
}

# Run one target check. The visitor isolates each call in a subshell.
_git_gate_body() {
INPUT="$_GIT_GATE_INPUT"
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -r "$HOOK_DIR/_lib-git-global.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOOK_DIR/_lib-git-global.sh"
fi

if [ -z "$COMMAND" ]; then
  . "$(dirname "$0")/_lib-fail-closed-json.sh"
  _fmt_pat='git[[:space:]]+commit'
  if command -v git_subcommand_payload_pattern >/dev/null 2>&1; then
    _fmt_pat="$(git_subcommand_payload_pattern commit)"
  fi
  if raw_payload_command_matches "$INPUT" "$_fmt_pat"; then
    echo "BLOCKED: commit-format hook cannot parse this commit command. Restore jq and retry." >&2
    exit 2
  fi
  exit 0
fi

if command -v command_has_git_subcommand >/dev/null 2>&1; then
  command_has_git_subcommand "$COMMAND" commit || exit 0
elif ! echo "$COMMAND" | grep -qE '\bgit\s+commit\b'; then
  exit 0
fi

if [[ "$COMMAND" =~ $'\n'[[:space:]]*git[[:space:]]+commit ]]; then
  echo "BLOCKED: commit-format hook does not accept newline compound commit commands." >&2
  exit 2
fi

if printf '%s' "$COMMAND" | grep -qF "$(printf '\140')"; then
  echo "BLOCKED: commit-format hook does not accept backtick command substitutions." >&2
  exit 2
fi

# Detect a second commit chained *after* a confirmed heredoc substitution.
# The heredoc body is literal commit-message content, so raw command scans
# must not interpret `; git commit`, `&& git commit`, or `| git commit` in
# that body as executable shell syntax.
has_heredoc_compound_commit() {
  local cmd="$1" line marker delimiter check_line
  local in_heredoc=0 strip_tabs=0 awaiting_close=0 awaiting_connector=0
  local tab
  tab="$(printf '\t')"
  local close_compound_re='^[[:space:]]*\)"?[[:space:]]*(;|&&|&|\|)[[:space:]]*git[[:space:]]+commit([[:space:]]|$)'
  local close_continuation_re='^[[:space:]]*\)"?[[:space:]]*\\[[:space:]]*$'

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_heredoc" -eq 1 ]; then
      check_line="$line"
      if [ "$strip_tabs" -eq 1 ]; then
        while [ "${check_line:0:1}" = "$tab" ]; do
          check_line="${check_line:1}"
        done
      fi
      if [ "$check_line" = "$delimiter" ]; then
        in_heredoc=0
        awaiting_close=1
      fi
      continue
    fi

    if [ "$awaiting_close" -eq 1 ]; then
      if [[ "$line" =~ $close_compound_re ]]; then
        return 0
      fi
      if [[ "$line" =~ $close_continuation_re ]]; then
        awaiting_close=0
        awaiting_connector=1
        continue
      fi
      # Blank lines are permitted before the command substitution closes.
      if [[ ! "$line" =~ ^[[:space:]]*$ ]]; then
        awaiting_close=0
      fi
    fi

    if [ "$awaiting_connector" -eq 1 ]; then
      if [[ "$line" =~ ^[[:space:]]*(;|&&|&|\|)[[:space:]]*git[[:space:]]+commit([[:space:]]|$) ]]; then
        return 0
      fi
      if [[ ! "$line" =~ ^[[:space:]]*$ ]]; then
        awaiting_connector=0
      fi
    fi

    # Match only the supported `$(cat <<EOF` shape that this hook already
    # recognises for the heredoc-substitution skip below. A terminator must
    # be found before any text is treated as a literal heredoc body.
    marker=$(printf '%s\n' "$line" | sed -nE "s/.*\\$\\(cat[[:space:]]+<<(-?)[[:space:]]*['\\\"]?([A-Za-z_][A-Za-z0-9_]*)['\\\"]?[[:space:]]*$/\\1:\\2/p")
    if [ -z "$marker" ]; then
      continue
    fi
    strip_tabs=0
    case "$marker" in
      -:*) strip_tabs=1 ;;
    esac
    delimiter="${marker#*:}"
    in_heredoc=1
  done <<< "$cmd"

  return 1
}

if has_heredoc_compound_commit "$COMMAND"; then
  echo "BLOCKED: commit-format hook does not accept compound commit commands." >&2
  exit 2
fi

# Heredoc-substitution short-circuit (#194):
#
#   git commit -m "$(cat <<'EOF'
#   feat(#42): subject line
#   ...
#   EOF
#   )"
#
# At hook-invocation time the shell hasn't expanded `$(cat <<...)` yet — the
# hook sees the literal string `$(cat <<'EOF' ... EOF )` as the `-m` value,
# which obviously can't match the conventional-commit subject regex. Skipping
# validation here is the right call: the actual subject is in the heredoc
# body, not in the `-m` argument string the hook can read. Operators who
# want subject validation on a multi-line message should use the file-based
# shape (`git commit -F path/to/msg`) — that path goes through the existing
# -F branch below and gets full validation.
#
# Trade-off: this allows a malformed subject through if the heredoc body is
# itself malformed. Acceptable bounded risk — the heredoc-substitution shape
# is uncommon (mostly Claude Code's own commit-message authoring path), and
# the more important goal is keeping the hook from misfiring on a legitimate
# multi-line commit produced from within a worktree.
_fmt_heredoc_re='git[[:space:]]+commit\b[^|;&]*-m\b[^|;&]*\$\(cat[[:space:]]+<<-?[[:space:]]*'\''?[A-Za-z_][A-Za-z0-9_]*'\''?'
if command -v git_subcommand_re >/dev/null 2>&1; then
  _fmt_heredoc_re="$(git_subcommand_re commit)"'[^|;&]*-m\b[^|;&]*\$\(cat[[:space:]]+<<-?[[:space:]]*'\''?[A-Za-z_][A-Za-z0-9_]*'\''?'
fi
if printf '%s\n' "$COMMAND" | LC_ALL=C grep -qE "$_fmt_heredoc_re"; then
  echo "INFO: heredoc-substitution detected in -m; skipping subject validation. Use 'git commit -F <file>' for validation on multi-line messages." >&2
  exit 0
fi

# Tokenize the command without evaluating it. The hook input is untrusted text.
# A raw regex can mistake option text for a commit-message option. Keep shell
# quoting intact while reading tokens, then inspect only real option tokens.
tokenize_shell_command() {
  local input="$1"
  local length char token="" quote="" escaped=0 token_started=0
  local i=0

  COMMAND_TOKENS=()
  length=${#input}
  while [ "$i" -lt "$length" ]; do
    char=${input:i:1}

    if [ -n "$quote" ]; then
      if [ "$quote" = "'" ]; then
        if [ "$char" = "'" ]; then
          quote=""
        else
          token+="$char"
        fi
      elif [ "$escaped" -eq 1 ]; then
        token+="$char"
        escaped=0
      elif [ "$char" = "\\" ]; then
        escaped=1
      elif [ "$char" = '"' ]; then
        quote=""
      else
        token+="$char"
      fi
    else
      case "$char" in
        " "|$'\t')
          if [ "$token_started" -eq 1 ]; then
            COMMAND_TOKENS+=("$token")
            token=""
            token_started=0
          fi
          ;;
        $'\n')
          if [ "$token_started" -eq 1 ]; then
            COMMAND_TOKENS+=("$token")
            token=""
            token_started=0
          fi
          COMMAND_TOKENS+=(";")
          ;;
        "'")
          quote="'"
          token_started=1
          ;;
        '"')
          quote='"'
          token_started=1
          ;;
        "\\")
          escaped=1
          token_started=1
          ;;
        ";"|"|"|"&"|"<"|">")
          if [ "$token_started" -eq 1 ]; then
            COMMAND_TOKENS+=("$token")
            token=""
            token_started=0
          fi
          COMMAND_TOKENS+=("$char")
          ;;
        *)
          token+="$char"
          token_started=1
          ;;
      esac
    fi

    i=$((i + 1))
  done

  if [ -n "$quote" ] || [ "$escaped" -eq 1 ]; then
    return 1
  fi
  if [ "$token_started" -eq 1 ]; then
    COMMAND_TOKENS+=("$token")
  fi
  return 0
}

# #1842 / AgDR-0271: read the words of $1 past each redirection, as the
# shell does. Use the redirection reader of _lib-git-global.sh (#1835). A
# redirection and its target are not words. Put the decoded words in
# COMMAND_TOKENS. Each `;`, `&`, `|`, `(` or `)` that is not part of a
# redirection becomes one token, and so does each line break outside
# quotes (as `;`), as in tokenize_shell_command. Set _FMT_SAW_INPUT to 1
# when the command holds an input redirection. Return 1 when a word cannot
# be read. Return 2 when a redirection target cannot be read.
_fmt_read_words() {
  local before used rrc blank_re in_re
  local -a out=()
  blank_re=$'^[ \t]+'
  # _git_redir_fd comes from _lib-git-global.sh.
  # shellcheck disable=SC2154
  in_re='^'"${_git_redir_fd}"'<'
  _FMT_SAW_INPUT=0
  _GIT_SCAN="$1"
  while :; do
    if [[ "$_GIT_SCAN" =~ $blank_re ]]; then
      _GIT_SCAN="${_GIT_SCAN:${#BASH_REMATCH[0]}}"
    fi
    [ -n "$_GIT_SCAN" ] || break
    before="$_GIT_SCAN"
    rrc=0
    _git_take_redir || rrc=$?
    if [ "$rrc" -eq 0 ]; then
      [[ "$before" =~ $in_re ]] && _FMT_SAW_INPUT=1
      used="${before:0:$((${#before} - ${#_GIT_SCAN}))}"
      # A line break after the operator or in the target ends the command.
      case "$used" in *$'\n'*) out+=(";") ;; esac
      continue
    fi
    [ "$rrc" -eq 1 ] || return 2
    case "$_GIT_SCAN" in
      [\;\&\|\(\)]*)
        out+=("${_GIT_SCAN:0:1}")
        _GIT_SCAN="${_GIT_SCAN:1}"
        continue
        ;;
    esac
    _git_take_raw_word || return 1
    tokenize_shell_command "$_GIT_TAKEN" || return 1
    out+=(${COMMAND_TOKENS[@]+"${COMMAND_TOKENS[@]}"})
  done
  COMMAND_TOKENS=(${out[@]+"${out[@]}"})
  return 0
}

_fmt_rc=0
if command -v _git_take_redir >/dev/null 2>&1 && command -v _git_take_raw_word >/dev/null 2>&1; then
  _fmt_read_words "$COMMAND" || _fmt_rc=$?
else
  tokenize_shell_command "$COMMAND" || _fmt_rc=1
fi
if [ "$_fmt_rc" -eq 2 ]; then
  echo "BLOCKED: commit-format hook cannot read this commit command past a redirection. Use a plain redirection target, or write the message to a file and pass -F <file>." >&2
  exit 2
fi
if [ "$_fmt_rc" -ne 0 ]; then
  echo "BLOCKED: commit-format hook cannot safely parse this commit command." >&2
  exit 2
fi

token_count=${#COMMAND_TOKENS[@]}
commit_index=-1
for ((i=0; i < token_count; i++)); do
  # #1816: accept a quoted or case-variant command word and a quoted verb.
  if command -v git_token_is_cmd_word >/dev/null 2>&1; then
    git_token_is_cmd_word "${COMMAND_TOKENS[i]}" || continue
  else
    [ "${COMMAND_TOKENS[i]}" = "git" ] || continue
  fi
  j=$((i + 1))
  while [ "$j" -lt "$token_count" ]; do
    tok="${COMMAND_TOKENS[j]}"
    width=0
    if command -v git_global_option_width >/dev/null 2>&1; then
      width=$(git_global_option_width "$tok")
    fi
    if [ "$width" -eq 2 ]; then
      j=$((j + 2))
      continue
    fi
    if [ "$width" -eq 1 ]; then
      j=$((j + 1))
      continue
    fi
    if command -v git_token_is_verb >/dev/null 2>&1; then
      if git_token_is_verb "$tok" commit; then
        commit_index=$((j + 1))
      fi
    elif [ "$tok" = "commit" ]; then
      commit_index=$((j + 1))
    fi
    break
  done
  [ "$commit_index" -ge 0 ] && break
done

if [ "$commit_index" -lt 0 ]; then
  exit 0
fi

if printf '%s' "$COMMAND" | grep -qF '$('; then
  echo "BLOCKED: commit-format hook does not accept command substitutions." >&2
  exit 2
fi

token_count=${#COMMAND_TOKENS[@]}
for ((i=0; i < token_count; i++)); do
  case "${COMMAND_TOKENS[i]}" in
    ";"|"|"|"&"|"<"|">")
      echo "BLOCKED: commit-format hook does not accept compound commit commands." >&2
      exit 2
      ;;
  esac
done

MSG=""
MSG_FILE=""
for ((i=commit_index; i < token_count; i++)); do
  token="${COMMAND_TOKENS[i]}"
  case "$token" in
    ";"|"|"|"&"|"<"|">"|"("|")")
      break
      ;;
    -m|--message)
      next=$((i + 1))
      if [ "$next" -ge "$token_count" ]; then
        echo "BLOCKED: commit-format hook found -m without a message." >&2
        exit 2
      fi
      MSG="${COMMAND_TOKENS[next]}"
      break
      ;;
    --message=*)
      MSG="${token#--message=}"
      break
      ;;
    -F|--file)
      next=$((i + 1))
      if [ "$next" -ge "$token_count" ]; then
        echo "BLOCKED: commit-format hook found -F without a file." >&2
        exit 2
      fi
      MSG_FILE="${COMMAND_TOKENS[next]}"
      break
      ;;
    --file=*)
      MSG_FILE="${token#--file=}"
      break
      ;;
    -[!-]?*)
      # #1842: a short option group, such as `-am <msg>` or `-m<msg>`.
      # Read it as git does. A letter before m or F is a flag. A letter
      # that takes a value (m, F, c, C, t, S, u) takes the rest of the
      # word. When the rest is empty, m and F take the next word.
      rest="${token#-}"
      opt=""
      while [ -n "$rest" ]; do
        opt="${rest:0:1}"
        rest="${rest:1}"
        case "$opt" in
          m|F|c|C|t|S|u) break ;;
        esac
        opt=""
      done
      case "$opt" in
        m|F)
          if [ -z "$rest" ]; then
            next=$((i + 1))
            if [ "$next" -ge "$token_count" ]; then
              echo "BLOCKED: commit-format hook found -$opt without a value." >&2
              exit 2
            fi
            rest="${COMMAND_TOKENS[next]}"
          fi
          if [ "$opt" = m ]; then
            MSG="$rest"
          else
            MSG_FILE="$rest"
          fi
          break
          ;;
      esac
      ;;
  esac
done

# #1842: with `-F -` the message comes from standard input. When an input
# redirection supplies it, the gate cannot read it. Fail closed.
if [ "$MSG_FILE" = "-" ] && [ "${_FMT_SAW_INPUT:-0}" -eq 1 ]; then
  echo "BLOCKED: commit-format hook cannot read a commit message from an input redirection. Write the message to a file and pass -F <file>." >&2
  exit 2
fi

if [ -z "$MSG" ] && [ -n "$MSG_FILE" ] && [ -f "$MSG_FILE" ]; then
  MSG=$(cat "$MSG_FILE")
fi

if [ -z "$MSG" ]; then
  # Interactive commit — skip (accepted gap, matches sibling hooks)
  exit 0
fi

# Get the first line of the message (the subject)
SUBJECT=$(echo "$MSG" | head -1)

if [ -z "$SUBJECT" ]; then
  exit 0
fi

# Validate:
#   type: subject              (no scope)
#   type(scope): subject       (with scope)
#   type!: subject             (breaking change, Conventional Commits 1.0)
#   type(scope)!: subject      (breaking change with scope)
#
# Default types per .claude/rules/git-conventions.md ship at
# .claude/project-config.defaults.json (.commit.type_whitelist). Projects
# override per-fork via .claude/project-config.json — see apexyard#109.
#
# Backward-compat: the legacy flat `commit_types` top-level key in
# .claude/project-config.json is still honoured when present, so forks that
# customised before #109 landed keep working without edits.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
TYPES=""

# 1. Preferred: read from the unified project-config via the shared reader.
if [ -n "$REPO_ROOT" ] && [ -f "$HOOK_DIR/_lib-read-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$HOOK_DIR/_lib-read-config.sh"
  TYPES=$(config_get '.commit.type_whitelist[]' 2>/dev/null | paste -sd'|' -)
fi

# 2. Legacy compat: flat `commit_types` key at the top level of project-config.json.
if [ -z "$TYPES" ] && [ -n "$REPO_ROOT" ] && [ -f "${REPO_ROOT}/.claude/project-config.json" ]; then
  LEGACY=$(jq -r '.commit_types // [] | join("|")' "${REPO_ROOT}/.claude/project-config.json" 2>/dev/null)
  if [ -n "$LEGACY" ] && [ "$LEGACY" != "null" ]; then
    TYPES="$LEGACY"
  fi
fi

# 3. Last-resort fallback — matches the shipped defaults (keeps this hook
#    working in a bare checkout with no config files at all).
if [ -z "$TYPES" ]; then
  TYPES="feat|fix|refactor|test|docs|chore|style|perf|build|ci|revert|spike|sync"
fi

TYPE_REGEX="^(${TYPES})(\([^)]+\))?!?:[[:space:]]+.+"

if ! echo "$SUBJECT" | grep -qE "$TYPE_REGEX"; then
  cat >&2 <<MSG_END
BLOCKED: Commit subject doesn't match the conventional commit format.

Subject was:
  ${SUBJECT}

Expected format (from .claude/rules/git-conventions.md):
  type: subject
  type(scope): subject
  type!: subject             (breaking change)
  type(scope)!: subject      (breaking change with scope)

Where type is one of:
  feat, fix, refactor, test, docs, chore, style, perf, build, ci, revert

Examples:
  feat: add user avatar upload
  fix(auth): handle expired refresh tokens
  feat!: remove deprecated v1 endpoints
  feat(api)!: change response format to JSON:API
  refactor: split order service into read/write sides
  docs(#42): update deployment runbook

The scope in parens is optional for commits (but REQUIRED for PR titles
with a ticket reference — that's enforced by validate-pr-create.sh).

To unblock:
  1. Amend the commit: git commit --amend -m "type: your subject"
  2. Or write a new commit with a conforming subject

If you think this rule is too strict for your project, customize the type
list in .claude/hooks/validate-commit-format.sh or file a ticket to add
\`.commit_types\` as a project-config option.
MSG_END
  exit 2
fi

exit 0

}

_GIT_GATE_INPUT=$(cat)
# #1810 / AgDR-0263: a quoted heredoc body that only feeds a file write is
# data. Remove it from the command before the visitor and the checks read
# it, so prose that names a commit does not start the commit checks. If jq
# fails, keep the raw input.
_fmt_cmd=$(printf '%s' "$_GIT_GATE_INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || _fmt_cmd=""
if [ -n "$_fmt_cmd" ] && _fmt_scan=$(_fmt_strip_file_heredocs "$_fmt_cmd"); then
  if _fmt_input=$(printf '%s' "$_GIT_GATE_INPUT" | jq -c --arg c "$_fmt_scan" '.tool_input.command = $c' 2>/dev/null) \
    && [ -n "$_fmt_input" ]; then
    _GIT_GATE_INPUT="$_fmt_input"
  fi
fi
_GIT_GATE_LIB="$(cd "$(dirname "$0")" && pwd)/_lib-git-global.sh"
if [ -r "$_GIT_GATE_LIB" ]; then
  # shellcheck disable=SC1090
  . "$_GIT_GATE_LIB"
fi
if command -v git_visit_invocations >/dev/null 2>&1; then
  git_visit_invocations _git_gate_body block "$_GIT_GATE_INPUT" commit
  exit $?
fi
_git_gate_body
