#!/bin/bash
# Must-block bypass shapes for AgDR-0181 / #1459 security narrowing.
# Each case must fail at commit 39c5b95 (scrub used for routing / weak deny)
# and pass against the current hooks (raw routing + raw-deny gate).
#
# macOS /bin/bash 3.2: no associative arrays, no mapfile, no ${var,,}.
set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOKS="${HOOKS_OVERRIDE:-$ROOT/.claude/hooks}"
SNAP_HOOKS="${SNAP_HOOKS:-/tmp/ay-1459-snap-39c5b95}"
CONFIG_DEFAULTS="${CONFIG_DEFAULTS_OVERRIDE:-$ROOT/.claude/project-config.defaults.json}"
GIT_FIXTURE="${GIT_FIXTURE:-$ROOT/.claude/hooks/tests/fixtures/empty-gitdir.tar.gz}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
fail_before_pass=0
fail_before_fail=0

# Isolate from the operator session pin and any ambient CLAUDE_CODE_SESSION_ID.
export APEXYARD_OPS_DISABLE_PIN=1
unset CLAUDE_CODE_SESSION_ID || true

check() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "PASS [$label]"; pass=$((pass + 1))
  else
    echo "FAIL [$label]: expected $want, got $got" >&2
    fail=$((fail + 1))
  fi
}

seed_git_repo() {
  local dest="$1"
  if [ ! -f "$GIT_FIXTURE" ]; then
    echo "FAIL: missing git fixture $GIT_FIXTURE" >&2
    exit 1
  fi
  tar xzf "$GIT_FIXTURE" -C "$dest"
}

# Isolated temp repo for every git-using fixture. Never touch the worktree.
setup_ticket_sandbox() {
  local dest="$1" hooks_src="$2"
  rm -rf "$dest"
  mkdir -p "$dest/.claude/hooks" "$dest/.claude/session" "$dest/src"
  : > "$dest/onboarding.yaml"
  : > "$dest/apexyard.projects.yaml"
  cp "$CONFIG_DEFAULTS" "$dest/.claude/project-config.defaults.json"
  for file in require-active-ticket.sh _lib-detect-bash-write.sh \
    _lib-command-scrub.sh _lib-mask-quoted.sh _lib-read-config.sh \
    _lib-path-resolve.sh _lib-active-ticket.sh _lib-ops-root.sh; do
    [ -f "$hooks_src/$file" ] && cp "$hooks_src/$file" "$dest/.claude/hooks/$file"
  done
  # No active ticket — writes to src/app.ts must block.
  rm -f "$dest/.claude/session/current-ticket"
  seed_git_repo "$dest"
}

ticket_rc() {
  local dest="$1" cmd="$2" payload rc
  payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  (cd "$dest" && printf '%s' "$payload" | APEXYARD_OPS_DISABLE_PIN=1 bash .claude/hooks/require-active-ticket.sh >/dev/null 2>&1)
  rc=$?
  printf '%s' "$rc"
}

setup_dispatch_sandbox() {
  local dest="$1" hooks_src="$2"
  rm -rf "$dest"
  mkdir -p "$dest/hooks"
  cp "$hooks_src/dispatch-bash.sh" "$dest/hooks/dispatch-bash.sh"
  [ -f "$hooks_src/_lib-extract-pr.sh" ] && cp "$hooks_src/_lib-extract-pr.sh" "$dest/hooks/_lib-extract-pr.sh"
  [ -f "$hooks_src/_lib-command-scrub.sh" ] && cp "$hooks_src/_lib-command-scrub.sh" "$dest/hooks/_lib-command-scrub.sh"
  chmod +x "$dest/hooks/dispatch-bash.sh"
  local script
  for script in block-ambient-tracker-repo.sh block-privileged-escalation.sh \
    require-skill-for-issue-create.sh require-migration-ticket.sh \
    require-active-ticket.sh suggest-mcp-search.sh warn-review-marker-write.sh \
    warn-isolated-build-risk.sh block-reviewer-repo-mutation.sh \
    block-git-add-all.sh block-main-push.sh validate-branch-name.sh \
    pre-push-gate.sh block-agent-routing-drift.sh check-secrets.sh \
    block-onboarding-in-git.sh verify-commit-refs.sh validate-commit-format.sh \
    require-agdr-for-arch-changes.sh warn-bootstrap-scope.sh \
    suggest-ticket-template.sh validate-issue-structure.sh \
    block-private-refs-in-public-repos.sh validate-pr-create.sh \
    require-agdr-for-arch-pr.sh nudge-control-adversarial-test.sh \
    block-unreviewed-merge.sh require-design-review-for-ui.sh \
    block-merge-on-red-ci.sh require-architecture-review.sh detect-role-trigger.sh
  do
    cat > "$dest/hooks/$script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
name=$(basename "$0")
printf '%s\n' "$name" >> "${DISPATCH_LOG:?}"
EOF
    chmod +x "$dest/hooks/$script"
  done
}

