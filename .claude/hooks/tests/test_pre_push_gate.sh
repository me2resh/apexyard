#!/bin/bash
# Smoke tests for .claude/hooks/pre-push-gate.sh — the advisory-only
# rewrite from me2resh/apexyard#1366 / AgDR-0173.
#
# The pre-#1366 version of this hook read a `.pre_push.commands` list and
# ran it with `bash -c`. PR #1405's review found that any command-text
# based target resolution could be fooled by read-only text that merely
# MENTIONS a push — a heredoc body, a quoted separator, a commit message,
# an echo (Hakim's H1 finding, still reproducing on that PR's last
# commit). This hook no longer runs ANY repository's commands, so there
# is nothing left for that class of bug to exploit. The negative cases
# below (H1-*) prove exactly that: even with a `.pre_push.commands` entry
# configured to leave a marker file, none of the read-only shapes cause
# the marker to appear.
#
# Each case:
#   - sets up an isolated sandbox repo under $TMPDIR
#   - pipes a synthetic PreToolUse JSON blob into the hook
#   - asserts exit code + stderr contents + (H1 cases) absence of a
#     side-effect marker file
#
# Exit 0 if all cases pass. Report every failed case before exiting 1.

set -u

HOOK_SRC="${PRE_PUSH_GATE_HOOK_SRC:-$(cd "$(dirname "$0")/.." && pwd)/pre-push-gate.sh}"
AGDR_SRC="${PRE_PUSH_GATE_AGDR_SRC:-$(cd "$(dirname "$0")/../../.." && pwd)/docs/agdr/AgDR-0173-git-native-pre-push-command-execution.md}"
if [ ! -x "$HOOK_SRC" ]; then
  echo "FAIL: hook not found or not executable at $HOOK_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

# -- sandbox builder -----------------------------------------------------
# make_sandbox <install_git_native> <fork_shape>
#
# Install advice requires a valid session pin to the sandbox fork. Cases
# set their own pin or explicitly clear all session pin variables. This
# keeps them independent of the session that runs the suite.
#
# install_git_native=1: core.hooksPath set to .githooks with a real,
# executable stub pre-push file — the hook should stay silent regardless
# of fork_shape.
# fork_shape=fork: plant a `.apexyard-fork` marker at the sandbox root.
# fork_shape=managed (default): no anchor in the sandbox's own tree.
make_sandbox() {
  local install_git_native="${1:-0}"
  local fork_shape="${2:-managed}"
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    touch onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/pre-push-gate.sh"
  chmod +x "$sb/.claude/hooks/pre-push-gate.sh"

  # Marker file used by the H1 cases below to prove NO command ran. A real
  # .pre_push.commands entry that would leave this marker if it ever ran.
  local src_root
  src_root=$(cd "$(dirname "$0")/../../.." && pwd)
  if [ -f "$src_root/.claude/hooks/_lib-read-config.sh" ]; then
    cp "$src_root/.claude/hooks/_lib-read-config.sh" "$sb/.claude/hooks/_lib-read-config.sh"
  fi
  if [ -f "$src_root/.claude/hooks/_lib-ops-root.sh" ]; then
    cp "$src_root/.claude/hooks/_lib-ops-root.sh" "$sb/.claude/hooks/_lib-ops-root.sh"
  fi
  if [ -f "$src_root/.claude/project-config.defaults.json" ]; then
    cp "$src_root/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  fi
  cat > "$sb/.claude/project-config.json" <<EOF
{"pre_push": {"commands": [{"name": "leave-marker", "run": "touch '$sb/MARKER_RAN'"}]}}
EOF

  case "$fork_shape" in
    fork)
      touch "$sb/.apexyard-fork"
      ;;
    managed | *) ;;
  esac

  if [ "$install_git_native" = "1" ]; then
    mkdir -p "$sb/.githooks"
    printf '#!/bin/bash\nexit 0\n' > "$sb/.githooks/pre-push"
    chmod +x "$sb/.githooks/pre-push"
    (cd "$sb" && git config core.hooksPath .githooks)
  fi

  (cd "$sb" && pwd -P)
}

push_json() {
  cat <<EOF
{"tool_input":{"command":"git push origin HEAD"}}
EOF
}

