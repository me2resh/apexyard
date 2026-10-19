#!/bin/bash
# Merge words in read-only data must not start a merge gate. Ambiguous and
# executable forms stay visible to the raw merge detector.
set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


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

# Each executable class has a paired data-only command.
mkdir -p "$TMP/must-detect"
case_count=0
must_detect() {
  case_count=$((case_count + 1))
  printf '%s' "$1" > "$TMP/must-detect/$case_count.label"
  printf '%s' "$2" > "$TMP/must-detect/$case_count.cmd"
  check "$1" yes "$2"
}
g='gh'; p='pr'; m='merge'; phrase="$g $p $m 7"
# Rework coverage: unknown words, command sources, paths, and host options.
# Each executable shape has the same text in a quoted data heredoc.
allow_count=0
mkdir -p "$TMP/rework-allow"
rework_allow() {
  allow_count=$((allow_count + 1))
  printf '%s' "$2" > "$TMP/rework-allow/$allow_count.cmd"
  printf '%s' "$1" > "$TMP/rework-allow/$allow_count.label"
  check "$1" no "$2"
}
rework_case() {
  must_detect "rework $1" "$2"
  rework_allow "rework $1 data" "$(printf "cat <<'DATA'\n%s\nDATA" "$2")"
}
G=$g; P=$p; M=$m; BS='\\'
rework_case "class 01" "\${X:-$G} $P $M 7"
rework_case "class 02" "\"\${X:-$G}\" $P $M 7"
rework_case "class 03" "\$(echo $G) $P $M 7"
rework_case "class 04" "\`echo $G\` $P $M 7"
rework_case "class 05" "\$'$G' $P $M 7"
rework_case "class 06" "set -- $G; \$1 $P $M 7"
rework_case "class 07" "$G $P \${X:-$M} 7"
rework_case "class 08" "$G $P \$(echo $M) 7"
rework_case "class 09" "$G $P \$'$M' 7"
rework_case "class 10" "$G $P mer${BS}ge 7"
rework_case "class 11" "g${BS}h $P $M 7"
rework_case "class 12" "$G $P {$M,} 7"
rework_case "class 13" "f(){ $G $P \"\$1\" 7; }; f $M"
rework_case "class 14" "\"/opt/homebrew/bin/$G\" $P $M 7"
rework_case "class 15" "/opt/homebrew/bin/\"$G\" $P $M 7"
rework_case "class 16" "bash -c 'g\"\"h $P $M 7'"
rework_case "class 17" "bash <<< 'g\"\"h $P $M 7'"
rework_case "class 18" "echo 'g\"\"h $P $M 7' | sh"
rework_case "class 19" "eval 'g\"\"h $P $M 7'"
rework_case "class 20" "$G $P --repo=o/r $M 7"
rework_case "class 21" "$G $P -R o/r $M 7"
rework_case "class 22" "$G --repo=o/r $P $M 7"
rework_case "class 23" "$G api -X PUT repos/o/r/pulls/7/\"$M\""
rework_case "class 24" "glab mr \${X:-$M} 7"
for op in '&>' '&>>' '>&'; do
  rework_case "redirect $op" "$g $op /dev/null $p $m 7"
done
for option in '--repo=x' '-R x' '--repo x'; do
  rework_case "option before $option" "$g $option $p $m 7"
  rework_case "option between $option" "$g $p $option $m 7"
done
rework_case 'array word' '${G[0]} pr merge 7'
rework_case 'glob word' "g? $p $m 7"
rework_case 'empty word' "$g \"\" $p $m 7"
rework_case 'source body' "source 'g\"\"h $p $m 7'"
for cmd in \
  'cp "$SRC" "$DST" "$EXTRA"' \
  'for f in "$A" "$B" "$C"; do echo "$f"; done' \
  'git add -- "$F1" "$F2" "$F3"' \
  "printf '%s %s %s\\n' \"\$x\" \"\$y\" \"\$z\"" \
  'rsync -a $SRC $MID $DST' \
  'test -f "$A" && echo "$B" "$C" "$D"'; do
  rework_allow 'variable arguments' "$cmd"
  check 'variable command position still blocks' yes "\"\$G\" $p $m 7"
