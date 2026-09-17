#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$ROOT/../settings.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash_entries=$(jq '[.hooks.SessionStart[].hooks[]] | length' "$SETTINGS")
[ "$bash_entries" -eq 1 ]
dispatcher_command=$(jq -r '[.hooks.SessionStart[].hooks[].command][0]' "$SETTINGS")
grep -q 'dispatch-session-start.sh' <<<"$dispatcher_command"

mkdir -p "$TMP/.claude/hooks"
cp "$ROOT/dispatch-session-start.sh" "$TMP/.claude/hooks/dispatch-session-start.sh"
chmod +x "$TMP/.claude/hooks/dispatch-session-start.sh"

scripts='pin-ops-root.sh onboarding-check.sh check-upstream-drift.sh check-jq-installed.sh check-git-hooks-installed.sh check-portfolio-config.sh clear-bootstrap-marker.sh clear-active-reviewer-marker.sh clear-onboarding-depth-mode-marker.sh clear-onboarding-glossary-seen-marker.sh clear-issue-skill-marker.sh link-custom-skills.sh apply-agent-routing.sh remind-mcp-tools.sh validate-search-config.sh print-portfolio-primer.sh reindex-on-session-start.sh warn-unqualified-review-marker.sh'
for script in $scripts; do
  grep -q "APEXYARD_SESSION_START_HOOK: $script" "$ROOT/dispatch-session-start.sh"
done
for script in $scripts; do
  cat > "$TMP/.claude/hooks/$script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
name=$(basename "$0")
printf '%s\n' "$name" >> "${SESSION_LOG:?}"
grep -q 'SessionStart' <<<"$input"
if [ "${SESSION_FAIL_SCRIPT:-}" = "$name" ]; then
  exit 1
fi
EOF
  chmod +x "$TMP/.claude/hooks/$script"
done

payload='{"hook_event_name":"SessionStart"}'
printf '%s' "$payload" \
  | SESSION_LOG="$TMP/log" SESSION_FAIL_SCRIPT=check-jq-installed.sh \
    "$TMP/.claude/hooks/dispatch-session-start.sh" >/dev/null

[ "$(head -1 "$TMP/log")" = "pin-ops-root.sh" ]
for script in $scripts; do
  [ "$(grep -cxF "$script" "$TMP/log")" -eq 1 ]
done

echo "PASS: SessionStart dispatcher"