make_pin() {
  local root="$1" sid="$2" pin_dir
  pin_dir=$(mktemp -d)
  printf '%s\n' "$root" > "$pin_dir/ops-root-${sid}"
  printf '%s' "$pin_dir"
}

run_pinned_hook() {
  local sb="$1" pin_dir="$2" sid="$3" hook_path="${4:-.claude/hooks/pre-push-gate.sh}"
  (
    cd "$sb" || exit 1
    # Capture stderr while discarding stdout.
    # shellcheck disable=SC2069
    push_json | env -u APEXYARD_OPS_DISABLE_PIN \
      CLAUDE_CODE_SESSION_ID="$sid" APEXYARD_OPS_PIN_DIR="$pin_dir" \
      bash "$hook_path" 2>&1 1>/dev/null
  )
}

json_cmd() {
  # Build a {"tool_input":{"command": <cmd>}} payload with jq -n so the
  # command text is safely quoted regardless of what it contains
  # (quotes, newlines, backslashes) — the exact classes of text the
  # ORIGINAL hook mis-parsed. See #1405 review, finding B3.
  jq -n --arg c "$1" '{tool_input:{command:$c}}'
}

run_hook() {
  local sb="$1"
  local stdin_payload="$2"
  local want_rc="$3"
  local want_stderr_regex="$4"
  local label="$5"
  (
    cd "$sb" || exit 1
    echo "$stdin_payload" | env -u CLAUDE_CODE_SESSION_ID -u APEXYARD_OPS_PIN_DIR -u APEXYARD_OPS_DISABLE_PIN bash .claude/hooks/pre-push-gate.sh 2>/tmp/pre-push-gate-stderr.$$
  )
  local got_rc=$?
  local got_stderr
  got_stderr=$(cat /tmp/pre-push-gate-stderr.$$ 2>/dev/null)
  rm -f /tmp/pre-push-gate-stderr.$$

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:200})" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

assert_no_marker() {
  local sb="$1" label="$2"
  if [ -f "$sb/MARKER_RAN" ]; then
    echo "FAIL [$label]: MARKER_RAN exists — a repository command ran" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}${label} "
  else
    echo "PASS [$label]"
    PASS=$((PASS+1))
  fi
}

# -------------------- CASE 1: non-git-push command --------------------
case1() {
  local sb; sb=$(make_sandbox)
  echo '{"tool_input":{"command":"ls -la"}}' | (cd "$sb" && env -u CLAUDE_CODE_SESSION_ID -u APEXYARD_OPS_PIN_DIR -u APEXYARD_OPS_DISABLE_PIN bash .claude/hooks/pre-push-gate.sh 2>/dev/null)
  local rc=$?
  if [ "$rc" = "0" ]; then
    echo "PASS [non-git-push-silent]"
    PASS=$((PASS+1))
  else
    echo "FAIL [non-git-push-silent]: want rc=0, got $rc" >&2
    FAIL=$((FAIL+1))
  fi
  rm -rf "$sb"
}

# ---- CASE 2: pinned fork, no git-native hook -> full install advice ----
case2() {
  local sb; sb=$(make_sandbox 0 fork)
  local sid="test-session-fork" pin_dir out rc
  pin_dir=$(make_pin "$sb" "$sid")
  out=$(run_pinned_hook "$sb" "$pin_dir" "$sid")
  rc=$?
  if [ "$rc" = "0" ] && echo "$out" | grep -qF "core.hooksPath" && echo "$out" | grep -qF "$sb"; then
    echo "PASS [pinned-fork-gets-install-advice-and-names-repo]"
    PASS=$((PASS+1))
  else
    echo "FAIL [pinned-fork-gets-install-advice-and-names-repo]: rc=$rc stderr=$out" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}pinned-fork-gets-install-advice-and-names-repo "
  fi
  assert_no_marker "$sb" "pinned-fork-advice-runs-no-commands"
  rm -rf "$sb" "$pin_dir"
}

