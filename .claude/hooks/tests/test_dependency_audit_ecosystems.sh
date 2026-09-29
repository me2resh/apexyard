#!/bin/bash
# Regression tests for me2resh/apexyard#1359 - dependency audit ecosystem dispatch.
# AgDR-0176. Network is forbidden. Fixtures and stubs only.
#
# Acceptance criteria covered:
#   AC1  Detect npm + Python ecosystems from manifests
#   AC2  Python vulnerability path (pip-audit stub, OSV fallback, no silent clean)
#   AC3  Remediation is ecosystem-aware (no npm update for PyPI)
#   AC4  Severity mapping includes Unknown
#   AC5  SPDX licence lists + Unknown pending review (not banned)
#   AC6  Mixed repo: one report, per-ecosystem sections, combined totals
#   AC7  Pipeline is ecosystem-aware (path filters + python job)
#
# Fail-before is shown by running this test on dev, where the helper does not exist.

set -u
export PYTHONDONTWRITEBYTECODE=1

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HELPER="$SRC_ROOT/golden-paths/pipelines/scripts/dependency-audit.py"
FIXED_SKILL="$SRC_ROOT/.claude/skills/audit-deps/SKILL.md"
FIXED_AGENT="$SRC_ROOT/.claude/agents/dependency-auditor.md"
FIXED_PIPELINE="$SRC_ROOT/golden-paths/pipelines/dependency-audit.yml"
FIXTURE_SRC="$SRC_ROOT/.claude/hooks/tests/fixtures/dependency-audit-1359/projects"

PASS=0
FAIL=0
FAILED_CASES=""

pass() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
fail() {
  echo "FAIL [$1]: $2" >&2
  FAIL=$((FAIL + 1))
  FAILED_CASES="${FAILED_CASES}$1 "
}

# ---------------------------------------------------------------------------
# Temp workspace (never the worktree) for package.json + HTTP JSON stubs.
# ---------------------------------------------------------------------------
SB=$(mktemp -d "${TMPDIR:-/tmp}/dep-audit-1359.XXXXXX")
trap 'rm -rf "$SB"' EXIT

mkdir -p "$SB/http" "$SB/projects"

# HTTP fixtures (created outside .claude/hooks/tests to avoid JSON write blocks)
python3 - "$SB/http" <<'PY'
import json, sys
from pathlib import Path
http = Path(sys.argv[1])
files = {
  "osv_querybatch.json": {
    "results": [{"vulns": [{"id": "PYSEC-DEMO-1", "aliases": ["GHSA-demo-0001"]}]}]
  },
  "osv_vuln_PYSEC-DEMO-1.json": {
    "id": "PYSEC-DEMO-1",
    "aliases": ["GHSA-demo-0001"],
    "database_specific": {"severity": "HIGH"},
    "severity": [],
  },
  "osv_vuln_GHSA-demo-0001.json": {
    "id": "GHSA-demo-0001",
    "aliases": ["PYSEC-DEMO-1"],
    "database_specific": {"severity": "HIGH"},
    "severity": [],
  },
  "osv_vuln_PYSEC-NOSCORE.json": {
    "id": "PYSEC-NOSCORE",
    "aliases": [],
    "severity": [],
  },
  "pypi_demo-lib_1.0.0.json": {
    "info": {"name": "demo-lib", "version": "1.0.0", "license": "MIT", "classifiers": []}
  },
  "pypi_demo-lib.json": {"info": {"name": "demo-lib", "version": "1.1.0"}},
  "pypi_requests_2.31.0.json": {
    "info": {"name": "requests", "version": "2.31.0", "license": "Apache-2.0", "classifiers": []}
  },
  "pypi_requests.json": {"info": {"name": "requests", "version": "2.32.0"}},
  "pypi_safe-pkg_1.0.0.json": {
    "info": {"name": "safe-pkg", "version": "1.0.0", "license": "MIT"}
  },
  "pypi_safe-pkg.json": {"info": {"name": "safe-pkg", "version": "1.0.0"}},
}
for name, data in files.items():
    (http / name).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY

# Project trees in $SB
mkdir -p "$SB/projects/npm-only" "$SB/projects/python-only" "$SB/projects/mixed" \
  "$SB/projects/tooling-only" "$SB/projects/unpinned" "$SB/projects/poetry-lock" \
  "$SB/projects/bad-poetry-lock" "$SB/projects/hostile"

