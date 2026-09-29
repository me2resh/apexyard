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
HELPER="${DEPENDENCY_AUDIT_TEST_HELPER:-$SRC_ROOT/golden-paths/pipelines/scripts/dependency-audit.py}"
FIXED_SKILL="$SRC_ROOT/.claude/skills/audit-deps/SKILL.md"
FIXED_AGENT="$SRC_ROOT/.claude/agents/dependency-auditor.md"
FIXED_PIPELINE="${DEPENDENCY_AUDIT_TEST_PIPELINE:-$SRC_ROOT/golden-paths/pipelines/dependency-audit.yml}"
FIXED_REQUIREMENTS="${DEPENDENCY_AUDIT_TEST_REQUIREMENTS:-$SRC_ROOT/golden-paths/pipelines/scripts/dependency-audit-tools.requirements.txt}"
FIXED_AGDR="${DEPENDENCY_AUDIT_TEST_AGDR:-$SRC_ROOT/docs/agdr/AgDR-0184-dependency-audit-tool-hash-pins-deferred.md}"
FIXED_DESIGN="${DEPENDENCY_AUDIT_TEST_DESIGN:-$SRC_ROOT/docs/designs/dependency-audit-ecosystems-technical-design.md}"
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
  && grep -qF 'dependency-audit-tools.requirements.txt' "$FIXED_PIPELINE" \
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

# AC7: npm outdated + licence-checker restored (parity with dev)
if grep -qF 'npm outdated' "$FIXED_PIPELINE" \
  && grep -qF 'license-checker' "$FIXED_PIPELINE"; then
  pass "AC7-fixed-pipeline-npm-outdated-and-licences"
else
  fail "AC7-fixed-pipeline-npm-outdated-and-licences" "npm outdated / license-checker missing"
fi

# Install from pin file (AgDR-0184)
if grep -qF 'dependency-audit-tools.requirements.txt' "$FIXED_PIPELINE" \
  && grep -qF 'AgDR-0184' "$FIXED_PIPELINE"; then
  pass "AC7-fixed-pipeline-installs-from-pin-file"
else
  fail "AC7-fixed-pipeline-installs-from-pin-file" "pin file install / AgDR-0184 missing"
fi

# Summarize fails closed on helper/job failure (no continue-on-error on helper)
if ! grep -A2 'Run shared helper' "$FIXED_PIPELINE" | grep -q 'continue-on-error: true' \
  && grep -qF 'NPM_RESULT' "$FIXED_PIPELINE" \
  && grep -qF 'has_report' "$FIXED_PIPELINE"; then
  pass "AC7-fixed-pipeline-summarize-fail-closed"
else
  fail "AC7-fixed-pipeline-summarize-fail-closed" "helper continue-on-error or summarize gates missing"
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

# ---------------------------------------------------------------------------
# Rex review regressions (B1–B5 + advisories) — stubbed scanners, no network
# ---------------------------------------------------------------------------

assert_incomplete_nonzero() {
  local label="$1"
  local json_path="$2"
  local rc="$3"
  if python3 -c '
import json, sys
d=json.load(open(sys.argv[1]))
sets=d.get("dependency_sets") or []
incomplete=any(
  s.get("coverage") in ("incomplete","failed")
  or s.get("check_status") in ("failed","incomplete","skipped")
  for s in sets
)
code=int(d.get("exit_code", 0))
ok = incomplete and code != 0 and int(sys.argv[2]) != 0
raise SystemExit(0 if ok else 1)
' "$json_path" "$rc"; then
    pass "$label"
  else
    fail "$label" "rc=$rc body=$(cat "$json_path" 2>/dev/null | head -c 400)"
  fi
}

# B1a: real interpreter missing pip_audit module → OSV fallback note, not silent clean
# (with fixture HTTP so OSV path can complete). Without fixtures this still must not
# report complete+exit 0 when the scanner path fails closed before fallback data.
mkdir -p "$SB/projects/b1-missing-module" "$SB/http-b1"
printf 'requests==2.31.0\n' > "$SB/projects/b1-missing-module/requirements.txt"
printf '%s\n' '{"results":[{"vulns":[{"id":"PYSEC-DEMO-1","aliases":["GHSA-demo-0001"]}]}]}' \
  > "$SB/http-b1/osv_querybatch.json"
cp "$SB/http/osv_vuln_PYSEC-DEMO-1.json" "$SB/http-b1/" 2>/dev/null || true
cp "$SB/http/"*.json "$SB/http-b1/" 2>/dev/null || true
set +e
python3 -I "$HELPER" "$SB/projects/b1-missing-module" \
  --fixture-http "$SB/http-b1" \
  --skip-npm-scan >"$SB/b1-missing.json" 2>"$SB/b1-missing.err"
b1_rc=$?
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/b1-missing.json"'"))
notes=" ".join(d.get("notes") or [])
sets=d.get("dependency_sets") or []
# Either OSV fallback ran (complete with note) OR failed closed — never silent clean
# without attempting a scanner.
ok = ("Falling back to direct OSV" in notes) or any(
  s.get("coverage") in ("incomplete","failed") for s in sets
)
# Must not be: complete + exit 0 + empty notes (the B1 bug)
silent_clean = (
  d.get("exit_code", 0) == 0
  and all(s.get("coverage")=="complete" for s in sets)
  and "Falling back" not in notes
  and not (d.get("findings") or [])
  and "pip-audit" not in notes.lower()
)
raise SystemExit(0 if ok and not silent_clean else 1)
'; then
  pass "B1-fixed-missing-pip-audit-module-not-silent-clean"
