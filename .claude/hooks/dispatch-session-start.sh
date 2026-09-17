#!/usr/bin/env bash
# Dispatch SessionStart hooks after the settings wrapper resolves the ops root.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd -P)"
INPUT=$(cat)
# APEXYARD_SESSION_START_HOOK: pin-ops-root.sh
# APEXYARD_SESSION_START_HOOK: onboarding-check.sh
# APEXYARD_SESSION_START_HOOK: check-upstream-drift.sh
# APEXYARD_SESSION_START_HOOK: check-jq-installed.sh
# APEXYARD_SESSION_START_HOOK: check-git-hooks-installed.sh
# APEXYARD_SESSION_START_HOOK: check-portfolio-config.sh
# APEXYARD_SESSION_START_HOOK: clear-bootstrap-marker.sh
# APEXYARD_SESSION_START_HOOK: clear-active-reviewer-marker.sh
# APEXYARD_SESSION_START_HOOK: clear-onboarding-depth-mode-marker.sh
# APEXYARD_SESSION_START_HOOK: clear-onboarding-glossary-seen-marker.sh
# APEXYARD_SESSION_START_HOOK: clear-issue-skill-marker.sh
# APEXYARD_SESSION_START_HOOK: link-custom-skills.sh
# APEXYARD_SESSION_START_HOOK: apply-agent-routing.sh
# APEXYARD_SESSION_START_HOOK: remind-mcp-tools.sh
# APEXYARD_SESSION_START_HOOK: validate-search-config.sh
# APEXYARD_SESSION_START_HOOK: print-portfolio-primer.sh
# APEXYARD_SESSION_START_HOOK: reindex-on-session-start.sh
# APEXYARD_SESSION_START_HOOK: warn-unqualified-review-marker.sh

run_direct() {
  local script="$1" rc=0
  if "$HOOK_DIR/$script" <<<"$INPUT"; then :; else rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    printf 'WARN: SessionStart hook %s exited %s; continuing.\n' "$script" "$rc" >&2
  fi
}

# Pinning is the one ordering dependency. Run it before the remaining hooks.
run_direct pin-ops-root.sh

if ! TMP_DIR=$(mktemp -d 2>/dev/null); then
  printf '%s\n' 'WARN: could not create SessionStart output directory; running remaining hooks directly.' >&2
  for script in onboarding-check.sh check-upstream-drift.sh check-jq-installed.sh check-git-hooks-installed.sh check-portfolio-config.sh clear-bootstrap-marker.sh clear-active-reviewer-marker.sh clear-onboarding-depth-mode-marker.sh clear-onboarding-glossary-seen-marker.sh clear-issue-skill-marker.sh link-custom-skills.sh apply-agent-routing.sh remind-mcp-tools.sh validate-search-config.sh print-portfolio-primer.sh reindex-on-session-start.sh warn-unqualified-review-marker.sh; do
    run_direct "$script"
  done
  exit 0
fi
trap 'rm -rf "$TMP_DIR"' EXIT

# SessionStart hooks are advisory or housekeeping. Run the complete list even
# when one hook fails so a slow or unavailable check cannot suppress marker
# cleanup, routing, or the search refresh.
run_hook() {
  local script="$1" slot="$2" rc=0
  if "$HOOK_DIR/$script" <<<"$INPUT" >"$TMP_DIR/$slot.out" 2>"$TMP_DIR/$slot.err"; then :; else rc=$?; fi
  printf '%s' "$rc" >"$TMP_DIR/$slot.rc"
}

report_hook() {
  local script="$1" slot="$2" rc
  cat "$TMP_DIR/$slot.out"
  cat "$TMP_DIR/$slot.err" >&2
  rc=$(cat "$TMP_DIR/$slot.rc")
  if [ "$rc" -ne 0 ]; then
    printf 'WARN: SessionStart hook %s exited %s; continuing.\n' "$script" "$rc" >&2
  fi
}

scripts=(
  onboarding-check.sh \
  check-upstream-drift.sh \
  check-jq-installed.sh \
  check-git-hooks-installed.sh \
  check-portfolio-config.sh \
  clear-bootstrap-marker.sh \
  clear-active-reviewer-marker.sh \
  clear-onboarding-depth-mode-marker.sh \
  clear-onboarding-glossary-seen-marker.sh \
  clear-issue-skill-marker.sh \
  link-custom-skills.sh \
  apply-agent-routing.sh \
  remind-mcp-tools.sh \
  validate-search-config.sh \
  print-portfolio-primer.sh \
  reindex-on-session-start.sh \
  warn-unqualified-review-marker.sh
)

pids=()
names=()
for i in "${!scripts[@]}"; do
  slot=$((i + 1))
  names[slot]="${scripts[$i]}"
  run_hook "${scripts[$i]}" "$slot" &
  pids[slot]=$!
done
for slot in "${!pids[@]}"; do
  wait "${pids[$slot]}" || true
  report_hook "${names[$slot]}" "$slot"
done
