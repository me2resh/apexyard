#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# Reuse the CLI contract fixture, not its mock config, inside child hooks.
# shellcheck source=/dev/null
AZURE_FIXTURE_ONLY=1 . "$ROOT/.claude/hooks/tests/test_tracker_azure.sh"
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/.claude/hooks" "$SB/.claude/session/reviews" "$SB/bin"
cp "$ROOT"/.claude/hooks/*.sh "$SB/.claude/hooks/"
cp "$ROOT/.claude/project-config.defaults.json" "$SB/.claude/project-config.defaults.json"
touch "$SB/.apexyard-fork" "$SB/onboarding.yaml"
printf 'projects: []\n' > "$SB/apexyard.projects.yaml"
cat > "$SB/.claude/project-config.json" <<'JSON'
{"tracker":{"kind":"az","azure_organization":"https://dev.azure.com/example","azure_project":"Example Project","azure_repository":"service"},"review_markers":{"require_posted_review":true}}
JSON
{ printf '#!/bin/bash\n'; declare -f az; printf '\naz "$@"\n'; } > "$SB/bin/az"
printf '#!/bin/bash\necho UNEXPECTED_GITHUB >&2\nexit 99\n' > "$SB/bin/gh"
chmod +x "$SB/bin/az" "$SB/bin/gh" "$SB/.claude/hooks/"*.sh
git -C "$SB" init -q
git -C "$SB" remote add origin https://github.com/azure/service.git
export PATH="$SB/bin:$PATH" TEST_SHA OLD_SHA
unset -f gh 2>/dev/null || true
cd "$SB" || exit 1
# shellcheck source=/dev/null
. "$SB/.claude/hooks/_lib-review-markers.sh"
REX=$(review_marker_path azure/service 7 rex "$SB")
HUMAN=$(review_marker_path azure/service 7 ceo "$SB")
printf '%s\n' "$TEST_SHA" > "$REX"
printf 'sha=%s\napproved_by=user\nskill_version=2\n' "$TEST_SHA" > "$HUMAN"
INPUT=$(jq -nc --arg cwd "$SB" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:"tracker_pr_merge azure/service 7 squash true"}}')
PASS=0 FAIL=0
gate() {
  local script="$1" expected="$2" output rc=0
  output=$(printf '%s' "$INPUT" | bash "$SB/.claude/hooks/$script" 2>&1) || rc=$?
  if [ "$rc" = "$expected" ] && ! printf '%s' "$output" | grep -q UNEXPECTED_GITHUB; then
    printf 'PASS %s rc=%s\n' "$script" "$rc"; PASS=$((PASS + 1))
  else printf 'FAIL %s expected=%s rc=%s %s\n' "$script" "$expected" "$rc" "$output" >&2; FAIL=$((FAIL + 1)); fi
}
gate block-unreviewed-merge.sh 0
printf '%s\n' "$OLD_SHA" > "$REX"
gate block-unreviewed-merge.sh 2
printf '%s\n' "$TEST_SHA" > "$REX"
rm "$HUMAN"
gate block-unreviewed-merge.sh 2
printf 'sha=%s\napproved_by=user\nskill_version=2\n' "$TEST_SHA" > "$HUMAN"
AZ_ITERATION=1 gate block-unreviewed-merge.sh 2
gate block-merge-on-red-ci.sh 0
AZ_POLICY=rejected gate block-merge-on-red-ci.sh 2
AZ_STATUS_ITERATION=1 gate block-merge-on-red-ci.sh 2
AZ_CONTINUATION=1 gate require-design-review-for-ui.sh 2
AZ_CONTINUATION=1 gate require-architecture-review.sh 2
AZ_FILE_PATH=.claude/project-config.json AZ_ORIGINAL_PATH=specs/design.md gate require-architecture-review.sh 2
AZ_FILE_PATH=.claude/project-config.json AZ_ORIGINAL_PATH=widgets/view.custom gate require-design-review-for-ui.sh 2
AZ_FILE_PATH=.claude/project-config.json AZ_BASE_FAIL=1 gate require-design-review-for-ui.sh 2
AZ_FILE_PATH=.claude/project-config.json AZ_BASE_FAIL=1 gate require-architecture-review.sh 2
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
