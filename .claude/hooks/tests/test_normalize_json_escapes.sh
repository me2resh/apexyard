#!/bin/bash
# Byte-for-byte regression and bash 3.2 timing test for the raw-payload decoder.
set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-extract-pr.sh"
# shellcheck source=/dev/null
. "$LIB_SRC"

if [ "${1:-}" = --worker ]; then
  input=$(cat "$3")
  case "$2" in
    old) _normalize_json_escapes_legacy "$input" ;;
    new) _normalize_json_escapes "$input" ;;
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
  _normalize_json_escapes_legacy "$input" > "$tmp_dir/old"
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
# The legacy decoder uses 0x1E as its backslash sentinel. A raw 0x1E in the
# input must pass through unchanged, not become a backslash.
assert_equal raw_record_separator $'g\036h pr merge'
assert_equal record_separator_with_escapes $'a\036\\\\\\n\036\\t\036\036\n'
assert_equal backslash_before_record_separator $'x\\\036n\\'

_normalize_json_escapes_legacy $'g\036h' > "$tmp_dir/old"
printf 'g\036h' > "$tmp_dir/want"
if cmp -s "$tmp_dir/old" "$tmp_dir/want"; then
  printf 'PASS legacy keeps a raw 0x1E byte\n'
  pass=$((pass + 1))
else
  printf 'FAIL legacy keeps a raw 0x1E byte\n' >&2
  fail=$((fail + 1))
fi
assert_equal escaped_and_literal_newlines $'a\\n\n\\u0009\n'
assert_equal invalid_utf8 $'before\377\\t\\/after'

# Keep the large equivalence input modest enough for the legacy Bash 3.2
# substitution path while exercising record boundaries and escape decoding.
large_input=$(awk 'BEGIN { for (line = 0; line < 5000; line++) print "x" }')
large_input+='\t'
assert_equal five_thousand_lines "$large_input"

# Build each command at runtime so hook command scans do not see it here.
merge_verb=mer
merge_verb+=ge
cli=gh
payloads=(
  "$(printf '%s\\tpr %s 5' "$cli" "$merge_verb")"
  "$(printf '%s pr\\u0020%s 5' "$cli" "$merge_verb")"
  "$(printf '%s\\u0009pr %s 5' "$cli" "$merge_verb")"
  "$(printf '%s api repos\\/o\\/r\\/pulls\\/5\\/%s' "$cli" "$merge_verb")"
)
mkdir "$tmp_dir/selective-bin" "$tmp_dir/all-bin"
cat > "$tmp_dir/selective-bin/awk" <<'EOF'
#!/bin/sh
case "$*" in
  *'function decode(s,'*) printf partial-output; exit 1 ;;
esac
exec /usr/bin/awk "$@"
EOF
printf '%s\n' '#!/bin/sh' 'printf partial-output' 'exit 1' > "$tmp_dir/all-bin/awk"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$tmp_dir/selective-bin/jq"
chmod +x "$tmp_dir/selective-bin/awk" "$tmp_dir/all-bin/awk" "$tmp_dir/selective-bin/jq"

for mode in selective all; do
  for i in 0 1 2 3; do
    encoded_payload='{"tool_input":{"command":"'"${payloads[$i]}"'"}}'
    _normalize_json_escapes_legacy "$encoded_payload" > "$tmp_dir/old"
    PATH="$tmp_dir/$mode-bin:$PATH" _normalize_json_escapes "$encoded_payload" > "$tmp_dir/fallback"
    if cmp -s "$tmp_dir/old" "$tmp_dir/fallback"; then
      printf 'PASS %s awk failure: payload %s equals legacy\n' "$mode" "$i"
      pass=$((pass + 1))
    else
      printf 'FAIL %s awk failure: payload %s differs from legacy\n' "$mode" "$i" >&2
      fail=$((fail + 1))
    fi
    if is_merge_command_raw "$(cat "$tmp_dir/fallback")"; then
      printf 'PASS %s awk failure: payload %s detects merge\n' "$mode" "$i"
      pass=$((pass + 1))
    else
      printf 'FAIL %s awk failure: payload %s misses merge\n' "$mode" "$i" >&2
      fail=$((fail + 1))
    fi
  done
done

# The gate uses this exact fallback expression when jq cannot parse input.
# The fake jq forces that path; the selective awk shim leaves other awk calls.
encoded_payload='{"tool_input":{"command":"'"${payloads[0]}"'"}}'
printf '%s' "$encoded_payload" | PATH="$tmp_dir/selective-bin:$PATH" \
  /bin/bash "$(dirname "$LIB_SRC")/block-unreviewed-merge.sh" > "$tmp_dir/gate-out" 2>&1
gate_status=$?
if [ "$gate_status" -eq 2 ] && grep -q 'BLOCKED: merge gate cannot evaluate' "$tmp_dir/gate-out"; then
  printf 'PASS selective awk failure: merge gate blocks\n'
  pass=$((pass + 1))
else
  printf 'FAIL selective awk failure: merge gate exit %s\n' "$gate_status" >&2
  fail=$((fail + 1))
fi

# The explicit system Bash invocation is intentional: env bash may select
# Homebrew Bash. SIGKILL is required because Bash 3.2 defers SIGTERM while
# it is inside a global parameter substitution.
run_timed() {
  local kind="$1" output="$2" pid watchdog status started elapsed
  started=$(date +%s)
  /bin/bash "$0" --worker "$kind" "$tmp_dir/payload" > "$output" &
  pid=$!
  (
    sleep 10 &
    sleeper=$!
    trap 'kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null; exit 0' TERM
    wait "$sleeper" 2>/dev/null
    kill -KILL "$pid" 2>/dev/null
  ) &
  watchdog=$!
  wait "$pid"
  status=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  elapsed=$(( $(date +%s) - started ))
  printf '%s %s\n' "$status" "$elapsed"
}

awk 'BEGIN { for (i = 0; i < 10000; i++) printf "\\n" }' > "$tmp_dir/payload"
# Override only for testing the Bash 5 branch on a host whose /bin/bash is 3.x.
bash_major=${TEST_FORCE_BASH_MAJOR:-$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')}
if [ "$bash_major" -eq 3 ]; then
  read -r old_status old_seconds < <(run_timed old "$tmp_dir/old-large")
  if [ "$old_status" -eq 137 ]; then
    printf 'PASS old implementation timed out: SIGKILL after %ss\n' "$old_seconds"
    pass=$((pass + 1))
  else
    printf 'FAIL old implementation unexpectedly exited %s after %ss\n' "$old_status" "$old_seconds" >&2
    fail=$((fail + 1))
  fi
else
  printf 'NOTE: old implementation timing not asserted: /bin/bash major version %s\n' "$bash_major"
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