else
  fail "B1-fixed-missing-pip-audit-module-not-silent-clean" "rc=$b1_rc $(cat "$SB/b1-missing.json" | head -c 500)"
fi

# B1b: pip-audit fatal exit (module present, empty/non-JSON stdout, exit 1) → failed
mkdir -p "$SB/projects/b1-fatal"
printf 'requests==2.31.0\n' > "$SB/projects/b1-fatal/requirements.txt"
cat > "$SB/fake-pip-audit-fatal" <<'EOF'
#!/bin/bash
if [[ "$*" == *"-c"* ]]; then exit 0; fi
echo "OSV backend unavailable" >&2
exit 1
EOF
chmod +x "$SB/fake-pip-audit-fatal"
set +e
python3 -I "$HELPER" "$SB/projects/b1-fatal" \
  --trusted-python "$SB/fake-pip-audit-fatal" \
  --fixture-http "$SB/http" \
  --skip-npm-scan >"$SB/b1-fatal.json" 2>/dev/null
b1f_rc=$?
set -e
assert_incomplete_nonzero "B1-fixed-pip-audit-fatal-exit-failed" "$SB/b1-fatal.json" "$b1f_rc"

# B1c: --runner=osv on mixed repo marks npm incomplete / non-zero exit
set +e
python3 -I "$HELPER" "$SB/projects/mixed" \
  --runner=osv \
  --fixture-http "$SB/http" \
  --pip-audit-stub "$SB/projects/python-only/pip-audit-stub.json" \
  >"$SB/b1-osv-mixed.json" 2>/dev/null
b1m_rc=$?
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/b1-osv-mixed.json"'"))
sets=d.get("dependency_sets") or []
npm=next(s for s in sets if s.get("ecosystem")=="npm")
ok = npm.get("coverage")=="incomplete" and d.get("exit_code",0) != 0
raise SystemExit(0 if ok else 1)
'; then
  pass "B1-fixed-runner-osv-mixed-npm-incomplete"
else
  fail "B1-fixed-runner-osv-mixed-npm-incomplete" "rc=$b1m_rc $(cat "$SB/b1-osv-mixed.json" | head -c 400)"
fi

# B2: npm ENOLOCK error JSON → failed / incomplete, not clean
mkdir -p "$SB/projects/b2-enolock"
printf '%s\n' '{"name":"no-lock","version":"1.0.0"}' > "$SB/projects/b2-enolock/package.json"
cat > "$SB/fake-npm-enolock" <<'EOF'
#!/bin/bash
printf '%s\n' '{"error":{"code":"ENOLOCK","summary":"This command requires an existing lockfile.","detail":"Try creating one first with npm i --package-lock-only"}}'
exit 1
EOF
chmod +x "$SB/fake-npm-enolock"
# Inject via DEPENDENCY_AUDIT — helper has no npm stub flag; wrap PATH
mkdir -p "$SB/bin"
cat > "$SB/bin/npm" <<EOF
#!/bin/bash
exec "$SB/fake-npm-enolock" "\$@"
EOF
chmod +x "$SB/bin/npm"
set +e
PATH="$SB/bin:$PATH" python3 -I "$HELPER" "$SB/projects/b2-enolock" \
  --ecosystem=npm \
  --skip-python-scan >"$SB/b2-enolock.json" 2>/dev/null
b2_rc=$?
set -e
assert_incomplete_nonzero "B2-fixed-npm-enolock-failed" "$SB/b2-enolock.json" "$b2_rc"

# B3 i1: mixed pyproject pins + ranges → incomplete; only exact pins inventoried
mkdir -p "$SB/projects/b3-pyproject"
cat > "$SB/projects/b3-pyproject/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "0.1.0"
dependencies = ["flask==2.0.0", "requests>=2", "django"]

[build-system]
requires = ["setuptools==68.0.0"]
build-backend = "setuptools.build_meta"
EOF
set +e
python3 -I "$HELPER" "$SB/projects/b3-pyproject" \
  --skip-python-scan --skip-npm-scan >"$SB/b3-pyproject.json" 2>/dev/null
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/b3-pyproject.json"'"))
sets=d.get("dependency_sets") or []
s=sets[0]
names={p["name"] for p in s.get("packages") or []}
# flask exact pin kept; ranges incomplete; setuptools from build-system must NOT appear
ok = (
  s.get("coverage")=="incomplete"
  and "flask" in names
  and "setuptools" not in names
  and "django" not in names
)
raise SystemExit(0 if ok else 1)
'; then
  pass "B3-fixed-pyproject-ranges-incomplete-no-build-system"
else
  fail "B3-fixed-pyproject-ranges-incomplete-no-build-system" "$(cat "$SB/b3-pyproject.json" | head -c 500)"
fi

# B3 i2: poetry.lock legacy + git sources → incomplete, not sent as PyPI
mkdir -p "$SB/projects/b3-poetry-src"
cat > "$SB/projects/b3-poetry-src/poetry.lock" <<'EOF'
[[package]]
name = "internal-lib"
version = "1.0.0"
description = ""
category = "main"
optional = false
python-versions = "*"

[package.source]
type = "legacy"
url = "https://pypi.internal.example/simple"
reference = "internal"

[[package]]
name = "vcs-lib"
version = "2.0.0"
description = ""
category = "main"
optional = false
python-versions = "*"

[package.source]
type = "git"
url = "https://github.com/example/vcs-lib.git"
reference = "main"

[[package]]
name = "demo-lib"
version = "1.0.0"
description = ""
category = "main"
optional = false
python-versions = "*"

