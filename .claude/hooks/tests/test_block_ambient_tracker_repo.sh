#!/bin/bash
# Regression tests for the explicit tracker-repository guard (#1268).

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

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
  mkdir -p "$root"
  : > "$root/.apexyard-fork"
  git init -q --template= "$root"
  git -C "$root" remote add origin "$origin"
}

# add_project <ops-root> <name> <repo>: registers a project, clones it under
# workspace/<name>/ and writes its ticket marker into the clone's git dir, as
# /start-ticket does. Run from the ops root, the marker lives in the project's
# clone, not in the ops fork.
add_project() {
  local root="$1" name="$2" repo="$3"
  [ -f "$root/apexyard.projects.yaml" ] || printf 'projects:\n' > "$root/apexyard.projects.yaml"
  printf '  - name: %s\n    repo: %s\n' "$name" "$repo" >> "$root/apexyard.projects.yaml"
  mkdir -p "$root/workspace"
  git init -q --template= "$root/workspace/$name"
  printf '%s\n' "repo=$repo" > "$root/workspace/$name/.git/apexyard-ticket"
}

root="$TMP/different"
make_repo "$root" "git@github.com:owner/framework.git"
add_project "$root" demo owner/project
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
run_case '#1525 brief-only tracker text is data' 0 \
  $'cat > /tmp/brief.md <<\'EOF\'\ngh issue view 4\nEOF' "$root"
run_case '#1525 build-agent command keeps raw fallback' 2 \
  $'cat > /tmp/brief.md <<\'EOF\'\ngh issue view 4\nEOF\nclaude -p build' "$root"
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
add_project "$matching" demo owner/project
run_case 'matching checkout origin keeps ambient lookup available' 0 'gh issue view 42' "$matching"

empty="$TMP/empty"
make_repo "$empty" "git@github.com:owner/framework.git"
run_case 'no active repo marker leaves unrelated commands unchanged' 0 'gh issue view 42' "$empty"

multiple="$TMP/multiple"
make_repo "$multiple" "git@github.com:owner/framework.git"
add_project "$multiple" a owner/project-a
add_project "$multiple" b owner/project-b
run_case 'multiple active repos require an explicit target' 2 'gh pr list' "$multiple"
multi_msg=$(cd "$multiple" && printf '%s' "{\"tool_input\":{\"command\":\"gh pr list\"}}" | "$HOOK" 2>&1 >/dev/null)
case "$multi_msg" in
  *"multiple repositories"*) echo "PASS: the multiple-repository message is restored"; PASS=$((PASS + 1)) ;;
  *) echo "FAIL: the multiple-repository message is missing: $multi_msg" >&2; FAIL=$((FAIL + 1)) ;;
esac
run_case 'repository flag on a continued line is explicit' 0 \
  "$(printf 'gh issue view 42 \\\n  --repo owner/project-a')" "$multiple"
run_case 'short repository flag on a continued line is explicit' 0 \
  "$(printf 'gh pr list \\\n  -R owner/project-b')" "$multiple"
run_case 'continued CLI word without a repository remains blocked' 2 \
  "$(printf 'gh \\\n  issue view 42')" "$multiple"
run_case 'continued subcommand without a repository remains blocked' 2 \
  "$(printf 'gh pr \\\n  list')" "$multiple"
# #1521: Bash also removes a continuation inside a double-quoted CLI word.
run_case 'double-quoted split CLI word stays blocked' 2 \
  "$(printf '"g\\\nh" issue view 1')" "$multiple"
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
run_case 'comment ending in a letter and backslash does not hide a split CLI word' 2 \
  "$(printf '# note x\\\ng\\\nh issue view 1')" "$multiple"
run_case 'heredoc delimiter ending in a backslash does not hide the next command' 2 \
  "$(printf "cat <<'E\\\\'\nbody\nE\\\\\ngh pr list")" "$multiple"
run_case 'command substitution is not joined' 2 \
  "$(printf 'x="$(printf a)" gh pr list \\\n --title "b --repo owner/project-a"')" "$multiple"
# #1503: nested double quotes inside a parameter expansion can hide a
# continued `--repo` in quoted text, so a command with `${` stays unjoined.
run_case 'parameter expansion with nested quotes is not joined' 2 \
  "$(printf 'gh pr list --search "${x:-"a \\\n --repo owner/project-a"}"')" "$multiple"
