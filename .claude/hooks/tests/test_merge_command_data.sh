#!/bin/bash
# Merge words in read-only data must not start a merge gate. Ambiguous and
# executable forms stay visible to the raw merge detector.
set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOKS=${HOOKS_OVERRIDE:-$ROOT/.claude/hooks}
TMP=$(mktemp -d)
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
check 'rg pattern is data' no "rg 'glab mr merge 7' notes.txt"
check 'echo argument is data' no "echo 'gh api repos/demo/service/pulls/7/merge'"
check 'quoted scratch heredoc is data' no "$(printf "cat > /tmp/merge-notes <<'TEXT'\ngh pr merge 7\nglab mr merge 7\nTEXT")"
check 'read-only heredoc is data' no "$(printf "cat <<'TEXT'\ntracker_pr_merge demo/service 7 squash\nTEXT")"

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

# Each gate must also no-op silently on the reported read-only shapes. The
# sandbox is its own repository so any git lookup stays off the worktree.
SB="$TMP/gates"
mkdir -p "$SB/.claude/hooks" "$SB/bin"
cp "$ROOT/.claude/hooks"/_lib-*.sh "$SB/.claude/hooks/"
cp "$HOOKS/_lib-extract-pr.sh" "$HOOKS/_lib-command-scrub.sh" "$SB/.claude/hooks/"
cat > "$SB/bin/gh" <<'EOF'
#!/bin/bash
exit 0
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
done

printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
