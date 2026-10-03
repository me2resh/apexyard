#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$ROOT/../settings.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash_entries=$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]] | length' "$SETTINGS")
[ "$bash_entries" -eq 1 ]
dispatcher_command=$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command][0]' "$SETTINGS")
grep -q 'dispatch-bash.sh' <<<"$dispatcher_command"
reviewer_entries=$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("block-reviewer-repo-mutation.sh"))] | length' "$SETTINGS")
[ "$reviewer_entries" -eq 0 ]

mkdir -p "$TMP/hooks"
cp "$ROOT/dispatch-bash.sh" "$TMP/hooks/dispatch-bash.sh"
cp "$ROOT/_lib-extract-pr.sh" "$TMP/hooks/_lib-extract-pr.sh"
cp "$ROOT/_lib-command-scrub.sh" "$TMP/hooks/_lib-command-scrub.sh"
chmod +x "$TMP/hooks/dispatch-bash.sh"

scripts='block-ambient-tracker-repo.sh block-privileged-escalation.sh require-skill-for-issue-create.sh require-migration-ticket.sh require-active-ticket.sh warn-review-marker-write.sh warn-isolated-build-risk.sh block-reviewer-repo-mutation.sh block-git-add-all.sh block-main-push.sh validate-branch-name.sh pre-push-gate.sh block-agent-routing-drift.sh check-secrets.sh block-onboarding-in-git.sh verify-commit-refs.sh validate-commit-format.sh require-agdr-for-arch-changes.sh warn-bootstrap-scope.sh suggest-ticket-template.sh validate-issue-structure.sh block-private-refs-in-public-repos.sh validate-pr-create.sh require-agdr-for-arch-pr.sh nudge-control-adversarial-test.sh block-unreviewed-merge.sh require-design-review-for-ui.sh block-merge-on-red-ci.sh require-architecture-review.sh detect-role-trigger.sh'
for script in $scripts; do
  cat > "$TMP/hooks/$script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
name=$(basename "$0")
printf '%s\n' "$name" >> "${DISPATCH_LOG:?}"
if [ "$name" = block-git-add-all.sh ] && grep -q 'git add -A' <<<"$input"; then
  exit 2
fi
if [ "${DISPATCH_FAIL_SCRIPT:-}" = "$name" ]; then
  exit "${DISPATCH_FAIL_EXIT:-1}"
fi
EOF
  chmod +x "$TMP/hooks/$script"
done

run() {
  local command="$1"
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$command" \
    | DISPATCH_LOG="$TMP/log" "$TMP/hooks/dispatch-bash.sh"
}

run true
grep -qx 'block-ambient-tracker-repo.sh' "$TMP/log"
grep -qx 'block-reviewer-repo-mutation.sh' "$TMP/log"
if grep -q 'block-unreviewed-merge.sh' "$TMP/log"; then
  exit 1
fi

# PR-create text in data must not route any PR-create hook.
for command in "printf '%s' 'gh pr create --title x'" \
  "$(printf "cat <<'TEXT'\ngh pr create --title x\nTEXT")"; do
  : > "$TMP/log"
  jq -nc --arg c "$command" '{tool_name:"Bash",tool_input:{command:$c}}' \
    | DISPATCH_LOG="$TMP/log" "$TMP/hooks/dispatch-bash.sh"
  if grep -q '^validate-pr-create.sh$' "$TMP/log"; then
    echo "FAIL: dispatcher routed quoted PR-create data" >&2
    exit 1
  fi
done

: > "$TMP/log"
run 'gh pr merge 42'
[ "$(grep -c '^block-unreviewed-merge.sh$' "$TMP/log")" -eq 1 ]

# A non-blocking hook failure must not suppress later gates.
: > "$TMP/log"
set +e
printf '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42"}}' \
  | DISPATCH_LOG="$TMP/log" DISPATCH_FAIL_SCRIPT=block-ambient-tracker-repo.sh "$TMP/hooks/dispatch-bash.sh" >/dev/null
rc=$?
set -e
[ "$rc" -eq 0 ]
[ "$(grep -c '^block-unreviewed-merge.sh$' "$TMP/log")" -eq 1 ]
[ "$(grep -c '^require-architecture-review.sh$' "$TMP/log")" -eq 1 ]

# me2resh/apexyard#1403: a merge-gate hook that cannot run its own check —
# reproduced here by a stub that sources a missing sibling library, which
# under POSIX mode ends the shell with exit 1 (not 2) before the hook's
# real logic ever runs — must still BLOCK the merge, not warn-and-continue
# like an ordinary advisory hook. `glab mr merge` reaches run_merge_gates
# with no preceding hook, keeping each sub-test isolated to exactly one
# merge-gate script at a time.
for gate in block-unreviewed-merge.sh require-design-review-for-ui.sh block-merge-on-red-ci.sh require-architecture-review.sh; do
  cp "$TMP/hooks/$gate" "$TMP/hooks/$gate.orig"
  cat > "$TMP/hooks/$gate" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