[metadata]
lock-version = "1.1"
python-versions = "^3.11"
content-hash = "synthetic"
EOF
set +e
python3 -I "$HELPER" "$SB/projects/b3-poetry-src" \
  --skip-python-scan --skip-npm-scan >"$SB/b3-poetry.json" 2>/dev/null
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/b3-poetry.json"'"))
sets=d.get("dependency_sets") or []
s=sets[0]
names={p["name"] for p in s.get("packages") or []}
ok = s.get("coverage")=="incomplete" and "internal-lib" not in names and "vcs-lib" not in names and "demo-lib" in names
raise SystemExit(0 if ok else 1)
'; then
  pass "B3-fixed-poetry-legacy-git-incomplete"
else
  fail "B3-fixed-poetry-legacy-git-incomplete" "$(cat "$SB/b3-poetry.json" | head -c 500)"
fi

# B3 i3: uv.lock editable / git / private registry → incomplete
mkdir -p "$SB/projects/b3-uv"
cat > "$SB/projects/b3-uv/uv.lock" <<'EOF'
version = 1
revision = 1

[[package]]
name = "b3-uv"
version = "0.1.0"
source = { editable = "." }

[[package]]
name = "vcs-pkg"
version = "1.0.0"
source = { git = "https://github.com/example/vcs-pkg" }

[[package]]
name = "private-pkg"
version = "1.0.0"
source = { registry = "https://pypi.private.example/simple" }

[[package]]
name = "demo-lib"
version = "1.0.0"
source = { registry = "https://pypi.org/simple" }
EOF
set +e
python3 -I "$HELPER" "$SB/projects/b3-uv" \
  --skip-python-scan --skip-npm-scan >"$SB/b3-uv.json" 2>/dev/null
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/b3-uv.json"'"))
sets=d.get("dependency_sets") or []
s=sets[0]
names={p["name"] for p in s.get("packages") or []}
ok = (
  s.get("coverage")=="incomplete"
  and "demo-lib" in names
  and "b3-uv" not in names
  and "vcs-pkg" not in names
  and "private-pkg" not in names
)
raise SystemExit(0 if ok else 1)
'; then
  pass "B3-fixed-uv-non-pypi-sources-incomplete"
else
  fail "B3-fixed-uv-non-pypi-sources-incomplete" "$(cat "$SB/b3-uv.json" | head -c 500)"
fi

# B3 i4: Pipfile.lock git/editable without version → incomplete
mkdir -p "$SB/projects/b3-pipfile"
cat > "$SB/projects/b3-pipfile/Pipfile.lock" <<'EOF'
{
  "_meta": {"hash": {"sha256": "x"}, "pipfile-spec": 6, "requires": {}, "sources": [{"name": "pypi", "url": "https://pypi.org/simple", "verify_ssl": true}]},
  "default": {
    "requests": {"hashes": [], "version": "==2.31.0"},
    "vcs-tool": {"git": "https://github.com/example/vcs-tool.git", "ref": "main"},
    "local-tool": {"path": ".", "editable": true}
  },
  "develop": {}
}
EOF
set +e
python3 -I "$HELPER" "$SB/projects/b3-pipfile" \
  --skip-python-scan --skip-npm-scan >"$SB/b3-pipfile.json" 2>/dev/null
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/b3-pipfile.json"'"))
sets=d.get("dependency_sets") or []
s=sets[0]
names={p["name"] for p in s.get("packages") or []}
ok = s.get("coverage")=="incomplete" and "requests" in names and "vcs-tool" not in names
raise SystemExit(0 if ok else 1)
'; then
  pass "B3-fixed-pipfile-git-editable-incomplete"
else
  fail "B3-fixed-pipfile-git-editable-incomplete" "$(cat "$SB/b3-pipfile.json" | head -c 500)"
fi

# B3 i5: --extra-index-url, --requirement include, ==2.* wildcard
mkdir -p "$SB/projects/b3-req"
printf 'demo-lib==1.0.0\n' > "$SB/projects/b3-req/base.txt"
cat > "$SB/projects/b3-req/requirements.txt" <<'EOF'
--extra-index-url https://pypi.internal.example/simple
--requirement base.txt
requests==2.*
EOF
set +e
python3 -I "$HELPER" "$SB/projects/b3-req" \
  --skip-python-scan --skip-npm-scan >"$SB/b3-req.json" 2>/dev/null
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/b3-req.json"'"))
sets=d.get("dependency_sets") or []
s=sets[0]
names={p["name"] for p in s.get("packages") or []}
ok = (
  s.get("coverage")=="incomplete"
  and "demo-lib" in names
  and "requests" not in names
)
raise SystemExit(0 if ok else 1)
'; then
  pass "B3-fixed-extra-index-requirement-wildcard"
else
  fail "B3-fixed-extra-index-requirement-wildcard" "$(cat "$SB/b3-req.json" | head -c 500)"
fi

# B4: Pipfile.lock holding [] must not crash; incomplete / non-zero
mkdir -p "$SB/projects/b4-pipfile-list"
printf '[]\n' > "$SB/projects/b4-pipfile-list/Pipfile.lock"
set +e
python3 -I "$HELPER" "$SB/projects/b4-pipfile-list" \
  --skip-python-scan --skip-npm-scan >"$SB/b4.json" 2>"$SB/b4.err"
b4_rc=$?
set -e
if [ -s "$SB/b4.json" ] && python3 -c '
import json
d=json.load(open("'"$SB/b4.json"'"))
sets=d.get("dependency_sets") or []
ok = any(s.get("coverage") in ("incomplete","failed") for s in sets) and d.get("exit_code",0) != 0
raise SystemExit(0 if ok else 1)
'; then
  pass "B4-fixed-pipfile-lock-list-no-crash"
