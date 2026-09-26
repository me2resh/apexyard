#!/bin/bash
# Tests for _lib-mask-quoted.sh (me2resh/apexyard#1356).
#
# Covers:
#   - masking neutralises a metacharacter that sits inside quotes, so an
#     ADDITIVE consumer stops reporting a fabricated write target
#   - a genuine write still yields its real target, including a quoted target
#     and a target whose name contains a masked character
#   - every uncertainty guard hands back the raw command unchanged
#   - unmask round-trips the substitution
#   - GOVERNANCE PIN: the gate's presence question is still answered from raw
#     text, per AgDR-0113
#
# Exit 0 if all cases pass; 1 on failure.

set -u

LIB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB_MASK="$LIB_DIR/_lib-mask-quoted.sh"
LIB_WRITE="$LIB_DIR/_lib-detect-bash-write.sh"

for f in "$LIB_MASK" "$LIB_WRITE"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required lib missing: $f" >&2
    exit 1
  fi
done

# shellcheck source=/dev/null
. "$LIB_MASK"
# shellcheck source=/dev/null
. "$LIB_WRITE"

PASS=0
FAIL=0
FAILED_CASES=""

ok()  { echo "PASS [$1]"; PASS=$((PASS+1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}$1 "; }

# Targets extracted from the MASKED command, unmasked back to real text.
masked_targets() {
  local cmd masked t
  cmd="$1"
  masked=$(mask_quoted_metachars "$cmd")
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    unmask_quoted_metachars "$t"
    echo
  done <<EOF
$(bash_extract_write_targets "$masked")
EOF
}

assert_no_masked_target() {
  local label="$1" cmd="$2" got
  got=$(masked_targets "$cmd" | tr -d '\n')
  if [ -z "$got" ]; then ok "$label"; else bad "$label" "expected no target, got '$got'"; fi
}

assert_masked_target() {
  local label="$1" cmd="$2" want="$3" got
  got=$(masked_targets "$cmd" | grep -c -x -F -- "$want")
  if [ "$got" -ge 1 ]; then ok "$label"; else
    bad "$label" "expected target '$want', got '$(masked_targets "$cmd" | tr '\n' ' ')'"
  fi
}

# The safety property for a command that really writes. Every target the
# detector finds in the RAW command must still appear after masking. Exact
# spelling does not matter here. The raw extractor has its own tokenising
# limits, and masking must not change them.
assert_no_target_hidden() {
  local label="$1" cmd="$2" raw_t missing=""
  while IFS= read -r raw_t; do
    [ -z "$raw_t" ] && continue
    masked_targets "$cmd" | grep -q -x -F -- "$raw_t" || missing="$missing '$raw_t'"
  done <<EOF
$(bash_extract_write_targets "$cmd")
EOF
  if [ -z "$(bash_extract_write_targets "$cmd")" ]; then
    bad "$label" "the raw command yields no target, so this case proves nothing"
  elif [ -z "$missing" ]; then
    ok "$label"
  else
    bad "$label" "masking hid:$missing"
  fi
}

# Each passthrough case must hold a quoted metacharacter. Without one, the
# masked text equals the raw text whether or not a guard trips, so the case
# could never fail.
assert_raw_passthrough() {
  local label="$1" cmd="$2" got
  case "$cmd" in
    *'>'*|*'<'*|*'|'*|*'&'*|*';'*) ;;
    *) bad "$label" "case holds no metacharacter, so it proves nothing"; return ;;
  esac
  got=$(mask_quoted_metachars "$cmd")
  if [ "$got" = "$cmd" ]; then ok "$label"; else bad "$label" "command was modified"; fi
}

# --- 1. Quoted metacharacters stop producing a fabricated target ---------
# Each command below is read-only. Before #1356 each one yielded the target
# shown in the comment.

assert_no_masked_target "awk program, NR comparison (was '1)')" \
  "awk '/^## D/ { c=1 } { if (c && NR > 1) exit }' dfd.md"
assert_no_masked_target "grep alternation holding the char (was 'quote')" \
  "grep -nE 'redirect|>|quote' file.sh"
