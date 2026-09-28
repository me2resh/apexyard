#!/usr/bin/env bash
set -euo pipefail

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skill="$skill_dir/SKILL.md"

grep -q '^name: orbit$' "$skill"
grep -q 'portfolio_workspace_dir' "$skill"
grep -q "entry's.*workspace" "$skill"
grep -q 'ORBIT_BIN' "$skill"
grep -q 'orbit_root' "$skill"
grep -q 'cd "\$orbit_root"' "$skill"
grep -q 'validate --all --root "\$orbit_root"' "$skill"
grep -q 'not-verified' "$skill"
grep -q 'Naqid' "$skill"
grep -q 'no-challenge' "$skill"
# apexyard#1446 (AgDR-0179): handoff is the one operation allowed to write a
# tracker issue. Assert the boundary line names that exception explicitly,
# and that every non-handoff operation stays record-only.
grep -q 'one exception to "no tracker records"' "$skill"
grep -q 'does not create branches, commits, code changes, or deployments' "$skill"
! grep -qE 'gh (issue create|pr merge)' "$skill"

echo "orbit skill smoke test passed"