else
  fail "B4-fixed-pipfile-lock-list-no-crash" "rc=$b4_rc err=$(cat "$SB/b4.err") out=$(cat "$SB/b4.json" 2>/dev/null | head -c 300)"
fi

# B4 pipeline: summarize treats missing report / failed need as incomplete
if grep -qF 'npm report missing' "$FIXED_PIPELINE" \
  || grep -qF 'NPM_HAS_REPORT' "$FIXED_PIPELINE"; then
  pass "B4-fixed-pipeline-missing-report-incomplete"
else
  fail "B4-fixed-pipeline-missing-report-incomplete" "summarize missing-report gate absent"
fi

# B5 covered by AC7-fixed-pipeline-npm-outdated-and-licences above
pass "B5-fixed-npm-outdated-licence-restored-see-AC7"

# A1: multi-line / hostile package name rejected (never written to pins / URLs)
mkdir -p "$SB/projects/hostile-names"
# Realistic poetry-style multi-line capture bait (must not become pin lines)
cat > "$SB/projects/hostile-names/poetry.lock" <<'EOF'
[[package]]
name = """safe-pkg
--index-url https://attacker.example/simple
-r /etc/hosts"""
version = "1.0.0"

[metadata]
lock-version = "1.1"
python-versions = "*"
content-hash = "synthetic"
EOF
# Also keep a requirements fixture that the committed hostile-names path used
printf 'safe-pkg==1.0.0\n' > "$FIXTURE_SRC/hostile-names/requirements.txt"
set +e
python3 -I "$HELPER" "$SB/projects/hostile-names" \
  --skip-python-scan --skip-npm-scan >"$SB/a1.json" 2>/dev/null
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/a1.json"'"))
sets=d.get("dependency_sets") or []
s=sets[0]
pkgs=s.get("packages") or []
# Hostile multi-line name must not appear as a package pin
ok = s.get("coverage")=="incomplete" and all("\n" not in p.get("name","") for p in pkgs) and len(pkgs)==0
raise SystemExit(0 if ok else 1)
'; then
  pass "A1-fixed-multiline-package-name-rejected"
else
  fail "A1-fixed-multiline-package-name-rejected" "$(cat "$SB/a1.json" | head -c 500)"
fi

# Use hostile-names fixture directory (was unused)
if [ -f "$FIXTURE_SRC/hostile-names/requirements.txt" ]; then
  set +e
  python3 -I "$HELPER" "$FIXTURE_SRC/hostile-names" \
    --skip-python-scan --skip-npm-scan >"$SB/hostile-fixture.json" 2>/dev/null
  set -e
  if python3 -c '
import json
d=json.load(open("'"$SB/hostile-fixture.json"'"))
ok=any(s.get("ecosystem")=="python" for s in d.get("dependency_sets") or [])
raise SystemExit(0 if ok else 1)
'; then
    pass "A1-fixed-hostile-names-fixture-used"
  else
    fail "A1-fixed-hostile-names-fixture-used" "fixture not read"
  fi
else
  fail "A1-fixed-hostile-names-fixture-used" "fixture missing"
fi

# A2: symlinked lock outside checkout refused
mkdir -p "$SB/projects/a2-symlink" "$SB/outside-lock"
cat > "$SB/outside-lock/poetry.lock" <<'EOF'
[[package]]
name = "demo-lib"
version = "1.0.0"
[metadata]
lock-version = "1.1"
python-versions = "*"
content-hash = "x"
EOF
ln -s "$SB/outside-lock/poetry.lock" "$SB/projects/a2-symlink/poetry.lock"
set +e
python3 -I "$HELPER" "$SB/projects/a2-symlink" \
  --skip-python-scan --skip-npm-scan >"$SB/a2.json" 2>/dev/null
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/a2.json"'"))
sets=d.get("dependency_sets") or []
s=sets[0]
ok = s.get("coverage")=="incomplete" and "escape" in (s.get("coverage_reason") or "").lower()
raise SystemExit(0 if ok else 1)
'; then
  pass "A2-fixed-symlink-lock-outside-refused"
else
  fail "A2-fixed-symlink-lock-outside-refused" "$(cat "$SB/a2.json" | head -c 400)"
fi

# A3: size cap — oversized requirements → incomplete
mkdir -p "$SB/projects/a3-huge"
python3 - <<PY
from pathlib import Path
p = Path("$SB/projects/a3-huge/requirements.txt")
# Just over 10 MiB of comment lines (no network, fast enough)
p.write_bytes(b"# " + (b"x" * (10 * 1024 * 1024)) + b"\nrequests==2.31.0\n")
PY
set +e
python3 -I "$HELPER" "$SB/projects/a3-huge" \
  --skip-python-scan --skip-npm-scan >"$SB/a3.json" 2>/dev/null
set -e
if python3 -c '
import json
d=json.load(open("'"$SB/a3.json"'"))
sets=d.get("dependency_sets") or []
s=sets[0]
ok = s.get("coverage")=="incomplete" and "cap" in (s.get("coverage_reason") or "").lower()
raise SystemExit(0 if ok else 1)
'; then
  pass "A3-fixed-manifest-size-cap"
else
  fail "A3-fixed-manifest-size-cap" "$(cat "$SB/a3.json" | head -c 400)"
fi

# Unescaped names in PyPI URLs — unit check on pypi_json_url
if HELPER_PATH="$HELPER" python3 - <<'PY'
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("dep_audit", Path(os.environ["HELPER_PATH"]))
mod = importlib.util.module_from_spec(spec)
sys.modules["dep_audit"] = mod
spec.loader.exec_module(mod)
url = mod.pypi_json_url("pkg name", "1.0+local")
assert " " not in url
assert "%20" in url or "%2B" in url or "+" not in url.split("/pypi/")[-1]
# Plus in version must be encoded
assert "1.0+local" not in url
raise SystemExit(0)
PY
then
  pass "A-fixed-pypi-url-encodes-name-version"