assert_no_masked_target "echo of arrows in prose (was 'ZERO')" \
  "echo '  >> ZERO MATCHES'"
assert_no_masked_target "git log pretty format (was '%s')" \
  "git log --format='%h > %s'"
assert_no_masked_target "jq program comparison (was '1)')" \
  "jq '.[] | select(.n > 1)' data.json"
assert_no_masked_target "double-quoted argument holding the char" \
  "echo \"a > b\""

# --- 2. Genuine writes keep their real target ----------------------------

assert_masked_target "plain redirect"            "echo hello > notes.txt"       "notes.txt"
assert_masked_target "append redirect"           "echo hello >> notes.txt"      "notes.txt"
assert_masked_target "double-quoted target"      'echo hello > "src/app.ts"'    "src/app.ts"
assert_masked_target "single-quoted target"      "echo hello > 'src/app.ts'"    "src/app.ts"
assert_masked_target "tee target"                "echo hello | tee notes.txt"   "notes.txt"
assert_masked_target "second target in a chain"  "echo a > /tmp/x; echo b > src/app.ts" "src/app.ts"
# Offsets are preserved, so a masked character inside a real target round-trips.
assert_masked_target "target name holding the char" 'echo hello > "a>b.txt"'    "a>b.txt"
# A quote inside the OTHER quote style is literal, matching bash.
assert_masked_target "apostrophe inside a double-quoted argument" \
  'echo "it'"'"'s fine" > notes.txt' "notes.txt"

# --- 3. Uncertainty guards hand back the raw command ---------------------

# Each command also holds a quoted `>`. Without the guard, masking would
# replace it, and the case would fail.
assert_raw_passthrough "heredoc operator present"  "cat <<EOF 'a > b'"
assert_raw_passthrough "backtick present"          "echo \`date\` 'a > b'"
assert_raw_passthrough "unbalanced single quote"   "echo 'a > b"
assert_raw_passthrough "unbalanced double quote"   'echo "a > b'

# --- 3b. Adversarial: a real write must never be hidden -------------------
#
# The safety property this helper must hold. Masking may only ever REMOVE a
# metacharacter that bash itself treats as literal. If a crafted command made
# the scanner treat a REAL redirect as quoted, an additive consumer would stop
# reporting a genuine target. Each case below writes to `TARGET`.

# Built with printf rather than written inline. The inline spelling needed a
# single-quoted string ending in a backslash, which is the SC1003 shape.
esc_quote_cmd=$(printf 'echo \\%s > TARGET' "'")
assert_masked_target "adversarial: escaped quote outside quotes" \
  "$esc_quote_cmd" "TARGET"
assert_masked_target "adversarial: escaped double quote inside double quotes" \
  'echo "a\"b" > TARGET' "TARGET"
assert_masked_target "adversarial: quoted span on an earlier line" \
  "$(printf 'echo %sa > b%s\necho x > TARGET' "'" "'")" "TARGET"
assert_masked_target "adversarial: empty quoted span before the write" \
  "echo '' > TARGET" "TARGET"
assert_masked_target "adversarial: adjacent quoted spans before the write" \
  "echo 'a''b' > TARGET" "TARGET"
assert_masked_target "adversarial: quoted span after the write" \
  "echo x > TARGET 'a > b'" "TARGET"
assert_masked_target "adversarial: quoted spans on both sides of the write" \
  "echo 'a>b' > TARGET && echo 'c>d'" "TARGET"
# AgDR-0113 records that odd quote counts inside a heredoc body broke the
# heredoc stripper. Here one apostrophe sits in a heredoc body on each side of
# a real write, so the scan ends balanced. Only the `<<` guard catches it.
assert_masked_target "adversarial: apostrophes in two heredoc bodies straddle a write" \
  "$(printf 'cat <<E\nit%ss\nE\necho x > TARGET\ncat <<F\nit%ss\nF' "'" "'")" "TARGET"

# --- 3c. The comment divergence (#1356 review findings) -------------------
#
# Bash does not process quote characters inside a comment. This scanner would.
# An odd number of quotes inside a comment, rebalanced after a REAL redirect,
# leaves the scan balanced, so the end-of-scan check cannot see the problem.
# Guard 4 catches it by refusing to mask any command with a `#` at a comment
# position. A comment starts where a word starts: at the start of the
# command, after whitespace, or after an operator character. The first review
# found the whitespace shape. A second review found the operator shapes. That
# is why the header calls the guard list a living list.