# ---- CASE 3: git push, git-native hook installed -> silent, no reminder ----
# fork_shape does not matter once the hook is actually installed.
case3() {
  local sb; sb=$(make_sandbox 1 fork)
  local out rc
  out=$(cd "$sb" && echo "$(push_json)" | env -u CLAUDE_CODE_SESSION_ID -u APEXYARD_OPS_PIN_DIR -u APEXYARD_OPS_DISABLE_PIN bash .claude/hooks/pre-push-gate.sh 2>&1 1>/dev/null)
  rc=$?
  if [ "$rc" = "0" ] && [ -z "$out" ]; then
    echo "PASS [git-native-hook-installed-silent]"
    PASS=$((PASS+1))
  else
    echo "FAIL [git-native-hook-installed-silent]: want rc=0 and empty stderr, got rc=$rc stderr='$out'" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}git-native-hook-installed-silent "
  fi
  assert_no_marker "$sb" "git-native-hook-installed: still runs no commands"
  rm -rf "$sb"
}

# ---- CASE 4: fork, core.hooksPath set but the target file is missing ----
# (e.g. .githooks/ dir removed after the config was set) -> install advice
# still printed, since the git-native layer will not actually run.
case4() {
  local sb; sb=$(make_sandbox 0 fork)
  (cd "$sb" && git config core.hooksPath .githooks)
  local sid="test-session-missing-hook" pin_dir out rc
  pin_dir=$(make_pin "$sb" "$sid")
  out=$(run_pinned_hook "$sb" "$pin_dir" "$sid")
  rc=$?
  if [ "$rc" = "0" ] && echo "$out" | grep -qF "core.hooksPath"; then
    echo "PASS [pinned-fork-hookspath-set-but-file-missing-still-advises]"
    PASS=$((PASS+1))
  else
    echo "FAIL [pinned-fork-hookspath-set-but-file-missing-still-advises]: rc=$rc stderr=$out" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}pinned-fork-hookspath-set-but-file-missing-still-advises "
  fi
  rm -rf "$sb" "$pin_dir"
}

# ---- #1491: an unpinned or stale-pinned fork gets no install advice ----
case_no_valid_pin_gets_no_advice() {
  local sb; sb=$(make_sandbox 0 fork)
  local out rc sid="test-session-stale" pin_dir

  out=$(cd "$sb" && push_json | env -u CLAUDE_CODE_SESSION_ID \
    -u APEXYARD_OPS_PIN_DIR -u APEXYARD_OPS_DISABLE_PIN \
    bash .claude/hooks/pre-push-gate.sh 2>&1 1>/dev/null)
  rc=$?
  if [ "$rc" = "0" ] && ! echo "$out" | grep -qF "core.hooksPath"; then
    echo "PASS [no-pin-gives-no-install-advice]"
    PASS=$((PASS+1))
  else
    echo "FAIL [no-pin-gives-no-install-advice]: rc=$rc stderr=$out" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}no-pin-gives-no-install-advice "
  fi

  pin_dir=$(make_pin "$sb/missing-root" "$sid")
  out=$(run_pinned_hook "$sb" "$pin_dir" "$sid")
  rc=$?
  if [ "$rc" = "0" ] && ! echo "$out" | grep -qF "core.hooksPath"; then
    echo "PASS [stale-pin-gives-no-install-advice]"
    PASS=$((PASS+1))
  else
    echo "FAIL [stale-pin-gives-no-install-advice]: rc=$rc stderr=$out" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}stale-pin-gives-no-install-advice "
  fi

  rm -rf "$pin_dir"
  pin_dir=$(make_pin "$sb" "$sid")
  out=$(cd "$sb" && push_json | env CLAUDE_CODE_SESSION_ID="$sid" \
    APEXYARD_OPS_PIN_DIR="$pin_dir" APEXYARD_OPS_DISABLE_PIN=1 \
    bash .claude/hooks/pre-push-gate.sh 2>&1 1>/dev/null)
  rc=$?
  if [ "$rc" = "0" ] && ! echo "$out" | grep -qF "core.hooksPath"; then
    echo "PASS [disabled-pin-gives-no-install-advice]"
    PASS=$((PASS+1))
  else
    echo "FAIL [disabled-pin-gives-no-install-advice]: rc=$rc stderr=$out" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}disabled-pin-gives-no-install-advice "
  fi
  rm -rf "$sb" "$pin_dir"
}