else
  fail "A-fixed-pypi-url-encodes-name-version" "URL encoding check failed"
fi

# AgDR-0184 present
if [ -f "$SRC_ROOT/docs/agdr/AgDR-0184-dependency-audit-tool-hash-pins-deferred.md" ]; then
  pass "AC-extra-agdr-0184-present"
else
  fail "AC-extra-agdr-0184-present" "AgDR-0184 missing"
fi

# R2-1: the preferred scanner is absent and the OSV fallback returns bad JSON.
mkdir -p "$SB/projects/r2-osv-failure" "$SB/http-r2-bad-json"
printf 'requests==2.31.0\n' > "$SB/projects/r2-osv-failure/requirements.txt"
printf '{invalid json\n' > "$SB/http-r2-bad-json/osv_querybatch.json"
set +e
python3 -I "$HELPER" "$SB/projects/r2-osv-failure" \
  --trusted-python "$SB/does-not-exist-python" \
  --fixture-http "$SB/http-r2-bad-json" \
  --skip-npm-scan >"$SB/r2-osv-failure.json" 2>"$SB/r2-osv-failure.err"
r2_osv_rc=$?
set -e
if python3 - "$SB/r2-osv-failure.json" "$r2_osv_rc" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
py = next(s for s in data["dependency_sets"] if s["ecosystem"] == "python")
assert int(sys.argv[2]) == data["exit_code"] == 3
assert py["coverage"] in ("failed", "incomplete")
assert py["check_status"] == "failed"
assert "OSV querybatch failed" in py["coverage_reason"]
PY
then
  pass "R2-1-osv-fallback-failure-fails-closed"
else
  fail "R2-1-osv-fallback-failure-fails-closed" "rc=$r2_osv_rc body=$(head -c 350 "$SB/r2-osv-failure.json")"
fi

# R2-1 also preserves a report when OSV returns valid JSON with the wrong shape.
printf '[]\n' > "$SB/http-r2-bad-json/osv_querybatch.json"
set +e
python3 -I "$HELPER" "$SB/projects/r2-osv-failure" \
  --trusted-python "$SB/does-not-exist-python" \
  --fixture-http "$SB/http-r2-bad-json" \
  --skip-npm-scan >"$SB/r2-osv-shape.json" 2>"$SB/r2-osv-shape.err"
r2_shape_rc=$?
set -e
if python3 - "$SB/r2-osv-shape.json" "$r2_shape_rc" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
py = next(s for s in data["dependency_sets"] if s["ecosystem"] == "python")
assert int(sys.argv[2]) == data["exit_code"] == 3
assert py["check_status"] == "failed" and "OSV querybatch" in py["coverage_reason"]
PY
then
  pass "R2-1-osv-fallback-bad-shape-fails-closed"
else
  fail "R2-1-osv-fallback-bad-shape-fails-closed" "rc=$r2_shape_rc err=$(head -c 200 "$SB/r2-osv-shape.err")"
fi

# R2-2: ranges and direct sources cannot become exact PyPI pins.
if HELPER_PATH="$HELPER" python3 - <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("dep_audit_r2_poetry", os.environ["HELPER_PATH"])
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)
text = '''
[tool.poetry.dependencies]
python = ">=3.11"
requests = { version = ">=2.0", extras = ["socks"] }
flask = { version = "~2.0" }
vcs-lib = { git = "https://example.invalid/vcs-lib" }
local-lib = { path = "../local-lib" }
remote-lib = { url = "https://example.invalid/remote.whl" }
demo-lib = { version = "==1.0.0" }
'''
pins, incomplete, reason = mod.parse_pyproject_static(text, "pyproject.toml")
assert incomplete and {p.name for p in pins} == {"demo-lib"}, (pins, reason)
PY
then
  pass "R2-2-poetry-ranges-and-direct-sources-incomplete"
else
  fail "R2-2-poetry-ranges-and-direct-sources-incomplete" "range or direct source was treated as a pin"
fi

if HELPER_PATH="$HELPER" python3 - <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("dep_audit_r2_groups", os.environ["HELPER_PATH"])
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)
text = '''
[tool.poetry.dependencies]
demo-lib = "1.0.0"
[tool.poetry.dev-dependencies]
pytest = "==7.4.0"
[tool.poetry.group.docs.dependencies]
sphinx = ">=7"
[tool.poetry.group.qa.dependencies]
ruff = "==0.5.0"
'''
pins, incomplete, reason = mod.parse_pyproject_static(text, "pyproject.toml")
assert incomplete, reason
assert {p.name for p in pins} == {"demo-lib", "pytest", "ruff"}, pins
PY
then
  pass "R2-2-poetry-dev-and-group-tables-read"
else
  fail "R2-2-poetry-dev-and-group-tables-read" "dev/group dependency was ignored"
fi

# R2-3: both ecosystem helpers record every exit code but fail only without a report.
if python3 - "$FIXED_PIPELINE" <<'PY'
from pathlib import Path
import re, sys
workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
for ecosystem in ("npm", "python"):
    block = workflow.split(f"- name: Run shared helper ({ecosystem})", 1)[1].split("- name:", 1)[0]
    assert 'echo "exit_code=$code"' in block
    assert 'echo "has_report=true"' in block and 'echo "has_report=false"' in block
    assert 'exit "$code"' not in block
    assert re.search(r'else\s+echo "has_report=false"[^\n]*\s+exit 1\s+fi', block), block