q="'"
comment_straddle="echo hi # don${q}t
echo x > TARGET # it${q}s fine"
assert_masked_target "adversarial: quotes straddling a redirect inside comments" \
  "$comment_straddle" "TARGET"
assert_raw_passthrough "guard: a comment at line start" \
  "# a note
echo 'a > b'"
assert_raw_passthrough "guard: a comment after whitespace" \
  "echo 'a > b' # a note"

# The same straddle, with each comment directly after an operator character.
# Each command is valid bash, and bash writes TARGET. The four-guard helper
# at 004e0b9 hid the target in every one of them.
assert_no_target_hidden "adversarial: comment after ';'" \
  "echo hi;# don${q}t
echo x > TARGET;# it${q}s fine"
assert_no_target_hidden "adversarial: comment after '&'" \
  "echo hi &# don${q}t
echo x > TARGET &# it${q}s fine"
assert_no_target_hidden "adversarial: comment after '|'" \
  "echo hi |# don${q}t
cat > TARGET;# it${q}s fine"
assert_no_target_hidden "adversarial: comment after ')'" \
  "(echo hi)# don${q}t
(echo x > TARGET)# it${q}s fine"
assert_no_target_hidden "adversarial: comment after '('" \
  "(# don${q}t
echo x > TARGET)# it${q}s fine"
for op in ';' '&' '|' '(' ')' '<' '>'; do
  assert_raw_passthrough "guard: a comment directly after '$op'" "echo 'a > b' ${op}# a note"
done

# The guard must not over-fire. A `#` that is NOT at a comment position is an
# ordinary character, and the motivating case from #1356 depends on it.
assert_no_masked_target "guard does not over-fire on '## D' inside a quoted awk program" \
  "awk '/^## D/ { c=1 } { if (c && NR > 1) exit }' dfd.md"

# --- 3c2. Command substitution inside double quotes (#1356 review) --------
#
# Bash parses the body of `$( )` in a fresh quoting context, even inside
# double quotes. So the `>` below is a real redirect. The four-guard helper
# kept it masked as quoted text. Guard 5 returns the raw command instead.

assert_no_target_hidden "adversarial: redirect inside \"\$( )\"" \
  'x="$(echo hi > TARGET)"'
assert_raw_passthrough "guard: \$( inside double quotes" \
  'x="$(echo hi > TARGET)"'
assert_raw_passthrough "guard: \$(( inside double quotes" \
  'echo "$(( 2 > 1 ))"'
# An escaped dollar opens no substitution, so masking still applies.
assert_no_masked_target "guard does not over-fire on an escaped dollar" \
  'echo "\$(x) > y"'

# --- 3c3. Security review and third code review shapes (#1356) ------------
#
# A security review and a third code review found more divergences. For each
# shape bash 5.3 writes TARGET, and the helper at 112b8b8 hid the redirect.
# Each guard below returns the raw command instead.

bs='\\'
nl=$'\n'
p25=$'\025'

# `$'...'` processes backslash escapes, so `\'` does not close the span.
assert_no_target_hidden "adversarial: \$'...' with an escaped quote" \
  "echo \$'${bs}'' > TARGET ${bs}'"
assert_no_target_hidden "adversarial: \$'...' in a natural form" \
  "echo \$'it${bs}'s' > TARGET; echo 'C:${bs}'"
assert_no_target_hidden "adversarial: printf \$'...' then a stray escaped quote" \
  "printf \$'it${bs}'s${bs}n' > TARGET; echo ${bs}'"
assert_raw_passthrough "guard: \$' outside quotes" "echo \$'a > b'"
# A `$'` that only ends a single-quoted regex is not ANSI-C quoting.
assert_no_masked_target "guard does not over-fire on a regex anchor before a quote" \
  "grep -E 'x>\$' f"

# Bash 5.3 function substitution runs a command inside double quotes.
assert_no_target_hidden "adversarial: \${ cmd; } inside double quotes" \
  'x="${ echo hi > TARGET; }"'
