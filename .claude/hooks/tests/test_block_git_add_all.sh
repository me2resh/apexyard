#!/bin/bash
# Tests for block-git-add-all.sh command-position matching (me2resh/apexyard#2071).
#
# The bug: the gate ran only when the whole Bash call *started* with `git add`,
# because the dispatcher routed it from the prefix glob `git add *`. A command
# with any prefix (`cd src && git add -A`, `echo hi; git add -A`, `FOO=1 …`,
# `sudo …`, `bash -c '…'`) skipped the hook and staged the whole tree.
#
# The fix: the dispatcher runs the hook on every Bash call (row `Bash|*`), and
# the hook matches `git add -A / --all / .` at a COMMAND position — start of a
# line, after a shell separator, after `then`/`do`/`else`, past a common command
# prefix (sudo/env/assignments) or a `-c` shell wrapper. A quoted mention (a
# commit message, a printf payload, a PR body) stays allowed, and so does a
# parenthesised one: `(` and `{` are prose punctuation as often as command
# openers, so blocking them would be a false block on an ordinary command
# (AgDR-0267). `(git add -A)` and `{ git add -A; }` are therefore NOT caught —
# an exotic-shape residue that `dev` also left open (epic #1846), not a
# regression.
#
# Exit 0 if every case passes; 1 on the first failing case.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/block-git-add-all.sh"
DISPATCH_SRC="$SRC_ROOT/.claude/hooks/dispatch-bash.sh"

for f in "$HOOK_SRC" "$DISPATCH_SRC"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0

