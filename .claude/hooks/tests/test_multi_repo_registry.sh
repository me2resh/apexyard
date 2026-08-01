#!/bin/bash
# Tests for the multi-repo registry project (me2resh/apexyard#1123).
#
# The registry (apexyard.projects.yaml) used to model a project as EXACTLY
# ONE repo (singular `repo: owner/name`). A product split across several
# repos (backend + gateway + workers, say) had no first-class way to
# register as ONE project, and the dangerous consequence was that
# block-private-refs-in-public-repos.sh built its scrub list by reading one
# `repo:` per project — so a project registered under its "primary" repo
# left every OTHER repo's slug unscrubbed, a real disclosure gap.
#
# This file proves:
#   1. [SECURITY, the AC #1123 prioritises] A multi-repo project's
#      NON-primary repo slugs are scrubbed by block-private-refs on a
#      public-repo write — not just the primary/first one.
#   2. Singular `repo:` behaves byte-identically to before this change
#      (backwards compatibility).
#   3. A one-element `repos:` list is equivalent to singular `repo:`.
#   4. Tracker resolution (_tracker_project_value, via tracker_kind) finds
#      a multi-repo project's per-project override regardless of WHICH of
#      its repos is passed — defaults implicitly to "any repo resolves the
#      same project", satisfying "accepts explicit --repo for the others".
#   5. _lib-multi-repo-trace.sh's mrt_resolve_target (tier 4) matches a
#      NON-primary repo slug, and mrt_primary_repo_for / mrt_repos_for
#      resolve correctly for both singular and plural schemas.
#
# Exit 0 = all pass. Exit 1 on first failure.

set -u

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LEAK_HOOK="$HOOK_DIR/block-private-refs-in-public-repos.sh"
TRACKER_LIB="$HOOK_DIR/_lib-tracker.sh"
CONFIG_LIB="$HOOK_DIR/_lib-read-config.sh"
PORTFOLIO_LIB="$HOOK_DIR/_lib-portfolio-paths.sh"
OPSROOT_LIB="$HOOK_DIR/_lib-ops-root.sh"
TRACE_LIB="$HOOK_DIR/_lib-multi-repo-trace.sh"

for f in "$LEAK_HOOK" "$TRACKER_LIB" "$CONFIG_LIB" "$PORTFOLIO_LIB" "$TRACE_LIB"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file not found: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

pass_case() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "   $2" >&2; FAIL=$((FAIL + 1)); FAILED_CASES="${FAILED_CASES}${1}; "; }

# =============================================================================
# Part 1 — leak-scrub coverage (block-private-refs-in-public-repos.sh)
# =============================================================================

LEAK_TMPDIR=$(mktemp -d -t multi-repo-leak.XXXXXX)
trap 'rm -rf "$LEAK_TMPDIR"' EXIT

mkdir -p "$LEAK_TMPDIR/fork/subdir"
cat > "$LEAK_TMPDIR/fork/onboarding.yaml" <<'YAML'
company: test
YAML
cat > "$LEAK_TMPDIR/fork/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: some-platform
    repos:
      - acme/some-platform-backend
      - acme/some-platform-gateway
      - acme/some-platform-worker
    primary: acme/some-platform-backend
    workspace: workspace/some-platform
    status: active
  - name: solo-app
    repo: acme/solo-app
    workspace: workspace/solo-app
    status: active
  - name: one-elem
    repos:
      - acme/one-elem-repo
    workspace: workspace/one-elem
    status: active
YAML

make_payload() {
  local cmd="$1"
  jq -n --arg c "$cmd" '{tool_input: {command: $c}}'
}

