#!/bin/bash
# Class-level regression fixtures use runtime phrase placeholders.
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
G=g; G="${G}h"; P=p; P="${P}r"; M=mer; M="${M}ge"
mkdir -p "$TMP/.claude/hooks" "$TMP/bin"
cp "$HOOKS"/_lib-*.sh "$TMP/.claude/hooks/"
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
(cd "$TMP" && git init -q --template=) || exit 1
pair() {
  local label=$1 block=$2 allow=$3 cmd want rc gate mode
  for mode in block allow; do
    cmd=$block; want=2
    if [ "$mode" = allow ]; then cmd=$allow; want=0; fi
    for gate in block-unreviewed-merge.sh block-merge-on-red-ci.sh require-design-review-for-ui.sh require-architecture-review.sh; do
      cp "$HOOKS/$gate" "$TMP/.claude/hooks/$gate"
      payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
      (cd "$TMP" && printf '%s' "$payload" | PATH="$TMP/bin:$PATH" /bin/bash ".claude/hooks/$gate" > /dev/null 2>"$TMP/err")
      rc=$?
      if [ "$rc" -eq "$want" ]; then
        PASS=$((PASS+1)); printf 'PASS [%s %s / %s]\n' "$label" "$mode" "$gate"
      else
        FAIL=$((FAIL+1)); printf 'FAIL [%s %s / %s]: rc=%s\n' "$label" "$mode" "$gate" "$rc" >&2
      fi
    done
  done
}
phrase=$(printf '"$%s" %s %s 17' G "$P" "$M")
data=$(printf "cat <<'DATA'\n%s\nDATA" "$phrase")
pair 'layers' "sh -c 'sh -c \"$G $P $M 17\"'" 'sh -c '\''sh -c "echo hello"'\'
pair 'function' "f() { $phrase; }; f" 'f() { echo "$U" "$V" "$W"; }; f'
pair 'launcher literal peer' "echo $G | xargs $G $P $M 17" 'echo hello | xargs echo'
pair 'shell heredoc' "$(printf 'sh <<EOF\n%s\nEOF' "$phrase")" "$data"
# Direct renamed executables remain an external-state limit. A definition
# that includes a visible phrase still has to block.
pair 'alternate-name definition' "f() { $G $P $M 17; }; f" 'f() { cp "$A" "$B"; }; f'
for prefix in 'time -p' 'env -i' 'command -p' 'exec -a label' 'nohup --' 'sudo -u root' 'sudo -n' 'nice -n 2' 'env -u TEMP' 'time -o log'; do
  opaque=$(printf '"$%s" "$%s" "$%s" 17' G P M)
  pair 'prefix options' "$prefix $opaque" "$prefix cp \"\$A\" \"\$B\""
done
padding=$(printf '%0130d' 0)
split_host="${G%?}''${G#?}"
pair 'word cap' "./$padding/$split_host $P $M 17" "python3 '$padding'"
opaque_number=$(printf '"$%s" "$%s" "$%s" 17' G P M)
pair 'redirect substitution' "echo >\$( $opaque_number )" 'echo >"$DEST"'
pair 'herestring substitution' "cat <<<\$( $opaque_number )" 'cat <<<"$SRCV"'
pair 'quoted parenthesis' "echo \$(printf \')\'; $phrase)" 'echo $(printf '\'')'\''; echo case "$U" "$V" "$W")'
comment_allow=$(printf "echo \$( # a comment with an apostrophe: '\n echo clear\n)")
pair 'comment boundary' "echo \$( $phrase )" "$comment_allow"
tick_allow=$(printf 'echo `# a comment containing an unmatched quote: "\necho clear\n`')
pair 'backtick comment boundary' "echo \`$phrase\`" "$tick_allow"
pair 'process target boundary' "> >(cat) $phrase" 'echo > >(cat)'
pair 'reserved word boundary' "echo \$( $phrase )" 'echo $(case2 || echo clear)'
pair 'case parenthesis' "echo \$(case x in (x) $phrase;; esac)" 'echo $(case x in (x) echo "$U" "$V" "$W";; esac)'
for prefix in '' 'nohup '; do
  for expansion in '$Q' '"$Q"'; do
    for number in '' ' 17'; do
      pair 'phrase gap' "$prefix$G $expansion $P $M$number" "$prefix$G $expansion $P status$number"
    done
  done
done
printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