# ---- #1491: a pinned linked worktree resolves to its main checkout ----
case_pinned_linked_worktree_gets_advice() {
  local sb; sb=$(make_sandbox 0 fork)
  local linked; linked=$(mktemp -d)
  if ! git -C "$sb" worktree add -q -b linked "$linked"; then
    echo "FAIL [pinned-linked-worktree-setup]" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}pinned-linked-worktree-setup "
    rm -rf "$sb" "$linked"
    return
  fi

  local sid="test-session-linked" pin_dir out rc
  pin_dir=$(make_pin "$sb" "$sid")
  out=$(run_pinned_hook "$linked" "$pin_dir" "$sid" "$sb/.claude/hooks/pre-push-gate.sh")
  rc=$?
  if [ "$rc" = "0" ] && echo "$out" | grep -qF "core.hooksPath" &&
    ! echo "$out" | grep -qF "not an ApexYard fork"; then
    echo "PASS [pinned-linked-worktree-gets-advice-without-false-note]"
    PASS=$((PASS+1))
  else
    echo "FAIL [pinned-linked-worktree-gets-advice-without-false-note]: rc=$rc stderr=$out" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}pinned-linked-worktree-gets-advice-without-false-note "
  fi
  rm -rf "$sb" "$linked" "$pin_dir"
}

case_agdr_states_pinned_limit() {
  if grep -qF 'only for sessions with a valid pin' "$AGDR_SRC"; then
    echo "PASS [AgDR-0173-states-pinned-session-limit]"
    PASS=$((PASS+1))
  else
    echo "FAIL [AgDR-0173-states-pinned-session-limit]" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}AgDR-0173-states-pinned-session-limit "
  fi
}

# =====================================================================
# B2 tests (PR #1428 review, Rex findings B2 and S1, Hakim finding A5 —
# maintainer decision)
#
# ApexYard never suggests installing the git-native hook, or setting
# core.hooksPath, outside the resolved ops root. AgDR-0115 already
# forbids ApexYard from wiring core.hooksPath into a managed-project
# clone — suggesting it here would point an operator at exactly that.
# Fork status comes from `resolve_ops_root`, never from a file a repo
# ships about itself (round 3 — round 2 trusted self-reported files,
# which a managed clone could spoof).
# =====================================================================

# ---- B2-1: pinned session in a managed clone -> short note only ----
case_b2_managed_clone_short_note() {
  local sb; sb=$(make_sandbox 0 managed)
  local real_root sid="test-session-managed" pin_dir
  real_root=$(make_sandbox 0 fork)
  pin_dir=$(make_pin "$real_root" "$sid")
  local out rc
  out=$(run_pinned_hook "$sb" "$pin_dir" "$sid")
  rc=$?
  assert_no_marker "$sb" "B2-managed-clone-gets-short-note: still runs no commands"
  if [ "$rc" = "0" ] && echo "$out" | grep -qF "not an ApexYard fork"; then
    echo "PASS [B2-managed-clone-gets-short-note]"
    PASS=$((PASS+1))
  else
    echo "FAIL [B2-managed-clone-gets-short-note]: rc=$rc stderr=$out" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}B2-managed-clone-gets-short-note "
  fi
  if echo "$out" | grep -qF "core.hooksPath"; then
    echo "FAIL [B2-managed-clone-never-suggests-hookspath]: $out" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}B2-managed-clone-never-suggests-hookspath "
  else
    echo "PASS [B2-managed-clone-never-suggests-hookspath]"
    PASS=$((PASS+1))
  fi
  if echo "$out" | grep -qF "install-git-hooks.sh"; then
    echo "FAIL [B2-managed-clone-never-suggests-installer]: $out" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}B2-managed-clone-never-suggests-installer "
  else
    echo "PASS [B2-managed-clone-never-suggests-installer]"
    PASS=$((PASS+1))
  fi
  # Rex B1: the note must name the repo it checked.
  if echo "$out" | grep -qF "$sb"; then
    echo "PASS [B2-managed-clone-note-names-its-own-repo]"
    PASS=$((PASS+1))
  else
    echo "FAIL [B2-managed-clone-note-names-its-own-repo]: $out" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}B2-managed-clone-note-names-its-own-repo "
  fi
  rm -rf "$sb" "$real_root" "$pin_dir"
}