dispatch_has_merge() {
  local dest cmd log
  dest="$1"
  cmd="$2"
  log="$dest/log"
  : > "$log"
  jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' \
    | DISPATCH_LOG="$log" "$dest/hooks/dispatch-bash.sh" >/dev/null 2>&1 || true
  if grep -q '^block-unreviewed-merge.sh$' "$log"; then
    printf yes
  else
    printf no
  fi
}

# Build cases as a label+command list via a directory of files.
CASES_DIR="$TMP/cases"
mkdir -p "$CASES_DIR"
i=0
add_case() {
  local label="$1" cmd="$2"
  i=$((i + 1))
  printf '%s' "$label" > "$CASES_DIR/$i.label"
  printf '%s' "$cmd" > "$CASES_DIR/$i.cmd"
}

add_case 'hash after command substitution' 'echo $(true)#; echo x > src/app.ts'
add_case 'backslash-eval' "\\eval 'echo x > src/app.ts'"
add_case 'quoted-eval word' "\"eval\" 'echo x > src/app.ts'"
add_case 'bin-sh -c' "/bin/sh -c 'echo x > src/app.ts'"
add_case 'bash -lc' "bash -lc 'echo x > src/app.ts'"
add_case 'sh -ec' "sh -ec 'echo x > src/app.ts'"
add_case 'sh -xc' "sh -xc 'echo x > src/app.ts'"
add_case 'quoted-sh -c' "'sh' -c 'echo x > src/app.ts'"
add_case 'dash -c' "dash -c 'echo x > src/app.ts'"
add_case 'pipe into bash' "echo 'echo x > src/app.ts' | bash"
add_case 'bash heredoc body write' "$(printf "bash <<'E'\necho x > src/app.ts\nE")"
add_case 'sh -s heredoc body write' "$(printf "sh -s <<EOF\necho x > src/app.ts\nEOF")"
add_case 'dot process-substitution' ". <(echo 'echo x > src/app.ts')"
add_case 'trap EXIT write' "trap 'echo x > src/app.ts' EXIT"
add_case 'awk redirect in BEGIN' "awk 'BEGIN{print 1 > \"src/app.ts\"}'"
add_case 'awk system write' "awk 'BEGIN{system(\"echo x > src/app.ts\")}'"
add_case 'unquoted heredoc with command substitution' "$(printf 'cat > /tmp/x <<EOF\n$(echo x > src/app.ts)\nEOF')"

# Deny-gate controls: 39c5b95 already blocked these via raw fallback or a
# still-visible line-2 redirect. They must keep blocking after the narrowing.
CTRL_DIR="$TMP/controls"
mkdir -p "$CTRL_DIR"
ci=0
add_ctrl() {
  local label="$1" cmd="$2"
  ci=$((ci + 1))
  printf '%s' "$label" > "$CTRL_DIR/$ci.label"
  printf '%s' "$cmd" > "$CTRL_DIR/$ci.cmd"
}
add_ctrl 'here-string then write' "$(printf 'cat <<<ignored\necho x > src/app.ts')"
add_ctrl 'arithmetic shift then write' "$(printf '(( y = 1 << true ))\necho x > src/app.ts')"
add_ctrl 'case pattern in command substitution' 'case x in "$(echo x > src/app.ts)") ;; esac'

# Fail-before against 39c5b95 snapshot (expect allow / exit 0 — the bypass).
if [ -d "$SNAP_HOOKS" ] && [ -f "$SNAP_HOOKS/require-active-ticket.sh" ]; then
  setup_ticket_sandbox "$TMP/snap_ticket" "$SNAP_HOOKS"
  n=1
  while [ -f "$CASES_DIR/$n.label" ]; do
    label=$(cat "$CASES_DIR/$n.label")
    cmd=$(cat "$CASES_DIR/$n.cmd")
    got=$(ticket_rc "$TMP/snap_ticket" "$cmd")
    if [ "$got" = "0" ]; then
      echo "FAIL-BEFORE OK [ticket/$label]: 39c5b95 allowed (rc=0)"
      fail_before_pass=$((fail_before_pass + 1))
    else
      echo "FAIL-BEFORE MISS [ticket/$label]: 39c5b95 rc=$got (wanted 0 to prove bypass)" >&2
      fail_before_fail=$((fail_before_fail + 1))
    fi
    n=$((n + 1))
  done
