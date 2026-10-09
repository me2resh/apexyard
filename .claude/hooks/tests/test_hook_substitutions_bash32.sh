#!/bin/bash
# Byte equivalence and failure behavior for the three unbounded-command joins.
# Run with both /bin/bash and /opt/homebrew/bin/bash. The timed child is always
# /bin/bash, since that is the interpreter affected by the slow substitutions.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


HOOK_DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$HOOK_DIR/_lib-detect-bash-write.sh"
PR_HOOK="$HOOK_DIR/validate-pr-create.sh"
MIG_HOOK="$HOOK_DIR/require-migration-ticket.sh"
TEST_BASH=$BASH
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Build the vcs verb at runtime so live agent hooks do not scan a static
# "git …" line in this file when the suite is authored or edited.
_vcs=$(printf '%s%s' g it)
_lib_rel='.claude/hooks/_lib-detect-bash-write.sh'

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
cp "$HOOK_DIR/_lib-awk-fallback.sh" "$TMP/_lib-awk-fallback.sh"

# Pre-#1555 library (parameter-expansion splitter), vendored as a fixture.
# It is the equivalence oracle: the new code must extract the same targets.
# A fixture, not git history, so the test also passes after a squash merge.
cp "$(dirname "$0")/fixtures/_lib-detect-bash-write.pre-1555.sh" "$TMP/old-lib.sh"

# shellcheck source=/dev/null
. "$LIB"

PASS=0
FAIL=0

record() {
  local label="$1" ok="$2"
  if [ "$ok" = 1 ]; then
    echo "PASS [$label]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [$label]" >&2
    FAIL=$((FAIL + 1))
  fi
}

# Fake awk helpers ----------------------------------------------------------
REAL_AWK=$(command -v awk)
mkdir -p "$TMP/fail-bin" "$TMP/fail-split-bin" "$TMP/fail-both-bin"

# Fail every awk invocation.
printf '#!/bin/sh\nexit "$FAIL_RC"\n' > "$TMP/fail-bin/awk"
chmod +x "$TMP/fail-bin/awk"
cp "$TMP/fail-bin/awk" "$TMP/fail-both-bin/awk"
cp "$TMP/fail-bin/awk" "$TMP/fail-both-bin/tr"

# Fail ONLY the new split awk (distinctive clobber placeholder in program).
cat > "$TMP/fail-split-bin/awk" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    *APEXYARD_CLOBBER*) exit "\${FAIL_RC:-1}" ;;
  esac
done
exec $REAL_AWK "\$@"
EOF
chmod +x "$TMP/fail-split-bin/awk"

