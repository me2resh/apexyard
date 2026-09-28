#!/bin/bash
# _lib-fixtures.sh — shared sandbox + ORBIT record fixtures for the
# /orbit handoff smoke tests (apexyard#1446).
#
# Builds a throwaway orbit_root with a matching Plan, Snapshot,
# Reconciliation and Execution Slice, all named with synthetic
# (non-portfolio) identifiers, and a mock `orbit`/`gh` on PATH.
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
# set under <sandbox>/orbit. Prints the orbit_root path.
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
  "projectId": "demo-widget",
  "capturedAt": "2026-09-28T00:00:00Z",
  "repositories": { "demo-widget": "0000000000000000000000000000000000000a" }
}
JSON

  cat > "$orbit_root/reconciliations/reconciliation-demo-widget-r1.json" <<'JSON'
{
  "specVersion": "0.1",
  "id": "reconciliation-demo-widget-r1",
  "planId": "plan-demo-widget",
  "planRevision": 1,
  "projectSnapshotId": "snapshot-demo-widget-1",
  "criteria": [{ "criterionId": "ac1-1", "status": "not-verified", "evidence": "none", "explanation": "fixture" }]
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
# `sync github --dry-run`'s exit code (default 0, printing a fixed preview).
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
  echo '{"dryRun":true,"repo":"demo-org/demo-widget","title":"[Slice] Fixture objective for the handoff smoke test.","body":"slice-demo-widget-o1"}'
  exit 0
fi
echo "mock orbit: unhandled args: \$*" >&2
exit 99
EOF
  chmod +x "$sb/bin/orbit"
}

# Installs a mock `gh` on PATH inside <sandbox>/bin. `issue_count` controls
# how many rows `gh issue list --search ...` reports (default 0, meaning no
# duplicate found).
fixtures_install_mock_gh() {
  sb="$1"
  issue_count="${2:-0}"
  mkdir -p "$sb/bin"
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
  if [ "$issue_count" = "0" ]; then
    echo '[]'
  else
    echo '[{"number":4242}]'
  fi
  exit 0
fi
echo "mock gh: unhandled args: \$*" >&2
exit 99
EOF
  chmod +x "$sb/bin/gh"
}
