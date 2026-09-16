#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/hooks"
cp "$ROOT/dispatch-bash.sh" "$TMP/hooks/dispatch-bash.sh"
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
[ "$(grep -c '^require-architecture-review.sh$' "$TMP/log")" -eq 1 ]

: > "$TMP/log"
set +e
run 'git add -A'
rc=$?
set -e
[ "$rc" -eq 2 ]
[ "$(grep -c '^block-git-add-all.sh$' "$TMP/log")" -eq 1 ]

echo "PASS: bash dispatcher"