printf '%s\n' '{"name":"demo-npm","version":"1.0.0","license":"MIT"}' \
  > "$SB/projects/npm-only/package.json"
printf 'requests==2.31.0\n' > "$SB/projects/python-only/requirements.txt"
printf '%s\n' '[{"name":"requests","version":"2.31.0","id":"PYSEC-DEMO-1","aliases":["GHSA-demo-0001"],"manifest":"requirements.txt"}]' \
  > "$SB/projects/python-only/pip-audit-stub.json"
printf '%s\n' '{"name":"demo-mixed","version":"1.0.0"}' > "$SB/projects/mixed/package.json"
printf 'demo-lib==1.0.0\n' > "$SB/projects/mixed/requirements.txt"
cp "$FIXTURE_SRC/tooling-only/pyproject.toml" "$SB/projects/tooling-only/pyproject.toml"
printf 'requests>=2.0\n' > "$SB/projects/unpinned/requirements.txt"
cp "$FIXTURE_SRC/poetry-lock/poetry.lock" "$SB/projects/poetry-lock/poetry.lock"
cp "$FIXTURE_SRC/bad-poetry-lock/poetry.lock" "$SB/projects/bad-poetry-lock/poetry.lock"
# Hostile advisory text for serialization checks (synthetic names only)
printf 'safe-pkg==1.0.0\n' > "$SB/projects/hostile/requirements.txt"

run_helper() {
  local project="$1"
  shift
  python3 -I "$HELPER" "$project" "$@" 2>"$SB/helper.err"
}

# ---------------------------------------------------------------------------
# AC1 - Ecosystem detection
# ---------------------------------------------------------------------------
# AC1 fixed: python-only discovery
fixed_out=$(run_helper "$SB/projects/python-only" --skip-python-scan --skip-npm-scan) || true
if echo "$fixed_out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "python" in d.get("ecosystems",[]) else 1)'; then
  pass "AC1-fixed-detects-python"
else
  fail "AC1-fixed-detects-python" "helper output: $fixed_out"
fi

# AC1 fixed: npm-only discovery
fixed_npm=$(run_helper "$SB/projects/npm-only" --skip-npm-scan --skip-python-scan) || true
if echo "$fixed_npm" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("ecosystems")==["npm"] else 1)'; then
  pass "AC1-fixed-detects-npm"
else
  fail "AC1-fixed-detects-npm" "helper output: $fixed_npm"
fi

if grep -qE 'requirements\*\.txt|pyproject\.toml|poetry\.lock' "$FIXED_SKILL" \
  && grep -qF 'pip-audit' "$FIXED_SKILL"; then
  pass "AC1-fixed-skill-documents-python"
else
  fail "AC1-fixed-skill-documents-python" "fixed skill missing Python detection / pip-audit"
fi

# ---------------------------------------------------------------------------
# AC2 - Python vulnerability path
# ---------------------------------------------------------------------------
py_scan=$(run_helper "$SB/projects/python-only" \
  --fixture-http "$SB/http" \
  --pip-audit-stub "$SB/projects/python-only/pip-audit-stub.json" \
  --skip-npm-scan) || true
if echo "$py_scan" | python3 -c '
import json,sys
d=json.load(sys.stdin)
findings=d.get("findings") or []
ok=any(f.get("package")=="requests" and f.get("severity")=="High" for f in findings)
sys.exit(0 if ok else 1)
'; then
  pass "AC2-fixed-pip-audit-stub-finds-vuln"
else
  fail "AC2-fixed-pip-audit-stub-finds-vuln" "output: $py_scan"
fi

# Explicit --runner=pip-audit with missing tool exits 3
set +e
python3 -I "$HELPER" "$SB/projects/python-only" \
  --runner=pip-audit \
  --trusted-python "$SB/does-not-exist-python" \
  --fixture-http "$SB/http" \
  --skip-npm-scan >"$SB/missing.json" 2>"$SB/missing.err"
missing_rc=$?
set -e
if [ "$missing_rc" -eq 3 ]; then
  pass "AC2-fixed-explicit-pip-audit-missing-exits-3"