else
  echo "WARN: SNAP_HOOKS missing at $SNAP_HOOKS — skip fail-before proofs" >&2
fi

# Pass-after against current hooks (expect block / exit 2).
setup_ticket_sandbox "$TMP/cur_ticket" "$HOOKS"
n=1
while [ -f "$CASES_DIR/$n.label" ]; do
  label=$(cat "$CASES_DIR/$n.label")
  cmd=$(cat "$CASES_DIR/$n.cmd")
  got=$(ticket_rc "$TMP/cur_ticket" "$cmd")
  check "ticket/$label" 2 "$got"
  n=$((n + 1))
done

# Deny-gate controls must still block (no fail-before requirement).
n=1
while [ -f "$CTRL_DIR/$n.label" ]; do
  label=$(cat "$CTRL_DIR/$n.label")
  cmd=$(cat "$CTRL_DIR/$n.cmd")
  got=$(ticket_rc "$TMP/cur_ticket" "$cmd")
  check "ticket-ctrl/$label" 2 "$got"
  n=$((n + 1))
done

# ---------------------------------------------------------------------------
# Dispatcher routing: merge wrappers must still reach the merge gate
# ---------------------------------------------------------------------------
MERGE_CASES_DIR="$TMP/merge_cases"
mkdir -p "$MERGE_CASES_DIR"
mi=0
add_merge() {
  local label="$1" cmd="$2"
  mi=$((mi + 1))
  printf '%s' "$label" > "$MERGE_CASES_DIR/$mi.label"
  printf '%s' "$cmd" > "$MERGE_CASES_DIR/$mi.cmd"
}
add_merge 'bash -lc merge' "bash -lc 'gh pr merge 42'"
add_merge 'pipe into bash merge' "echo 'gh pr merge 42' | bash"
add_merge 'bash heredoc merge body' "$(printf "bash <<'EOF'\ngh pr merge 42\nEOF")"
add_merge 'quoted api merge after cd' "cd /tmp && echo 'gh api repos/acme/app/pulls/42/merge'"

if [ -d "$SNAP_HOOKS" ] && [ -f "$SNAP_HOOKS/dispatch-bash.sh" ]; then
  setup_dispatch_sandbox "$TMP/snap_dispatch" "$SNAP_HOOKS"
  n=1
  while [ -f "$MERGE_CASES_DIR/$n.label" ]; do
    label=$(cat "$MERGE_CASES_DIR/$n.label")
    cmd=$(cat "$MERGE_CASES_DIR/$n.cmd")
    got=$(dispatch_has_merge "$TMP/snap_dispatch" "$cmd")
    if [ "$got" = "no" ]; then
      echo "FAIL-BEFORE OK [dispatch/$label]: 39c5b95 missed merge gate"
      fail_before_pass=$((fail_before_pass + 1))
    else
      echo "FAIL-BEFORE MISS [dispatch/$label]: 39c5b95 already routed (got $got)" >&2
      fail_before_fail=$((fail_before_fail + 1))
    fi
    n=$((n + 1))
  done
fi

setup_dispatch_sandbox "$TMP/cur_dispatch" "$HOOKS"
n=1
while [ -f "$MERGE_CASES_DIR/$n.label" ]; do
  label=$(cat "$MERGE_CASES_DIR/$n.label")
  cmd=$(cat "$MERGE_CASES_DIR/$n.cmd")
  got=$(dispatch_has_merge "$TMP/cur_dispatch" "$cmd")
  check "dispatch/$label" yes "$got"
  n=$((n + 1))
done

# Ordinary false positives must still pass (ticket gate allows them).
setup_ticket_sandbox "$TMP/fp_ticket" "$HOOKS"
check 'fp git log format' 0 "$(ticket_rc "$TMP/fp_ticket" "git log --format='%h > %s'")"
check 'fp grep pattern' 0 "$(ticket_rc "$TMP/fp_ticket" "grep -nE 'a|>|b' file")"
check 'fp echo quoted redirect text' 0 "$(ticket_rc "$TMP/fp_ticket" "echo '  >> TEXT'")"
check 'fp quoted heredoc scratch write' 0 \
  "$(ticket_rc "$TMP/fp_ticket" "$(printf "cat > /tmp/run.log <<'TEXT'\n> src/app.ts\nTEXT")")"

printf 'RESULT: %s passed, %s failed; fail-before proofs %s ok / %s missed\n' \
  "$pass" "$fail" "$fail_before_pass" "$fail_before_fail"
[ "$fail" -eq 0 ] && [ "$fail_before_fail" -eq 0 ]
