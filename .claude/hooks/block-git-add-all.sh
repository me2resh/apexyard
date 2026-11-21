#!/bin/bash
# Blocks: git add -A, git add ., git add --all
# Rationale: these commands stage every modified file in the working tree,
# including unintended ones (.env, credentials, generated artifacts, scratch
# files). Always add specific files by name.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  . "$(dirname "$0")/_lib-fail-closed-json.sh"
  if raw_payload_command_matches "$INPUT" 'git[[:space:]]+add[[:space:]]+(-A|--all|\.)'; then
    echo "BLOCKED: staging guard cannot parse this git add command. Restore jq and retry." >&2
    exit 2
  fi
  exit 0
fi

# The match must land on a COMMAND position, not only at the start of the
# whole call (me2resh/apexyard#2071). `cd src && git add -A`,
# `echo hi; git add -A`, `FOO=1 git add -A`, `sudo git add -A`, a `bash -c`
# wrapper and a multi-line script each reach the same staging command.
# A quoted mention — a commit message, a printf payload, a PR body — stays
# allowed when the `git` there follows a quote or any other character that is
# not a command separator. A parenthesised mention such as "(git add -A)" is
# allowed for the same reason: `(` and `{` are prose punctuation as often as
# command openers, and treating them as command positions would block ordinary
# review prose. That is a false block on an ordinary command (kind 1,
# AgDR-0267), so it outranks the catch. The cost is deliberate and named:
# `(git add -A)` and `{ git add -A; }` are NOT caught. `dev` did not catch
# them either, so they are exotic shapes that stay advisory (epic #1846).
# A heredoc body is NOT stripped before this check: the governance rule in
# _lib-strip-heredoc.sh forbids deciding whether a gate fires from stripped
# text, so a body line that starts with `git add -A` still blocks. Write the
# message with `-F <file>`.
# A prose mention directly after a separator inside quotes blocks only when
# the flag is followed by more text or a closing `)`/`}`: `"x && git add -A
# done"` blocks, while `"x && git add -A"` stays allowed because a closing
# quote right after the flag is not a direct-pattern terminator. The `-c`
# wrapper tail does accept a closing quote, so a wrapper mention inside prose
# still blocks. AgDR-0262 accepts prose blocks; use `-F` / `--body-file`.
# Triage of the shapes tracked in me2resh/apexyard#2087, against the AgDR-0267
# bar: handle an ordinary command, or stay cheap without adding parser surface.
#
# Caught now:
#   - wrapper options: `sudo -u root`, `sudo -E`, `env -i`.
#   - attached git options: `git -Csub`, `git --git-dir=.git`, `git --work-tree=.`.
#   - any other git global option, e.g. `git --no-pager add -A`.
#   - an absolute path to git: `/usr/bin/git add -A`.
#   - a backslash-escaped command name: `\git add -A`.
#   - a quoted assignment value with spaces: `FOO="a b" git add -A`.
#   - a `$( )` command substitution, through the `$(` command position.
#   - a bare `eval 'git add -A'`, through the same wrapper rule as a `-c` shell.
#
# Accepted residuals, each with its one-line reason:
#   - `(` and `{` openers. Treating them as command positions reopens the
#     quoted-prose false blocks pinned below, which AgDR-0262 ranks first.
#   - a backtick command substitution. A backtick is ordinary markdown prose
#     punctuation, so a command position there blocks prose mentions.
# The header stays aligned with the matrix in test_block_git_add_all.sh.
_add_flag='(-A|--all|\.)'
_add_tail='([[:space:];&|)}<>]|$)'
_add_pos='(^[[:space:]]*|[;&|][[:space:]]*|[[:space:]](then|do|else)[[:space:]]+|\$\([[:space:]]*)'
_add_prefix='((sudo|env|command|nohup|time|exec|builtin)([[:space:]]+-{1,2}[A-Za-z][A-Za-z0-9-]*([[:space:]]+[^[:space:]]+)?)*[[:space:]]+)*([A-Za-z_][A-Za-z0-9_]*=([^[:space:]]*|"[^"]*"|\x27[^\x27]*\x27)[[:space:]]+)*'
# Any git global option, attached or separated: `-Csub`, `-C sub`,
# `--git-dir=.git`, `--git-dir .git`, `--no-pager`.
_add_gitopt='((-[A-Za-z]([A-Za-z0-9-]*|[[:space:]]+[^[:space:];&|]+)|--[a-z][a-z-]*([=][^[:space:];&|]+|[[:space:]]+[^[:space:];&|]+)?)[[:space:]]+)*'
# An absolute path to git, or a backslash-escaped command name, is the same
# command at a command position.
_add_gitcore="([[:alnum:]_./\\\\-]+/)?[\\\\/]?git[[:space:]]+${_add_gitopt}add[[:space:]]+${_add_flag}"
_add_git="${_add_gitcore}${_add_tail}"
# The wrapper pattern needs its own tail: it ends inside the quoted `-c` body,
# so the flag must be followed by a real terminator. Without it, `\.` matches
# the first character of a dot path (`bash -c 'git add .gitignore'`) and
# explicit-path staging is falsely blocked (#2073 review). `eval` takes the
# script as a plain argument, so its `-c` token is optional.
_add_wtail="([[:space:];&|)}<>'\"]|\$)"
_add_wrapped="${_add_pos}${_add_prefix}(bash|sh|zsh|dash|eval)([[:space:]]+-[A-Za-z-]+)*[[:space:]]+(-[A-Za-z]*c[A-Za-z]*[[:space:]]+)?.*${_add_gitcore}${_add_wtail}"

if printf '%s' "$COMMAND" | grep -qE "${_add_pos}${_add_prefix}${_add_git}" \
  || printf '%s' "$COMMAND" | grep -qE "${_add_wrapped}"; then
  cat >&2 <<MSG
BLOCKED: 'git add -A', 'git add --all', and 'git add .' are forbidden.

These commands stage every modified file in the working tree —
including .env files, credentials, generated artifacts, scratch
files, and partially-edited unrelated work. ApexYard requires
explicit file selection on every stage (.claude/rules/git-conventions.md
§ "File Staging").

To unblock:
  1. List the changed files: git status --short
  2. Stage each file you intend to commit by name:
       git add path/to/file1 path/to/file2
  3. Verify the staged set: git diff --cached --stat
  4. Retry the commit

If you have many files in the same change, group by directory:
       git add src/auth/ src/billing/
That's still explicit (you typed the path) and still safe.

If the match is prose in a commit message or body, write the text to a
file and pass -F <file> or --body-file <file>.

The one common exception — staging all files under a single feature
directory after a refactor — is fine via the directory form above.
There's no exception for whole-tree staging.
MSG
  exit 2
fi

exit 0
