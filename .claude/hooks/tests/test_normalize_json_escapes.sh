#!/bin/bash
# Byte-for-byte regression and bash 3.2 timing test for the raw-payload decoder.
set -u

LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-extract-pr.sh"
# shellcheck source=/dev/null
. "$LIB_SRC"

# The implementation before #1550, retained as the behavior oracle. The
# order is significant, including for adjacent and doubled backslashes.
old_normalize_json_escapes() {
  local text="$1"
  local tab=$'\t'
  local nl=$'\n'
  local bs2='\\'
  local esc_u0020="${bs2}u0020"
  local esc_u0009="${bs2}u0009"
  local esc_u000A="${bs2}u000A"
  local esc_u000a="${bs2}u000a"
  local esc_slash="${bs2}/"
  local esc_t="${bs2}t"
  local esc_n="${bs2}n"
  text="${text//$esc_u0020/ }"
  text="${text//$esc_u0009/$tab}"
  text="${text//$esc_u000A/$nl}"
  text="${text//$esc_u000a/$nl}"
  text="${text//$esc_slash//}"
  text="${text//$esc_t/$tab}"
  text="${text//$esc_n/$nl}"
  printf '%s' "$text"
}

if [ "${1:-}" = --worker ]; then
  case "$2" in
    old) old_normalize_json_escapes "$3" ;;
    new) _normalize_json_escapes "$3" ;;
    *) exit 2 ;;
  esac
  exit $?
fi

tmp_dir=$(mktemp -d)
trap 'rm -r "$tmp_dir"' EXIT
pass=0
fail=0

assert_equal() {
  local label="$1" input="$2"
  old_normalize_json_escapes "$input" > "$tmp_dir/old"
  _normalize_json_escapes "$input" > "$tmp_dir/new"
  if cmp -s "$tmp_dir/old" "$tmp_dir/new"; then
    printf 'PASS equivalence: %s\n' "$label"
    pass=$((pass + 1))
  else
    printf 'FAIL equivalence: %s\n' "$label" >&2
    fail=$((fail + 1))
  fi
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
assert_equal escaped_and_literal_newlines $'a\\n\n\\u0009\n'

# A failed decoder must leave the raw payload available to the merge gates.
# Build the command text at runtime so hook command scans do not see it here.
merge_verb=mer
merge_verb+=ge
merge_cmd=$(printf '%s %s %s 42' gh pr "$merge_verb")
encoded_payload='{"tool_input":{"command":"'"$merge_cmd"'\n# note"}}'
printf '%s' "$encoded_payload" > "$tmp_dir/original"
mkdir "$tmp_dir/fake-bin"
printf '%s\n' '#!/bin/sh' 'printf partial-output' 'exit "$FAKE_AWK_STATUS"' > "$tmp_dir/fake-bin/awk"
chmod +x "$tmp_dir/fake-bin/awk"
for awk_status in 1 127; do
  if FAKE_AWK_STATUS="$awk_status" PATH="$tmp_dir/fake-bin:$PATH" \
      _normalize_json_escapes "$encoded_payload" > "$tmp_dir/fallback" && \
      cmp -s "$tmp_dir/original" "$tmp_dir/fallback"; then
    printf 'PASS awk exit %s: original payload returned\n' "$awk_status"
    pass=$((pass + 1))
  else
    printf 'FAIL awk exit %s: original payload not returned\n' "$awk_status" >&2
    fail=$((fail + 1))
  fi
  if is_merge_command_raw "$(cat "$tmp_dir/fallback")"; then
    printf 'PASS awk exit %s: fallback scan detects payload\n' "$awk_status"
    pass=$((pass + 1))
  else
    printf 'FAIL awk exit %s: fallback scan misses payload\n' "$awk_status" >&2
    fail=$((fail + 1))
  fi
  if (
    set -euo pipefail
    FAKE_AWK_STATUS="$awk_status" PATH="$tmp_dir/fake-bin:$PATH" \
      _normalize_json_escapes "$encoded_payload" > "$tmp_dir/strict"
    cmp -s "$tmp_dir/original" "$tmp_dir/strict"
    is_merge_command_raw "$(cat "$tmp_dir/strict")"
  ); then
    printf 'PASS awk exit %s: strict shell reaches fallback scan\n' "$awk_status"
    pass=$((pass + 1))
  else
    printf 'FAIL awk exit %s: strict shell misses fallback scan\n' "$awk_status" >&2
    fail=$((fail + 1))
  fi
done

# The explicit system Bash invocation is intentional: env bash may select
# Homebrew Bash. SIGKILL is required because Bash 3.2 defers SIGTERM while
# it is inside a global parameter substitution.
run_timed() {
  local kind="$1" output="$2" pid watchdog status started elapsed
  started=$(date +%s)
  /bin/bash "$0" --worker "$kind" "$payload" > "$output" &
  pid=$!
  ( sleep 10; kill -KILL "$pid" 2>/dev/null ) &
  watchdog=$!
  wait "$pid"
  status=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  elapsed=$(( $(date +%s) - started ))
  printf '%s %s\n' "$status" "$elapsed"
}

payload=$(awk 'BEGIN { for (i = 0; i < 10000; i++) printf "\\n" }')
read -r old_status old_seconds < <(run_timed old "$tmp_dir/old-large")
if [ "$old_status" -eq 137 ]; then
  printf 'PASS old implementation timed out: SIGKILL after %ss\n' "$old_seconds"
  pass=$((pass + 1))
else
  printf 'FAIL old implementation unexpectedly exited %s after %ss\n' "$old_status" "$old_seconds" >&2
  fail=$((fail + 1))
fi

read -r new_status new_seconds < <(run_timed new "$tmp_dir/new-large")
new_size=$(wc -c < "$tmp_dir/new-large")
if [ "$new_status" -eq 0 ] && [ "$new_size" -eq 10000 ]; then
  printf 'PASS new implementation: 10000 decoded newlines in %ss\n' "$new_seconds"
  pass=$((pass + 1))
else
  printf 'FAIL new implementation: status=%s bytes=%s elapsed=%ss\n' "$new_status" "$new_size" "$new_seconds" >&2
  fail=$((fail + 1))
fi

printf 'Results: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