run_leak_case() {
  local name="$1" expected_exit="$2" expected_stderr_substr="$3" cmd="$4"
  local stderr_file
  stderr_file=$(mktemp)
  ( cd "$LEAK_TMPDIR/fork/subdir" && echo "$(make_payload "$cmd")" | "$LEAK_HOOK" ) 2> "$stderr_file"
  local actual_exit=$? stderr_content
  stderr_content=$(cat "$stderr_file")
  rm -f "$stderr_file"

  local ok=1
  [ "$actual_exit" != "$expected_exit" ] && ok=0
  if [ -n "$expected_stderr_substr" ] && ! echo "$stderr_content" | grep -qF -- "$expected_stderr_substr"; then
    ok=0
  fi

  if [ "$ok" = 1 ]; then
    pass_case "$name"
  else
    fail_case "$name" "expected exit=$expected_exit (got $actual_exit); expected stderr to contain: [$expected_stderr_substr]; stderr was: $stderr_content"
  fi
}

# 1a. THE security AC — a NON-primary repo slug (gateway, not backend) must
#     be scrubbed. Before #1123 this leaked (exit 0, nothing scanned) because
#     only the first `repo:` line per project was ever read.
run_leak_case "multi-repo: NON-primary repo slug (gateway) is scrubbed" \
  2 "project repo: acme/some-platform-gateway" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces on acme/some-platform-gateway too'"

# 1b. A THIRD repo (worker) — not just the second — confirming the fix
#     covers the WHOLE list, not merely "first two".
run_leak_case "multi-repo: third repo slug (worker) is scrubbed" \
  2 "project repo: acme/some-platform-worker" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'seen in acme/some-platform-worker logs'"

# 1c. The PRIMARY repo itself must still be scrubbed too (not a regression
#     introduced by generalising to a list).
run_leak_case "multi-repo: primary repo slug (backend) is still scrubbed" \
  2 "project repo: acme/some-platform-backend" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'crash in acme/some-platform-backend'"

# 1d. The project NAME (shared across all its repos) still scrubs too.
run_leak_case "multi-repo: project name (some-platform) is scrubbed" \
  2 "project name: some-platform" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'found during some-platform rebuild'"

# 1e. Clean body with none of the multi-repo project's slugs → no false positive.
run_leak_case "multi-repo: clean body naming none of the repos → pass" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'a generic framework issue, no project named'"

# 2. Backwards compatibility — singular `repo:` project (solo-app) behaves
#    exactly as it did before this change: bare slug leak still blocks.
run_leak_case "backwards-compat: singular repo: project still scrubs its slug" \
  2 "project repo: acme/solo-app" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme/solo-app'"

# 3. Equivalence — a ONE-ELEMENT `repos:` list scrubs identically to a
#    singular `repo:` project (case 2 above). Same assertion shape, proving
#    the two schemas are byte-equivalent in the scrub list they produce.
run_leak_case "equivalence: one-element repos: list scrubs its sole slug" \
  2 "project repo: acme/one-elem-repo" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme/one-elem-repo'"

# =============================================================================
# Part 2 — tracker resolution defaults to primary, accepts --repo for others
# =============================================================================

TRACKER_TMPDIR=$(mktemp -d -t multi-repo-tracker.XXXXXX)

mkdir -p "$TRACKER_TMPDIR/.claude/hooks"
touch "$TRACKER_TMPDIR/onboarding.yaml"
cp "$TRACKER_LIB"   "$TRACKER_TMPDIR/.claude/hooks/_lib-tracker.sh"
cp "$CONFIG_LIB"    "$TRACKER_TMPDIR/.claude/hooks/_lib-read-config.sh"
cp "$PORTFOLIO_LIB" "$TRACKER_TMPDIR/.claude/hooks/_lib-portfolio-paths.sh"
[ -f "$OPSROOT_LIB" ] && cp "$OPSROOT_LIB" "$TRACKER_TMPDIR/.claude/hooks/_lib-ops-root.sh"

cat > "$TRACKER_TMPDIR/.claude/project-config.defaults.json" <<'JSON'
{ "tracker": { "kind": "gh", "id_pattern": "^(#[0-9]+|GH-[0-9]+)$" } }
JSON