else
  fail "AC2-fixed-explicit-pip-audit-missing-exits-3" "want exit 3 got $missing_rc"
fi

# OSV fallback when pip-audit absent (no --runner override)
set +e
python3 -I "$HELPER" "$SB/projects/python-only" \
  --trusted-python "$SB/does-not-exist-python" \
  --fixture-http "$SB/http" \
  --skip-npm-scan >"$SB/osv-fallback.json" 2>"$SB/osv-fallback.err"
osv_rc=$?
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/osv-fallback.json"'"))
notes=" ".join(d.get("notes") or [])
findings=d.get("findings") or []
ok=("Falling back to direct OSV" in notes) and any(f.get("advisory_id")=="PYSEC-DEMO-1" for f in findings)
raise SystemExit(0 if ok else 1)
'; then
  pass "AC2-fixed-osv-fallback-on-missing-pip-audit"
else
  fail "AC2-fixed-osv-fallback-on-missing-pip-audit" "rc=$osv_rc notes/findings mismatch"
fi

# Unsupported lock schema stays incomplete / not clean
set +e
python3 -I "$HELPER" "$SB/projects/bad-poetry-lock" \
  --fixture-http "$SB/http" \
  --skip-npm-scan >"$SB/bad-lock.json" 2>/dev/null
bad_rc=$?
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/bad-lock.json"'"))
sets=d.get("dependency_sets") or []
ok=any(s.get("coverage")=="incomplete" for s in sets) and d.get("exit_code",0) == 3
raise SystemExit(0 if ok else 1)
'; then
  pass "AC2-fixed-unsupported-lock-incomplete"
else
  fail "AC2-fixed-unsupported-lock-incomplete" "rc=$bad_rc body=$(cat "$SB/bad-lock.json")"
fi

# ---------------------------------------------------------------------------
# AC3 - Remediation ecosystem-aware
# ---------------------------------------------------------------------------
if echo "$py_scan" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for f in d.get("findings") or []:
    if f.get("ecosystem")=="python":
        rem=f.get("remediation","")
        if rem.startswith("npm update"):
            raise SystemExit(1)
        if "Do not run npm update" not in rem:
            raise SystemExit(1)
raise SystemExit(0)
'; then
  pass "AC3-fixed-python-remediation-not-npm"
else
  fail "AC3-fixed-python-remediation-not-npm" "python finding still suggests npm update"
fi

if grep -qF 'Do not run npm update' "$FIXED_AGENT"; then
  pass "AC3-fixed-agent-documents-python-fix"
else
  fail "AC3-fixed-agent-documents-python-fix" "fixed agent missing python remediation rule"
fi

# ---------------------------------------------------------------------------
# AC4 - Severity mapping + Unknown
# ---------------------------------------------------------------------------
sev_out=$(HELPER_PATH="$HELPER" python3 - <<'PY'
import importlib.util, json, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("dep_audit", Path(os.environ["HELPER_PATH"]))
mod = importlib.util.module_from_spec(spec)
sys.modules["dep_audit"] = mod
spec.loader.exec_module(mod)
cases = []
cases.append(mod.map_npm_severity("moderate")[0] == "Medium")
cases.append(mod.map_osv_severity({"database_specific":{"severity":"HIGH"}})[0] == "High")
cases.append(mod.map_osv_severity({"database_specific":{"severity":"MODERATE"}})[0] == "Medium")
sev, reason = mod.map_osv_severity({"id":"x","severity":[]})
cases.append(sev == "Unknown" and "no severity" in reason)
sev2, _reason2 = mod.map_osv_severity({"severity":[{"type":"CVSS_V3","vector":"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"}]})
cases.append(sev2 == "Unknown")
print(json.dumps(cases))
sys.exit(0 if all(cases) else 1)
PY
)
sev_rc=$?
if [ "$sev_rc" -eq 0 ]; then
  pass "AC4-fixed-severity-mapping"
else
  fail "AC4-fixed-severity-mapping" "cases=$sev_out"
fi

if grep -qF 'Unknown' "$FIXED_SKILL" && grep -qF 'MODERATE' "$FIXED_SKILL"; then
  pass "AC4-fixed-skill-documents-severity"
else
  fail "AC4-fixed-skill-documents-severity" "fixed skill missing Unknown / MODERATE mapping"