# ---- B2-3 (Hakim A5 / Rex S1): a repo that SHIPS `.apexyard-fork` but is
# NOT the resolved ops root gets no install advice. The hook must trust
# `resolve_ops_root`'s pin over a marker the working-directory repo
# reports about itself. Set up a real, pin-valid ops root elsewhere, pin
# a session to it, and prove the spoofed sandbox — despite shipping its
# own `.apexyard-fork` — gets only the managed-clone note.
case_b2_spoofed_fork_marker_gets_no_advice() {
  local sb; sb=$(make_sandbox 0 fork)

  local real_root; real_root=$(mktemp -d)
  touch "$real_root/.apexyard-fork"
  mkdir -p "$real_root/.claude/hooks"

  local pin_dir; pin_dir=$(mktemp -d)
  local sid="test-session-spoof"
  printf '%s\n' "$real_root" > "$pin_dir/ops-root-${sid}"

  local out
  out=$(cd "$sb" && echo "$(push_json)" | \
    env -u APEXYARD_OPS_DISABLE_PIN CLAUDE_CODE_SESSION_ID="$sid" APEXYARD_OPS_PIN_DIR="$pin_dir" \
    bash .claude/hooks/pre-push-gate.sh 2>&1 1>/dev/null)

  if echo "$out" | grep -qF "core.hooksPath"; then
    echo "FAIL [B2-spoofed-fork-marker-gets-no-hookspath-advice]: $out" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}B2-spoofed-fork-marker-gets-no-hookspath-advice "
  else
    echo "PASS [B2-spoofed-fork-marker-gets-no-hookspath-advice]"
    PASS=$((PASS+1))
  fi
  if echo "$out" | grep -qF "not an ApexYard fork"; then
    echo "PASS [B2-spoofed-fork-marker-gets-managed-clone-note]"
    PASS=$((PASS+1))
  else
    echo "FAIL [B2-spoofed-fork-marker-gets-managed-clone-note]: $out" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}B2-spoofed-fork-marker-gets-managed-clone-note "
  fi
  rm -rf "$sb" "$real_root" "$pin_dir"
}

# =====================================================================
# H1 negative tests (me2resh/apexyard#1366 / PR #1405 review / AgDR-0173)
#
# Each case configures a REAL .pre_push.commands entry that would leave
# MARKER_RAN if it ever executed, then feeds the hook a command whose TEXT
# merely mentions "git push" without being one. The old hook (still on
# `dev` as of this writing) ran the command list on every one of these —
# see the fail-before proof in the PR evidence. This hook must not.
# =====================================================================

# ---- H1-1: heredoc body mentioning a push ----
case_h1_heredoc() {
  local sb; sb=$(make_sandbox 0)
  local cmd
  cmd=$(printf 'cat <<EOF\nsee git push origin main for details\nEOF\n')
  run_hook "$sb" "$(json_cmd "$cmd")" 0 "" "H1-heredoc-body-does-not-run-commands"
  assert_no_marker "$sb" "H1-heredoc-body-does-not-run-commands"
  rm -rf "$sb"
}

# ---- H1-2: quoted string mentioning a push ----
case_h1_quoted_string() {
  local sb; sb=$(make_sandbox 0)
  local cmd='grep -n "git push origin main" some-file.txt'
  run_hook "$sb" "$(json_cmd "$cmd")" 0 "" "H1-quoted-string-does-not-run-commands"
  assert_no_marker "$sb" "H1-quoted-string-does-not-run-commands"
  rm -rf "$sb"
}

# ---- H1-3: commit message mentioning a push ----
case_h1_commit_message() {
  local sb; sb=$(make_sandbox 0)
  local cmd='git commit -m "docs: explain git push origin main in the runbook"'
  run_hook "$sb" "$(json_cmd "$cmd")" 0 "" "H1-commit-message-does-not-run-commands"
  assert_no_marker "$sb" "H1-commit-message-does-not-run-commands"
  rm -rf "$sb"
}

# ---- H1-4: echo mentioning a push ----
case_h1_echo() {
  local sb; sb=$(make_sandbox 0)
  local cmd='echo "reminder: run git push origin main after review"'
  run_hook "$sb" "$(json_cmd "$cmd")" 0 "" "H1-echo-does-not-run-commands"
  assert_no_marker "$sb" "H1-echo-does-not-run-commands"
  rm -rf "$sb"
}

case1
case2
case3
case4
case_no_valid_pin_gets_no_advice
case_pinned_linked_worktree_gets_advice
case_agdr_states_pinned_limit
case_h1_heredoc
case_h1_quoted_string
case_h1_commit_message
case_h1_echo
case_b2_managed_clone_short_note
case_b2_spoofed_fork_marker_gets_no_advice

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
