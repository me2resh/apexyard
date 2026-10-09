#!/bin/bash
# One byte-for-byte table for the shared helper and its transformations.
set -euo pipefail

# Isolate from live session pins and caches.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$HOOK_DIR/_lib-awk-fallback.sh"
. "$HOOK_DIR/_lib-detect-bash-write.sh"
. "$HOOK_DIR/_lib-extract-pr.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
check() {
  if cmp -s "$TMP/want" "$TMP/got"; then
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n' "$1" >&2
    FAIL=$((FAIL + 1))
  fi
}
old_split() {
  local cmd="$1" split
  [ -z "$cmd" ] && return 0
  split="$cmd"
  split="${split//>>|/@@APEXYARD_CLOBBER_APPEND@@}"
  split="${split//>|/@@APEXYARD_CLOBBER@@}"
  split="${split//&&/$'\n'}"
  split="${split//||/$'\n'}"
  split="${split//;/$'\n'}"
  split="${split//|/$'\n'}"
  split="${split//@@APEXYARD_CLOBBER_APPEND@@/>>|}"
  split="${split//@@APEXYARD_CLOBBER@@/>|}"
  printf '%s\n' "$split"
}

old_regions() {
  local s="$1"
  s="${s// && /$'\n'}"
  s="${s// || /$'\n'}"
  s="${s// | /$'\n'}"
  printf '%s\n' "$s" | grep -oE '\bsed\b.*'
}

old_join() {
  local COMMAND="$1" nl
  nl=$'\n'; COMMAND="${COMMAND//\\$nl/ }"
  printf '%s' "$COMMAND"
}

samples=(
  ''
  'read data'
  'read data;'
  'read data&&echo x||cat y|cat z'
  'echo >|a >>|b >||c'
  '@@APEXYARD_CLOBBER@@ @@APEXYARD_CLOBBER_APPEND@@'
  'echo "a && b; c | d"'
  $'sed -n \047p;w out\047 f && sed -n \047q\047 f'
  $'sed -n p f || sed -n w\\ out f | cat'
  $'one\\\ntwo'
  $'one\\\\\ntwo'
  $'one\ntwo\n'
  $'one\n\ntwo'
  $'one\\'
  $'one\r\ntwo\r'
  $'"quoted" '\''single'\'' café 雪'
  $'bad\377byte && sed -n p f'
)


functions=(_bdw_split_top_level _bdw_sed_regions join_shell_continuations)
oracles=(old_split old_regions old_join)
for index in "${!functions[@]}"; do
  for i in "${!samples[@]}"; do
    "${oracles[index]}" "${samples[i]}" > "$TMP/want" || :
    "${functions[index]}" "${samples[i]}" broad-space > "$TMP/got" || :
    check "${functions[index]}/$i"
  done
done
assert_equal() {
  _normalize_json_escapes_legacy "$2" > "$TMP/want"
  _normalize_json_escapes "$2" > "$TMP/got"
  check "decode/$1"
}
assert_equal empty ''
assert_equal plain 'plain ASCII and café'
assert_equal space '\u0020'
assert_equal tab_unicode '\u0009'
assert_equal newline_upper '\u000A'
assert_equal newline_lower '\u000a'
assert_equal slash '\/'
assert_equal tab_short '\t'
assert_equal newline_short '\n'
assert_equal doubled_newline '\\n'
assert_equal doubled_tab '\\t'
assert_equal adjacent '\u0020\u0009\u000A\u000a\/\t\n'
assert_equal mixed 'before\\n\n\u000A/u000a\/after'
assert_equal unsupported '\u0021\u000B\r\b\"'
assert_equal trailing_backslash 'ends\'
assert_equal literal_newlines $'a\nb\n'
assert_equal sentinel_byte $'a\034b\034\n'
assert_equal raw_record_separator $'g\036h pr merge'
assert_equal record_separator_with_escapes $'a\036\\\\\\n\036\\t\036\036\n'
assert_equal backslash_before_record_separator $'x\\\036n\\'
assert_equal escaped_and_literal_newlines $'a\\n\n\\u0009\n'
assert_equal invalid_utf8 $'before\377\\t\\/after'
# Preserve the large decoder case and the legacy sentinel regression.
large_input=$(awk 'BEGIN { for (line = 0; line < 5000; line++) print "x" }')
large_input+='\t'
assert_equal five_thousand_lines "$large_input"
printf 'g\036h' > "$TMP/want"
_normalize_json_escapes_legacy $'g\036h' > "$TMP/got"
check legacy-raw-record-separator

