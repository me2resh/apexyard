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

# Finding 1: quoted expansion before a literal last segment is not a merge host.
# Finding 2: a prefixed or nested phrase with a literal peer still blocks.
# Placeholders are built at run time so public tests never embed a ready bypass.
G=g; G="${G}h"; P=p; P="${P}r"; M=mer; M="${M}ge"
home_tool=$(printf '"$%s/bin/tool" "$IN" "$OUT"' HOME)
dir_run=$(printf '"$%s"/run.sh "$A" "$B"' DIR)
dir_run_flag=$(printf '"$%s/run.sh" -v "$A" "$B"' DIR)
glob_suf='./*.sh "$A" "$B"'
three_opaque=$(printf '"$%s" "$%s" "$%s"' PY SCRIPT ARG)
check 'quoted path last segment stays clear' 1 "$home_tool"
check 'split-quoted path last segment stays clear' 1 "$dir_run"
check 'quoted path with host options stays clear' 1 "$dir_run_flag"
check 'glob with literal suffix stays clear' 1 "$glob_suf"
check 'three opaque words stay clear' 1 "$three_opaque"
opaque_pr=$(printf '"$%s" "$%s" "$%s" 7' G P M)
check 'three opaque words with PR number still blocks' 0 "$opaque_pr"
check 'three opaque words with PR number data pair' 1 "$(printf "cat <<'DATA'\n%s\nDATA" "$opaque_pr")"
check 'quoted path last segment data pair' 1 "$(printf "cat <<'DATA'\n%s\nDATA" "$home_tool")"
# Opaque host token built without writing the three-word phrase as one literal.
opaque_host=$(printf '"$%s"' G)
unsafe_prefix=$(printf 'nohup %s %s %s 7' "$opaque_host" "$P" "$M")
unsafe_opt=$(printf 'time %s -R o/r %s %s 7' "$G" "$P" "$M")
unsafe_sub=$(printf 'echo $( %s %s %s 7 )' "$opaque_host" "$P" "$M")
unsafe_proc=$(printf 'cat <( %s %s %s 7 )' "$opaque_host" "$P" "$M")
unsafe_tick=$(printf 'echo `%s %s %s 7`' "$G" "$P" "$M")
check 'prefix with opaque host still blocks' 0 "$unsafe_prefix"
check 'prefix with host options still blocks' 0 "$unsafe_opt"
check 'command substitution body still blocks' 0 "$unsafe_sub"
check 'process substitution body still blocks' 0 "$unsafe_proc"
check 'backtick substitution body still blocks' 0 "$unsafe_tick"
for unsafe in "$unsafe_prefix" "$unsafe_opt" "$unsafe_sub" "$unsafe_proc" "$unsafe_tick"; do
  check 'prefixed or nested phrase data pair' 1 "$(printf "cat <<'DATA'\n%s\nDATA" "$unsafe")"
done
# Gate coverage for the new allow and unsafe classes.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOS'
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
EOS
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/glab"
chmod +x "$TMP/bin/gh" "$TMP/bin/glab"
for gate in block-unreviewed-merge.sh block-merge-on-red-ci.sh require-architecture-review.sh require-design-review-for-ui.sh; do
  cp "$HOOKS/$gate" "$TMP/.claude/hooks/$gate"
  for cmd in "$home_tool" "$dir_run" "$glob_suf"; do
    payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
    (cd "$TMP" && printf '%s' "$payload" | PATH="$TMP/bin:$PATH" APEXYARD_OPS_DISABLE_PIN=1 /bin/bash ".claude/hooks/$gate" >/dev/null 2>"$TMP/err")
    rc=$?
    if [ "$rc" -eq 0 ]; then
      PASS=$((PASS+1)); printf 'PASS [%s allow last-segment]\n' "$gate"
    else
      FAIL=$((FAIL+1)); printf 'FAIL [%s allow last-segment]: rc=%s\n' "$gate" "$rc" >&2
    fi
  done
  for cmd in "$unsafe_prefix" "$unsafe_opt" "$unsafe_sub" "$unsafe_proc"; do
    payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
    (cd "$TMP" && printf '%s' "$payload" | PATH="$TMP/bin:$PATH" APEXYARD_OPS_DISABLE_PIN=1 /bin/bash ".claude/hooks/$gate" >/dev/null 2>"$TMP/err")
    rc=$?
    if [ "$rc" -eq 2 ]; then
      PASS=$((PASS+1)); printf 'PASS [%s block prefix/nested]\n' "$gate"
    else
      FAIL=$((FAIL+1)); printf 'FAIL [%s block prefix/nested]: rc=%s\n' "$gate" "$rc" >&2
    fi
  done