fi

# ---------------------------------------------------------------------------
# AC5 - Licence lists
# ---------------------------------------------------------------------------
if grep -qF 'GPL-2.0-only' "$FIXED_SKILL" \
  && grep -qF 'Pending review' "$FIXED_SKILL" \
  && ! grep -qE 'Banned.*Unknown' "$FIXED_SKILL"; then
  pass "AC5-fixed-spdx-and-unknown-pending"
else
  fail "AC5-fixed-spdx-and-unknown-pending" "fixed skill licence lists incorrect"
fi

lic_out=$(HELPER_PATH="$HELPER" python3 - <<'PY'
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("dep_audit", Path(os.environ["HELPER_PATH"]))
mod = importlib.util.module_from_spec(spec)
sys.modules["dep_audit"] = mod
spec.loader.exec_module(mod)
checks = []
checks.append(mod.classify_licence("MIT") == ("allowed", "MIT"))
checks.append(mod.classify_licence("GPL-3.0-only")[0] == "restricted")
checks.append(mod.classify_licence("GPL-3.0") == ("restricted", "GPL-3.0-only"))
checks.append(mod.classify_licence("Unknown")[0] == "pending_review")
checks.append(mod.classify_licence(None)[0] == "pending_review")
checks.append(mod.classify_licence("UNLICENSED")[0] == "banned")
checks.append(mod.classify_licence("MIT AND Apache-2.0")[0] == "pending_review")
raise SystemExit(0 if all(checks) else 1)
PY
)
lic_rc=$?
if [ "$lic_rc" -eq 0 ]; then
  pass "AC5-fixed-classify-licence"
else
  fail "AC5-fixed-classify-licence" "classifier mismatch out=$lic_out"
fi

# ---------------------------------------------------------------------------
# AC6 - Mixed repository report
# ---------------------------------------------------------------------------
set +e
python3 -I "$HELPER" "$SB/projects/mixed" \
  --fixture-http "$SB/http" \
  --pip-audit-stub "$SB/projects/python-only/pip-audit-stub.json" \
  --skip-npm-scan >"$SB/mixed.json" 2>/dev/null
mixed_rc=$?
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/mixed.json"'"))
ecos=set(d.get("ecosystems") or [])
sets=d.get("dependency_sets") or []
has_npm=any(s.get("ecosystem")=="npm" for s in sets)
has_py=any(s.get("ecosystem")=="python" for s in sets)
totals=d.get("severity_totals") or {}
ok = ecos >= {"npm","python"} and has_npm and has_py and "Unknown" in totals and "Critical" in totals
raise SystemExit(0 if ok else 1)
'; then
  pass "AC6-fixed-mixed-one-report-both-ecosystems"
else
  fail "AC6-fixed-mixed-one-report-both-ecosystems" "rc=$mixed_rc $(cat "$SB/mixed.json")"
fi

# Tooling-only pyproject is not_applicable
set +e
python3 -I "$HELPER" "$SB/projects/tooling-only" --skip-python-scan --skip-npm-scan >"$SB/tooling.json" 2>/dev/null
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/tooling.json"'"))
sets=d.get("dependency_sets") or []
ok=any(s.get("coverage")=="not_applicable" for s in sets)
raise SystemExit(0 if ok else 1)
'; then
  pass "AC6-fixed-tooling-only-not-applicable"
else
  fail "AC6-fixed-tooling-only-not-applicable" "$(cat "$SB/tooling.json")"
fi

# Unpinned requirements incomplete
set +e
python3 -I "$HELPER" "$SB/projects/unpinned" --skip-python-scan --skip-npm-scan >"$SB/unpinned.json" 2>/dev/null
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/unpinned.json"'"))
sets=d.get("dependency_sets") or []
ok=any(s.get("coverage")=="incomplete" for s in sets)
raise SystemExit(0 if ok else 1)
'; then
  pass "AC6-fixed-unpinned-incomplete"
else
  fail "AC6-fixed-unpinned-incomplete" "$(cat "$SB/unpinned.json")"
fi

