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

assert_raw_passthrough() {
  local label="$1" cmd="$2" got
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

assert_raw_passthrough "heredoc operator present"  'cat <<EOF'
assert_raw_passthrough "backtick present"          'echo `date`'
assert_raw_passthrough "unbalanced single quote"   "echo 'unbalanced"
assert_raw_passthrough "unbalanced double quote"   'echo "unbalanced'

# --- 3b. Adversarial: a real write must never be hidden -------------------
#
# The safety property this helper must hold. Masking may only ever REMOVE a
# metacharacter that bash itself treats as literal. If a crafted command made
# the scanner treat a REAL redirect as quoted, an additive consumer would stop
# reporting a genuine target. Each case below writes to `TARGET`.

assert_masked_target "adversarial: escaped quote outside quotes" \
  'echo \'"'"' > TARGET' "TARGET"
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
# heredoc stripper. The `<<` guard is what keeps that shape safe here.
assert_masked_target "adversarial: apostrophes in a heredoc body, write after" \
  "$(printf 'cat <<E\nit%ss\nE\necho x > TARGET' "'")" "TARGET"

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
# additive-only. If someone wires masking into bash_command_appears_to_write,
# these cases fail — that is the signal to re-read AgDR-0113 first, because a
# parser bug there fails OPEN across all three consuming hooks at once.

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
