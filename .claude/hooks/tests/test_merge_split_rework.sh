#!/bin/bash
# Spaced redirections keep data inert and shell execution visible.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOKS=${HOOKS_OVERRIDE:-$ROOT/.claude/hooks}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
# shellcheck source=/dev/null
. "$HOOKS/_lib-extract-pr.sh"
phrase='gh pr merge 7'
check() {
  local label=$1 want=$2 cmd=$3 rc
  is_merge_command "$cmd"; rc=$?
  if [ "$rc" -eq "$want" ]; then
    PASS=$((PASS+1)); printf 'PASS [%s]\n' "$label"
  else
    FAIL=$((FAIL+1)); printf 'FAIL [%s]: rc=%s\n' "$label" "$rc" >&2
  fi
}
mkdir -p "$TMP/.claude/hooks" "$TMP/bin"
cp "$HOOKS"/_lib-*.sh "$TMP/.claude/hooks/"
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
(cd "$TMP" && git init -q --template=) || exit 1
for op in '>& out.txt' '>& 2' '&> out.txt' '&>> out.txt'; do
  check 'spaced or combined redirect data' 1 "echo '$phrase' $op"
  check 'redirect data piped into a shell' 0 "echo '$phrase' $op | sh"
  for gate in block-unreviewed-merge.sh block-merge-on-red-ci.sh require-architecture-review.sh require-design-review-for-ui.sh; do
    cp "$HOOKS/$gate" "$TMP/.claude/hooks/$gate"
    for mode in data shell; do
      cmd="echo '$phrase' $op"; want=0
      if [ "$mode" = shell ]; then cmd="$cmd | sh"; want=2; fi
      payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
      (cd "$TMP" && printf '%s' "$payload" | PATH="$TMP/bin:$PATH" APEXYARD_OPS_DISABLE_PIN=1 /bin/bash ".claude/hooks/$gate" >/dev/null 2>"$TMP/err")
      rc=$?
      if [ "$rc" -eq "$want" ]; then
        PASS=$((PASS+1)); printf 'PASS [%s / %s / %s]\n' "$gate" "$mode" "$op"
      else
        FAIL=$((FAIL+1)); printf 'FAIL [%s / %s / %s]: rc=%s\n' "$gate" "$mode" "$op" "$rc" >&2
      fi
    done
  done
done
for op in '>&!' '>&|' '>>!'; do
  check 'clobber redirect to ordinary data' 1 "echo '$phrase' $op out.txt"
  check 'clobber redirect to startup file' 0 "echo '$phrase' $op ~/.zshenv"
done
# An unknown host can contain path separators. Do not trust a literal prefix.
for cmd in 'prefix${Q} pr merge 7' '/opt\/gh pr merge 7'; do
  check 'opaque host word' 0 "$cmd"
  check 'opaque host word in quoted data' 1 "$(printf "cat <<'DATA'\n%s\nDATA" "$cmd")"
done
for keyword in if elif else while until; do
  check 'control word followed by unknown command' 0 "$keyword \"\$G\" pr merge 7"
  check 'control word followed by variable arguments' 1 "$keyword cp \"\$A\" \"\$B\" \"\$C\""
done
check 'literal punctuation stays literal' 1 'gh pr "m.rge" 7'
check 'unknown verb stays opaque' 0 'gh pr "m${Q}rge" 7'
_has_split_merge_phrase "'' gh pr merge 7"; rc=$?
if [ "$rc" -eq 1 ]; then
  PASS=$((PASS+1)); printf 'PASS [empty quote state stays in its word]\n'
else
  FAIL=$((FAIL+1)); printf 'FAIL [empty quote state stays in its word]\n' >&2
fi
check 'quoted command word still blocks' 0 '"gh" pr merge 7'
printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