# Review of PR #1511: a skipped (unjoined) command can split the CLI word
# from its subcommand. Bash still joins the lines, so the gate must block.
run_case 'parameter expansion before a split CLI word stays blocked' 2 \
  "$(printf 'x=${y} gh \\\n  issue view 42')" "$multiple"
run_case 'command substitution before a split CLI word stays blocked' 2 \
  "$(printf 'x=$(true) gh \\\n  issue view 42')" "$multiple"
run_case 'backtick before a split CLI word stays blocked' 2 \
  "$(printf 'x=`true` gh \\\n  issue view 42')" "$multiple"
run_case 'ANSI-C quoting before a split CLI word stays blocked' 2 \
  "$(printf "x=\$'a' gh \\\\\n  issue view 42")" "$multiple"
run_case 'trailing comment after a split CLI word stays blocked' 2 \
  "$(printf 'gh \\\n  issue view 42 # note')" "$multiple"
# A tracker command that only the joined view can see always blocks, even
# with a flag: the joined view may join inside quotes, where Bash does not.
# This is a conservative false positive (review round 2 of PR #1511).
run_case 'split CLI word after a skip token blocks even with a repository flag' 2 \
  "$(printf 'x=${y} gh \\\n  issue view 42 --repo owner/project-a')" "$multiple"
run_case 'split CLI word with a flag inside double quotes stays blocked' 2 \
  "$(printf 'x=${y} gh \\\n issue view 42 "a \\\n --repo owner/project-a"')" "$multiple"
run_case 'split CLI word with a flag inside single quotes stays blocked' 2 \
  "$(printf "x=\${y} gh \\\\\n issue view 42 'a \\\\\n --repo owner/project-a'")" "$multiple"
run_case 'split CLI word with a flag after an escaped backslash stays blocked' 2 \
  "$(printf 'x=${y} gh \\\n issue view 42 \\\\\n --repo owner/project-a')" "$multiple"
run_case 'qualified command then a split CLI word with a quoted flag stays blocked' 2 \
  "$(printf 'gh pr list --repo owner/project-a; x=${y} gh \\\n issue view 42 "a \\\n --repo owner/project-a"')" "$multiple"
# Review round 3 of PR #1511: a join can also REMOVE a tracker match (a
# letter glued onto the CLI word), so match counts cannot decide. A command
# whose continuations the join does not model gets no flag-based allowance.
run_case 'join that removes one match and adds another stays blocked (double quotes)' 2 \
  "$(printf 'x=${y} echo a\\\ngh issue view 1 --repo owner/project-a; x=${y} gh \\\n issue view 42 "a \\\n --repo owner/project-a"')" "$multiple"
run_case 'join that removes one match and adds another stays blocked (single quotes)' 2 \
  "$(printf "x=\${y} echo a\\\\\ngh issue view 1 --repo owner/project-a; x=\${y} gh \\\\\n issue view 42 'a \\\\\n --repo owner/project-a'")" "$multiple"
run_case 'join that removes one match and adds another stays blocked (escaped backslash)' 2 \
  "$(printf 'x=${y} echo a\\\ngh issue view 1 --repo owner/project-a; x=${y} gh \\\n issue view 42 \\\\\n --repo owner/project-a')" "$multiple"
run_case 'one-line command with a skip token and a repository flag is explicit' 0 \
  'x=${y} gh issue view 42 --repo owner/project-a' "$multiple"
# The continuation follows the closing quote. Bash passes agh to echo.
run_case 'parameter expansion and a continued quoted echo argument stay allowed' 0 \
  "$(printf 'x=${y} echo "ag"\\\nh issue view 1')" "$multiple"
# jq replaces invalid UTF-8 with U+FFFD before the hook receives the command.
# Keep that input covered, then use a UTF-8 letter to distinguish byte-based
# delimiter matching from locale-dependent character matching in both scans.
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 run_case 'tracker next to invalid UTF-8 input stays blocked' 2 \
  "$(printf '\377gh issue view 1')" "$multiple"
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 run_case 'tracker delimiter uses bytes in the direct and segment scans' 2 \
  "$(printf '\303\251gh issue view 1')" "$multiple"
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 run_case 'tracker delimiter uses bytes in the unmodelled joined scan' 2 \
  "$(printf 'x=${y} \303\251g\\\nh issue view 1')" "$multiple"
