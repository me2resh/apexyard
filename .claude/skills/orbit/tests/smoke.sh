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
grep -q 'validate --all' "$skill"
grep -q 'not-verified' "$skill"
grep -q 'Naqid' "$skill"
grep -q 'no-challenge' "$skill"
grep -q 'does not create issues' "$skill"
! grep -q 'gh issue create' "$skill"
! grep -q 'gh pr merge' "$skill"

echo "orbit skill smoke test passed"
