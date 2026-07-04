#!/bin/bash
# test_per_project_tracker.sh — per-project tracker config resolution (Part A of #670).
#
# A registry entry may carry an optional `tracker:` block that overrides the
# global .claude/project-config.json tracker config FOR THAT PROJECT. The lib
# selects the project by the OPERATION'S TARGET REPO, threaded as an optional
# argument to tracker_kind / tracker_id_pattern — NOT a session-global marker,
# NOT cwd (see AgDR-0072).
#
# Cases:
#   1. tracker_kind <repo-with-override>  → the per-project kind        [discriminator]
#   2. tracker_kind <repo-without-block>  → the global default          (fallback)
#   3. tracker_kind  (no arg)             → the global default          (today's behaviour, unchanged)
#   4. tracker_id_pattern <repo-with-override> → the per-project id_pattern
#   5. tracker_id_pattern (no arg)        → the global default pattern
#
# Exit 0 = all pass. Exit 1 on first failure.

set -u

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACKER_LIB="$HOOK_DIR/_lib-tracker.sh"
CONFIG_LIB="$HOOK_DIR/_lib-read-config.sh"
PORTFOLIO_LIB="$HOOK_DIR/_lib-portfolio-paths.sh"
OPSROOT_LIB="$HOOK_DIR/_lib-ops-root.sh"

PASS=0
FAIL=0
FAILED=""

pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; echo "FAIL: $1"; echo "    expected: [$2]"; echo "    actual:   [$3]"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }

# Build an isolated single-fork sandbox with a global tracker block + a registry
# whose second project carries a per-project tracker override.
make_sandbox() {
  local sb
  sb=$(mktemp -d); sb=$(cd "$sb" && pwd -P)
  mkdir -p "$sb/.claude/hooks"
  touch "$sb/onboarding.yaml"
  cp "$TRACKER_LIB"   "$sb/.claude/hooks/_lib-tracker.sh"
  cp "$CONFIG_LIB"    "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$PORTFOLIO_LIB" "$sb/.claude/hooks/_lib-portfolio-paths.sh"
  [ -f "$OPSROOT_LIB" ] && cp "$OPSROOT_LIB" "$sb/.claude/hooks/_lib-ops-root.sh"

  # Global tracker config (defaults file present so config_get has a base).
  cat > "$sb/.claude/project-config.defaults.json" <<'JSON'
{ "tracker": { "kind": "gh", "id_pattern": "^(#[0-9]+|GH-[0-9]+)$" } }
JSON
  # No override file needed — defaults supply the global block.

  # Registry: proj-a has NO tracker block; proj-b overrides kind + id_pattern.
  cat > "$sb/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: proj-a
    repo: org/repo-a
  - name: proj-b
    repo: org/repo-b
    tracker:
      kind: jira
      id_pattern: "^PROJ-[0-9]+$"
  - name: proj-c
    repo: org/repo-c
    tracker:
      kind: custom
      view_command: "printf '%s' '{\"state\":\"Open\",\"title\":\"pp\",\"url\":\"\",\"labels\":[]}'"
YAML
  echo "$sb"
}

SB=$(make_sandbox)
# Resolve the project from cwd-walk-up; make sure no session pin hijacks it.
unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true

cd "$SB" || { echo "FAIL: cannot cd to sandbox"; exit 1; }
# shellcheck source=/dev/null
. "$SB/.claude/hooks/_lib-tracker.sh"

# Per-project resolution needs a YAML parser (yq OR python3+PyYAML). When neither
# is present the feature degrades to the global config (by design), so the
# per-project assertions would not hold — SKIP them rather than fail a bare
# adopter's suite. The global-fallback / no-arg cases hold regardless.
HAVE_YAML=no
if command -v yq >/dev/null 2>&1 || python3 -c 'import yaml' >/dev/null 2>&1; then
  HAVE_YAML=yes
fi

# Case 1 — discriminator: per-project override wins for its repo.
if [ "$HAVE_YAML" = yes ]; then
  tracker_clear_cache
  got=$(tracker_kind "org/repo-b")
  assert_eq "tracker_kind <repo with override> → per-project kind" "jira" "$got"
else
  echo "SKIP: tracker_kind per-project override (no yq / python3+PyYAML)"
fi

# Case 2 — project without a tracker block falls back to the global default.
# Holds with or without a YAML parser (empty per-project lookup → global).
tracker_clear_cache
got=$(tracker_kind "org/repo-a")
assert_eq "tracker_kind <repo without block> → global default" "gh" "$got"

# Case 3 — no-arg call is unchanged (today's behaviour).
tracker_clear_cache
got=$(tracker_kind)
assert_eq "tracker_kind (no arg) → global default" "gh" "$got"

# Case 4 — per-project id_pattern override.
if [ "$HAVE_YAML" = yes ]; then
  tracker_clear_cache
  got=$(tracker_id_pattern "org/repo-b")
  assert_eq "tracker_id_pattern <repo with override> → per-project pattern" "^PROJ-[0-9]+$" "$got"
else
  echo "SKIP: tracker_id_pattern per-project override (no yq / python3+PyYAML)"
fi

# Case 5 — no-arg id_pattern is the global default.
tracker_clear_cache
got=$(tracker_id_pattern)
assert_eq "tracker_id_pattern (no arg) → global default" "^(#[0-9]+|GH-[0-9]+)$" "$got"

# Case 6 — tracker_view dispatches the per-project kind + view_command for its
# repo. proj-c overrides kind=custom + a view_command that emits known JSON;
# tracker_view must use that (not the global gh path) when given org/repo-c.
if [ "$HAVE_YAML" = yes ] && command -v jq >/dev/null 2>&1; then
  tracker_clear_cache
  got=$(tracker_view "1" "org/repo-c" | jq -r '.title' 2>/dev/null)
  assert_eq "tracker_view <repo with custom override> dispatches per-project view_command" "pp" "$got"
else
  echo "SKIP: tracker_view per-project case (needs jq + yq/python3-yaml)"
fi

rm -rf "$SB"
echo "=========================================="
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then printf "Failed cases:%b\n" "$FAILED"; exit 1; fi
exit 0
