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
chmod +x "$TMP/hooks/dispatch-bash.sh"

scripts='block-ambient-tracker-repo.sh block-privileged-escalation.sh require-skill-for-issue-create.sh require-migration-ticket.sh require-active-ticket.sh suggest-mcp-search.sh warn-review-marker-write.sh warn-isolated-build-risk.sh block-reviewer-repo-mutation.sh block-git-add-all.sh block-main-push.sh validate-branch-name.sh pre-push-gate.sh block-agent-routing-drift.sh check-secrets.sh block-onboarding-in-git.sh verify-commit-refs.sh validate-commit-format.sh require-agdr-for-arch-changes.sh warn-bootstrap-scope.sh suggest-ticket-template.sh validate-issue-structure.sh block-private-refs-in-public-repos.sh validate-pr-create.sh require-agdr-for-arch-pr.sh nudge-control-adversarial-test.sh block-unreviewed-merge.sh require-design-review-for-ui.sh block-merge-on-red-ci.sh require-architecture-review.sh detect-role-trigger.sh'
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
  exit 1
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

echo "PASS: bash dispatcher"
