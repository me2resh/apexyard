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
# An expansion host word with an expansion in the subcommand slot. A later
# literal subcommand or verb word confirms the phrase.
gap2=$(printf '"$%s" "$X"' G)
pair 'opaque host gap' "$gap2 $P $M 17" "$gap2 $P status 17"
pair 'prefixed opaque host gap' "ionice $gap2 $P $M 17" "ionice $gap2 $P status 17"
pair 'opaque host shifted verb' "$gap2 \"\$P\" $M 17" "$gap2 \"\$P\" status 17"
# Here-document bodies inside a substitution are data for the boundary
# walk. Each allow case is an ordinary command. Its block twin adds a merge
# after the substitution or inside it, after the delimiter line.
hd() { printf '%s "$(cat <<%s\n%s\n%s\n)"' "$1" "$2" "$3" "${4:-EOF}"; }
hdin() { printf 'x=$(cat <<%s\n%s\nEOF\n%s\n)' "$1" "$2" "$3"; }
big=$(printf 'line %04d of a long body text here.\n' $(seq 1 120))
title='fix(#12): add the retry flag'
coauthor=$(printf '%s\n\nCo-Authored-By: Name <name@example.invalid>' "$title")
for spec in \
  "commit apostrophe|git commit -m|'EOF'|Fix the user's login bug" \
  "commit ticket title|git commit -m|'EOF'|$title" \
  "commit ticket title and trailer|git commit -m|'EOF'|$coauthor" \
  "commit ticket title and apostrophe|git commit -m|'EOF'|fix(#12): handle the reviewer's note" \
  "unquoted delimiter apostrophe|git commit -m|EOF|It's done" \
  "unpaired double quote|git commit -m|'EOF'|feat: add a 12\" ruler" \
  "pull request ticket reference|$G $P create --title t --body|'EOF'|See (#12) for context" \
  "issue comment ticket reference|$G issue comment 3 --body|'EOF'|Fixed in (#12)." \
  "pull request large body|$G $P create --title t --body|'EOF'|$big" \
  "issue large body|$G issue create --title t --body|'EOF'|$big" \
  "commit large body|git commit -m|'EOF'|$big" \
  "double-quoted delimiter|git commit -m|\"EOF\"|It's a (#12) fix" \
  "unpaired substitution prose|git commit -m|'EOF'|docs: explain the \$( walk; it's data" \
  "case word prose|git commit -m|'EOF'|case one) it's open" \
  ; do
  label=${spec%%|*}; rest=${spec#*|}
  cmd=${rest%%|*}; rest=${rest#*|}
  delim=${rest%%|*}; body=${rest#*|}
  allow=$(hd "$cmd" "$delim" "$body")
  pair "heredoc $label" "$allow; $phrase" "$allow"
done
for n in 3900 4000 4090 4100 4200; do
  body=$(printf "%0${n}d" 0)
  allow=$(hd 'git commit -m' "'EOF'" "$body")
  pair "heredoc body size $n" "$allow; $phrase" "$allow"
done
tabbed=$(printf 'git commit -m "$(cat <<-EOF\n\tIt%ss done\n\tEOF\n)"' "'")
pair 'heredoc tab-stripped delimiter' "$tabbed; $phrase" "$tabbed"
twohd=$(printf 'x=$(cat <<A <<B # it%ss two\nfix(#1): a\nA\nb%ss\nB\n)' "'" "'")
pair 'heredoc two bodies' "$twohd; $phrase" "$twohd"
pair 'heredoc closing parenthesis' "$(hdin "'EOF'" "don't ) stop" "$phrase")" "$(hdin "'EOF'" "don't ) stop" 'echo clear')"
pair 'heredoc merge after delimiter' "$(hdin "'EOF'" "$title" "$phrase")" "$(hdin "'EOF'" "$title" 'echo clear')"
# A substitution body that does not close in command text fails closed.
pair 'heredoc missing delimiter' "$(hd 'git commit -m' "'EOF'" "It's (#12)" 'END')" "$(hd 'git commit -m' "'EOF'" "It's (#12)")"
pair 'unclosed substitution' "echo \$( echo clear" 'echo $( echo clear )'
pair 'unclosed backtick' 'echo `echo clear' 'echo `echo clear`'
# Long prose bodies stay data. The command limit bounds each walk.
line='This sentence is ordinary prose for a pull request body. It has no shell syntax.'
for size in 8192 20480; do
  prose=''
  while [ "${#prose}" -lt "$size" ]; do prose="$prose$line
"; done
  allow=$(hd "$G $P create --title t --body" "'EOF'" "$prose")
  pair "heredoc prose body $size" "$allow; $phrase" "$allow"
  allow=$(hd 'git commit -m' "'EOF'" "$prose")
  pair "heredoc commit body $size" "$allow; $phrase" "$allow"
done
# A here-document body outside a substitution is its own nested body.
# Its quotes do not hide the next command. A shell reader still sees it.
top=$(printf "cat <<'EOF'\ndon't (#12)\nEOF")
pair 'heredoc quote isolation' "$top
$phrase" "$top
echo clear"
pair 'heredoc to end of input' "$(printf 'sh <<EOF\n%s' "$phrase")" "$(printf "cat <<'EOF'\nit's \$( data")"
pair 'here-string in substitution' "echo \$(cat <<<\"it's\"); $phrase" "echo \$(cat <<<\"it's\")"
pair 'arithmetic shift' "echo \$((1<<2)); $phrase" 'echo $((1<<2))'
tick_quote=$(printf 'echo `echo it%ss`' "'")
pair 'backtick apostrophe' "$tick_quote; $phrase" "$tick_quote"
pair 'backtick escaped tick' "echo \`echo \\\` x\`; $phrase" "echo \`echo \\\` x\`"
# An ANSI-C quote can hold an escaped single quote. The scan reads it as
# the shell does, in command text and in the substitution walk.
ansi=$': $(echo $\'\\\'\')'
pair 'ANSI-C quote' "echo \$'\\''; $phrase" "echo \$'\\''; echo clear"
ansi_hd() { printf "bash <<'EOF'\n%s\nx=\$(printf \")\"; %s)\nEOF" "$ansi" "$1"; }
pair 'heredoc ANSI-C quote' "$(ansi_hd "$phrase")" "$(ansi_hd 'echo "$U" "$V" "$W"')"
# When a shell word is present, a shell can read a here-document body.
# A substitution that does not close in that body fails closed.
pair 'shell heredoc unclosed substitution' "$(printf "bash <<'EOF'\necho \$( data\nEOF")" "$(printf "cat <<'EOF'\necho \$( data\nEOF")"
printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
