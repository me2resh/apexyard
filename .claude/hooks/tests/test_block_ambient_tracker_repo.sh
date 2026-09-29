#!/bin/bash
# Regression tests for the explicit tracker-repository guard (#1268).

set -u
SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOKS="${HOOKS_OVERRIDE:-$SRC_ROOT/.claude/hooks}"
HOOK="$HOOKS/block-ambient-tracker-repo.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export APEXYARD_OPS_DISABLE_PIN=1
unset CLAUDE_CODE_SESSION_ID || true
PASS=0
FAIL=0

run_case() {
  local name="$1" expected="$2" command="$3" root="$4" rc
  rc=0
  (cd "$root" && printf '%s' "{\"tool_input\":{\"command\":$(printf '%s' "$command" | jq -Rs .)}}" | "$HOOK" >"$TMP/ambient-tracker.out" 2>&1) || rc=$?
  if [ "$rc" -eq "$expected" ] && { [ "$expected" -ne 0 ] || [ ! -s "$TMP/ambient-tracker.out" ]; }; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected $expected, got $rc)" >&2
    cat "$TMP/ambient-tracker.out" >&2
    FAIL=$((FAIL + 1))
  fi
}

make_repo() {
  local root="$1" origin="$2"
  mkdir -p "$root/.claude/session/tickets"
  : > "$root/.apexyard-fork"
  git init -q --template= "$root"
  git -C "$root" remote add origin "$origin"
}

root="$TMP/different"
make_repo "$root" "git@github.com:owner/framework.git"
printf '%s\n' 'repo=owner/project' > "$root/.claude/session/tickets/demo"
run_case 'unqualified issue lookup is blocked for a different active repo' 2 'gh issue view 42' "$root"
run_case 'environment-prefixed issue lookup is blocked' 2 'FOO=bar gh issue view 42' "$root"
run_case 'timeout-prefixed issue lookup is blocked' 2 'timeout 5 gh issue view 42' "$root"
run_case 'command-prefixed issue lookup is blocked' 2 'command gh issue view 42' "$root"
run_case 'subshell issue lookup is blocked' 2 '( gh issue view 42 )' "$root"
run_case 'conditional issue lookup is blocked' 2 'if true; then gh issue view 42; fi' "$root"
run_case 'pipeline issue lookup is blocked' 2 'printf x | gh issue view 42' "$root"
run_case 'repository flag in a comment does not authorize issue lookup' 2 'gh issue view 42 # --repo owner/project' "$root"
run_case 'repository flag in a separate command does not authorize issue lookup' 2 'echo --repo owner/project; gh issue view 42' "$root"
run_case 'short repository flag in a separate command does not authorize PR lookup' 2 'echo -R owner/project; gh pr list' "$root"
run_case 'repository flag after option terminator does not authorize issue lookup' 2 'gh issue view 42 -- --repo owner/project' "$root"
run_case 'single-quoted tracker text is data' 0 "printf '%s' 'gh pr create --title x'" "$root"
run_case 'double-quoted tracker text is data' 0 'printf "%s" "gh issue create --title x"' "$root"
run_case 'quoted command text inside a quoted argument is data' 0 "printf '%s' \"'gh' pr create --title x\"" "$root"
run_case 'quoted heredoc tracker text is data' 0 "$(printf "cat <<'TEXT'\ngh pr create --title x\nTEXT")" "$root"
run_case 'unquoted heredoc tracker text is data' 0 "$(printf 'cat <<TEXT\ngh issue create --title x\nTEXT')" "$root"
run_case 'real PR create with tracker text in its body is blocked' 2 "gh pr create --body 'gh issue create --title x'" "$root"
run_case 'plain issue create is blocked' 2 'gh issue create --title x' "$root"
run_case 'tracker command after cd and and is blocked' 2 'cd x && gh pr create --title x' "$root"
run_case 'tracker command after semicolon is blocked' 2 'printf x; gh issue create --title x' "$root"
run_case 'tracker command inside bash -c is blocked' 2 "bash -c 'gh pr create --title x'" "$root"
run_case 'tracker text piped into bash is blocked' 2 "printf 'gh issue create --title x' | bash" "$root"
run_case 'tracker command in bash heredoc is blocked' 2 "$(printf 'bash <<EOF\ngh pr create --title x\nEOF')" "$root"
run_case 'quoted gh command word is blocked' 2 "'gh' pr create --title x" "$root"
run_case 'split-quoted gh command word is blocked' 2 "g'h' pr create --title x" "$root"
run_case 'escaped gh command word is blocked' 2 'g\h pr create --title x' "$root"
run_case 'quoted pr subcommand is blocked' 2 "gh 'pr' create --title x" "$root"
run_case 'environment-prefixed create is blocked' 2 'FOO=bar gh issue create --title x' "$root"
run_case 'tracker command through eval is blocked' 2 "eval 'gh pr create --title x'" "$root"
run_case 'explicit issue repo is allowed' 0 'gh issue view 42 --repo owner/project' "$root"
run_case 'explicit short repo flag is allowed' 0 'gh pr list -R owner/project' "$root"