# The helper must discard partial output, verify its marker, and preserve
# raw marker bytes and trailing newlines on both paths.
identity_fallback() { printf '%s' "$1"; }
identity_program='
  NR > 1 { printf "%s\n", previous }
  { previous = $0 }
  END { printf "%s", substr(previous, 1, length(previous) - 1) }
'
mkdir "$TMP/bin"
cat > "$TMP/bin/awk" <<'EOF'
#!/bin/sh
case "$AWK_MODE" in
  partial) printf partial; exit 1 ;;
  missing) exit 127 ;;
  no-marker) printf partial; exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/awk"
inputs=('' 'plain' $'a\n\n' $'a\034b\034\n' $'\034' $'bad\377byte\n')
for mode in success partial missing no-marker; do
  for i in "${!inputs[@]}"; do
    printf '%s' "${inputs[i]}" > "$TMP/want"
    if [ "$mode" = success ]; then
      _run_awk_or_fallback "${inputs[i]}" identity_fallback "$identity_program" > "$TMP/got"
    else
      PATH="$TMP/bin:$PATH" AWK_MODE="$mode" \
        _run_awk_or_fallback "${inputs[i]}" identity_fallback "$identity_program" > "$TMP/got"
    fi
    check "helper/$mode/$i"
  done
done
# Literal expected outputs test Bash removal separately from broad gate scans.
join_inputs=($'gh pr\\\nmerge' $"echo 'a"$'\\\n'$"b'" $'echo # x\\\ngh pr merge' $'echo "a\\\nb"' $'echo a\\\\\nb')
join_wants=('gh prmerge' $"echo 'a"$'\\\n'$"b'" $'echo # x\\\ngh pr merge' 'echo "ab"' $'echo a\\\\\nb')
for i in "${!join_inputs[@]}"; do
  printf '%s' "${join_wants[i]}" > "$TMP/want"
  join_shell_continuations "${join_inputs[i]}" > "$TMP/got"
  check "bash-join/$i"
done
# A raw record separator must classify split-line merges as opaque.
opaque_input=$'perl -e \'system qw(gh\npr merge 5)\'; # \034'
printf opaque > "$TMP/want"
if _has_opaque_merge_wrapper "$opaque_input"; then printf opaque; else printf clear; fi > "$TMP/got"
check opaque-raw-sentinel
PATH="$TMP/bin:$PATH" AWK_MODE=missing _has_opaque_merge_wrapper "$opaque_input" && printf opaque > "$TMP/got" || printf clear > "$TMP/got"
check opaque-fallback-raw-sentinel

# Awk failure must retain token joins and the older broad-space scan.
printf 'gh pr merge 5\ngh p  r merge 5' > "$TMP/want"
PATH="$TMP/bin:$PATH" AWK_MODE=missing join_shell_continuations $'gh p\\\nr merge 5' > "$TMP/got"
check fallback-retains-token-join
PATH="$TMP/bin:$PATH" AWK_MODE=missing _has_opaque_merge_wrapper $'perl -e \'system qw(gh\npr merge 5)\'' && printf opaque > "$TMP/got" || printf clear > "$TMP/got"
printf opaque > "$TMP/want"
check opaque-fallback-split-line

printf 'shared awk table: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