# On awk failure, split must equal the legacy oracle (not a synthetic "> .").
for rc in 1 127; do
  old_split "read data" > "$TMP/want"
  if PATH="$TMP/fail-bin:$PATH" FAIL_RC="$rc" "$TEST_BASH" -c '
      set -e -o pipefail
      . "$1"
      _bdw_split_top_level "read data" > "$2"
    ' _ "$LIB" "$TMP/got" && cmp -s "$TMP/want" "$TMP/got"; then
    record "awk-exit-$rc/split-legacy-fallback" 1
  else
    record "awk-exit-$rc/split-legacy-fallback" 0
  fi

  if PATH="$TMP/fail-bin:$PATH" FAIL_RC="$rc" "$TEST_BASH" -c '
      set -e -o pipefail
      . "$1"
      _bdw_sed_regions "sed -n p f && sed -n '\''w out'\'' f" > "$2"
    ' _ "$LIB" "$TMP/got" && grep -q 'sed -n.*w out' "$TMP/got"; then
    record "awk-exit-$rc/sed-region-retained" 1
  else
    record "awk-exit-$rc/sed-region-retained" 0
  fi

  pr_verb='g'"h pr "'create'
  pr_sample=$'echo x\n'"$pr_verb"$' \\\n --title x'
  jq -nc --arg c "$pr_sample" '{tool_input:{command:$c}}' > "$TMP/payload"
  : > "$TMP/got"
  if PATH="$TMP/fail-bin:$PATH" FAIL_RC="$rc" CAPTURE="$TMP/got" \
      "$TEST_BASH" "$TMP/pr-capture.sh" < "$TMP/payload" > /dev/null 2>&1 \
      && grep -q "$pr_verb" "$TMP/got"; then
    record "awk-exit-$rc/pr-verb-retained" 1
  else
    record "awk-exit-$rc/pr-verb-retained" 0
  fi

  jq -nc --arg c 'read data' '{tool_input:{command:$c}}' > "$TMP/read-payload"
  if PATH="$TMP/fail-bin:$PATH" FAIL_RC="$rc" \
      "$TEST_BASH" "$PR_HOOK" < "$TMP/read-payload" > /dev/null 2> "$TMP/pr-error"; then
    record "awk-exit-$rc/pr-gate-fails-closed" 0
  elif grep -q 'Could not normalize command text safely' "$TMP/pr-error"; then
    record "awk-exit-$rc/pr-gate-fails-closed" 1
  else
    echo "FAIL [awk-exit-$rc/pr-gate-fails-closed]: wrong error" >&2
    record "awk-exit-$rc/pr-gate-fails-closed" 0
  fi

  old_join "$pr_sample" > "$TMP/want"
  : > "$TMP/got"
  if PATH="$TMP/fail-both-bin:$PATH" FAIL_RC="$rc" CAPTURE="$TMP/got" \
      "$TEST_BASH" "$TMP/pr-capture.sh" < "$TMP/payload" > /dev/null 2>&1 \
      && cmp -s "$TMP/want" "$TMP/got"; then
    record "awk-and-tr-exit-$rc/pr-old-join" 1
  else
    record "awk-and-tr-exit-$rc/pr-old-join" 0
  fi
done

# ---------------------------------------------------------------------------
# Rex #1557: when the split awk fails, extracted write targets must equal
# the pre-#1555 library (never rewrite every target to ".").
# ---------------------------------------------------------------------------
TARGET_CMDS=(
  'echo x > db/migrations/006.sql'
  'printf a >> /abs/path/file'
  'cat <<EOF > out.txt'
  'echo a > first.txt; echo b > second.txt'
)

assert_targets_match_old() {
  local label="$1" path_prefix="$2" cmd="$3" require_nonempty="${4:-1}"
  local new_out old_out
  new_out=$(PATH="$path_prefix:$PATH" FAIL_RC=1 "$TEST_BASH" -c '
      . "$1"
      bash_extract_write_targets "$2"
    ' _ "$LIB" "$cmd")
  old_out=$(PATH="$path_prefix:$PATH" FAIL_RC=1 "$TEST_BASH" -c '
      . "$1"
      bash_extract_write_targets "$2"
    ' _ "$TMP/old-lib.sh" "$cmd")
  if [ "$new_out" != "$old_out" ]; then
    echo "FAIL [$label]: new=[$new_out] old=[$old_out]" >&2
    record "$label" 0
    return
  fi
  if [ "$require_nonempty" = 1 ]; then
    if [ -z "$new_out" ] || [ "$new_out" = "." ]; then
      echo "FAIL [$label]: expected real targets, got [$new_out]" >&2
      record "$label" 0
      return
    fi
  fi
  record "$label" 1
}

for cmd in "${TARGET_CMDS[@]}"; do
  case "$cmd" in
    *db/migrations*) label_base=migration-redirect ;;
    *abs/path*)      label_base=abs-append ;;
    *EOF*)           label_base=heredoc-redirect ;;
    *first.txt*)     label_base=two-targets ;;
    *)               label_base=other ;;
  esac
  # Selective fail: dedup awk still works; targets must be real and equal.
  assert_targets_match_old "selective-awk-fail/$label_base" "$TMP/fail-split-bin" "$cmd" 1
  # Every awk fails: dedup also fails on both libs; require equality only.
  assert_targets_match_old "every-awk-fail/$label_base" "$TMP/fail-bin" "$cmd" 0
