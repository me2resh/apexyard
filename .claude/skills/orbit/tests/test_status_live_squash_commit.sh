#!/usr/bin/env bash
# Variables come from the caller or fixture functions.
# shellcheck disable=SC2154,SC2034

set -eu
# shellcheck source=./_lib-slice-fixtures.sh
. "$(dirname "$0")/_lib-slice-fixtures.sh"
slice_setup
candidate_write
g add docs
g commit -qm 'Deliver slice (#42)'
echo 'After.' > "$sb/after.txt"
g add after.txt
g commit -qm 'Later change'
g branch -f base
cat > "$sb/bin/orbit" <<'CLI'
#!/usr/bin/env bash
echo 'Recorded progress.'
CLI
before=$(g status --porcelain; g ls-files --others --exclude-standard)
out=$(bash "$real_root/.claude/skills/orbit/lib/status-live.sh" --orbit-root "$orbit_root" --plan plan-demo-widget --repo-path "$sb" --base base)
[[ "$out" == *'Later change'* && "$out" != *'Deliver slice'* ]] || { echo "$out"; exit 1; }
after=$(g status --porcelain; g ls-files --others --exclude-standard)
[ "$before" = "$after" ]