cat > "$TRACKER_TMPDIR/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: some-platform
    repos:
      - acme/some-platform-backend
      - acme/some-platform-gateway
    primary: acme/some-platform-backend
    tracker:
      kind: jira
      id_pattern: "^PLAT-[0-9]+$"
  - name: single-proj
    repo: acme/single-proj
YAML

HAVE_YAML=no
if command -v yq >/dev/null 2>&1; then HAVE_YAML=yes; fi

if [ "$HAVE_YAML" = yes ]; then
  (
    cd "$TRACKER_TMPDIR" || exit 1
    unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$TRACKER_TMPDIR/.claude/hooks/_lib-tracker.sh"

    tracker_clear_cache
    got=$(tracker_kind "acme/some-platform-backend")
    [ "$got" = "jira" ] && echo "OK:primary" || echo "MISMATCH:primary:$got"

    tracker_clear_cache
    got=$(tracker_kind "acme/some-platform-gateway")
    [ "$got" = "jira" ] && echo "OK:non-primary" || echo "MISMATCH:non-primary:$got"

    tracker_clear_cache
    got=$(tracker_id_pattern "acme/some-platform-gateway")
    [ "$got" = "^PLAT-[0-9]+\$" ] && echo "OK:id-pattern-non-primary" || echo "MISMATCH:id-pattern-non-primary:$got"

    tracker_clear_cache
    got=$(tracker_kind "acme/single-proj")
    [ "$got" = "gh" ] && echo "OK:singular-fallback" || echo "MISMATCH:singular-fallback:$got"
  ) > "$TRACKER_TMPDIR/results.txt" 2>/dev/null

  if grep -q "^OK:primary$" "$TRACKER_TMPDIR/results.txt"; then
    pass_case "tracker_kind <multi-repo primary> → per-project override (jira)"
  else
    fail_case "tracker_kind <multi-repo primary> → per-project override (jira)" "$(grep MISMATCH:primary "$TRACKER_TMPDIR/results.txt")"
  fi

  if grep -q "^OK:non-primary$" "$TRACKER_TMPDIR/results.txt"; then
    pass_case "tracker_kind <multi-repo NON-primary> → SAME per-project override (jira) — the #1123 AC"
  else
    fail_case "tracker_kind <multi-repo NON-primary> → SAME per-project override (jira) — the #1123 AC" "$(grep MISMATCH:non-primary "$TRACKER_TMPDIR/results.txt")"
  fi

  if grep -q "^OK:id-pattern-non-primary$" "$TRACKER_TMPDIR/results.txt"; then
    pass_case "tracker_id_pattern <multi-repo NON-primary> → per-project override"
  else
    fail_case "tracker_id_pattern <multi-repo NON-primary> → per-project override" "$(grep MISMATCH:id-pattern-non-primary "$TRACKER_TMPDIR/results.txt")"
  fi

  if grep -q "^OK:singular-fallback$" "$TRACKER_TMPDIR/results.txt"; then
    pass_case "tracker_kind <singular repo:, no override> → global default (unaffected)"
  else
    fail_case "tracker_kind <singular repo:, no override> → global default (unaffected)" "$(grep MISMATCH:singular-fallback "$TRACKER_TMPDIR/results.txt")"
  fi
else
  echo "SKIP: tracker per-project multi-repo cases (no yq installed)"
fi

rm -rf "$TRACKER_TMPDIR"

# =============================================================================
# Part 3 — _lib-multi-repo-trace.sh: tier-4 match on a non-primary repo, and
# the primary/repos resolver helpers.
# =============================================================================

TRACE_TMPDIR=$(mktemp -d -t multi-repo-trace.XXXXXX)
mkdir -p "$TRACE_TMPDIR/.claude/hooks"
touch "$TRACE_TMPDIR/onboarding.yaml"
cp "$CONFIG_LIB"    "$TRACE_TMPDIR/.claude/hooks/_lib-read-config.sh"
cp "$PORTFOLIO_LIB" "$TRACE_TMPDIR/.claude/hooks/_lib-portfolio-paths.sh"
cp "$TRACE_LIB"     "$TRACE_TMPDIR/.claude/hooks/_lib-multi-repo-trace.sh"
[ -f "$OPSROOT_LIB" ] && cp "$OPSROOT_LIB" "$TRACE_TMPDIR/.claude/hooks/_lib-ops-root.sh"

