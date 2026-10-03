#!/bin/bash
# Must-block bypass shapes for AgDR-0181 / #1459 allowlist scrubbing.
# Existing cases must fail at commit 39c5b95 (scrub used for routing /
# weak deny). New allowlist cases must fail at d5e7ce4 (deny-list scrub).
# Pass-after expects the current hooks to block (ticket gate exit 2).
#
# macOS /bin/bash 3.2: no associative arrays, no mapfile, no ${var,,}.
set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOKS="${HOOKS_OVERRIDE:-$ROOT/.claude/hooks}"
SNAP_HOOKS="${SNAP_HOOKS:-}"
CONFIG_DEFAULTS="${CONFIG_DEFAULTS_OVERRIDE:-$ROOT/.claude/project-config.defaults.json}"
TMP=$(mktemp -d)
export GIT_CEILING_DIRECTORIES="$TMP"
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

# Isolated empty git dir at run time. Never unpack a binary fixture.
# Empty template avoids writing .git/hooks (sandbox may deny that path).
seed_git_repo() {
  local dest="$1"
  (cd "$dest" && git init -q --template=)
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
  # _lib-extract-pr.sh sources the tracker library. Copy it so the sandbox
  # does not depend on finding it through the surrounding git checkout.
  [ -f "$hooks_src/_lib-tracker.sh" ] && cp "$hooks_src/_lib-tracker.sh" "$dest/hooks/_lib-tracker.sh"
  chmod +x "$dest/hooks/dispatch-bash.sh"
  local script
  for script in block-ambient-tracker-repo.sh block-privileged-escalation.sh \
    require-skill-for-issue-create.sh require-migration-ticket.sh \
    require-active-ticket.sh warn-review-marker-write.sh \
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

# CI supplies a temporary repository containing the pinned PR snapshots.
# Clone it into this test's own temporary directory before running git archive.
# Local runs may omit it and retain visible, non-failing snapshot warnings.
SOURCE_REPO=""
if [ -n "${APEXYARD_SNAPSHOT_REPO:-}" ]; then
  SOURCE_REPO="$TMP/source"
  if ! git clone -q --no-checkout --no-hardlinks "$APEXYARD_SNAPSHOT_REPO" "$SOURCE_REPO" 2>/dev/null; then
    SOURCE_REPO=""
  fi
fi

missing_snapshot() {
  if [ "${REQUIRE_SNAPSHOTS:-0}" = "1" ]; then
    echo "FAIL: required fail-before snapshot $1 is missing" >&2
    fail=$((fail + 1))
  else
    echo "WARN: fail-before snapshot $1 is missing; local proof skipped"
  fi
}

archive_snapshot() {
  local sha="$1" dest="$2"
  [ -n "$SOURCE_REPO" ] || return 1
  mkdir -p "$dest"
  if git -C "$SOURCE_REPO" archive "$sha" .claude/hooks >"$TMP/$sha.tar" 2>/dev/null; then
    tar -xf "$TMP/$sha.tar" -C "$dest" || return 1
    [ -f "$dest/.claude/hooks/require-active-ticket.sh" ] || return 1
    return 0
  fi
  return 1
}

# Full 40-character SHAs for the reviewed PR #1466 snapshots (AgDR-0207).
# Short prefixes can become ambiguous as history grows.
SNAP_ARCHIVE="$TMP/39c5b959f0544785c643c6945b487ec579b4a035"
D5_ARCHIVE="$TMP/d5e7ce4d50e07bd0bd026230e1fb78714e809a27"
HEAD_ARCHIVE="$TMP/1fea7308d0a6de4412198b1bc645ada8a47a8f05"
if [ "${REQUIRE_SNAPSHOTS:-0}" != "1" ] && [ -n "$SNAP_HOOKS" ] \
    && [ -f "$SNAP_HOOKS/require-active-ticket.sh" ]; then
  :
elif archive_snapshot 39c5b959f0544785c643c6945b487ec579b4a035 "$SNAP_ARCHIVE"; then
  SNAP_HOOKS="$SNAP_ARCHIVE/.claude/hooks"
else
  SNAP_HOOKS=""
  missing_snapshot 39c5b959f0544785c643c6945b487ec579b4a035
fi
if archive_snapshot d5e7ce4d50e07bd0bd026230e1fb78714e809a27 "$D5_ARCHIVE"; then
  D5_HOOKS="$D5_ARCHIVE/.claude/hooks"
else
  D5_HOOKS=""
  missing_snapshot d5e7ce4d50e07bd0bd026230e1fb78714e809a27
fi
if archive_snapshot 1fea7308d0a6de4412198b1bc645ada8a47a8f05 "$HEAD_ARCHIVE"; then
  HEAD_HOOKS="$HEAD_ARCHIVE/.claude/hooks"
else
  HEAD_HOOKS=""
  missing_snapshot 1fea7308d0a6de4412198b1bc645ada8a47a8f05
fi

if [ "${SNAPSHOT_PREFLIGHT_ONLY:-0}" = "1" ]; then
  printf 'Snapshot preflight: %s failed\n' "$fail"
  [ "$fail" -eq 0 ]
  exit $?
fi

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

# Deny/control cases that already blocked under older snaps.
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
# A leading assignment can name a program that git or gh runs, so it returns raw.
add_ctrl 'GIT_PAGER assignment before git log' "GIT_PAGER='sh -c \"echo x > src/app.ts\"' git log -1"
add_ctrl 'PAGER assignment before git log' "PAGER='sh -c \"echo x > src/app.ts\"' git log -1"
add_ctrl 'GIT_EXTERNAL_DIFF assignment before git diff' "GIT_EXTERNAL_DIFF='sh -c \"echo x > src/app.ts\"' git diff"
add_ctrl 'GIT_SSH_COMMAND assignment before git fetch' "GIT_SSH_COMMAND='sh -c \"echo x > src/app.ts\"' git fetch origin"
add_ctrl 'GIT_EDITOR assignment before git commit' "GIT_EDITOR='sh -c \"echo x > src/app.ts\"' git commit"
add_ctrl 'GIT_SEQUENCE_EDITOR assignment before git commit' "GIT_SEQUENCE_EDITOR='sh -c \"echo x > src/app.ts\"' git commit"
add_ctrl 'EDITOR assignment before git commit' "EDITOR='sh -c \"echo x > src/app.ts\"' git commit"
add_ctrl 'GH_PAGER assignment before gh pr view' "GH_PAGER='sh -c \"echo x > src/app.ts\"' gh pr view 1"
add_ctrl 'BROWSER assignment before gh pr view --web' "BROWSER='sh -c \"echo x > src/app.ts\"' gh pr view 1 --web"
# git subcommands that take a program to run in an option are not allowlisted.
add_ctrl 'git grep --open-files-in-pager' "git grep --open-files-in-pager='sh -c \"echo x > src/app.ts\"' foo"
add_ctrl 'git grep -O' "git grep -O'sh -c \"echo x > src/app.ts\"' foo"
add_ctrl 'git fetch --upload-pack' "git fetch --upload-pack='sh -c \"echo x > src/app.ts\"' origin"
add_ctrl 'git push --receive-pack' "git push --receive-pack='sh -c \"echo x > src/app.ts\"' origin"

# New allowlist cases that bypassed at d5e7ce4 (deny-list scrub).
ALLOW_DIR="$TMP/allow_cases"
mkdir -p "$ALLOW_DIR"
ai=0
add_allow() {
  local label="$1" cmd="$2"
  ai=$((ai + 1))
  printf '%s' "$label" > "$ALLOW_DIR/$ai.label"
  printf '%s' "$cmd" > "$ALLOW_DIR/$ai.cmd"
}
add_allow 'git -c alias write' "git -c alias.w='!echo x > src/app.ts' w"
add_allow 'git rebase --exec' "git rebase --exec 'echo x > src/app.ts'"
add_allow 'gnu sed e flag' "sed -n '1e echo x > src/app.ts' in.txt"
add_allow 'watch quoted write' "watch 'echo x > src/app.ts'"
add_allow 'script -c' "script -c 'echo x > src/app.ts' /tmp/typescript"
add_allow 'flock -c' "flock /tmp/lock -c 'echo x > src/app.ts'"
add_allow 'make recipe heredoc' "$(printf "make -f - <<'EOF'\nall:\n\techo x > src/app.ts\nEOF")"
add_allow 'ed bang shell' "$(printf "ed <<'EOF'\n!echo x > src/app.ts\nEOF")"
add_allow 'pwsh -c' "pwsh -c 'echo x > src/app.ts'"
add_allow 'busybox ash -c' "busybox ash -c 'echo x > src/app.ts'"
add_allow 'tcsh -c' "tcsh -c 'echo x > src/app.ts'"
add_allow 'su -c' "su -c 'echo x > src/app.ts'"
add_allow 'ssh localhost' "ssh localhost 'echo x > src/app.ts'"
add_allow 'parallel' "parallel 'echo {} > src/app.ts' ::: x"
add_allow 'sqlite3 shell' "sqlite3 ':memory:' '.shell echo x > src/app.ts'"
add_allow 'vim -es bang' "vim -es -c '!echo x > src/app.ts' -c q"
add_allow 'tmux new -d' "tmux new -d 'echo x > src/app.ts'"
add_allow 'npx -c' "npx -c 'echo x > src/app.ts'"
add_allow 'git -c pager then log' "git -c core.pager='echo x > src/app.ts' log"
add_allow 'git alias config write' "git config alias.w '!echo x > src/app.ts'"
add_allow 'gh extension' "gh synth-ext run -- 'echo x > src/app.ts'"

# Extra must-block shapes. d5e7ce4 already blocked the shell forms via its
# deny list, so they have no d5 fail-before proof. Pass-after still requires
# the allowlist to keep blocking them.
EXTRA_DIR="$TMP/extra_cases"
mkdir -p "$EXTRA_DIR"
ei=0
add_extra() {
  local label="$1" cmd="$2"
  ei=$((ei + 1))
  printf '%s' "$label" > "$EXTRA_DIR/$ei.label"
  printf '%s' "$cmd" > "$EXTRA_DIR/$ei.cmd"
}
add_extra 'assign then bash -c' "FOO=x bash -c 'echo x > src/app.ts'"
add_extra 'time bash -c' "time bash -c 'echo x > src/app.ts'"
add_extra 'bang sh -c' "! sh -c 'echo x > src/app.ts'"
add_extra 'brace group sh -c' "{ sh -c 'echo x > src/app.ts'; }"
add_extra 'if then sh -c' "if true; then sh -c 'echo x > src/app.ts'; fi"
add_extra 'double-quoted command substitution write' 'x="$(echo hi > src/app.ts)"'

# #1480 write-detector gaps. These forms missed on dev / AgDR-0181 residue.
# Pass-after must block (exit 2). Fail-before is proven outside this file
# against an unfixed detector copy — never asserted here.
GAP_DIR="$TMP/gap_cases"
mkdir -p "$GAP_DIR"
gi=0
add_gap() {
  local label="$1" cmd="$2"
  gi=$((gi + 1))
  printf '%s' "$label" > "$GAP_DIR/$gi.label"
  printf '%s' "$cmd" > "$GAP_DIR/$gi.cmd"
}
add_gap 'git log --output=file' 'git log --output=src/app.ts'
add_gap 'git log --output file' 'git log --output src/app.ts'
add_gap 'git diff --output=file' 'git diff --output=src/app.ts'
add_gap 'git diff --output file' 'git diff --output src/app.ts'
add_gap 'sort -o file' 'sort -o src/app.ts input.txt'
add_gap 'yq -i file' 'yq -i ".a=1" src/app.ts'
add_gap 'python3 -Bc open w' "python3 -Bc \"open('src/app.ts','w').write('x')\""

# Heredoc bodies start on the next line. Commands after the opener must still
# be checked against the allowlist on the opener line.
HEREDOC_DIR="$TMP/heredoc_cases"
mkdir -p "$HEREDOC_DIR"
hi=0
add_heredoc() {
  local label="$1" cmd="$2"
  hi=$((hi + 1))
  printf '%s' "$label" > "$HEREDOC_DIR/$hi.label"
  printf '%s' "$cmd" > "$HEREDOC_DIR/$hi.cmd"
}
add_heredoc 'quoted opener pipe bash' "$(printf "cat <<'EOF' | bash\necho hi > src/app.ts\nEOF")"
add_heredoc 'quoted opener pipe sh -s' "$(printf "cat <<'EOF' | sh -s\necho hi > src/app.ts\nEOF")"
add_heredoc 'unquoted opener pipe bash' "$(printf "cat <<EOF | bash\necho hi > src/app.ts\nEOF")"
add_heredoc 'quoted opener semicolon bash -c' "$(printf "cat <<'EOF'; bash -c 'echo hi > src/app.ts'\necho hi > src/app.ts\nEOF")"
add_heredoc 'quoted opener semicolon eval' "$(printf "cat <<'EOF'; eval 'echo hi > src/app.ts'\necho hi > src/app.ts\nEOF")"
add_heredoc 'quoted opener pipe xargs sh -c' "$(printf "cat <<'EOF' | xargs -I{} sh -c 'echo hi > src/app.ts'\necho hi > src/app.ts\nEOF")"

FP_MARKDOWN_CMD=$(printf "cat > /tmp/x <<'EOF'\n# Markdown\n> quoted text\nEOF")
FP_GREP_CMD=$(printf "cat <<'EOF' | grep x\nx > src/app.ts\nEOF")
FP_TWO_HEREDOC_CMD=$(printf "cat <<'A' <<'B' | grep x\nfirst > src/app.ts\nA\nsecond > src/app.ts\nB")

fail_before_ticket() {
  local snap="$1" tag="$2" cases_dir="$3"
  local n label cmd got
  [ -n "$snap" ] && [ -d "$snap" ] && [ -f "$snap/require-active-ticket.sh" ] || return 0
  setup_ticket_sandbox "$TMP/snap_ticket_$tag" "$snap"
  n=1
  while [ -f "$cases_dir/$n.label" ]; do
    label=$(cat "$cases_dir/$n.label")
    cmd=$(cat "$cases_dir/$n.cmd")
    got=$(ticket_rc "$TMP/snap_ticket_$tag" "$cmd")
    if [ "$got" = "0" ]; then
      echo "FAIL-BEFORE OK [ticket-$tag/$label]: allowed (rc=0)"
      fail_before_pass=$((fail_before_pass + 1))
    else
      echo "FAIL-BEFORE MISS [ticket-$tag/$label]: rc=$got (wanted 0 to prove bypass)" >&2
      fail_before_fail=$((fail_before_fail + 1))
    fi
    n=$((n + 1))
  done
}

# Fail-before against 39c5b95 snapshot (expect allow / exit 0 — the bypass).
if [ -d "$SNAP_HOOKS" ] && [ -f "$SNAP_HOOKS/require-active-ticket.sh" ]; then
  fail_before_ticket "$SNAP_HOOKS" "39c5b95" "$CASES_DIR"
fi

# Fail-before against d5e7ce4 for the new allowlist cases.
if [ -n "$D5_HOOKS" ]; then
  fail_before_ticket "$D5_HOOKS" "d5e7ce4" "$ALLOW_DIR"
fi

if [ -n "$HEAD_HOOKS" ]; then
  # These six bypasses must all allow at 1fea730 and block after the fix.
  fail_before_ticket "$HEAD_HOOKS" "1fea730" "$HEREDOC_DIR"

  # The ordinary quoted cases already pass at 1fea730. Its single-delimiter
  # gate incorrectly blocks the second body in the two-heredoc case.
  setup_ticket_sandbox "$TMP/head_fp_ticket" "$HEAD_HOOKS"
  check 'baseline fp quoted heredoc markdown scratch write' 0 \
    "$(ticket_rc "$TMP/head_fp_ticket" "$FP_MARKDOWN_CMD")"
  check 'baseline fp heredoc pipe grep with redirect text' 0 \
    "$(ticket_rc "$TMP/head_fp_ticket" "$FP_GREP_CMD")"
  check 'baseline fp two heredoc bodies in order' 2 \
    "$(ticket_rc "$TMP/head_fp_ticket" "$FP_TWO_HEREDOC_CMD")"
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

n=1
while [ -f "$ALLOW_DIR/$n.label" ]; do
  label=$(cat "$ALLOW_DIR/$n.label")
  cmd=$(cat "$ALLOW_DIR/$n.cmd")
  got=$(ticket_rc "$TMP/cur_ticket" "$cmd")
  check "ticket-allow/$label" 2 "$got"
  n=$((n + 1))
done

n=1
while [ -f "$EXTRA_DIR/$n.label" ]; do
  label=$(cat "$EXTRA_DIR/$n.label")
  cmd=$(cat "$EXTRA_DIR/$n.cmd")
  got=$(ticket_rc "$TMP/cur_ticket" "$cmd")
  check "ticket-extra/$label" 2 "$got"
  n=$((n + 1))
done

n=1
while [ -f "$GAP_DIR/$n.label" ]; do
  label=$(cat "$GAP_DIR/$n.label")
  cmd=$(cat "$GAP_DIR/$n.cmd")
  got=$(ticket_rc "$TMP/cur_ticket" "$cmd")
  check "ticket-gap1480/$label" 2 "$got"
  n=$((n + 1))
done

n=1
while [ -f "$HEREDOC_DIR/$n.label" ]; do
  label=$(cat "$HEREDOC_DIR/$n.label")
  cmd=$(cat "$HEREDOC_DIR/$n.cmd")
  got=$(ticket_rc "$TMP/cur_ticket" "$cmd")
  check "ticket-heredoc/$label" 2 "$got"
  n=$((n + 1))
done

# Controls must still block (no fail-before requirement).
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

# #1489 review regressions. Do not apply these to the historical #1459 proof.
add_merge 'F1.1 echo then quoted API' "echo checking; gh api -X PUT 'repos/me2resh/apexyard/pulls/1497/merge' -f merge_method=squash"
add_merge 'F1.2 grep then quoted API' 'grep -q ok status.txt && gh api --method PUT "repos/o/r/pulls/7/merge"'
add_merge 'F1.3 quoted API then echo line' $'gh api -X PUT "repos/o/r/pulls/7/merge" -f merge_method=squash\necho merged'
add_merge 'F1.4 cd API then echo line' $'cd /x && gh api -X PUT "repos/o/r/pulls/7/merge"\necho done'
add_merge 'F2.1 rg preprocessor payload' "echo 'gh pr merge 7 --squash' > m.sh; rg --pre sh . m.sh"
add_merge 'F2.2 git hook payload' "echo x; echo 'gh pr merge 7 --squash' > .git/hooks/pre-commit; git commit --allow-empty -m x"
add_merge 'F2.3 git external diff payload' "echo '[diff]' >> .git/config; echo 'external = sh -c \"gh pr merge 7\" #' >> .git/config; git diff"
add_merge 'sort compressor payload' "echo 'gh pr merge 7' > m.sh; sort --compress-program=./m.sh input.txt"

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
check 'fp printf quoted redirect text' 0 "$(ticket_rc "$TMP/fp_ticket" "printf '%s\n' 'a > b'")"
check 'fp quoted heredoc scratch write' 0 \
  "$(ticket_rc "$TMP/fp_ticket" "$(printf "cat > /tmp/run.log <<'TEXT'\n> src/app.ts\nTEXT")")"
check 'fp quoted heredoc with nested markers' 0 \
  "$(ticket_rc "$TMP/fp_ticket" "$(printf "cat > /tmp/x <<'EOF'\n\`date\`\n\$(echo hi)\nbash\n> src/app.ts\ngh pr merge 1\nEOF")")"
check 'fp gh pr comment body-file heredoc' 0 \
  "$(ticket_rc "$TMP/fp_ticket" "$(printf "gh pr comment 1 --body-file - <<'EOF'\nsee \`code\` and > quote\nEOF")")"
check 'fp quoted heredoc markdown scratch write' 0 "$(ticket_rc "$TMP/fp_ticket" "$FP_MARKDOWN_CMD")"
check 'fp heredoc pipe grep with redirect text' 0 "$(ticket_rc "$TMP/fp_ticket" "$FP_GREP_CMD")"
check 'fp two heredoc bodies in order' 0 "$(ticket_rc "$TMP/fp_ticket" "$FP_TWO_HEREDOC_CMD")"

# Scrubber must stay silent on stderr (GNU tr portability).
# shellcheck source=/dev/null
. "$HOOKS/_lib-command-scrub.sh"
errf="$TMP/scrub-stderr"
: > "$errf"
scrub_bash_command "cat file" >/dev/null 2>"$errf"
if [ -s "$errf" ]; then
  echo "FAIL [stderr plain read]: $(tr '\n' ' ' <"$errf")" >&2
  fail=$((fail + 1))
else
  echo "PASS [stderr plain read]"; pass=$((pass + 1))
fi
: > "$errf"
scrub_bash_command 'printf %s \foo' >/dev/null 2>"$errf"
if [ -s "$errf" ]; then
  echo "FAIL [stderr backslash cmd]: $(tr '\n' ' ' <"$errf")" >&2
  fail=$((fail + 1))
else
  echo "PASS [stderr backslash cmd]"; pass=$((pass + 1))
fi

printf 'RESULT: %s passed, %s failed; fail-before proofs %s ok / %s missed\n' \
  "$pass" "$fail" "$fail_before_pass" "$fail_before_fail"
[ "$fail" -eq 0 ] && [ "$fail_before_fail" -eq 0 ]