matching="$TMP/matching"
make_repo "$matching" "git@github.com:owner/project.git"
printf '%s\n' 'repo=owner/project' > "$matching/.claude/session/tickets/demo"
run_case 'matching checkout origin keeps ambient lookup available' 0 'gh issue view 42' "$matching"

empty="$TMP/empty"
make_repo "$empty" "git@github.com:owner/framework.git"
run_case 'no active repo marker leaves unrelated commands unchanged' 0 'gh issue view 42' "$empty"

multiple="$TMP/multiple"
make_repo "$multiple" "git@github.com:owner/framework.git"
printf '%s\n' 'repo=owner/project-a' > "$multiple/.claude/session/tickets/a"
printf '%s\n' 'repo=owner/project-b' > "$multiple/.claude/session/tickets/b"
run_case 'multiple active repos require an explicit target' 2 'gh pr list' "$multiple"
run_case 'repository flag on a continued line is explicit' 0 \
  "$(printf 'gh issue view 42 \\\n  --repo owner/project-a')" "$multiple"
run_case 'short repository flag on a continued line is explicit' 0 \
  "$(printf 'gh pr list \\\n  -R owner/project-b')" "$multiple"
run_case 'continued CLI word without a repository remains blocked' 2 \
  "$(printf 'gh \\\n  issue view 42')" "$multiple"
run_case 'continued subcommand without a repository remains blocked' 2 \
  "$(printf 'gh pr \\\n  list')" "$multiple"
# An escaped backslash before a newline is a literal backslash. The newline
# ends the command, so a flag on the next line belongs to a new command.
run_case 'escaped backslash then newline does not carry a repository flag' 2 \
  "$(printf 'gh pr list \\\\\n --repo owner/project-a')" "$multiple"
run_case 'escaped backslash then newline, flag at line start, stays blocked' 2 \
  "$(printf 'gh pr list \\\\\n--repo owner/project-a')" "$multiple"
# Bash keeps a backslash-newline inside single quotes, and the gate does not
# join inside any quotes, so quoted text cannot supply the flag.
run_case 'continuation inside single quotes does not join a repository flag' 2 \
  "$(printf "true && gh pr list --title 'a \\\\\n --repo owner/project-a'")" "$multiple"
run_case 'continuation inside double quotes does not join a repository flag' 2 \
  "$(printf 'true && gh pr list --title "a \\\n --repo owner/project-a"')" "$multiple"
run_case 'ANSI-C quoted command is not joined' 2 \
  "$(printf "true && gh pr list --title \$'a' \\\\\n --repo owner/project-a")" "$multiple"
run_case 'continued lines then a separate unqualified command still block' 2 \
  "$(printf 'gh issue view 42 \\\n  --repo owner/project-a; gh pr list')" "$multiple"
# A backslash in a comment is not a continuation. The next line is a real
# command, so it must not be pulled into the comment and dropped.
run_case 'comment line ending in a backslash does not hide the next command' 2 \
  "$(printf '# list PRs \\\ngh pr list')" "$multiple"
run_case 'inline comment ending in a backslash does not hide the next command' 2 \
  "$(printf 'echo hi # note \\\ngh pr list')" "$multiple"
run_case 'heredoc delimiter ending in a backslash does not hide the next command' 2 \
  "$(printf "cat <<'E\\\\'\nbody\nE\\\\\ngh pr list")" "$multiple"
run_case 'command substitution is not joined' 2 \
  "$(printf 'x="$(printf a)" gh pr list \\\n --title "b --repo owner/project-a"')" "$multiple"
run_case 'a command over the size cap is not joined' 2 \
  "$(printf 'gh pr list --title "%s" \\\n  --repo owner/project-a' "$(printf '%02100d' 0)")" "$multiple"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