# expect <want_exit> <command>
expect() {
  local want="$1" cmd="$2" rc payload
  payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  if printf '%s' "$payload" | bash "$HOOK_SRC" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  if [ "$rc" -eq "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: want exit %s, got %s for command: %s\n' "$want" "$rc" "$cmd" >&2
  fi
}

# --- blocked: the staging command, however it is reached --------------------
expect 2 'git add -A'
expect 2 'git add --all'
expect 2 'git add .'
expect 2 'cd src && git add -A'
expect 2 'cd . && git add -A'
expect 2 'echo hi; git add -A'
expect 2 'true || git add -A'
expect 2 'make | tee log; git add .'
expect 2 'FOO=1 git add -A'
expect 2 'sudo git add -A'
expect 2 'env GIT_DIR=.git git add -A'
expect 2 'git -C sub add -A'
expect 2 'git -c user.name=x add --all'
expect 2 'if true; then git add -A; fi'
expect 2 'make && git add . && git commit -m build'
expect 2 "bash -c 'git add -A'"
expect 2 'bash -lc "cd x && git add -A"'
expect 2 "bash -c 'git add .'"
expect 2 'sh -c "cd x; git add ."'
expect 2 'git add -A>/dev/null'
expect 2 "bash -c 'git add -A>/dev/null'"
expect 2 'cd x
  git add -A'

# --- #2087: shapes that met the AgDR-0267 bar --------------------------------
# Wrapper options, attached and other git global options, an absolute or
# escaped git path, a quoted assignment value (double-quoted only), a `$( )`
# substitution, and a bare `eval` are ordinary commands, so the cheap catch
# lands here. Single-quoted FOO values with spaces are accepted residuals
# (they were not caught before #2073 either, and AgDR-0262 ranks the kind‑1
# prose‑block cost first).
expect 2 'sudo -u root git add -A'
expect 2 'sudo -E git add -A'
expect 2 'env -i git add -A'
expect 2 'git -Csub add -A'
expect 2 'git --git-dir=.git add -A'
expect 2 'git --work-tree=. add -A'
expect 2 'git --no-pager add -A'
expect 2 '/usr/bin/git add -A'
expect 2 '\git add -A'
expect 2 'FOO="a b" git add -A'
expect 0 "FOO='a b' git add -A"
expect 2 'echo "$(git add -A)"'
expect 2 "eval 'git add -A'"
expect 2 'eval "git add -A"'
expect 2 'eval git add -A'
expect 2 'eval "git add ."'
# The eval branch stays narrow: the previous word must not be `eval` alone.
expect 0 "eval 'cd x && git add -A'"
expect 0 'eval "$(fnm env)"'

# --- allowed: an explicit path, or the words inside a quoted mention ---------
expect 0 'git add path/to/file.txt'
expect 0 'git add src/auth/ src/billing/'
expect 0 'git status --short'
expect 0 'echo "git add -A"'
expect 0 'echo hi; git add src/app.ts'
expect 0 'git commit -m "never run git add -A"'
expect 0 'gh pr comment 1 --body "do not use git add -A"'
expect 0 'grep -rn "git add -A" docs/'
# A dot path is an explicit path, not whole-tree staging. The `-c` wrapper
# tail must not let `\.` match the first character of the path (#2073 review).
expect 0 "bash -c 'git add .gitignore'"
expect 0 "bash -c 'make' && git add .github/workflows/ci.yml"
expect 0 "bash -c 'git add ./src'"
expect 0 "printf '%s' '{\"tool_input\":{\"command\":\"git add -A\"}}'"

# --- #2110: allow pins for the widened patterns -----------------------------
# The `-c` wrapper token stays mandatory and `eval` stays narrow, so ordinary
# commands that merely mention the shape stay allowed. These are the exact
# commands Rex and Hakim found blocked at ff241414 (kind-1 regression). Pin
# them so a later widening cannot bring the false block back.
expect 0 'bash run.sh | grep "git add -A"'
expect 0 'bash .claude/hooks/tests/test_block_git_add_all.sh 2>&1 | grep -c "git add -A"'
expect 0 "bash -n hook.sh && grep -n 'git add -A' hook.sh"
expect 0 "sh -e x.sh; rg 'git add --all' docs/"
expect 0 'eval "$(ssh-agent -s)" && echo "never git add -A"'
expect 0 'eval "$(fnm env)"; grep -n "git add ." README.md'
# Absolute/escaped git paths and git global options stay allowed for a real
# explicit path, and so does a `-C` subdirectory.
expect 0 '/usr/bin/git add .gitignore'
expect 0 'git -C sub add src/'
expect 0 'git --no-pager log'
expect 0 "bash build.sh"
expect 0 'zsh -l'
# A closing quote right after the flag is not a terminator, so this prose
# mention stays allowed (the header names this shape; #2073 delta review).
expect 0 'git commit -m "x && git add -A"'
# The same prose with trailing text does block, as the header states.
expect 2 'git commit -m "x && git add -A done"'

# A parenthesised or braced mention is ordinary review prose. `dev` allowed it
# and the head must not block it (a false block on an ordinary command is kind
# 1, AgDR-0267). These four cases are the regression this matrix exists to pin.
expect 0 'git commit -m "docs: explain why (git add -A) is blocked"'
expect 0 'gh pr comment 2073 --body "the guard blocks (git add -A) at command position"'
expect 0 'printf "%s\n" "example: (git add -A)"'
expect 0 'echo "note; (git add -A) is blocked"'

# Deliberate residue, accepted in #2087 with a one-line reason each: `(` and
# `{` are not command positions here, and a backtick is prose punctuation as
# often as a substitution. A real subshell, brace group, or backtick command
# that stages the whole tree is therefore missed. `dev` missed them too.
expect 0 '(git add -A)'
expect 0 '{ git add -A; }'
expect 0 'echo `git add -A`'

# --- routing: the dispatcher must reach the gate without a prefix -----------
# The gate table row carries no command predicate any more, and the hook is in
# the unconditional loop, so a prefixed call still evaluates it exactly once.
if grep -q '^# APEXYARD_DISPATCH_GATE: Bash|\*|block-git-add-all\.sh$' "$DISPATCH_SRC" \
  && ! grep -q '^# APEXYARD_DISPATCH_GATE: Bash|git add \*|block-git-add-all\.sh$' "$DISPATCH_SRC"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: dispatch table still routes block-git-add-all.sh from a prefix glob" >&2
fi

if printf '%s' "$(jq -nc --arg c 'cd . && git add -A' '{tool_name:"Bash",tool_input:{command:$c}}')" \
  | bash "$DISPATCH_SRC" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1))
  echo "FAIL: the dispatcher allowed a prefixed git add -A" >&2
else
  rc=$?
  if [ "$rc" -eq 2 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: dispatcher exited %s for a prefixed git add -A (want 2)\n' "$rc" >&2
  fi
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