assert_no_target_hidden "adversarial: \${| cmd; } inside double quotes" \
  'x="${| echo hi > TARGET; REPLY=1; }"'
assert_raw_passthrough "guard: \${ plus a space inside double quotes" \
  "x=\"\${ echo 'a > b'; }\""
# Bash honours single quotes in the word of a double-quoted `${x#word}`.
# The third code review found this shape. The guard now returns the raw
# command for any `${`, `$(`, or `$[` inside double quotes.
assert_no_target_hidden "adversarial: single quotes inside a double-quoted \${x#word}" \
  "echo \"\${x#'\"'}\" > TARGET ${bs}'"
assert_raw_passthrough "guard: \${VAR} inside double quotes, by design" \
  "echo \"\${HOME}\" 'a > b'"
assert_raw_passthrough "guard: \$[ inside double quotes" \
  'echo "$[ 1 > 0 ]"'
# A plain `$name` inside double quotes is still masked normally.
assert_no_masked_target "guard does not over-fire on a plain \$name inside double quotes" \
  "echo \"\$HOME\" 'a > b'"

# A backslash-newline pair joins lines before bash tokenises them.
assert_no_target_hidden "adversarial: line continuation splits \$(" \
  "x=\"\$${bs}${nl}(echo hi > TARGET)\""
assert_no_target_hidden "adversarial: line continuation splits <<" \
  "cat <${bs}${nl}<E${nl}'${nl}E${nl}echo x > TARGET${nl}cat <${bs}${nl}<F${nl}'${nl}F"
assert_raw_passthrough "guard: backslash-newline anywhere in the command" \
  "echo 'a > b' ${bs}${nl}  more"

# A placeholder byte already in the command cannot round-trip through
# unmask_quoted_metachars. The helper must hand such a command back as is.
assert_raw_passthrough "guard: placeholder byte inside a real target" \
  "echo ';' ; echo x > a${p25}b"

# --- 3d. Oversize command: empty or unchanged, never altered ---------------
#
# The command travels through the environment. Linux caps one environment
# string at MAX_ARG_STRLEN, 128 KiB, and execve then fails with E2BIG. The
# helper then returns nothing. A caller that reads "" as "differs from the
# raw command" draws the opposite conclusion. The hook test pins the caller
# guard for that case. This case pins the helper side. The command holds no
# quote, so the only correct non-empty answer is the command unchanged.

oversize="echo $(head -c 140000 /dev/zero | tr '\0' 'x') > src/app.ts"
oversize_masked=$(mask_quoted_metachars "$oversize" 2>/dev/null)
if [ -z "$oversize_masked" ] || [ "$oversize_masked" = "$oversize" ]; then
  ok "oversize command yields an empty mask or the command unchanged"
else
  bad "oversize command yields an empty mask or the command unchanged" \
      "got ${#oversize_masked} bytes that differ from the command"
fi

# --- 4. unmask round-trips ------------------------------------------------

masked=$(mask_quoted_metachars "echo 'a > b | c & d ; e < f'")
round=$(unmask_quoted_metachars "$masked")
if [ "$round" = "echo 'a > b | c & d ; e < f'" ]; then
  ok "unmask restores every masked metacharacter"
else
  bad "unmask restores every masked metacharacter" "got '$round'"
fi

# --- 5. GOVERNANCE PIN (AgDR-0113) ---------------------------------------
#
# The presence question must keep reading RAW command text. This helper is
# additive-only. These cases fail if someone makes
# bash_command_appears_to_write quote-aware. That failure is the signal to
# re-read AgDR-0113 first. A parser bug there fails OPEN across all three
# consuming hooks at once.

for c in "git log --format='%h > %s'" \
         "echo '  >> ZERO MATCHES'" \
         "jq '.[] | select(.n > 1)' data.json"; do
  if bash_command_appears_to_write "$c"; then
    ok "presence question still reads raw text: ${c:0:34}"
  else
    bad "presence question still reads raw text: ${c:0:34}" \
        "detector went quote-aware — see AgDR-0113 before changing this"
  fi
done

# --- Summary --------------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