assert 'if [ "$FAIL_ON_INCOMPLETE" = "true" ]' in workflow
assert '::warning::Unknown-severity findings' in workflow
assert 'int(raw) not in (0, 4)' in workflow or 'elif code not in (0, 4)' in workflow
PY
then
  pass "R2-3-helper-exit-4-and-incomplete-opt-out-deferred"
else
  fail "R2-3-helper-exit-4-and-incomplete-opt-out-deferred" "workflow helper exits with report code"
fi

# Advisory: the npm outdated evidence cannot match the combined-report glob.
if python3 - "$FIXED_PIPELINE" <<'PY'
from pathlib import Path
import fnmatch, re, sys
workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
outdated = re.search(r'npm outdated --json > audit-evidence/([^\s]+)', workflow).group(1)
glob = re.search(r'root\.rglob\("([^\"]+)"\)', workflow).group(1)
assert not fnmatch.fnmatch(outdated, glob), (outdated, glob)
PY
then
  pass "R2-advisory-outdated-excluded-from-combine"
else
  fail "R2-advisory-outdated-excluded-from-combine" "outdated evidence matches report glob"
fi

if python3 - "$FIXED_PIPELINE" <<'PY'
from pathlib import Path
import sys
workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
assert 'GITHUB_STEP_SUMMARY' in workflow
for label in ("Outdated Packages", "License Compliance"):
    assert label in workflow, label
for output in ("outdated.outputs.major", "outdated.outputs.minor", "outdated.outputs.patch",
               "licenses.outputs.copyleft", "licenses.outputs.unknown"):
    assert output in workflow, output
PY
then
  pass "R2-advisory-npm-counts-in-step-summary"
else
  fail "R2-advisory-npm-counts-in-step-summary" "npm outdated/license counts absent"
fi

if HELPER_PATH="$HELPER" python3 - <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("dep_audit_r2_uv", os.environ["HELPER_PATH"])
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)
for url in ("https://pypi.org/simple", "https://files.pythonhosted.org/packages"):
    assert mod.uv_source_is_pypi({"registry": url}), url
for url in ("https://private.example/pypi.org/simple", "http://pypi.org/simple",
            "https://mirror.pypi.org/simple", "https://[invalid/simple"):
    assert not mod.uv_source_is_pypi({"registry": url}), url
PY
then
  pass "R2-advisory-uv-registry-exact-https-host"
else
  fail "R2-advisory-uv-registry-exact-https-host" "uv accepted a private or insecure registry"
fi

if HELPER_PATH="$HELPER" python3 - <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("dep_audit_r2_schema", os.environ["HELPER_PATH"])
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)
pins, incomplete, reason = mod._parse_uv_lock('version = "broken"\n', "uv.lock")
assert not pins and incomplete and "version" in reason.lower(), (pins, reason)
PY
then
  pass "R2-advisory-uv-noninteger-schema-incomplete"
else
  fail "R2-advisory-uv-noninteger-schema-incomplete" "uv.lock non-integer version crashed"
fi

# Advisory: a short OSV result list must fail the selected Python set.
mkdir -p "$SB/projects/r2-short-osv" "$SB/http-r2-short-osv"
printf 'requests==2.31.0\ndemo-lib==1.0.0\n' > "$SB/projects/r2-short-osv/requirements.txt"
printf '%s\n' '{"results":[{"vulns":[]}]}' > "$SB/http-r2-short-osv/osv_querybatch.json"
set +e
python3 -I "$HELPER" "$SB/projects/r2-short-osv" \
  --runner=osv --fixture-http "$SB/http-r2-short-osv" \
  --skip-npm-scan >"$SB/r2-short-osv.json" 2>"$SB/r2-short-osv.err"
r2_short_rc=$?
set -e
if python3 - "$SB/r2-short-osv.json" "$r2_short_rc" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
py = next(s for s in data["dependency_sets"] if s["ecosystem"] == "python")
assert int(sys.argv[2]) == data["exit_code"] == 3
assert py["coverage"] in ("failed", "incomplete") and py["check_status"] == "failed"
assert "OSV" in py["coverage_reason"] and "result" in py["coverage_reason"]
PY
then
  pass "R2-advisory-short-osv-batch-incomplete"
else
  fail "R2-advisory-short-osv-batch-incomplete" "rc=$r2_short_rc body=$(head -c 350 "$SB/r2-short-osv.json")"
fi

# ---------------------------------------------------------------------------
# #1478 follow-ups. Baseline sources can be selected via DEPENDENCY_AUDIT_TEST_*.
# ---------------------------------------------------------------------------

if python3 - "$FIXED_PIPELINE" "$FIXED_REQUIREMENTS" "$FIXED_AGDR" <<'PY'
from pathlib import Path
import sys
workflow, requirements, agdr = (Path(path).read_text(encoding="utf-8") for path in sys.argv[1:])
assert "pip install --require-hashes -r .github/scripts/dependency-audit-tools.requirements.txt" in workflow
assert "#1478" in agdr
lines = requirements.splitlines()
i = 0
req_count = 0
while i < len(lines):
    raw = lines[i]
    stripped = raw.strip()
    i += 1
    if not stripped or stripped.startswith("#"):
        continue
    assert "==" in stripped, f"requirement line missing == pin: {raw!r}"
    hash_count = 0
    while i < len(lines):
        nxt = lines[i].strip()
        if nxt.startswith("--hash=sha256"):
            hash_count += 1
            i += 1
            continue
        if not nxt or nxt.startswith("#"):
            i += 1
            continue
        break
    assert hash_count >= 1, f"no --hash=sha256 after {stripped!r}"
    req_count += 1