run_case 'a command over the size cap is not joined' 2 \
  "$(printf 'gh pr list --title "%s" \\\n  --repo owner/project-a' "$(printf '%02100d' 0)")" "$multiple"

# Hakim, PR #1511: a command with many continuations and a skip token must
# not stall the gate. 20000 continued lines must finish in under 1 second.
big="$TMP/big-command"
{
  printf 'cat <<E\nbody\nE\necho start'
  i=0
  while [ "$i" -lt 20000 ]; do printf ' \\\n -f x=1'; i=$((i + 1)); done
} > "$big"
start=$(jq -n now)
run_case 'many continuations with a skip token and no tracker command pass' 0 "$(cat "$big")" "$multiple"
elapsed=$(jq -n --argjson start "$start" 'now - $start')
if jq -en --argjson elapsed "$elapsed" '$elapsed < 1' >/dev/null; then
  echo "PASS: many continuations finish in ${elapsed}s (limit 1s)"
  PASS=$((PASS + 1))
else
  echo "FAIL: many continuations took ${elapsed}s (limit 1s)" >&2
  FAIL=$((FAIL + 1))
fi

# Each working tree is judged by its own marker. A linked worktree with a
# marker for another repo does not change the main clone's verdict.
iso="$TMP/isolated"
make_repo "$iso" "git@github.com:owner/framework.git"
printf '%s\n' 'repo=owner/framework' > "$iso/.git/apexyard-ticket"
git -C "$iso" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$iso" worktree add -q "$TMP/isolated-wt" -b wt
printf '%s\n' 'repo=owner/project-z' > "$(git -C "$TMP/isolated-wt" rev-parse --absolute-git-dir)/apexyard-ticket"
mkdir -p "$TMP/none"
run_case 'the main clone ignores a worktree marker for another repo' 0 'gh issue view 42' "$iso"
run_case 'the worktree is judged by its own marker' 2 'gh issue view 42' "$TMP/isolated-wt"
run_case 'a directory with no tree and no marker is not pinned' 0 'gh issue view 42' "$TMP/none"

# A project ticket written from the ops root lives in the project's clone. The
# guard run from the ops root must still see it, and a project tree is judged
# by its own marker only.
proj="$TMP/proj"
make_repo "$proj" "git@github.com:owner/framework.git"
add_project "$proj" p1 owner/p1
add_project "$proj" p2 owner/p2
rm -f "$proj/workspace/p2/.git/apexyard-ticket"
git -C "$proj/workspace/p1" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$proj/workspace/p1" worktree add -q "$TMP/proj-p1-wt" -b wt
run_case 'ops root sees a project marker kept in workspace/p1/.git' 2 'gh issue view 42' "$proj"
run_case 'ops root with the explicit repo is allowed' 0 'gh issue view 42 --repo owner/p1' "$proj"
run_case 'project tree p2 with no marker is not pinned by p1' 0 'gh issue view 42' "$proj/workspace/p2"
printf '%s\n' 'repo=owner/p3' > "$(git -C "$TMP/proj-p1-wt" rev-parse --absolute-git-dir)/apexyard-ticket"
multi=$(cd "$proj" && printf '%s' "{\"tool_input\":{\"command\":\"gh issue view 42\"}}" | "$HOOK" 2>&1 >/dev/null)
case "$multi" in
  *"multiple repositories"*) echo "PASS: ops root also reads a linked worktree marker of a project"; PASS=$((PASS + 1)) ;;
  *) echo "FAIL: ops root did not read the project worktree marker: $multi" >&2; FAIL=$((FAIL + 1)) ;;
esac

