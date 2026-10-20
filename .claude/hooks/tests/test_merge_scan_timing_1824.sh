#!/bin/bash
# The merge scan work stays linear in the command length (#1824).
#
# Each input is about 119 KB. A scan that reads a queued here-document
# body again for each later here-document takes many times longer than a
# reference scan of plain text of the same size. Run this test with the
# default awk. The macOS system awk shows the difference most clearly.
#
# A slow host can make the reference scan slow. Then the time limits are
# reported in NOTE lines and do not fail the test. The result checks
# always apply.
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
phrase=$(printf '"$%s" %s %s 17' G "$P" "$M")
mkdir -p "$TMP/.claude/hooks" "$TMP/bin"
cp "$HOOKS"/_lib-*.sh "$HOOKS/block-unreviewed-merge.sh" "$TMP/.claude/hooks/"
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
(cd "$TMP" && git init -q --template=) || exit 1
TIMEFORMAT=%R

ok() { PASS=$((PASS+1)); printf 'PASS [%s]\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL [%s]: %s\n' "$1" "$2" >&2; }

# gen <kind>: write one input of about 119 KB to stdout.
gen() {
  awk -v kind="$1" 'BEGIN {
    line = "This sentence is ordinary prose and it has no shell syntax at all.\n"
    size = 119000
    if (kind == "plain") {
      while (length(out) < size) out = out "echo " line
    } else if (kind == "many") {
      # 150 ordinary here-documents, one after the other.
      per = int((size / 150 - 30) / length(line))
      body = ""; for (k = 0; k < per; k++) body = body line
      for (j = 0; j < 150; j++) out = out "cat > f" j ".txt <<" sprintf("%c", 39) "EOF" sprintf("%c", 39) "\n" body "EOF\n"
    } else if (kind == "nested") {
      # A chain of 99 nested here-documents. The padding is innermost.
      head = tail = ""
      for (j = 0; j < 99; j++) { head = head "cat <<E" j "\n"; tail = "E" j "\n" tail }
      while (length(head) + length(out) + length(tail) < size) out = out line
      out = head out tail
    } else if (kind == "body") {
      # One large here-document body in a substitution.
      while (length(out) < size) out = out line
      out = "git commit -m \"$(cat <<" sprintf("%c", 39) "EOF" sprintf("%c", 39) "\n" out "EOF\n)\""
    } else if (kind == "nodelim") {
      # Many here-document words and no delimiter lines.
      while (length(out) < size - 200) out = out " <<E"
      out = "cat" out "\n" line
    }
    printf "%s", out
  }'
}

# measure <function> <input>: set SECS and RC.
measure() {
  { time "$1" "$2" >/dev/null 2>&1; } 2> "$TMP/time"
  RC=$?
  SECS=$(tail -n 1 "$TMP/time")
}

# Gate run for one command. Print the exit code.
gate() {
  local payload
  payload=$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')
  (cd "$TMP" && printf '%s' "$payload" | PATH="$TMP/bin:$PATH" /bin/bash .claude/hooks/block-unreviewed-merge.sh > /dev/null 2>"$TMP/err")
  echo $?
}

# Command substitution drops the final newline of each input.
nl='
'
plain=$(gen plain); many=$(gen many); nested=$(gen nested); body=$(gen body); nodelim=$(gen nodelim)
measure _has_split_merge_phrase "$plain"; ref=$SECS
limit=$(awk -v r="$ref" 'BEGIN { printf "%.2f", 4 * r + 1 }')
slow=$(awk -v r="$ref" 'BEGIN { print (r > 5) ? 1 : 0 }')
printf 'reference scan of %s characters: %ss, limit %ss\n' "${#plain}" "$ref" "$limit"
if [ "$slow" = 1 ]; then
  printf 'NOTE: the reference scan is slow on this host. The time limits do not apply.\n'
fi

# timed <label> <function> <input> <want>: want is "clear", "merge", or "any".
timed() {
  local label=$1 want=$4
  measure "$2" "$3"
  if awk -v t="$SECS" -v l="$limit" 'BEGIN { exit !(t <= l) }'; then
    ok "$label time ${SECS}s"
  elif [ "$slow" = 1 ]; then
    printf 'NOTE: %s took %ss, over the limit %ss\n' "$label" "$SECS" "$limit"
  else
    bad "$label time" "${SECS}s is over the limit ${limit}s"
  fi
  case "$want" in
    clear) if [ "$RC" -eq 1 ]; then ok "$label result"; else bad "$label result" "rc=$RC, want 1"; fi ;;
    merge) if [ "$RC" -ne 1 ]; then ok "$label result"; else bad "$label result" "rc=1, want a merge or a scan failure"; fi ;;
  esac
}

timed 'many here-documents' _has_split_merge_phrase "$many" clear
timed 'many here-documents, dispatcher route' is_merge_command "$many" clear
timed 'many here-documents and a merge' _has_split_merge_phrase "$many$nl$phrase" merge
timed 'nested here-documents' _has_split_merge_phrase "$nested" any
timed 'nested here-documents, dispatcher route' is_merge_command "$nested" any
timed 'nested here-documents and a merge' is_merge_command "$nested$nl$phrase" merge
timed 'one large body' _has_split_merge_phrase "$body" clear
timed 'one large body, dispatcher route' is_merge_command "$body" clear
timed 'one large body and a merge' _has_split_merge_phrase "$body; $phrase" merge
timed 'here-document words without delimiter lines' _has_split_merge_phrase "$nodelim" clear

# Many ordinary here-documents stay allowed. A merge after them blocks.
rc=$(gate "$many")
if [ "$rc" -eq 0 ]; then ok 'many here-documents gate allow'; else bad 'many here-documents gate allow' "rc=$rc"; fi
rc=$(gate "$many$nl$phrase")
if [ "$rc" -eq 2 ]; then ok 'many here-documents gate block'; else bad 'many here-documents gate block' "rc=$rc"; fi

printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
