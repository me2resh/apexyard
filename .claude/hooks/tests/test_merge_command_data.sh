#!/bin/bash
# Merge words in read-only data must not start a merge gate. Ambiguous and
# executable forms stay visible to the raw merge detector.
set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOKS=${HOOKS_OVERRIDE:-$ROOT/.claude/hooks}
TMP=$(mktemp -d)
export GIT_CEILING_DIRECTORIES="$TMP"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

# shellcheck source=/dev/null
. "$HOOKS/_lib-extract-pr.sh"

check() {
  local label="$1" want="$2" cmd="$3" got=no
  if is_merge_command "$cmd"; then got=yes; fi
  if [ "$got" = "$want" ]; then
    printf 'PASS [%s]\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL [%s]: want %s, got %s\n' "$label" "$want" "$got" >&2
    FAIL=$((FAIL + 1))
  fi
}

check 'grep pattern is data' no "grep -nE 'gh pr merge [0-9]+' notes.txt"
check 'rg retains raw merge scan' yes "rg 'glab mr merge 7' notes.txt"
check 'echo argument is data' no "echo 'gh api repos/demo/service/pulls/7/merge'"
check 'quoted scratch heredoc is data' no "$(printf "cat > /tmp/merge-notes <<'TEXT'\ngh pr merge 7\nglab mr merge 7\nTEXT")"
check 'read-only heredoc is data' no "$(printf "cat <<'TEXT'\ntracker_pr_merge demo/service 7 squash\nTEXT")"
for word in grep egrep fgrep cat echo printf head tail wc; do
  check "$word quoted data" no "$word 'gh pr merge 7'"
done
check 'allowlisted words across segments' no $'echo "gh pr merge 7; git commit" | grep merge && printf ok; head notes.txt\ntail notes.txt | wc'
check 'descriptor redirect remains data' no "echo 'gh pr merge 7' 2>&1 | cat"
check 'multiple heredoc bodies are data' no $'cat <<\'A\' <<\'B\' | grep merge\ngh pr merge 7\nA\nglab mr merge 7\nB'
check 'tab-stripped heredoc is data' no $'cat <<-\'TEXT\'\n\tgh pr merge 7\n\tTEXT'
check 'unquoted literal heredoc is data' no $'cat <<TEXT\ngh pr merge 7\nTEXT'

check 'gh CLI merge' yes 'gh pr merge 7 --squash'
check 'gh API merge' yes 'gh api repos/demo/service/pulls/7/merge -X PUT'
check 'glab CLI merge' yes 'glab mr merge 7 -R demo/service'
check 'glab API merge' yes 'glab api projects/demo%2Fservice/merge_requests/7/merge -X PUT'
check 'tracker wrapper merge' yes 'tracker_pr_merge demo/service 7 squash true'
check 'bash wrapper merge' yes "bash -lc 'gh pr merge 7'"
check 'pipe into bash merge' yes "echo 'gh pr merge 7' | bash"
check 'heredoc executed by bash' yes "$(printf "bash <<'TEXT'\ngh pr merge 7\nTEXT")"
check 'grep then real merge' yes "grep -q 'gh pr merge' notes.txt && gh pr merge 7"
check 'scratch heredoc then real merge' yes "$(printf "cat > /tmp/merge-notes <<'TEXT'\ngh pr merge 7\nTEXT\ngh pr merge 8")"
# This conservative route is pinned by test_command_scrub_must_block.sh.
check 'cd then quoted API remains gated' yes "cd /tmp && echo 'gh api repos/demo/service/pulls/7/merge'"

# These strings are inspected, never executed. Every gate must block them.
mkdir -p "$TMP/must-detect"
case_count=0
must_detect() {
  case_count=$((case_count + 1))
  printf '%s' "$1" > "$TMP/must-detect/$case_count.label"
  printf '%s' "$2" > "$TMP/must-detect/$case_count.cmd"
  check "$1" yes "$2"
}
must_detect 'F1.1 echo then quoted API' "echo checking; gh api -X PUT 'repos/me2resh/apexyard/pulls/1497/merge' -f merge_method=squash"
must_detect 'F1.2 grep then quoted API' 'grep -q ok status.txt && gh api --method PUT "repos/o/r/pulls/7/merge"'
must_detect 'F1.3 quoted API then echo line' $'gh api -X PUT "repos/o/r/pulls/7/merge" -f merge_method=squash\necho merged'
must_detect 'F1.4 cd API then echo line' $'cd /x && gh api -X PUT "repos/o/r/pulls/7/merge"\necho done'
must_detect 'F2.1 rg preprocessor payload' "echo 'gh pr merge 7 --squash' > m.sh; rg --pre sh . m.sh"
must_detect 'F2.2 git hook payload' "echo x; echo 'gh pr merge 7 --squash' > .git/hooks/pre-commit; git commit --allow-empty -m x"
must_detect 'F2.3 git external diff payload' "echo '[diff]' >> .git/config; echo 'external = sh -c \"gh pr merge 7\" #' >> .git/config; git diff"
must_detect 'sort compressor payload' "echo 'gh pr merge 7' > m.sh; sort --compress-program=./m.sh input.txt"

# Only the narrow command list can suppress merge text, regardless of the
# general scrubber policy. Unknown words and shell syntax retain the raw view.
for word in gh glab git tracker_pr_merge rg sort xargs find sh bash zsh unknown; do
  check "$word after data retains raw scan" yes "echo 'gh pr merge 7'; $word input"
