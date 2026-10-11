#!/bin/bash
# test_records_lint_changed_fields.sh — records-lint.sh checks only the text
# that changed against the merge base (apexyard#1636). No network.

set -u
# shellcheck source=./_lib-fixtures.sh
. "$(dirname "$0")/_lib-fixtures.sh"

fail=0
real_root="$(cd "$(dirname "$0")/../../../.." && pwd)"

sb=$(make_sandbox)
orbit_root=$(fixtures_write_orbit_root "$sb")
fixtures_install_mock_orbit "$sb"
mkdir -p "$sb/.claude/hooks" "$sb/.claude/skills/orbit/lib"
cp "$real_root/.claude/hooks/check-private-refs-runtime.sh" "$real_root"/.claude/hooks/_lib-*.sh "$sb/.claude/hooks/"
cp "$real_root/.claude/skills/orbit/lib/records-lint.sh" "$sb/.claude/skills/orbit/lib/"
chmod +x "$sb/.claude/hooks/"*.sh "$sb/.claude/skills/orbit/lib/records-lint.sh"
cat > "$sb/apexyard.projects.yaml" <<'YAML'
projects:
  - name: zephyrvault
    repo: acme-private/zephyrvault
    workspace: workspace/zephyrvault
YAML
touch "$sb/.apexyard-fork"
echo '{"portfolio":{"registry":"apexyard.projects.yaml"}}' > "$sb/.claude/project-config.json"
unset APEXYARD_OPS_ROOT APEXYARD_PORTFOLIO_ROOT CLAUDE_CODE_SESSION_ID
APEXYARD_OPS_PIN_DIR="$sb/pin"; export APEXYARD_OPS_PIN_DIR
lint="$sb/.claude/skills/orbit/lib/records-lint.sh"
ORBIT_BIN="$sb/bin/orbit"; export ORBIT_BIN
PATH="$sb/bin:$PATH"; export PATH

rec="$orbit_root/reconciliations/reconciliation-demo-widget-r1.json"
slice="$orbit_root/slices/slice-demo-o1.json"
long30="$(printf 'word %.0s' $(seq 1 30))"
bad_expl="Nothing is known yet."

# Baseline: a delivered slice with a long old sentence and a non-achieved
# assessment without Missing/Next. Both predate the rules.
jq --arg e "$long30" '.why = $e' "$slice" > "$slice.t" && mv "$slice.t" "$slice"
jq --arg e "$bad_expl" '.criterionAssessments[0].explanation = $e' "$rec" > "$rec.t" && mv "$rec.t" "$rec"
printf 'Old note line.\n' > "$orbit_root/notes.md"
g() { git -C "$sb" -c user.name=t -c user.email=t@example.com "$@"; }
g init -q . && g checkout -q -b main 2>/dev/null
g add orbit && g commit -q -m baseline && g branch base

run() { "$lint" --orbit-root "$orbit_root" --base base "$@" 2>&1; }
# expect <name> <exit> <substring> [lint args]
expect() {
  name="$1"; want="$2"; sub="$3"; shift 3
  out=$(run "$@"); rc=$?
  if [ "$rc" -ne "$want" ]; then echo "FAIL: $name: expected exit $want, got $rc ($out)"; fail=1; return; fi
  case "$out" in *"$sub"*) ;; *) echo "FAIL: $name: output lacks '$sub': $out"; fail=1 ;; esac
}
reset() { g checkout -q -- orbit; g clean -fdq orbit; }

# 1. Only basedOn changed: no sentence or Missing/Next check.
jq '.basedOn.reconciliationId = "reconciliation-demo-widget-r2"' "$slice" > "$slice.t" && mv "$slice.t" "$slice"
jq '.id = "reconciliation-demo-widget-r1"' "$rec" > "$rec.t" && mv "$rec.t" "$rec"
expect "a basedOn-only change passes" 0 "records-lint: OK"
expect "--all still checks old text" 12 "[sentence]" --all
reset

# 2. A changed text field with a long sentence fails.
jq --arg e "$long30 more" '.why = $e' "$slice" > "$slice.t" && mv "$slice.t" "$slice"
expect "a changed long field fails" 12 "[sentence]"
reset

# 3. A short change to the long field passes.
jq '.why = "Short reason."' "$slice" > "$slice.t" && mv "$slice.t" "$slice"
expect "a shortened field passes" 0 "records-lint: OK"
reset

# 4. An unchanged long field passes next to a changed short field.
jq '.objective = "Changed objective."' "$slice" > "$slice.t" && mv "$slice.t" "$slice"
expect "a changed short field passes" 0 "records-lint: OK"
reset

# 5. Missing/Next runs only on a changed explanation.
jq '.criterionAssessments[0].explanation = "Still nothing known."' "$rec" > "$rec.t" && mv "$rec.t" "$rec"
expect "a changed bad explanation fails" 13 "[missing-next]"
reset

# 6. The leak scrub reads the whole file, even for a basedOn-only change.
jq '.why = "Zephyrvault needs this."' "$slice" > "$slice.t" && mv "$slice.t" "$slice"
g add orbit && g commit -q -m "old leak"
g branch -f base
jq '.basedOn.reconciliationId = "reconciliation-demo-widget-r2"' "$slice" > "$slice.t" && mv "$slice.t" "$slice"
expect "the leak scrub runs on a basedOn-only file" 11 "[leak-scrub]"
reset

# 7. Validate runs with a changed file.
jq '.basedOn.reconciliationId = "reconciliation-demo-widget-r2"' "$slice" > "$slice.t" && mv "$slice.t" "$slice"
fixtures_install_mock_orbit "$sb" 1
expect "validate runs on a basedOn-only change" 10 "[validate]"
fixtures_install_mock_orbit "$sb"
reset

# 8. A new file is fully checked.
jq --arg e "$long30" '.id = "slice-demo-widget-o2" | .why = $e' "$slice" > "$orbit_root/slices/slice-demo-o2.json"
expect "a new file with a long sentence fails" 12 "[sentence]"
reset

# 9. A notes file: a changed line is checked, an old line is not.
printf 'Old note line.\nNew line at /Users/someone/x.\n' > "$orbit_root/notes.md"
expect "a notes file keeps the local-path check" 14 "[local-path]"
reset

rm -rf "$sb"
[ "$fail" -eq 0 ] && echo "PASS: records-lint checks only changed fields"
exit "$fail"
