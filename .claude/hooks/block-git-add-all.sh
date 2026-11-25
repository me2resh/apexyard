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
# AgDR-0267 § "Review bar for gate PRs"), so it outranks the catch. The cost
# is deliberate and named: `(git add -A)` and `{ git add -A; }` are NOT
# caught. `dev` did not catch them either, so #2087 records them as residuals.
# A heredoc body is NOT stripped before this check: the governance rule in
# _lib-strip-heredoc.sh forbids deciding whether a gate fires from stripped
# text, so a body line that starts with `git add -A` still blocks. Write the
# message with `-F <file>`.
# A prose mention directly after a separator inside quotes blocks only when
# the flag is followed by more text or a closing `)`/`}`: `"x && git add -A
# done"` blocks, while `"x && git add -A"` stays allowed because a closing
# quote right after the flag is not a direct-pattern terminator. The `-c`
# wrapper tail does accept a closing quote, so a wrapper mention inside prose
# still blocks. That prose block is the accepted cost of the `-c` wrapper
# catch under the AgDR-0267 kind-1 bar; use `-F` / `--body-file`.
# The absolute-path and git-option prefixes join the same separator-prose
# class: `echo "x; /usr/bin/git add -A done"` blocks, while a quoted mention
# with no trailing text stays allowed.
# Triage of the shapes tracked in me2resh/apexyard#2087, against the AgDR-0267
# bar: handle an ordinary command, or stay cheap without adding parser surface.
#
# Caught now:
#   - wrapper options: `sudo -u root`, `sudo -E`, `env -i`.
#   - attached git options: `git -Csub`, `git --git-dir=.git`, `git --work-tree=.`.
#   - any other git global option, e.g. `git --no-pager add -A`.
#   - an absolute path to git: `/usr/bin/git add -A`.
#   - a backslash-escaped command name: `\git add -A`.
#   - a double-quoted assignment value with spaces: `FOO="a b" git add -A`.
#   - a bare `eval 'git add -A'`, through its own narrow branch: the staging
#     command must be the first word of the eval argument.
#
# Accepted residuals, each with its one-line reason:
#   - `(` and `{` openers. Treating them as command positions reopens the
#     quoted-prose false blocks pinned below, which the AgDR-0267 kind-1 bar
#     ranks first.
#   - a backtick command substitution. A backtick is ordinary markdown prose
#     punctuation, so a command position there blocks prose mentions.
#   - a whole-command `$( )` substitution, e.g. `echo "$(git add -A)"`. The
#     `$(` position also fires inside single quotes, a grep pattern and a
#     quoted heredoc, where the shell runs nothing; `dev` allowed those, so
#     blocking them is a kind-1 false block (#2110 review). A substitution
#     that contains a separator (`$(cd x; git add -A)`) stays caught through
#     the separator.
#   - a wrapper word outside the fixed list, or an end-of-options marker after
#     one. Both are exotic under AgDR-0267, and the list is deliberately fixed.
#   - a single-quoted assignment value with spaces (`FOO='a b' git add -A`).
#     A portable single-quote match needs a shell-built pattern; the hex
#     escape for a quote is not portable: BSD grep reads it as a quote, GNU
#     grep as literal text (#2110 review, kind 3). `dev` missed the shape too.
#   - `eval` whose argument does not begin with the staging command, e.g.
#     `eval 'cd x && git add -A'`. `dev` missed it; widening re-blocks ordinary
#     `eval` lines that merely mention the shape (#2110 review, kind 1).
# The header stays aligned with the matrix in test_block_git_add_all.sh.
_add_flag='(-A|--all|\.)'
_add_tail='([[:space:];&|)}<>]|$)'
_add_pos='(^[[:space:]]*|[;&|][[:space:]]*|[[:space:]](then|do|else)[[:space:]]+)'
_add_prefix='((sudo|env|command|nohup|time|exec|builtin)([[:space:]]+-{1,2}[A-Za-z][A-Za-z0-9-]*([[:space:]]+[^[:space:]]+)?)*[[:space:]]+)*([A-Za-z_][A-Za-z0-9_]*=([^[:space:]]*|"[^"]*")[[:space:]]+)*'
# A git global option, attached or separated. Only `-C`, `-c` and the long
# options that take a value may consume the next word; a flag such as
# `--no-pager` or `-P` must not, or `git --no-pager grep -n add .` reads
# `grep` as the option value and the trailing `add .` as staging (#2110
# review, kind 1).
_add_gitopt='((-[Cc][[:space:]]+[^[:space:];&|]+|-[A-Za-z][A-Za-z0-9-]*|--(git-dir|work-tree|namespace|super-prefix|config-env)[[:space:]]+[^[:space:];&|]+|--[a-z][a-z-]*(=[^[:space:];&|]+)?)[[:space:]]+)*'
# An absolute path to git, or a backslash-escaped command name, is the same
# command at a command position.
_add_gitcore="([[:alnum:]_./\\\\-]+/)?[\\\\/]?git[[:space:]]+${_add_gitopt}add[[:space:]]+${_add_flag}"
_add_git="${_add_gitcore}${_add_tail}"
# The wrapper pattern needs its own tail: it ends inside the quoted `-c` body,
# so the flag must be followed by a real terminator. Without it, `\.` matches
# the first character of a dot path (`bash -c 'git add .gitignore'`) and
# explicit-path staging is falsely blocked (#2073 review). `-c` stays MANDATORY
# for the shells: making it optional blocked ordinary commands such as
# `bash run.sh | grep "git add -A"` (#2110 review, kind 1).
_add_wtail="([[:space:];&|)}<>'\"]|\$)"
_add_wrapped="${_add_pos}${_add_prefix}(bash|sh|zsh|dash)([[:space:]]+-[A-Za-z-]+)*[[:space:]]+-[A-Za-z]*c[A-Za-z]*[[:space:]]+.*${_add_gitcore}${_add_wtail}"
# `eval` has no `-c`: its script is a plain argument. Stay narrow — the staging
# command must be the FIRST word of that argument, optionally quoted. A `.*`
# here would re-block ordinary commands that merely mention the shape later
# in the line (#2110 review, kind 1).
_add_eval="${_add_pos}${_add_prefix}eval[[:space:]]+['\"]?[[:space:]]*${_add_gitcore}${_add_wtail}"

if printf '%s' "$COMMAND" | grep -qE "${_add_pos}${_add_prefix}${_add_git}" \
  || printf '%s' "$COMMAND" | grep -qE "${_add_wrapped}" \
  || printf '%s' "$COMMAND" | grep -qE "${_add_eval}"; then
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