. "$(dirname "$0")/_lib-does-not-exist.sh"
echo "unreachable: POSIX mode should have exited already"
EOF
  chmod +x "$TMP/hooks/$gate"

  : > "$TMP/log"
  set +e
  printf '{"tool_name":"Bash","tool_input":{"command":"glab mr merge 42"}}' \
    | POSIXLY_CORRECT=1 DISPATCH_LOG="$TMP/log" "$TMP/hooks/dispatch-bash.sh" >/dev/null 2>"$TMP/stderr"
  rc=$?
  set -e

  cp "$TMP/hooks/$gate.orig" "$TMP/hooks/$gate"
  rm -f "$TMP/hooks/$gate.orig"

  if [ "$rc" -ne 2 ]; then
    echo "FAIL: $gate under POSIX + missing library did not block (rc=$rc, want 2)" >&2
    cat "$TMP/stderr" >&2
    exit 1
  fi
  if ! grep -qi 'BLOCKED' "$TMP/stderr"; then
    echo "FAIL: $gate blocked (rc=2) but printed no BLOCKED message" >&2
    cat "$TMP/stderr" >&2
    exit 1
  fi
done

# me2resh/apexyard#1403: run_merge_gate_hook must fail closed on EVERY way
# a merge-gate hook can die, not only the missing-library-under-POSIX case
# above. Exercise exit 1 (an ordinary non-zero, non-BLOCKED failure), exit
# 127 ("command not found" — the hook ran but its own logic hit a missing
# command), a bash syntax error (bash itself reports exit 2, so this one
# blocks the same way a real BLOCKED verdict does), and a process killed by
# a signal (bash reports 128+signal, e.g. 143 for SIGTERM). Each scenario
# replaces block-unreviewed-merge.sh alone; `glab mr merge` isolates the
# test to that one gate, same as the missing-library block above.
cp "$TMP/hooks/block-unreviewed-merge.sh" "$TMP/hooks/block-unreviewed-merge.sh.orig"
for scenario in exit-1 exit-127 syntax-error killed-by-signal; do
  case "$scenario" in
    exit-1)
      cat > "$TMP/hooks/block-unreviewed-merge.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 1
EOF
      ;;
    exit-127)
      cat > "$TMP/hooks/block-unreviewed-merge.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
this-command-does-not-exist-anywhere
EOF
      ;;
    syntax-error)
      cat > "$TMP/hooks/block-unreviewed-merge.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
if [ 1 -eq 1
EOF
      ;;
    killed-by-signal)
      cat > "$TMP/hooks/block-unreviewed-merge.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
kill -TERM $$
EOF
      ;;
  esac
  chmod +x "$TMP/hooks/block-unreviewed-merge.sh"

  : > "$TMP/log"
  set +e
  printf '{"tool_name":"Bash","tool_input":{"command":"glab mr merge 42"}}' \
    | DISPATCH_LOG="$TMP/log" "$TMP/hooks/dispatch-bash.sh" >/dev/null 2>"$TMP/stderr"
  rc=$?
  set -e

  if [ "$rc" -ne 2 ]; then
    echo "FAIL: block-unreviewed-merge.sh ($scenario) did not block (rc=$rc, want 2)" >&2
    cat "$TMP/stderr" >&2
    exit 1
  fi
done
cp "$TMP/hooks/block-unreviewed-merge.sh.orig" "$TMP/hooks/block-unreviewed-merge.sh"
rm -f "$TMP/hooks/block-unreviewed-merge.sh.orig"

for command in \
  'gh pr merge 42' \
  'gh api repos/example/pulls/42' \
  'glab mr merge 42' \
  'glab api projects/1/merge_requests/42' \
  'tracker_pr_merge 42'; do
  : > "$TMP/log"
  run "$command"
  [ "$(grep -c '^block-unreviewed-merge.sh$' "$TMP/log")" -eq 1 ]
done

# /approve-merge wraps tracker_pr_merge in bash -c. Prefix case misses that
# shape. is_merge_command must still route the four merge gates (AgDR-0162).
: > "$TMP/log"
run "bash -c 'tracker_pr_merge acme/app 42 squash true'"
[ "$(grep -c '^block-unreviewed-merge.sh$' "$TMP/log")" -eq 1 ]
[ "$(grep -c '^require-design-review-for-ui.sh$' "$TMP/log")" -eq 1 ]
[ "$(grep -c '^block-merge-on-red-ci.sh$' "$TMP/log")" -eq 1 ]
[ "$(grep -c '^require-architecture-review.sh$' "$TMP/log")" -eq 1 ]
: > "$TMP/log"
run "bash -c 'gh pr merge 42 --squash'"
[ "$(grep -c '^block-unreviewed-merge.sh$' "$TMP/log")" -eq 1 ]

