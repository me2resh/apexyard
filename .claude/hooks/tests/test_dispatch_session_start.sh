#!/usr/bin/env bash
set -euo pipefail

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$ROOT/../settings.json"
DISPATCHER="$ROOT/dispatch-session-start.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

bash_entries=$(jq '[.hooks.SessionStart[].hooks[]] | length' "$SETTINGS")
[ "$bash_entries" -eq 1 ]
dispatcher_command=$(jq -r '[.hooks.SessionStart[].hooks[].command][0]' "$SETTINGS")
grep -q 'dispatch-session-start.sh' <<<"$dispatcher_command"

scripts='pin-ops-root.sh onboarding-check.sh check-upstream-drift.sh check-jq-installed.sh check-git-hooks-installed.sh check-portfolio-config.sh clear-bootstrap-marker.sh clear-active-reviewer-marker.sh clear-onboarding-depth-mode-marker.sh clear-onboarding-glossary-seen-marker.sh clear-issue-skill-marker.sh link-custom-skills.sh apply-agent-routing.sh print-portfolio-primer.sh warn-unqualified-review-marker.sh'
for script in $scripts; do
  grep -q "APEXYARD_SESSION_START_HOOK: $script" "$DISPATCHER"
done

# --- #1323: the script lists inside the dispatcher must agree -----------------
# The APEXYARD_SESSION_START_HOOK comments feed the exec-bit test. The scripts
# array feeds both the concurrent path and the mktemp-failure fallback. The
# comments must list pin-ops-root.sh followed by the array, in order.
comment_list() {
  sed -n 's/^# APEXYARD_SESSION_START_HOOK: //p' "$1" | tr '\n' ' '
}
array_list() {
  awk '/^scripts=\(/{in_list=1; next} in_list && /^\)/{exit} in_list {gsub(/[ \t\\]/, ""); if ($0 != "") print}' "$1" | tr '\n' ' '
}
lists_agree() {
  local file="$1" comments array loops
  comments=$(comment_list "$file")
  array="pin-ops-root.sh $(array_list "$file")"
  [ "$comments" = "$array" ] || return 1
  # No loop may carry its own literal copy of the list.
  loops=$(grep -cE '^[[:space:]]*for script in .*\.sh' "$file" || true)
  [ "$loops" -eq 0 ] || return 1
  # The mktemp-failure fallback must iterate the shared array.
  # shellcheck disable=SC2016 # literal ${scripts[@]} text, not an expansion
  grep -q 'for script in "\${scripts\[@\]}"' "$file"
}

lists_agree "$DISPATCHER" || fail "dispatcher comment list, scripts array, and fallback loop disagree"
[ "$(comment_list "$DISPATCHER")" = "$scripts " ] || fail "dispatcher comment list differs from this test's expected list"

# The parity check must actually catch drift. Break each source once.
sed '/^  apply-agent-routing\.sh$/d' "$DISPATCHER" > "$TMP/drift-array.sh"
if lists_agree "$TMP/drift-array.sh"; then fail "parity check missed a script removed from the array"; fi
sed '/^# APEXYARD_SESSION_START_HOOK: print-portfolio-primer\.sh$/d' "$DISPATCHER" > "$TMP/drift-comment.sh"
if lists_agree "$TMP/drift-comment.sh"; then fail "parity check missed a script removed from the comments"; fi
# shellcheck disable=SC2016 # literal ${scripts[@]} text, not an expansion
sed 's|for script in "\${scripts\[@\]}"; do|for script in onboarding-check.sh; do|' "$DISPATCHER" > "$TMP/drift-loop.sh"
if lists_agree "$TMP/drift-loop.sh"; then fail "parity check missed a literal list in the fallback loop"; fi

# --- Sandbox with stub hooks --------------------------------------------------
mkdir -p "$TMP/.claude/hooks"
cp "$DISPATCHER" "$TMP/.claude/hooks/dispatch-session-start.sh"
chmod +x "$TMP/.claude/hooks/dispatch-session-start.sh"

for script in $scripts; do
  cat > "$TMP/.claude/hooks/$script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
name=$(basename "$0")
printf '%s\n' "$name" >> "${SESSION_LOG:?}"
grep -q 'SessionStart' <<<"$input"
if [ "${SESSION_KILL_SLOT:-}" = "$name" ]; then
  # Kill the run_hook subshell before it writes this slot's exit status.
  kill -9 "$PPID"
fi
printf 'out:%s\n' "$name"
if [ "${SESSION_FAIL_SCRIPT:-}" = "$name" ]; then
  exit 1
fi
EOF
  chmod +x "$TMP/.claude/hooks/$script"
done

payload='{"hook_event_name":"SessionStart"}'

assert_all_ran_once() {
  local log="$1" label="$2"
  [ "$(head -1 "$log")" = "pin-ops-root.sh" ] || fail "$label: pin-ops-root.sh did not run first"
  for script in $scripts; do
    [ "$(grep -cxF "$script" "$log")" -eq 1 ] || fail "$label: $script did not run exactly once"
  done
}

# --- Concurrent path, one hook fails ------------------------------------------
printf '%s' "$payload" \
  | SESSION_LOG="$TMP/log" SESSION_FAIL_SCRIPT=check-jq-installed.sh \
    "$TMP/.claude/hooks/dispatch-session-start.sh" >/dev/null 2>"$TMP/err"
assert_all_ran_once "$TMP/log" "concurrent path"
grep -q 'WARN: SessionStart hook check-jq-installed.sh exited 1' "$TMP/err" || fail "concurrent path: failing hook not reported"

# --- #1323: mktemp failure runs the sequential fallback -----------------------
mkdir -p "$TMP/nomktemp"
cat > "$TMP/nomktemp/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/nomktemp/mktemp"
rc=0
printf '%s' "$payload" \
  | PATH="$TMP/nomktemp:$PATH" SESSION_LOG="$TMP/log-fallback" SESSION_FAIL_SCRIPT=check-jq-installed.sh \
    "$TMP/.claude/hooks/dispatch-session-start.sh" >"$TMP/out-fallback" 2>"$TMP/err-fallback" || rc=$?
[ "$rc" -eq 0 ] || fail "mktemp fallback: dispatcher exited $rc"
grep -q 'WARN: could not create SessionStart output directory' "$TMP/err-fallback" || fail "mktemp fallback: warning not printed"
assert_all_ran_once "$TMP/log-fallback" "mktemp fallback"
grep -q 'WARN: SessionStart hook check-jq-installed.sh exited 1' "$TMP/err-fallback" || fail "mktemp fallback: failing hook not reported"

# --- #1323: a slot with no exit status is a failure, not a crash --------------
rc=0
printf '%s' "$payload" \
  | SESSION_LOG="$TMP/log-kill" SESSION_KILL_SLOT=check-portfolio-config.sh \
    "$TMP/.claude/hooks/dispatch-session-start.sh" >"$TMP/out-kill" 2>"$TMP/err-kill" || rc=$?
[ "$rc" -eq 0 ] || fail "missing slot: dispatcher exited $rc"
grep -q 'WARN: SessionStart hook check-portfolio-config.sh left no exit status' "$TMP/err-kill" || fail "missing slot: not reported as failed"
# Slots after the lost one are still reported.
grep -qx 'out:warn-unqualified-review-marker.sh' "$TMP/out-kill" || fail "missing slot: later slot output was not reported"

echo "PASS: SessionStart dispatcher"