# After an update an adopter has old-layout files and no new marker yet. The
# guard run from the ops root must still see them.
oldl="$TMP/oldlayout"
make_repo "$oldl" "git@github.com:owner/framework.git"
printf 'projects:\n  - name: p1\n    repo: owner/p1\n' > "$oldl/apexyard.projects.yaml"
mkdir -p "$oldl/workspace" "$oldl/.claude/session/tickets"
git init -q --template= "$oldl/workspace/p1"
printf 'repo=owner/p1\nnumber=3\n' > "$oldl/.claude/session/tickets/p1"
run_case 'old tickets/p1 file alone still pins the ops root' 2 'gh issue view 42' "$oldl"
run_case 'old tickets/p1 file with the explicit repo is allowed' 0 'gh issue view 42 --repo owner/p1' "$oldl"
rm -f "$oldl/.claude/session/tickets/p1"
printf 'repo=owner/p1\nnumber=3\n' > "$oldl/.claude/session/current-ticket"
run_case 'old current-ticket naming owner/p1 alone still pins the ops root' 2 'gh issue view 42' "$oldl"
rm -f "$oldl/.claude/session/current-ticket"
printf 'repo=owner/unregistered\nnumber=3\n' > "$oldl/.claude/session/tickets/zzz"
# Every old-layout file pins its repo, as before markers moved, so the guard
# blocks at least what it blocked before.
run_case 'an old tickets file for an unregistered name still pins, as before' 2 'gh issue view 42' "$oldl"
rm -f "$oldl/.claude/session/tickets/zzz"
# The old per-branch form: tickets/<name>/<branch>.
mkdir -p "$oldl/.claude/session/tickets/p1"
printf 'repo=owner/p1\nnumber=3\n' > "$oldl/.claude/session/tickets/p1/feature__x"
run_case 'an old per-branch tickets/p1/feature__x file alone still pins the ops root' 2 'gh issue view 42' "$oldl"


# A partial install without the resolver library must still block. The guard
# then reads the old-layout markers inline.
nolib="$TMP/nolib-hooks"
mkdir -p "$nolib"
cp "$HOOKS"/*.sh "$nolib/"
rm -f "$nolib/_lib-active-ticket.sh"
saved_hook="$HOOK"
HOOK="$nolib/block-ambient-tracker-repo.sh"
run_case 'without the resolver library an old per-branch marker still pins' 2 'gh issue view 42' "$oldl"
rm -f "$oldl/.claude/session/tickets/p1/feature__x"
printf 'repo=owner/p1\nnumber=3\n' > "$oldl/.claude/session/current-ticket"
run_case 'without the resolver library current-ticket still pins' 2 'gh issue view 42' "$oldl"
run_case 'without the resolver library the explicit repo is allowed' 0 'gh issue view 42 --repo owner/p1' "$oldl"
rm -f "$oldl/.claude/session/current-ticket"
run_case 'without the resolver library and with no marker the guard allows' 0 'gh issue view 42' "$oldl"
HOOK="$saved_hook"

# A scratch clone or an isolated build clone outside the ops fork is not a
# registered tree, so it has no marker of its own. The session pin still finds
# the ops root. The guard must then read the ops fork's marker and every
# project marker, so an unqualified tracker command stays blocked when the
# active ticket names a different repo.
pinops="$TMP/pinops"
make_repo "$pinops" "git@github.com:owner/framework.git"
mkdir -p "$pinops/.claude/hooks" "$TMP/pins"
add_project "$pinops" demo owner/project
printf '%s\n' "$pinops" > "$TMP/pins/ops-root-ambient-test"
scratch="$TMP/scratch-clone"
make_repo "$scratch" "git@github.com:owner/other.git"
rm -f "$scratch/.apexyard-fork"
scratch_match="$TMP/scratch-match"
make_repo "$scratch_match" "git@github.com:owner/project.git"
rm -f "$scratch_match/.apexyard-fork"
pinned_case() {
  APEXYARD_OPS_DISABLE_PIN='' CLAUDE_CODE_SESSION_ID=ambient-test APEXYARD_OPS_PIN_DIR="$TMP/pins" \
    run_case "$@"
}
pinned_case 'unregistered clone sees a project marker through the pinned ops root' 2 'gh issue view 42' "$scratch"
pinned_case 'unregistered clone with the explicit repo is allowed' 0 'gh issue view 42 --repo owner/project' "$scratch"
pinned_case 'unregistered clone whose origin matches the ticket repo is allowed' 0 'gh issue view 42' "$scratch_match"
rm -f "$pinops/workspace/demo/.git/apexyard-ticket"
pinned_case 'unregistered clone with no ticket anywhere is not pinned' 0 'gh issue view 42' "$scratch"
printf '%s\n' 'repo=owner/project' > "$pinops/.git/apexyard-ticket"
pinned_case 'unregistered clone sees the ops fork marker through the pinned ops root' 2 'gh issue view 42' "$scratch"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
