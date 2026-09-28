#!/bin/bash
# _lib-fixtures.sh — shared sandbox + ORBIT record fixtures for the
# /orbit handoff smoke tests (apexyard#1446).
#
# Builds a throwaway orbit_root with a matching, schema-valid Plan,
# Snapshot, Reconciliation and Execution Slice, all named with synthetic
# (non-portfolio) identifiers, plus mock `orbit`/`gh` binaries on PATH.
#
# Usage:
#   source "$(dirname "$0")/_lib-fixtures.sh"
#   sb=$(make_sandbox)
#   orbit_root=$(fixtures_write_orbit_root "$sb")
#   slice_file="$orbit_root/slices/slice-demo-o1.json"

make_sandbox() {
  mktemp -d "${TMPDIR:-/tmp}/orbit-handoff-test.XXXXXX"
}

# Writes a valid, self-consistent Plan/Snapshot/Reconciliation/Slice record
# set under <sandbox>/orbit. Every record matches the real orbit-spec v0.1
# schemas (verified against the real CLI — see the PR body for the command).
# Prints the orbit_root path.
fixtures_write_orbit_root() {
  sb="$1"
  orbit_root="$sb/orbit"
  mkdir -p "$orbit_root/plans" "$orbit_root/snapshots" "$orbit_root/reconciliations" "$orbit_root/slices"

  cat > "$orbit_root/plans/plan-demo-widget.r1.json" <<'JSON'
{
  "specVersion": "0.1",
  "id": "plan-demo-widget",
  "revision": 1,
  "project": { "id": "demo-widget" },
  "title": "Demo widget plan",
  "intent": "Synthetic fixture plan for /orbit handoff smoke tests.",
  "outcomes": [{ "id": "o1-demo", "title": "Demo outcome" }],
  "acceptanceCriteria": [{ "id": "ac1-1", "outcomeId": "o1-demo", "statement": "Demo criterion." }]
}
JSON

  cat > "$orbit_root/snapshots/snapshot-demo-widget-1.json" <<'JSON'
{
  "specVersion": "0.1",
  "id": "snapshot-demo-widget-1",
  "project": { "id": "demo-widget" },
  "observedAt": "2026-09-28T00:00:00Z",
  "repositories": [
    { "repositoryId": "demo-widget", "branch": "main", "commit": "0000000000000000000000000000000000000a" }
  ]
}
JSON

  cat > "$orbit_root/reconciliations/reconciliation-demo-widget-r1.json" <<'JSON'
{
  "specVersion": "0.1",
  "id": "reconciliation-demo-widget-r1",
  "planId": "plan-demo-widget",
  "planRevision": 1,
  "projectSnapshotId": "snapshot-demo-widget-1",
  "reconciledAt": "2026-09-28T00:00:00Z",
  "observations": [],
  "criterionAssessments": [
    { "criterionId": "ac1-1", "status": "not-verified", "evidence": [], "explanation": "fixture" }
  ]
}
JSON

  cat > "$orbit_root/slices/slice-demo-o1.json" <<'JSON'
{
  "specVersion": "0.1",
  "id": "slice-demo-widget-o1",
  "planId": "plan-demo-widget",
  "outcomeId": "o1-demo",
  "basedOn": {
    "planRevision": 1,
    "reconciliationId": "reconciliation-demo-widget-r1",
    "repositories": { "demo-widget": "0000000000000000000000000000000000000a" }
  },
  "objective": "Fixture objective for the handoff smoke test.",
  "why": "Fixture reason.",
  "contributesTo": ["ac1-1"],
  "scope": { "include": ["fixture item"], "exclude": ["fixture excluded item"] }
}
JSON

  echo "$orbit_root"
}

# Installs a mock `orbit` on PATH inside <sandbox>/bin. `validate_exit`
# controls the `validate --all` exit code (default 0). `sync_exit` controls
# `sync github --dry-run`'s exit code (default 0, printing a clean preview
# whose body carries no private text — safe under any repo).
fixtures_install_mock_orbit() {
  sb="$1"
  validate_exit="${2:-0}"
  sync_exit="${3:-0}"
  mkdir -p "$sb/bin"
  cat > "$sb/bin/orbit" <<EOF
#!/bin/bash
if [ "\$1" = "validate" ]; then
  if [ "$validate_exit" != "0" ]; then
    echo "mock orbit: fixture validation failure" >&2
    exit "$validate_exit"
  fi
  echo "Validated 4 ORBIT records."
  exit 0
fi
if [ "\$1" = "sync" ] && [ "\$2" = "github" ]; then
  if [ "$sync_exit" != "0" ]; then
    echo "mock orbit: fixture sync failure" >&2
    exit "$sync_exit"
  fi
  echo '{"dryRun":true,"repo":"demo-org/demo-widget","title":"[Slice] Fixture objective for the handoff smoke test.","body":"## Orbit Execution Slice\n\nFixture objective for the handoff smoke test.\n\n### Why now\nFixture reason.\n\n### Scope\n**Includes**\n- fixture item\n\n**Excludes**\n- fixture excluded item\n\n### Orbit identifiers\n- Slice: \`slice-demo-widget-o1\`\n"}'
  exit 0
fi
echo "mock orbit: unhandled args: \$*" >&2
exit 99
EOF
  chmod +x "$sb/bin/orbit"
}

