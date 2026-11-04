#!/bin/bash
# Read forms and their write counterparts for #1914. Commands are inspected,
# never executed.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOKS=${HOOKS_OVERRIDE:-$ROOT/.claude/hooks}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
LIVE="$TMP/live"
mkdir -p "$LIVE/.claude/hooks" "$LIVE/.claude/session" "$TMP/home"
cp "$HOOKS"/*.sh "$LIVE/.claude/hooks/"
touch "$LIVE/.apexyard-fork"
git -C "$LIVE" init -q
export CLAUDE_PROJECT_DIR="$LIVE" CLAUDE_CODE_SESSION_ID=read1914
export APEXYARD_OPS_PIN_DIR="$TMP/pins"
PASS=0 FAIL=0
check() {
  local hook="$1" want="$2" label="$3" cmd="$4" rc=0
  jq -cn --arg c "$cmd" --arg cwd "$LIVE" '{tool_name:"Bash",agent_type:"code-reviewer",cwd:$cwd,tool_input:{command:$c}}' |
    (cd "$LIVE" && /bin/bash ".claude/hooks/$hook") >"$TMP/out" 2>"$TMP/err" || rc=$?
  if [ "$rc" = "$want" ]; then
    PASS=$((PASS+1)); echo "PASS $label"
  else
    FAIL=$((FAIL+1)); echo "FAIL $label: want=$want rc=$rc"; cat "$TMP/err"
  fi
}
protected() { check block-protected-target-writes.sh "$@"; }
protected 0 'grep pipeline' 'grep -n "scan_error" .claude/hooks/_lib-extract-pr.sh | sed -n '"'"'1,5p'"'"
protected 0 'assignment and awk' 'n=$(grep -n "_has_split_merge_phrase()" .claude/hooks/_lib-extract-pr.sh | cut -d: -f1); awk -v s=$n '"'"'NR>s && /^}/ {print NR; exit}'"'"' .claude/hooks/_lib-extract-pr.sh'
protected 0 'source and print marker' "bash -c '. $LIVE/.claude/hooks/_lib-session-markers.sh && active_issue_skill_marker_path $LIVE'"
protected 0 'documented cleanup' 'marker_home="'"$LIVE"'"; . "$marker_home/.claude/hooks/_lib-session-markers.sh"; skill_marker=$(active_issue_skill_marker_path "$marker_home") || exit 2; rm -f "$skill_marker"'
protected 0 'issue repro marker deletion' "bash -c '. $LIVE/.claude/hooks/_lib-session-markers.sh; m=\$(active_issue_skill_marker_path $LIVE); rm -f \"\$m\"'"
protected 2 'awk concatenated output' 'awk '"'"'{print > "/tmp/"; print > ".claude/" "hooks/x.sh"}'"'"' .claude/hooks/x.sh'
protected 2 'sort grouped output' 'sort -ro .claude/hooks/x.sh input'
protected 0 'awk ordinary output' 'awk '"'"'{print > "/tmp/read1914-output"}'"'"' .claude/hooks/x.sh'
protected 2 'awk multiple outputs' 'awk '"'"'{print > "/tmp/read1914-output"; print > ".claude/hooks/x.sh"}'"'"' .claude/hooks/x.sh'
for cmd in 'sed -i s/a/b/ .claude/hooks/x.sh' 'awk 1 > .claude/hooks/x.sh' 'rm -f .claude/hooks/x.sh' 'tee .claude/hooks/x.sh' 'awk -i inplace 1 .claude/hooks/x.sh' 'awk '"'"'{print > ".claude/hooks/x.sh"}'"'"' .claude/hooks/x.sh' 'sort -o .claude/hooks/x.sh input' 'uniq input .claude/hooks/x.sh'; do
  protected 2 "protected write $cmd" "$cmd"
done
for cmd in 'grep --anything x .claude/hooks/x.sh' 'sed -n 1p .claude/hooks/x.sh' 'cut -d: -f1 .claude/hooks/x.sh' 'head .claude/hooks/x.sh' 'tail .claude/hooks/x.sh' 'wc .claude/hooks/x.sh' 'cat .claude/hooks/x.sh' 'sort .claude/hooks/x.sh' 'uniq .claude/hooks/x.sh'; do
  protected 0 "read $cmd" "$cmd"
done
protected 2 'unknown diagnostic' 'mytool .claude/hooks/x.sh'
if grep -Fq "unknown verb 'mytool' has a live protected operand '.claude/hooks/x.sh'." "$TMP/err"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
# Paired unescaped backticks execute even in a double-quoted grep pattern.
protected 2 'paired backtick issue repro stays blocked' 'git -C /some/clone grep -n -E "PK: ?`|'"'"'[A-Z]+#'"'"'|`[A-Z]+#\$" origin/main -- app/src/infrastructure app/src/main'
protected 0 'single quoted backtick' 'git grep '"'"'`pattern$'"'"''
protected 0 'escaped backtick' 'git grep "\`pattern"'
protected 2 'unquoted sourced substitution write' 'echo $(. .claude/hooks/_lib-session-markers.sh; rm -f .claude/hooks/x.sh)'
protected 2 'double quoted substitution write' 'echo "`rm -f .claude/hooks/x.sh`"'
protected 0 'escaped paired issue pattern' 'git grep "PK: ?\`|[A-Z]+#|\`[A-Z]+#\$"'
protected 0 'unmatched quoted backtick' 'git grep "`pattern"'
protected 2 'invalid quoted backtick body writes before syntax error' 'echo "`rm -f .claude/hooks/x.sh
if`"'
printf '%s\n' rex > "$LIVE/.claude/session/active-reviewer.read1914"
review() { check block-reviewer-repo-mutation.sh "$@"; }
for cmd in 'git -C repo branch -a --contains abc' 'git tag --contains abc' 'git tag --sort=-v:refname' 'git hash-object file' 'git branch -r --no-contains abc --sort refname' 'git branch --list -vv --format=%(refname)' 'git tag -n --points-at abc' 'git branch --merged -a' 'git tag --contains' 'git -C /tmp/branch/repo branch --contains abc'; do
  review 0 "$cmd" "$cmd"
done
for cmd in 'git branch name' 'git branch -a name' 'git branch -d name' 'git branch -D name' 'git branch -m name' 'git branch -M name' 'git branch -c name' 'git branch -C name' 'git branch --set-upstream-to=main' 'git tag name' 'git tag -a name' 'git tag -d name' 'git tag -s name' 'git tag -f name' 'git hash-object -w file' 'git hash-object --stdin-paths' 'git tag --contains abc; git tag name' 'git branch -a; git branch name' 'git hash-object file; git hash-object -w file'; do
  review 2 "$cmd" "$cmd"
done
# Round 1: subcommand anchoring, redirects and real shell separators.
for cmd in 'git checkout dev  # return to the base branch' 'git commit -am "add hash-object test"' 'git add tag' 'git stash push -m "branch work"' 'git config user.name branch' 'git branch new-name' 'git tag -d v1' 'git hash-object -w f' 'git branch --format="x;y|z&k" new-name' 'git branch -a & git tag -d v1' 'git branch -a && git tag -d v1' 'git branch -a || git tag -d v1' 'git branch -a | git tag -d v1' 'git branch -a; git tag -d v1' $'git branch -a\ngit tag -d v1'; do
  review 2 "round 1 block $cmd" "$cmd"
done
for cmd in 'git branch -a 2>&1' 'git branch --show-current 2>/dev/null' "git branch --list 'fix/*'" 'git -C /x branch -a --contains abc123' 'git tag --contains abc123' 'git tag --sort=-v:refname' 'git hash-object f' 'git branch -a >&2' 'git branch -a &>/dev/null' 'git branch --format="x;y|z&k" --list "fix/*"' 'git -c x=y --git-dir=/x --work-tree=/y --no-pager -P --bare branch -a'; do
  review 0 "round 1 read $cmd" "$cmd"
done
# Build UTF-8 at runtime: test source and hook changes stay ASCII.
dash=$(printf '\342\200\224')
for hook in block-unreviewed-merge.sh block-merge-on-red-ci.sh require-architecture-review.sh require-design-review-for-ui.sh; do
  check "$hook" 0 'non-ASCII grep' "grep -rn '$dash help' ."
  check "$hook" 2 'merge stays gated' 'gh pr merge 7'
done
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
