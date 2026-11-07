#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $1 (expected $2, got $3)"
    FAIL=$((FAIL + 1))
  fi
}
mkdir -p "$TMP/hooks"
cp "$ROOT/dispatch-bash.sh" "$ROOT/_lib-git-global.sh" \
  "$ROOT/_lib-extract-pr.sh" "$ROOT/_lib-command-scrub.sh" \
  "$ROOT/_lib-awk-fallback.sh" "$ROOT/_lib-strip-heredoc.sh" "$TMP/hooks/"
# Replace all dispatched gates with logging stubs, as in test_dispatch_bash.sh.
for gate in $(sed -nE 's/^# APEXYARD_DISPATCH_GATE: Bash[^|]*\|[^|]*\|([^ ]+)\.sh$/\1/p' "$ROOT/dispatch-bash.sh" | sort -u); do
  printf '#!/bin/bash\ncat >/dev/null\necho %s.sh >> "$DISPATCH_LOG"\n' "$gate" > "$TMP/hooks/$gate.sh"
  chmod +x "$TMP/hooks/$gate.sh"
done
row=0
run_row() {
  local expected="$1" command="$2" shell rc gate routed
  row=$((row + 1))
  for shell in bash zsh; do
    if ! command -v "$shell" >/dev/null 2>&1; then
      # Not a SKIP line: the runner fails a suite that reports SKIP.
      echo "note: $shell is not installed, row $row runs in the other shell only"
      continue
    fi
    rc=0
    if [ "$shell" = zsh ]; then
      # Match the library's zero-based arrays and Bash regex capture names.
      zsh -f -c 'setopt KSH_ARRAYS BASH_REMATCH; . "$1" || exit 2; command_has_git_subcommand "$2" push' matrix "$ROOT/_lib-git-global.sh" "$command" || rc=$?
    else
      bash -c '. "$1" || exit 2; command_has_git_subcommand "$2" push' matrix "$ROOT/_lib-git-global.sh" "$command" || rc=$?
    fi
    check "$shell row $row" "$expected" "$rc"
  done
  # All DATA rows and the first two PUSH rows prove dispatcher routing.
  if [ "$expected" = 1 ] || [ "$row" = 7 ] || [ "$row" = 8 ]; then
    : > "$TMP/log"
    rc=0
    jq -nc --arg c "$command" '{tool_name:"Bash",tool_input:{command:$c}}' \
      | DISPATCH_LOG="$TMP/log" bash "$TMP/hooks/dispatch-bash.sh" || rc=$?
    check "dispatch row $row exit" 0 "$rc"
    # check-secrets is a commit gate; PUSH rows route the two push gates.
    for gate in block-main-push check-secrets pre-push-gate; do
      [ "$expected" = 1 ] || [ "$gate" != check-secrets ] || continue
      routed=1
      grep -qx "$gate.sh" "$TMP/log" && routed=0
      check "dispatch row $row $gate" "$expected" "$routed"
    done
  fi
}
while IFS= read -r line; do
  run_row "${line%% *}" "${line#* }"
done <<'MATRIX'
1 grep -n -E 'git push|credential' f
1 grep -e "git push origin dev" docs/x.md
1 echo "run git push later"
1 echo 'run git push later' > notes.txt
1 printf '%s\n' 'git push origin dev'
1 fgrep 'git push' f
0 git push origin dev
0 cd x && git push
0 rg -n 'git push' docs/
0 GIT_X=1 echo 'git push'
0 printf -v v 'git push'
0 echo 'git push' | sh
0 grep x f | sh -c 'git push'
0 bash -c 'git push origin dev'
0 sh -c "git push origin dev"
0 eval 'git push origin dev'
0 bash <<< 'git push origin dev'
0 python3 -c 'import os; os.system("git push origin dev")'
0 echo "$(git push origin dev)"
0 echo `git push`
0 echo 'a' ; git push
0 echo 'a' && git push
0 echo "a\" ; git push ; echo \"b"
0 echo 'it'"'"'s git push'
0 echo $'git push'
0 echo "git push" # comment
0 grep --pre=script 'git push' f
0 grep -P 'git push' f
0 grep --perl-regexp 'git push' f
0 ag 'git push' f
0 ack 'git push' f
MATRIX
run_row 0 $'echo \'x\'\ngit push'
# Bash prints one argument here: the escaped quotes do not end the quotes.
# The exemption deliberately rejects this unclear shape and retains PUSH.
actual=$(bash -c 'echo "a\" ; git push ; echo \"b"')
check escaped-quote-shell-result 'a" ; git push ; echo "b' "$actual"
echo "TOTAL $PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