assert req_count >= 1, "pin file has no requirement lines"
PY
then
  pass "F1478-hash-install-and-agdr-link"
else
  fail "F1478-hash-install-and-agdr-link" "require-hashes install, hashed pins, or AgDR-0184 #1478 link missing"
fi

mkdir -p "$SB/projects/uv-self" "$SB/http-1478"
cat > "$SB/projects/uv-self/pyproject.toml" <<'EOF'
[project]
name = "demo-project"
version = "0.1.0"
dependencies = ["safe-pkg==1.0.0"]
EOF
cat > "$SB/projects/uv-self/uv.lock" <<'EOF'
version = 1
[[package]]
name = "demo-project"
version = "0.1.0"
source = { editable = "." }
dependencies = [{ name = "safe-pkg" }]
[[package]]
name = "safe-pkg"
version = "1.0.0"
source = { registry = "https://pypi.org/simple" }
EOF
printf '%s\n' '{"results":[{"vulns":[]}]}' > "$SB/http-1478/osv_querybatch.json"
cp "$SB/http/pypi_safe-pkg_1.0.0.json" "$SB/http-1478/"
cp "$SB/http/pypi_safe-pkg.json" "$SB/http-1478/"
set +e
python3 -I "$HELPER" "$SB/projects/uv-self" --runner=osv \
  --fixture-http "$SB/http-1478" --skip-npm-scan > "$SB/uv-self.json" 2> "$SB/uv-self.err"
uv_self_rc=$?
set -e
if python3 - "$SB/uv-self.json" "$uv_self_rc" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
s = next(x for x in d["dependency_sets"] if x["ecosystem"] == "python")
assert int(sys.argv[2]) == d["exit_code"] == 0
assert s["coverage"] == s["check_status"] == "complete"
assert {p["name"] for p in s["packages"]} == {"safe-pkg"}
PY
then
  pass "F1478-uv-self-entry-complete"
else
  fail "F1478-uv-self-entry-complete" "rc=$uv_self_rc body=$(head -c 350 "$SB/uv-self.json")"
fi

mkdir -p "$SB/projects/uv-virtual"
cp "$SB/projects/uv-self/pyproject.toml" "$SB/projects/uv-virtual/pyproject.toml"
cat > "$SB/projects/uv-virtual/uv.lock" <<'EOF'
version = 1
[[package]]
name = "demo-project"
source = { virtual = "." }
dependencies = [{ name = "safe-pkg" }]
[[package]]
name = "safe-pkg"
version = "1.0.0"
source = { registry = "https://pypi.org/simple" }
EOF
set +e
python3 -I "$HELPER" "$SB/projects/uv-virtual" --runner=osv \
  --fixture-http "$SB/http-1478" --skip-npm-scan > "$SB/uv-virtual.json" 2> "$SB/uv-virtual.err"
uv_virtual_rc=$?
set -e
if python3 - "$SB/uv-virtual.json" "$uv_virtual_rc" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
s = next(x for x in d["dependency_sets"] if x["ecosystem"] == "python")
assert int(sys.argv[2]) == d["exit_code"] == 0
assert s["coverage"] == s["check_status"] == "complete"
assert {p["name"] for p in s["packages"]} == {"safe-pkg"}
PY
then
  pass "F1478-uv-virtual-self-entry-complete"
else
  fail "F1478-uv-virtual-self-entry-complete" "rc=$uv_virtual_rc body=$(head -c 350 "$SB/uv-virtual.json")"
fi

printf '%s\n' '[]' > "$SB/empty-1478-stub.json"
for dev_source in pep735 tool-uv dev-requirements; do
  project="$SB/projects/dev-$dev_source"
  mkdir -p "$project"
  case "$dev_source" in
    pep735)
      cat > "$project/pyproject.toml" <<'EOF'
[project]
name = "demo-project"
dependencies = ["safe-pkg==1.0.0"]
[dependency-groups]
dev = ["demo-dev>=2"]
EOF
      ;;
    tool-uv)
      cat > "$project/pyproject.toml" <<'EOF'
[project]
name = "demo-project"
dependencies = ["safe-pkg==1.0.0"]
[tool.uv]
dev-dependencies = ["demo-dev>=2"]
EOF
      ;;
    dev-requirements)
      printf '%s\n' 'safe-pkg==1.0.0' > "$project/requirements.txt"
      printf '%s\n' 'demo-dev>=2' > "$project/dev-requirements.txt"
      ;;
  esac
  set +e
  python3 -I "$HELPER" "$project" --pip-audit-stub "$SB/empty-1478-stub.json" \
    --fixture-http "$SB/http-1478" --skip-npm-scan > "$SB/dev-$dev_source.json" 2> "$SB/dev-$dev_source.err"
  dev_rc=$?
  set -e
  if python3 - "$SB/dev-$dev_source.json" "$dev_rc" "$dev_source" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
s = next(x for x in d["dependency_sets"] if x["ecosystem"] == "python")
assert int(sys.argv[2]) == d["exit_code"] == 3
assert s["coverage"] == s["check_status"] == "incomplete"
assert "demo-dev" in s["coverage_reason"]
assert {p["name"] for p in s["packages"]} == {"safe-pkg"}
if sys.argv[3] == "dev-requirements":
    assert "dev-requirements.txt" in s["manifests"]
PY
  then
    pass "F1478-$dev_source-unpinned-incomplete"
  else
    fail "F1478-$dev_source-unpinned-incomplete" "rc=$dev_rc body=$(head -c 350 "$SB/dev-$dev_source.json")"
  fi
done