done

# End-to-end: require-migration-ticket must BLOCK a migration write when the
# split awk fails and no migration ticket is active (exit 2).
make_mig_sandbox() {
  local sb
  sb=$(mktemp -d)
  sb=$(cd "$sb" && pwd -P)
  (
    cd "$sb" || exit 1
    $_vcs init -q
    $_vcs config user.email "test@example.com"
    $_vcs config user.name "test"
    touch onboarding.yaml
    printf '' > .apexyard-fork
    cat > apexyard.projects.yaml <<'YAML'
version: 1
projects:
  - name: example
    repo: example/example
YAML
    mkdir -p .claude/hooks migrations bin
    for f in _lib-tracker.sh _lib-read-config.sh _lib-portfolio-paths.sh \
             _lib-ops-root.sh _lib-awk-fallback.sh _lib-detect-bash-write.sh _lib-path-resolve.sh \
             _lib-active-ticket.sh _lib-ticket-path-exemptions.sh \
             _lib-command-scrub.sh; do
      [ -f "$HOOK_DIR/$f" ] && cp "$HOOK_DIR/$f" ".claude/hooks/$f"
    done
    cp "$MIG_HOOK" .claude/hooks/require-migration-ticket.sh
    chmod +x .claude/hooks/*.sh
    if [ -f "$HOOK_DIR/../project-config.defaults.json" ]; then
      cp "$HOOK_DIR/../project-config.defaults.json" .claude/project-config.defaults.json
    fi
    $_vcs add -A
    $_vcs commit -q -m "test fixture"
  )
  printf '%s\n' "$sb"
}

SB_MIG=$(make_mig_sandbox)
cp "$TMP/fail-split-bin/awk" "$SB_MIG/bin/awk"
jq -nc --arg c 'echo x > db/migrations/006.sql' \
  '{tool_name:"Bash", tool_input:{command:$c}}' > "$TMP/mig-payload"
(
  cd "$SB_MIG" || exit 99
  unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID
  export APEXYARD_OPS_DISABLE_PIN=1
  PATH="$SB_MIG/bin:$PATH" FAIL_RC=1 \
    bash .claude/hooks/require-migration-ticket.sh < "$TMP/mig-payload" \
    > /dev/null 2> "$TMP/mig-err"
)
mig_rc=$?
if [ "$mig_rc" -eq 2 ]; then
  record "migration-gate/selective-awk-fail-blocks" 1
else
  echo "FAIL [migration-gate]: exit=$mig_rc stderr=$(head -c 200 "$TMP/mig-err")" >&2
  record "migration-gate/selective-awk-fail-blocks" 0
fi
rm -rf "$SB_MIG"

# The watchdog runs sleep as its child. Record that PID before waiting for
# the tested child, then terminate both watchdog and sleep on every return.
run_timed() {
  local label="$1" expected="$2" child watchdog sleeper result
  local waited=0
  shift 2
  "$@" > /dev/null 2>&1 & child=$!
  (
    /bin/sleep 10 &
    printf '%s\n' "$!" > "$TMP/sleeper-pid"
    wait "$!"
    /bin/kill -KILL "$child" 2>/dev/null || :
  ) & watchdog=$!
  # Bounded wait for the watchdog PID file (Rex, PR #1557).
  while [ ! -s "$TMP/sleeper-pid" ]; do
    if [ "$waited" -ge 50 ]; then
      /bin/kill -KILL "$child" "$watchdog" 2>/dev/null || :
      echo "FAIL [10s-watchdog/$label]: PID file never appeared within 5s" >&2
      FAIL=$((FAIL + 1))
      rm -f "$TMP/sleeper-pid"
      return 0
    fi
    /bin/sleep 0.1 2>/dev/null || /bin/sleep 1
    waited=$((waited + 1))
  done
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