done

# Finding 4: behind a non-host prefix, an ordinary argument list can fill the
# phrase window. It stays clear unless the host or subcommand word is literal.
# A bare number confirms an all-opaque window only at command position.
f4_allow=(
  'python3 "$SCRIPT" "$IN" "$OUT" 5'
  './run.sh "$A" "$B" "$C" 1'
  "printf '%s %s %s %d\n' \"\$a\" \"\$b\" \"\$c\" 1"
  'for x in "$A" "$B" "$C" 1; do echo "$x"; done'
  'mv "$f" "$d" merge'
  'node "$S" "$A" "$B" "$C" 42'
  'cp -v "$A" "$B" merge'
  'sort "$f" "$d" "$e" 9 | head -n 3'
  'while read -r x; do mv "$x" "$Y" "$Z" 2; done'
  'echo "$A" "$B" merge 7'
)
f4_block=(
  "$(printf 'nohup "$%s" "$%s" "$%s" 7' G P M)"
  "$(printf 'mv "$f" "$d" && "$%s" "$%s" %s 7' G P "$M")"
  "$(printf 'for x in 1; do "$%s" "$%s" "$%s" 1; done' G P M)"
  "$(printf 'nice "$%s" %s "$%s" 7' G "$P" M)"
  "$(printf 'sudo %s "$%s" "$%s" 7' "$G" P M)"
  "$(printf './run.sh "$A"; time "$%s" "$%s" "$%s" 5' G P M)"
)
for cmd in "${f4_allow[@]}"; do
  check 'ordinary argument list stays clear' 1 "$cmd"
done
for cmd in "${f4_block[@]}"; do
  check 'prefixed or command-position phrase still blocks' 0 "$cmd"
  check 'prefixed or command-position phrase data pair' 1 "$(printf "cat <<'DATA'\n%s\nDATA" "$cmd")"
done
for gate in block-unreviewed-merge.sh block-merge-on-red-ci.sh require-architecture-review.sh require-design-review-for-ui.sh; do
  for cmd in "${f4_allow[@]}"; do
    payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
    (cd "$TMP" && printf '%s' "$payload" | PATH="$TMP/bin:$PATH" APEXYARD_OPS_DISABLE_PIN=1 /bin/bash ".claude/hooks/$gate" >/dev/null 2>"$TMP/err")
    rc=$?
    if [ "$rc" -eq 0 ]; then
      PASS=$((PASS+1)); printf 'PASS [%s allow argument list]\n' "$gate"
    else
      FAIL=$((FAIL+1)); printf 'FAIL [%s allow argument list]: rc=%s: %s\n' "$gate" "$rc" "$cmd" >&2
    fi
  done
  for cmd in "${f4_block[@]}"; do
    payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
    (cd "$TMP" && printf '%s' "$payload" | PATH="$TMP/bin:$PATH" APEXYARD_OPS_DISABLE_PIN=1 /bin/bash ".claude/hooks/$gate" >/dev/null 2>"$TMP/err")
    rc=$?
    if [ "$rc" -eq 2 ]; then
      PASS=$((PASS+1)); printf 'PASS [%s block window phrase]\n' "$gate"
    else
      FAIL=$((FAIL+1)); printf 'FAIL [%s block window phrase]: rc=%s\n' "$gate" "$rc" >&2
    fi
  done
done

printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