# Compound commands that start with git add still contain a merge. The
# prefix case must not skip is_merge_command on that payload.
: > "$TMP/log"
run "git add foo && tracker_pr_merge acme/app 42 squash true"
[ "$(grep -c '^block-unreviewed-merge.sh$' "$TMP/log")" -eq 1 ]
[ "$(grep -c '^require-design-review-for-ui.sh$' "$TMP/log")" -eq 1 ]

# A git commit whose message names the wrapper is fail-closed: the parser
# sees the token. Merge gates run. They no-op or block on their own parse.
: > "$TMP/log"
run "git commit -m fix tracker_pr_merge wrapper"
[ "$(grep -c '^block-unreviewed-merge.sh$' "$TMP/log")" -eq 1 ]

: > "$TMP/log"
set +e
run 'git add -A'
rc=$?
set -e
[ "$rc" -eq 2 ]
[ "$(grep -c '^block-git-add-all.sh$' "$TMP/log")" -eq 1 ]

# Broken jq must not fail-open a merge. The real merge gates fail closed
# when they cannot parse the command and the raw payload looks merge-shaped.
broken_jq="$(mktemp -d)"
trap 'rm -rf "$TMP" "$broken_jq"' EXIT
cat > "$broken_jq/jq" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
chmod +x "$broken_jq/jq"

run_broken_jq() {
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
    | PATH="$broken_jq:${PATH}" "$ROOT/dispatch-bash.sh"
}

set +e
run_broken_jq 'true' >/dev/null
rc=$?
set -e
[ "$rc" -ne 2 ]

for command in \
  'gh pr merge 42' \
  'gh api repos/example/repo/pulls/42/merge' \
  'glab mr merge 42' \
  'glab api projects/1/merge_requests/42/merge' \
  'tracker_pr_merge 42'; do
  set +e
  run_broken_jq "$command" >/dev/null
  rc=$?
  set -e
  [ "$rc" -eq 2 ]
done

# me2resh/apexyard#1403 review finding A1: an unreadable (not missing)
# _lib-extract-pr.sh must BLOCK (exit 2) with a message naming the file,
# not silently exit 1. Before the fix, the dispatcher's own `[ -f ]` guard
# let `set -e` kill the whole script the moment the `.` source failed on a
# file it could not read, and Claude Code only blocks a tool call on exit
# 2 — an unreadable library used to let every Bash command through
# unblocked, not just merges.
#
# Both sandboxes below are full copies of $TMP/hooks (dispatch-bash.sh plus
# every stub gate script already set up earlier in this test file), so a
# non-merge command like `echo hello` runs the same as it does in the
# healthy case above and the only variable under test is the state of
# _lib-extract-pr.sh itself.
unreadable_lib_dir="$(mktemp -d)"
missing_lib_dir="$(mktemp -d)"
trap 'rm -rf "$TMP" "$broken_jq" "$unreadable_lib_dir" "$missing_lib_dir"' EXIT

cp -r "$TMP/hooks" "$unreadable_lib_dir/hooks"
chmod 000 "$unreadable_lib_dir/hooks/_lib-extract-pr.sh"

set +e
printf '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' \
  | DISPATCH_LOG="$TMP/log" bash "$unreadable_lib_dir/hooks/dispatch-bash.sh" >/dev/null 2>"$TMP/stderr"
rc=$?
set -e

if [ "$rc" -ne 2 ]; then
  echo "FAIL: unreadable _lib-extract-pr.sh did not block (rc=$rc, want 2)" >&2
  cat "$TMP/stderr" >&2
  exit 1
fi
if ! grep -qi 'BLOCKED' "$TMP/stderr"; then
  echo "FAIL: unreadable _lib-extract-pr.sh blocked (rc=2) but printed no BLOCKED message" >&2
  cat "$TMP/stderr" >&2
  exit 1
fi
if ! grep -q '_lib-extract-pr.sh' "$TMP/stderr"; then
  echo "FAIL: block message does not name the unreadable file" >&2
  cat "$TMP/stderr" >&2
  exit 1
fi

# Control: a MISSING (not unreadable) library must not make the dispatcher
# itself invent a new absence block on top of the merge-gate path. This
# sandbox uses stub merge gates that always exit 0, so the dispatcher's
# fail-closed "run the merge gates" path still returns 0 here. In a real
# install the same missing file makes each gate's `_require_lib` block
# every Bash command (AgDR-0169 Consequences). That is not a no-op.
cp -r "$TMP/hooks" "$missing_lib_dir/hooks"
rm -f "$missing_lib_dir/hooks/_lib-extract-pr.sh"

set +e
printf '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' \
  | DISPATCH_LOG="$TMP/log" bash "$missing_lib_dir/hooks/dispatch-bash.sh" >/dev/null 2>"$TMP/stderr"
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
  echo "FAIL: with stub merge gates, a MISSING _lib-extract-pr.sh must not make the dispatcher invent its own absence block" >&2
  cat "$TMP/stderr" >&2
  exit 1
fi

echo "PASS: bash dispatcher"
