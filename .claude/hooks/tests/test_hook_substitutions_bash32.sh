#!/bin/bash
# Byte equivalence and failure behavior for the three unbounded-command joins.
# Run with both /bin/bash and /opt/homebrew/bin/bash. The timed child is always
# /bin/bash, since that is the interpreter affected by the slow substitutions.

set -u

HOOK_DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$HOOK_DIR/_lib-detect-bash-write.sh"
PR_HOOK="$HOOK_DIR/validate-pr-create.sh"
TEST_BASH=$BASH
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The pre-fix substitutions remain here as byte-for-byte oracles.
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

# Capture the real PR hook's normalized COMMAND before the rest of the hook.
# The inserted exit makes this a test of the exact call site, without needing
# a tracker, branch, or network access.
awk '{
  print
  if ($0 == "#!/bin/bash") { print "set -e"; print "set -o pipefail" }
  if ($0 == "unset _vpc_joined") {
    print "printf \047%s\047 \"$COMMAND\" > \"$CAPTURE\""
    print "exit 0"
  }
}' "$PR_HOOK" > "$TMP/pr-capture.sh"

# shellcheck source=/dev/null
. "$LIB"

PASS=0
FAIL=0
check_bytes() {
  local label="$1"
  if cmp -s "$TMP/want" "$TMP/got"; then
    PASS=$((PASS + 1))
  else
    echo "FAIL [$label]: byte mismatch" >&2
    od -An -tx1 "$TMP/want" >&2
    od -An -tx1 "$TMP/got" >&2
    FAIL=$((FAIL + 1))
  fi
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

for i in "${!samples[@]}"; do
  sample=${samples[i]}
  old_split "$sample" > "$TMP/want"
  _bdw_split_top_level "$sample" > "$TMP/got"
  check_bytes "split/$i"

  old_regions "$sample" > "$TMP/want"
  _bdw_sed_regions "$sample" > "$TMP/got"
  check_bytes "sed-region/$i"

  # jq output is captured by the hook with $(...), which strips trailing
  # newlines before the normalization site. Match that input contract.
  pr_sample=$sample
  while [ "${pr_sample%$'\n'}" != "$pr_sample" ]; do
    pr_sample=${pr_sample%$'\n'}
  done
  # JSON strings must be valid UTF-8; the two library sites cover bad bytes.
  if [ "$i" -eq "$((${#samples[@]} - 1))" ]; then continue; fi
  old_join "$pr_sample" > "$TMP/want"
  : > "$TMP/got"
  jq -nc --arg c "$pr_sample" '{tool_input:{command:$c}}' > "$TMP/payload"
  CAPTURE="$TMP/got" "$TEST_BASH" "$TMP/pr-capture.sh" < "$TMP/payload" > /dev/null 2>&1
  check_bytes "pr-join/$i"
done

# Both non-zero tool statuses must stay on a conservative path even when
# callers enable errexit and pipefail.
mkdir "$TMP/fail-bin"
printf '#!/bin/sh\nexit "$FAIL_RC"\n' > "$TMP/fail-bin/awk"
chmod +x "$TMP/fail-bin/awk"
mkdir "$TMP/fail-both-bin"
cp "$TMP/fail-bin/awk" "$TMP/fail-both-bin/awk"
cp "$TMP/fail-bin/awk" "$TMP/fail-both-bin/tr"
for rc in 1 127; do
  if PATH="$TMP/fail-bin:$PATH" FAIL_RC="$rc" "$TEST_BASH" -c '
      set -e -o pipefail
      . "$1"
      _bdw_split_top_level "read data" > "$2"
      _bdw_match_redirection_any_segment "read data"
      target=$(bash_extract_write_target "> .")
      [ "$target" = "." ]
    ' _ "$LIB" "$TMP/got" && [ "$(cat "$TMP/got")" = '> .' ]; then
    echo "PASS [awk-exit-$rc/split-fails-closed]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [awk-exit-$rc/split-fails-closed]" >&2
    FAIL=$((FAIL + 1))
  fi

  if PATH="$TMP/fail-bin:$PATH" FAIL_RC="$rc" "$TEST_BASH" -c '
      set -e -o pipefail
      . "$1"
      _bdw_sed_regions "sed -n p f && sed -n '\''w out'\'' f" > "$2"
    ' _ "$LIB" "$TMP/got" && grep -q 'sed -n.*w out' "$TMP/got"; then
    echo "PASS [awk-exit-$rc/sed-region-retained]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [awk-exit-$rc/sed-region-retained]" >&2
    FAIL=$((FAIL + 1))
  fi

  pr_verb='g'"h pr "'create'
  pr_sample=$'echo x\n'"$pr_verb"$' \\\n --title x'
  jq -nc --arg c "$pr_sample" '{tool_input:{command:$c}}' > "$TMP/payload"
  : > "$TMP/got"
  if PATH="$TMP/fail-bin:$PATH" FAIL_RC="$rc" CAPTURE="$TMP/got" \
      "$TEST_BASH" "$TMP/pr-capture.sh" < "$TMP/payload" > /dev/null 2>&1 \
      && grep -q "$pr_verb" "$TMP/got"; then
    echo "PASS [awk-exit-$rc/pr-verb-retained]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [awk-exit-$rc/pr-verb-retained]" >&2
    FAIL=$((FAIL + 1))
  fi

  jq -nc --arg c 'read data' '{tool_input:{command:$c}}' > "$TMP/read-payload"
  if PATH="$TMP/fail-bin:$PATH" FAIL_RC="$rc" \
      "$TEST_BASH" "$PR_HOOK" < "$TMP/read-payload" > /dev/null 2> "$TMP/pr-error"; then
    echo "FAIL [awk-exit-$rc/pr-gate-fails-closed]" >&2
    FAIL=$((FAIL + 1))
  elif grep -q 'Could not normalize command text safely' "$TMP/pr-error"; then
    echo "PASS [awk-exit-$rc/pr-gate-fails-closed]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [awk-exit-$rc/pr-gate-fails-closed]: wrong error" >&2
    FAIL=$((FAIL + 1))
  fi

  old_join "$pr_sample" > "$TMP/want"
  : > "$TMP/got"
  if PATH="$TMP/fail-both-bin:$PATH" FAIL_RC="$rc" CAPTURE="$TMP/got" \
      "$TEST_BASH" "$TMP/pr-capture.sh" < "$TMP/payload" > /dev/null 2>&1 \
      && cmp -s "$TMP/want" "$TMP/got"; then
    echo "PASS [awk-and-tr-exit-$rc/pr-old-join]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [awk-and-tr-exit-$rc/pr-old-join]" >&2
    FAIL=$((FAIL + 1))
  fi
done

# The watchdog runs sleep as its child. Record that PID before waiting for
# the tested child, then terminate both watchdog and sleep on every return.
run_timed() {
  local label="$1" expected="$2" child watchdog sleeper result
  shift 2
  "$@" > /dev/null 2>&1 & child=$!
  (
    /bin/sleep 10 &
    printf '%s\n' "$!" > "$TMP/sleeper-pid"
    wait "$!"
    /bin/kill -KILL "$child" 2>/dev/null || :
  ) & watchdog=$!
  while [ ! -s "$TMP/sleeper-pid" ]; do :; done
  wait "$child" 2>/dev/null; result=$?
  read -r sleeper < "$TMP/sleeper-pid"
  /bin/kill "$sleeper" "$watchdog" 2>/dev/null || :
  wait "$watchdog" 2>/dev/null || :
  rm -f "$TMP/sleeper-pid"
  if { [ "$expected" = pass ] && [ "$result" -eq 0 ]; } \
      || { [ "$expected" = killed ] && [ "$result" -eq 137 ]; }; then
    echo "PASS [10s-watchdog/$label: $expected]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [10s-watchdog/$label]: status=$result" >&2
    FAIL=$((FAIL + 1))
  fi
}

for ((i=0; i<5000; i++)); do
  printf 'echo a && echo b || cat x; echo y | cat z\n'
done > "$TMP/split-long"
for ((i=0; i<5000; i++)); do
  printf 'sed -n "p" f && sed -n "q" f || sed -n "r" f | cat\n'
done > "$TMP/region-long"
for ((i=0; i<5000; i++)); do
  printf 'read only data and quoted "text" \\\n'
done > "$TMP/join-long"
# The sentinel preserves trailing newlines when command substitution reads a file.
run_timed split pass /bin/bash -c '. "$1"; input=$(cat "$2"; printf "."); _bdw_split_top_level "${input%.}"' _ "$LIB" "$TMP/split-long"
run_timed sed-region pass /bin/bash -c '. "$1"; input=$(cat "$2"; printf "."); _bdw_sed_regions "${input%.}"' _ "$LIB" "$TMP/region-long"
jq -Rs '{tool_input:{command:.}}' < "$TMP/join-long" > "$TMP/payload"
run_timed pr-join pass /bin/bash "$TMP/pr-capture.sh" < "$TMP/payload"

# Optional before-state reproduction. These are the exact old substitutions
# above, run in separate stock-Bash children under the same watchdog.
if [ "${1:-}" = --baseline ]; then
  bash_major=$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')
  # Test-only override lets a macOS runner exercise the Bash 5 skip path.
  if [ -n "${TEST_FORCE_BASH_MAJOR:-}" ]; then bash_major=$TEST_FORCE_BASH_MAJOR; fi
  if [ "$bash_major" = 3 ]; then
    declare -f old_split old_regions old_join > "$TMP/oracles.sh"
    run_timed old-split killed /bin/bash -c '. "$1"; input=$(cat "$2"; printf "."); old_split "${input%.}"' _ "$TMP/oracles.sh" "$TMP/split-long"
    run_timed old-sed-region killed /bin/bash -c '. "$1"; input=$(cat "$2"; printf "."); old_regions "${input%.}"' _ "$TMP/oracles.sh" "$TMP/region-long"
    for ((i=0; i<5000; i++)); do
      printf 'read only data with quoted text and continuation \\\n'
    done > "$TMP/old-join-input"
    run_timed old-pr-join killed /bin/bash -c '. "$1"; old_join "$(cat "$2")"' _ \
      "$TMP/oracles.sh" "$TMP/old-join-input"
  else
    for label in old-split old-sed-region old-pr-join; do
      echo "SKIP [10s-watchdog/$label: /bin/bash major $bash_major]"
    done
  fi
fi

echo "substitution tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