# Installs a mock `orbit` whose dry-run preview body carries `private_word`
# as the FIRST WORD of the "### Why now" line — i.e. in the raw JSON, the
# character immediately before it is the "n" of the "\n" escape, not a real
# newline. A scrub run against the raw JSON misses this; a scrub run against
# the jq -r plain-text body catches it. Used by the leak-scrub refusal test.
fixtures_install_mock_orbit_with_leak() {
  sb="$1"
  private_word="$2"
  mkdir -p "$sb/bin"
  cat > "$sb/bin/orbit" <<EOF
#!/bin/bash
if [ "\$1" = "validate" ]; then
  echo "Validated 4 ORBIT records."
  exit 0
fi
if [ "\$1" = "sync" ] && [ "\$2" = "github" ]; then
  echo '{"dryRun":true,"repo":"me2resh/apexyard","title":"[Slice] Fixture objective for the handoff smoke test.","body":"## Orbit Execution Slice\n\nFixture objective for the handoff smoke test.\n\n### Why now\n$private_word needs this before the deadline.\n\n### Scope\n**Includes**\n- fixture item\n\n**Excludes**\n- fixture excluded item\n\n### Orbit identifiers\n- Slice: \`slice-demo-widget-o1\`\n"}'
  exit 0
fi
echo "mock orbit: unhandled args: \$*" >&2
exit 99
EOF
  chmod +x "$sb/bin/orbit"
}

# Installs a mock `gh` on PATH inside <sandbox>/bin. `gh issue list` reads
# two env vars at call time (not baked in at install time), so one mock
# serves every duplicate-check scenario:
#   MOCK_GH_FAIL=1                       -> the search itself fails (exit 1)
#   MOCK_GH_ISSUE_LIST_JSON_FILE=<path>  -> `cat`s that file as the result
#   (neither set)                        -> prints an empty array
fixtures_install_mock_gh() {
  sb="$1"
  mkdir -p "$sb/bin"
  cat > "$sb/bin/gh" <<'EOF'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  if [ "${MOCK_GH_FAIL:-0}" = "1" ]; then
    echo "gh: mock search failure (HTTP 502)" >&2
    exit 1
  fi
  if [ -n "${MOCK_GH_ISSUE_LIST_JSON_FILE:-}" ] && [ -f "${MOCK_GH_ISSUE_LIST_JSON_FILE:-}" ]; then
    cat "$MOCK_GH_ISSUE_LIST_JSON_FILE"
  else
    echo '[]'
  fi
  exit 0
fi
echo "mock gh: unhandled args: $*" >&2
exit 99
EOF
  chmod +x "$sb/bin/gh"
}

# Builds a fully sandboxed copy of the leak-scrub hook plus the
# handoff-preflight helper, at the SAME relative depth they have in the real
# repo (.claude/hooks/check-private-refs-runtime.sh and
# .claude/skills/orbit/lib/handoff-preflight.sh), so the helper's own
# self-location path resolution finds the sandboxed scrub — never the real
# fork's. Also writes a synthetic registry at <sandbox>/apexyard.projects.yaml
# with one private project, so the scrub has a real (but made-up) name to
# catch. Prints the path to the sandboxed helper.
fixtures_install_leak_scrub_sandbox() {
  sb="$1"
  private_name="${2:-zephyrvault}"
  private_repo="${3:-acme-private/zephyrvault}"

  real_root="$(cd "$(dirname "$0")/../../../.." && pwd)"
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/skills/orbit/lib"
  cp "$real_root/.claude/hooks/check-private-refs-runtime.sh" "$sb/.claude/hooks/check-private-refs-runtime.sh"
  cp "$real_root/.claude/skills/orbit/lib/handoff-preflight.sh" "$sb/.claude/skills/orbit/lib/handoff-preflight.sh"
  chmod +x "$sb/.claude/hooks/check-private-refs-runtime.sh" "$sb/.claude/skills/orbit/lib/handoff-preflight.sh"

  cat > "$sb/apexyard.projects.yaml" <<YAML
projects:
  - name: $private_name
    repo: $private_repo
    workspace: workspace/$private_name
YAML

  echo "$sb/.claude/skills/orbit/lib/handoff-preflight.sh"
}