done
rework_allow 'empty quote does not alter next command' '""; ls -la'
rework_allow 'listing with working awk' 'ls -la'
rework_case 'literal data becomes executable' "echo hello > out.txt $g $p $m 7 | sh"
rework_allow 'literal echo arguments after redirect' "echo hello > out.txt $g $p $m"
long_name=$(head -c 90 /dev/zero | tr '\0' X)
rework_case 'long parameter name' "\$$long_name $p $m 7"
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
  n=1
  while [ "$n" -le "$allow_count" ]; do
    cmd=$(cat "$TMP/rework-allow/$n.cmd")
    label=$(cat "$TMP/rework-allow/$n.label")
    payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
    (cd "$SB" && printf '%s' "$payload" | PATH="$SB/bin:$PATH" APEXYARD_OPS_DISABLE_PIN=1 /bin/bash ".claude/hooks/$gate" >/dev/null 2>"$TMP/stderr")
    rc=$?
    if [ "$rc" -eq 0 ] && [ ! -s "$TMP/stderr" ]; then
      printf 'PASS [%s / %s]\n' "$gate" "$label"; PASS=$((PASS + 1))
    else
      printf 'FAIL [%s / %s]: rc=%s\n' "$gate" "$label" "$rc" >&2; FAIL=$((FAIL + 1))
    fi
    n=$((n + 1))
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
  # Scanner failures have their own diagnostic, including for non-merge text.
  mkdir -p "$TMP/broken-awk"
  printf '#!/bin/bash\nexit 1\n' > "$TMP/broken-awk/awk"
  chmod +x "$TMP/broken-awk/awk"
  for scan_shape in broken large; do
    cmd='ls -la'; scan_path="$SB/bin:$PATH"
    if [ "$scan_shape" = broken ]; then
      scan_path="$TMP/broken-awk:$scan_path"
    else
      cmd="$cmd # $(head -c 121000 /dev/zero | tr '\0' a)"
    fi
    payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
    (cd "$SB" && printf '%s' "$payload" | PATH="$scan_path" APEXYARD_OPS_DISABLE_PIN=1 /bin/bash ".claude/hooks/$gate" >/dev/null 2>"$TMP/stderr")
    rc=$?
    if [ "$rc" -eq 2 ] && grep -q 'could not scan the command' "$TMP/stderr" && ! grep -q 'unexpanded' "$TMP/stderr"; then
      printf 'PASS [%s / %s scan error]\n' "$gate" "$scan_shape"; PASS=$((PASS + 1))
    else
      printf 'FAIL [%s / %s scan error]: rc=%s\n' "$gate" "$scan_shape" "$rc" >&2; FAIL=$((FAIL + 1))
    fi
  done
  padding=120000
  cmd="$phrase # $(head -c "$padding" /dev/zero | tr '\0' '$')"
  payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  start_s=$(date +%s)
  (cd "$SB" && printf '%s' "$payload" | PATH="$SB/bin:$PATH" APEXYARD_OPS_DISABLE_PIN=1 /bin/bash ".claude/hooks/$gate" >/dev/null 2>"$TMP/stderr")
  rc=$?; elapsed=$(( $(date +%s) - start_s ))
  if [ "$rc" -eq 2 ] && [ "$elapsed" -lt 5 ]; then
    printf 'PASS [%s / %s dollar padding: %ss]\n' "$gate" "$padding" "$elapsed"; PASS=$((PASS + 1))
  else
    printf 'FAIL [%s / %s dollar padding: rc=%s %ss]\n' "$gate" "$padding" "$rc" "$elapsed" >&2; FAIL=$((FAIL + 1))
  fi

done

# Measure the scanner separately from metadata lookups in the gates.
padding=$(head -c 119000 /dev/zero | tr '\0' '$')
start_s=$(date +%s)
_has_split_merge_phrase "$padding"; rc=$?
elapsed=$(( $(date +%s) - start_s ))
if [ "$rc" -eq 1 ] && [ "$elapsed" -lt 5 ]; then
  printf 'PASS [bounded dollar scan: %ss]\n' "$elapsed"; PASS=$((PASS + 1))
else
  printf 'FAIL [bounded dollar scan: rc=%s %ss]\n' "$rc" "$elapsed" >&2; FAIL=$((FAIL + 1))
fi
check 'large split phrase remains visible' yes "\"\$G\" $p $m 7 # $padding"
printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
