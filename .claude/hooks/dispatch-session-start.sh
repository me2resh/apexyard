#!/usr/bin/env bash
# Dispatch SessionStart hooks after the settings wrapper resolves the ops root.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd -P)"
INPUT=$(cat)
if ! TMP_DIR=$(mktemp -d 2>/dev/null); then
  printf '%s\n' 'WARN: could not create SessionStart output directory; continuing without dispatch.' >&2
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
  cat "$TMP_DIR/$slot.out" "$TMP_DIR/$slot.err"
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

# Pinning is the one ordering dependency. Run it before the remaining hooks;
# the advisory and housekeeping hooks can then run concurrently like the
# original SessionStart hook group did.
run_hook pin-ops-root.sh 0
report_hook pin-ops-root.sh 0

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