cat > "$TRACE_TMPDIR/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: some-platform
    repos:
      - acme/some-platform-backend
      - acme/some-platform-gateway
    primary: acme/some-platform-backend
    workspace: workspace/some-platform
  - name: single-proj
    repo: acme/single-proj
    workspace: workspace/single-proj
YAML

(
  cd "$TRACE_TMPDIR" || exit 1
  unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$TRACE_TMPDIR/.claude/hooks/_lib-read-config.sh"
  # shellcheck source=/dev/null
  . "$TRACE_TMPDIR/.claude/hooks/_lib-portfolio-paths.sh"
  # shellcheck source=/dev/null
  . "$TRACE_TMPDIR/.claude/hooks/_lib-multi-repo-trace.sh"

  echo "resolve_nonprimary=$(mrt_resolve_target 'github.com/acme/some-platform-gateway')"
  echo "resolve_primary=$(mrt_resolve_target 'github.com/acme/some-platform-backend')"
  echo "primary_repo=$(mrt_primary_repo_for 'some-platform')"
  echo "repos_count=$(mrt_repos_for 'some-platform' | wc -l | tr -d ' ')"
  echo "singular_primary=$(mrt_primary_repo_for 'single-proj')"
  echo "singular_repos_count=$(mrt_repos_for 'single-proj' | wc -l | tr -d ' ')"
) > "$TRACE_TMPDIR/results.txt" 2>/dev/null

if grep -q "^resolve_nonprimary=some-platform$" "$TRACE_TMPDIR/results.txt"; then
  pass_case "mrt_resolve_target: tier-4 matches a NON-primary repo slug"
else
  fail_case "mrt_resolve_target: tier-4 matches a NON-primary repo slug" "$(cat "$TRACE_TMPDIR/results.txt")"
fi

if grep -q "^resolve_primary=some-platform$" "$TRACE_TMPDIR/results.txt"; then
  pass_case "mrt_resolve_target: tier-4 still matches the primary repo slug"
else
  fail_case "mrt_resolve_target: tier-4 still matches the primary repo slug" "$(cat "$TRACE_TMPDIR/results.txt")"
fi

if grep -q "^primary_repo=acme/some-platform-backend$" "$TRACE_TMPDIR/results.txt"; then
  pass_case "mrt_primary_repo_for: resolves the explicit primary: field"
else
  fail_case "mrt_primary_repo_for: resolves the explicit primary: field" "$(cat "$TRACE_TMPDIR/results.txt")"
fi

if grep -q "^repos_count=2$" "$TRACE_TMPDIR/results.txt"; then
  pass_case "mrt_repos_for: enumerates all repos of a multi-repo project"
else
  fail_case "mrt_repos_for: enumerates all repos of a multi-repo project" "$(cat "$TRACE_TMPDIR/results.txt")"
fi

if grep -q "^singular_primary=acme/single-proj$" "$TRACE_TMPDIR/results.txt"; then
  pass_case "mrt_primary_repo_for: singular repo: project unaffected"
else
  fail_case "mrt_primary_repo_for: singular repo: project unaffected" "$(cat "$TRACE_TMPDIR/results.txt")"
fi

if grep -q "^singular_repos_count=1$" "$TRACE_TMPDIR/results.txt"; then
  pass_case "mrt_repos_for: singular repo: project normalises to a one-element list"
else
  fail_case "mrt_repos_for: singular repo: project normalises to a one-element list" "$(cat "$TRACE_TMPDIR/results.txt")"
fi

rm -rf "$TRACE_TMPDIR"

# =============================================================================
# Result
# =============================================================================

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases: $FAILED_CASES" >&2
  exit 1
fi
exit 0