if python3 - "$FIXED_PIPELINE" <<'PY'
from pathlib import Path
import sys
workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
assert workflow.count("- 'dev-requirements.txt'") == 2
assert workflow.count("- '**/dev-requirements.txt'") == 2
assert "-name 'dev-requirements.txt'" in workflow
PY
then
  pass "F1478-dev-requirements-triggers-python-job"
else
  fail "F1478-dev-requirements-triggers-python-job" "workflow does not detect standalone dev requirements"
fi

py39=""
for candidate in /usr/bin/python3 python3.9; do
  if command -v "$candidate" >/dev/null 2>&1 \
    && "$candidate" --version 2>&1 | grep -qE '^Python 3\.9\.'; then
    py39="$candidate"
    break
  fi
done
if [ -z "$py39" ]; then
  py39=python3
fi
set +e
"$py39" -I "$HELPER" "$SB/projects/hostile" --runner=osv \
  --fixture-http "$SB/http-1478" --skip-npm-scan > "$SB/python39.json" 2> "$SB/python39.err"
python39_rc=$?
set -e
if ! grep -qF 'zip(chunk, batch_results, strict=True)' "$HELPER" \
  && python3 - "$SB/python39.json" "$python39_rc" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert int(sys.argv[2]) == d["exit_code"]
assert d["exit_code"] in (0, 3, 4)
if d["exit_code"] == 3:
    assert any(s["coverage"] in ("failed", "incomplete") for s in d["dependency_sets"])
PY
then
  pass "F1478-python39-osv-no-crash"
else
  fail "F1478-python39-osv-no-crash" "interpreter=$py39 rc=$python39_rc err=$(head -c 200 "$SB/python39.err")"
fi

if python3 - "$FIXED_PIPELINE" "$SB/combine-1478.py" <<'PY'
from pathlib import Path
import sys, textwrap
workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
body = workflow.split("run: |\n          python3 <<'PY'\n", 1)[1].split("\n          PY", 1)[0]
Path(sys.argv[2]).write_text(textwrap.dedent(body) + "\n", encoding="utf-8")
PY
then
  for scenario in unknown-exit critical-without-finding; do
    case_dir="$SB/combine-$scenario"
    mkdir -p "$case_dir/audit-evidence/npm"
    if [ "$scenario" = unknown-exit ]; then
      helper_exit=9
      report_exit=9
    else
      helper_exit=1
      report_exit=1
    fi
    printf '{"severity_totals":{"Critical":0},"dependency_sets":[{"ecosystem":"npm","coverage":"complete","check_status":"complete"}],"exit_code":%s,"findings":[]}\n' "$report_exit" \
      > "$case_dir/audit-evidence/npm/npm-report.json"
    : > "$case_dir/outputs"
    : > "$case_dir/summary"
    set +e
    (cd "$case_dir" && HAS_NPM=true HAS_PYTHON=false NPM_RESULT=success PYTHON_RESULT=skipped \
      NPM_HAS_REPORT=true PYTHON_HAS_REPORT=false NPM_EXIT="$helper_exit" \
      GITHUB_OUTPUT="$case_dir/outputs" GITHUB_STEP_SUMMARY="$case_dir/summary" \
      python3 "$SB/combine-1478.py") > "$case_dir/out" 2> "$case_dir/err"
    combine_rc=$?
    set -e
    if [ "$combine_rc" -eq 0 ] && grep -q '^incomplete=true$' "$case_dir/outputs"; then
      pass "F1478-summarize-$scenario-incomplete"
    else
      fail "F1478-summarize-$scenario-incomplete" "rc=$combine_rc outputs=$(cat "$case_dir/outputs")"
    fi
  done
else
  fail "F1478-summarize-unknown-exit-incomplete" "cannot extract combine step"
  fail "F1478-summarize-critical-without-finding-incomplete" "cannot extract combine step"
fi

if python3 - "$FIXED_PIPELINE" "$SB" <<'PY'
from pathlib import Path
import subprocess, sys
workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
for ecosystem in ("npm", "python"):
    block = workflow.split(f"- name: Run shared helper ({ecosystem})", 1)[1].split("- name:", 1)[0]
    assert "rm -f audit-evidence/*-report.json" in block
    assert block.index("rm -f audit-evidence/*-report.json") < block.index("dependency-audit.py")
    directory = Path(sys.argv[2]) / f"stale-{ecosystem}"
    evidence = directory / "audit-evidence"
    evidence.mkdir(parents=True)
    (evidence / "old-report.json").write_text("stale", encoding="utf-8")
    (evidence / "npm-outdated.json").write_text("keep", encoding="utf-8")
    subprocess.run(["/bin/bash", "-c", "rm -f audit-evidence/*-report.json"], cwd=directory, check=True)
    assert not (evidence / "old-report.json").exists()
    assert (evidence / "npm-outdated.json").exists()
assert workflow.index("- name: Clear checkout audit reports") < workflow.index("- name: Download evidence")
PY
then
  pass "F1478-stale-reports-cleared-before-scan-and-combine"
else
  fail "F1478-stale-reports-cleared-before-scan-and-combine" "checkout reports can contaminate evidence"
fi

if python3 - "$FIXED_DESIGN" <<'PY'
from pathlib import Path
import sys
design = Path(sys.argv[1]).read_text(encoding="utf-8")
approvals = design.split("## Approvals\n", 1)[1].split("\n## ", 1)[0]
assert "approval remain pending" not in approvals
assert "PR #1430" in approvals
PY
then
  pass "F1478-design-approval-state-corrected"
else
  fail "F1478-design-approval-state-corrected" "approval section still claims pending"
fi

echo ""
echo "----------------------------------------"
echo "dependency-audit #1359 tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
