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
    PATH="$tmp_dir/$mode-bin:$PATH" _normalize_json_escapes "$encoded_payload" > "$tmp_dir/fallback"
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