# Poetry lock data-only inventory
printf '[]\n' > "$SB/empty-stub.json"
set +e
python3 -I "$HELPER" "$SB/projects/poetry-lock" \
  --fixture-http "$SB/http" \
  --skip-npm-scan \
  --pip-audit-stub "$SB/empty-stub.json" >"$SB/poetry.json" 2>/dev/null
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/poetry.json"'"))
sets=d.get("dependency_sets") or []
ok=any(
  s.get("ecosystem")=="python"
  and any(p.get("name")=="demo-lib" for p in s.get("packages") or [])
  for s in sets
)
raise SystemExit(0 if ok else 1)
'; then
  pass "AC6-fixed-poetry-lock-inventory"
else
  fail "AC6-fixed-poetry-lock-inventory" "$(cat "$SB/poetry.json")"
fi

# ---------------------------------------------------------------------------
# AC7 - Pipeline ecosystem-aware
# ---------------------------------------------------------------------------
if grep -qF 'pyproject.toml' "$FIXED_PIPELINE" \
  && grep -qF 'poetry.lock' "$FIXED_PIPELINE" \
  && grep -qF 'python-audit' "$FIXED_PIPELINE" \
  && grep -qF 'pip-audit==2.10.0' "$FIXED_PIPELINE" \
  && grep -qF 'dependency-audit.py' "$FIXED_PIPELINE"; then
  pass "AC7-fixed-pipeline-python-job-and-paths"
else
  fail "AC7-fixed-pipeline-python-job-and-paths" "fixed pipeline missing python job / paths / helper"
fi

# Preserve npm job
if grep -qF 'npm-audit' "$FIXED_PIPELINE" && grep -qF 'setup-node' "$FIXED_PIPELINE"; then
  pass "AC7-fixed-pipeline-keeps-npm"
else
  fail "AC7-fixed-pipeline-keeps-npm" "npm path removed"
fi

# Pinned action SHAs (no floating tags alone)
if grep -E 'uses: actions/(checkout|setup-node|setup-python|upload-artifact|download-artifact|github-script)@[0-9a-f]{40}' "$FIXED_PIPELINE" \
  | grep -q checkout \
  && grep -q 'setup-python@[0-9a-f]\{40\}' "$FIXED_PIPELINE"; then
  pass "AC7-fixed-pipeline-pinned-shas"
else
  fail "AC7-fixed-pipeline-pinned-shas" "missing full commit SHA pins"
fi

# github-script reads report from file, does not interpolate package names via expressions
if grep -qF "fs.readFileSync('combined-report.json'" "$FIXED_PIPELINE" \
  && ! grep -qE "\$\{\{.*package" "$FIXED_PIPELINE"; then
  pass "AC7-fixed-pipeline-no-expression-interpolation"
else
  fail "AC7-fixed-pipeline-no-expression-interpolation" "unsafe expression interpolation risk"
fi

# Helper revision recorded
if grep -qF 'HELPER_REVISION' "$HELPER" && grep -qF 'helper_revision' "$FIXED_SKILL"; then
  pass "AC7-fixed-helper-revision-documented"
else
  fail "AC7-fixed-helper-revision-documented" "helper revision missing"
fi

# Conflicting filters exit 2
set +e
python3 -I "$HELPER" "$SB/projects/mixed" --ecosystem=npm --language=python >"$SB/conflict.json" 2>"$SB/conflict.err"
conflict_rc=$?
set -e
if [ "$conflict_rc" -eq 2 ]; then
  pass "AC-extra-conflicting-filters-exit-2"
else
  fail "AC-extra-conflicting-filters-exit-2" "want 2 got $conflict_rc"
fi

# Success path: discovery-only should not write stderr
set +e
python3 -I "$HELPER" "$SB/projects/npm-only" --skip-npm-scan --skip-python-scan \
  >"$SB/quiet.out" 2>"$SB/quiet.err"
set -e
if [ ! -s "$SB/quiet.err" ]; then
  pass "AC-extra-no-stderr-on-success"
else
  fail "AC-extra-no-stderr-on-success" "stderr: $(cat "$SB/quiet.err")"
fi

# Shared helper exists beside pipeline
if [ -f "$SRC_ROOT/golden-paths/pipelines/scripts/dependency-audit-tools.lock.json" ]; then
  pass "AC-extra-tools-lock-present"
else
  fail "AC-extra-tools-lock-present" "missing tooling lock"
fi

echo ""
echo "----------------------------------------"
echo "dependency-audit #1359 tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