done
check 'argument named echo is not first command word' yes "unknown echo 'gh pr merge 7'"
check 'quoted command word retains raw scan' yes "'echo' 'gh pr merge 7'"
check 'concatenated command word retains raw scan' yes "echo'runner' 'gh pr merge 7'"
check 'assignment retains raw scan' yes "RUNNER=sh echo 'gh pr merge 7'"
check 'double-quoted substitution retains raw scan' yes 'echo "$(gh pr merge 7)"'
check 'backtick substitution retains raw scan' yes 'echo "`gh pr merge 7`"'
check 'process substitution retains raw scan' yes "cat <(echo 'gh pr merge 7')"
check 'heredoc opener pipe to shell retains raw scan' yes $'cat <<\'TEXT\' | sh\ngh pr merge 7\nTEXT'
check 'heredoc opener API retains raw scan' yes $'cat <<\'TEXT\'; gh api -X PUT "repos/o/r/pulls/7/merge"\nnotes\nTEXT'
check 'heredoc then executor retains raw scan' yes $'cat > m.sh <<\'TEXT\'\ngh pr merge 7\nTEXT\nsh m.sh'
check 'unquoted heredoc substitution retains raw scan' yes $'cat <<TEXT\n$(gh pr merge 7)\nTEXT'
check 'incomplete heredoc retains raw scan' yes $'cat <<\'TEXT\'\ngh pr merge 7'
check 'incomplete quote retains raw scan' yes "echo 'gh pr merge 7"

# The general scrub library is no longer part of merge detection.
scrub_bash_command() { printf '%s' "$1"; }
check 'merge scrub is independent of general helper' no "grep 'gh pr merge 7' notes.txt"
unset -f scrub_bash_command

# Each gate must also no-op silently on the reported read-only shapes. The
# sandbox is its own repository so any git lookup stays off the worktree.
SB="$TMP/gates"
mkdir -p "$SB/.claude/hooks" "$SB/bin"
cp "$HOOKS"/_lib-*.sh "$SB/.claude/hooks/"
cat > "$SB/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"pr checks"*) printf 'build\tfail\t1m\thttps://example.invalid\n'; exit 1 ;;
  *"pr view"*"number"*) echo 7 ;;
  *"pr view"*"headRepository"*|*"repo view"*) echo demo/service ;;
  *"pr view"*"headRefOid"*) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  *"api"*"changed_files"*) echo 2 ;;
  *"api"*"/files"*) printf '%s\n' docs/technical-design.md src/App.tsx ;;
  *) exit 1 ;;
esac
EOF
cat > "$SB/bin/glab" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$SB/bin/gh" "$SB/bin/glab"
(cd "$SB" && git init -q --template=) || exit 1
for gate in block-unreviewed-merge.sh block-merge-on-red-ci.sh require-architecture-review.sh require-design-review-for-ui.sh; do
  cp "$HOOKS/$gate" "$SB/.claude/hooks/$gate"
  for shape in grep heredoc; do
    case "$shape" in
      grep) cmd="grep -nE 'gh pr merge [0-9]+' notes.txt" ;;
      heredoc) cmd="$(printf "cat > /tmp/merge-notes <<'TEXT'\ngh pr merge 7\nTEXT")" ;;
    esac
    payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
    (cd "$SB" && printf '%s' "$payload" | PATH="$SB/bin:$PATH" APEXYARD_OPS_DISABLE_PIN=1 /bin/bash ".claude/hooks/$gate" >/dev/null 2>"$TMP/stderr")
    rc=$?
    if [ "$rc" -eq 0 ] && [ ! -s "$TMP/stderr" ]; then
      printf 'PASS [%s / %s data no-op]\n' "$gate" "$shape"
      PASS=$((PASS + 1))
    else
      printf 'FAIL [%s / %s data no-op]: rc=%s stderr=%s\n' "$gate" "$shape" "$rc" "$(tr '\n' ' ' < "$TMP/stderr")" >&2
      FAIL=$((FAIL + 1))
    fi
  done
  n=1
  while [ "$n" -le "$case_count" ]; do
    label=$(cat "$TMP/must-detect/$n.label")
    cmd=$(cat "$TMP/must-detect/$n.cmd")
    payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
    (cd "$SB" && printf '%s' "$payload" | PATH="$SB/bin:$PATH" APEXYARD_OPS_DISABLE_PIN=1 /bin/bash ".claude/hooks/$gate" >/dev/null 2>"$TMP/stderr")
    rc=$?
    if [ "$rc" -eq 2 ] && grep -q 'BLOCKED' "$TMP/stderr"; then
      printf 'PASS [%s / %s blocks]\n' "$gate" "$label"
      PASS=$((PASS + 1))
    else
      printf 'FAIL [%s / %s blocks]: rc=%s stderr=%s\n' "$gate" "$label" "$rc" "$(tr '\n' ' ' < "$TMP/stderr")" >&2
      FAIL=$((FAIL + 1))
    fi
    n=$((n + 1))
  done
done

# Removing the general scrub library must not change read-only classification.
rm -f "$SB/.claude/hooks/_lib-command-scrub.sh"
for gate in block-unreviewed-merge.sh block-merge-on-red-ci.sh require-architecture-review.sh require-design-review-for-ui.sh; do
  payload=$(jq -nc --arg c "grep 'gh pr merge 7' notes.txt" '{tool_name:"Bash",tool_input:{command:$c}}')
  (cd "$SB" && printf '%s' "$payload" | PATH="$SB/bin:$PATH" APEXYARD_OPS_DISABLE_PIN=1 /bin/bash ".claude/hooks/$gate" >/dev/null 2>"$TMP/stderr")
  rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$TMP/stderr" ]; then
    printf 'PASS [%s / no general scrub dependency]\n' "$gate"
    PASS=$((PASS + 1))
  else
    printf 'FAIL [%s / no general scrub dependency]: rc=%s\n' "$gate" "$rc" >&2
    FAIL=$((FAIL + 1))
  fi
done

printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
