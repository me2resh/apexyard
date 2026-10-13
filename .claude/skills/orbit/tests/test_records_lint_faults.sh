#!/bin/bash
# test_records_lint_faults.sh — records-lint.sh stops on the first fault with
# a clear message and a distinct exit code (AgDR-0225, ac8-1). No network.

set -u
# shellcheck source=./_lib-fixtures.sh
. "$(dirname "$0")/_lib-fixtures.sh"

fail=0
real_root="$(cd "$(dirname "$0")/../../../.." && pwd)"

sb=$(make_sandbox)
orbit_root=$(fixtures_write_orbit_root "$sb")
fixtures_install_mock_orbit "$sb"
# New Plan fixtures include the required operator interview.
{
  echo '## Interview'
  for key in q1-outcome q2-intent q3-outcomes q4-acceptance q5-constraints q6-save; do
    printf -- '- 2026-10-12, %s: Fixture answer.\n' "$key"
  done
} > "$orbit_root/plans/plan-demo-widget.notes.md"
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
# Anchor the sandbox as its own fork so the scrub reads the sandbox registry.
touch "$sb/.apexyard-fork"
echo '{"portfolio":{"registry":"apexyard.projects.yaml"}}' > "$sb/.claude/project-config.json"
unset APEXYARD_OPS_ROOT APEXYARD_PORTFOLIO_ROOT CLAUDE_CODE_SESSION_ID
APEXYARD_OPS_PIN_DIR="$sb/pin"; export APEXYARD_OPS_PIN_DIR
lint="$sb/.claude/skills/orbit/lib/records-lint.sh"
ORBIT_BIN="$sb/bin/orbit"; export ORBIT_BIN
PATH="$sb/bin:$PATH"; export PATH

rec="$orbit_root/reconciliations/reconciliation-demo-widget-r1.json"
slice="$orbit_root/slices/slice-demo-o1.json"
good_expl="Missing: the demo evidence. Next: the demo slice."
set_expl() { jq --arg e "$1" '.criterionAssessments[0].explanation = $e' "$rec" > "$rec.t" && mv "$rec.t" "$rec"; }
set_why() { jq --arg e "$1" '.why = $e' "$slice" > "$slice.t" && mv "$slice.t" "$slice"; }

# expect <name> <exit> <stderr-substring>
expect() {
  out=$("$lint" --orbit-root "$orbit_root" --all 2>&1); rc=$?
  if [ "$rc" -ne "$2" ]; then echo "FAIL: $1: expected exit $2, got $rc ($out)"; fail=1; return; fi
  case "$out" in *"$3"*) ;; *) echo "FAIL: $1: output lacks '$3': $out"; fail=1 ;; esac
}

set_expl "$good_expl"
expect "clean records pass" 0 "records-lint: OK"

set_why "$(printf 'word %.0s' $(seq 1 30))"
expect "a 30-word sentence fails" 12 "[sentence]"
set_why "Fixture reason."

set_expl "Nothing is known yet."
expect "an explanation without Missing and Next fails" 13 "[missing-next]"
set_expl "Next: the demo slice. Missing: the demo evidence."
expect "Next before Missing fails" 13 "[missing-next]"
set_expl "$good_expl"

set_why "Run it from /Users/someone/work/demo."
expect "a local path fails" 14 "[local-path]"

set_why "Zephyrvault needs this."
expect "a private name fails the leak scrub" 11 "[leak-scrub]"

# First fault wins: a long sentence (check 3) and a local path (check 5).
set_why "$(printf 'word %.0s' $(seq 1 30)) /Users/someone/x"
expect "the first fault stops the run" 12 "[sentence]"
case "$out" in *"local-path"*) echo "FAIL: the run went past the first fault"; fail=1 ;; esac
set_why "Fixture reason."

fixtures_install_mock_orbit "$sb" 1
expect "a validate fault stops first" 10 "[validate]"

fixtures_install_mock_orbit "$sb"
set_expl "$good_expl"
# A missing base ref prints one notice and checks every file.
out=$("$lint" --orbit-root "$orbit_root" --base origin/does-not-exist 2>&1); rc=$?
case "$out" in *"notice: base ref origin/does-not-exist not found"*) ;; *) echo "FAIL: no fallback notice: $out"; fail=1 ;; esac
case "$out" in *"validate"*|*FAIL*) echo "FAIL: unexpected fault: $out"; fail=1 ;; esac

# Branch scope must reject cross-initiative records, even with --all.
mkdir -p "$sb/docs"
mv "$orbit_root" "$sb/docs/orbit"
orbit_root="$sb/docs/orbit"
slice="$orbit_root/slices/slice-demo-o1.json"
git -C "$sb" init -q
git -C "$sb" config user.email test@example.com
git -C "$sb" config user.name test
plan=$(jq -r '.id' "$orbit_root"/plans/*.json | head -1)
git -C "$sb" add docs/orbit
git -C "$sb" commit -qm base
git -C "$sb" update-ref refs/remotes/origin/dev HEAD
git -C "$sb" checkout -qb "orbit/${plan#plan-}-cycle"
expect "own initiative no changed records" 0 "records-lint: OK"
set_why "Changed reason."
jq '.planId = "plan-other"' "$slice" > "$slice.t" && mv "$slice.t" "$slice"
expect "cross initiative slice" 15 "Record belongs to another initiative."
jq --arg p "$plan" '.planId = $p' "$slice" > "$slice.t" && mv "$slice.t" "$slice"
echo notes > "$orbit_root/plans/plan-other.notes.md"
expect "cross initiative notes" 15 "Notes belong to another initiative."
rm "$orbit_root/plans/plan-other.notes.md"
snapshot="$orbit_root/snapshots/snapshot-demo-widget-1.json"
jq '.observedAt = "2026-10-12T00:00:00Z"' "$snapshot" > "$snapshot.t" && mv "$snapshot.t" "$snapshot"
expect "unreferenced changed snapshot" 15 "Snapshot is not referenced"
rec="$orbit_root/reconciliations/reconciliation-demo-widget-r1.json"
set_expl "Missing: fresh evidence. Next: inspect the slice."
expect "referenced changed snapshot" 0 "records-lint: OK"
jq '.planId = "plan-other"' "$rec" > "$rec.t" && mv "$rec.t" "$rec"
expect "cross initiative reconciliation" 15 "Record belongs to another initiative."
jq --arg p "$plan" '.planId = $p' "$rec" > "$rec.t" && mv "$rec.t" "$rec"
# A superseded reconciliation in history/ is owned through .planId, not .id.
mkdir -p "$orbit_root/history"
jq '.id = "reconciliation-demo-widget-r0"' "$rec" > "$orbit_root/history/reconciliation-demo-r0.json"
expect "own initiative history reconciliation" 0 "records-lint: OK"
jq '.planId = "plan-other"' "$orbit_root/history/reconciliation-demo-r0.json" > "$rec.t" && mv "$rec.t" "$orbit_root/history/reconciliation-demo-r0.json"
expect "cross initiative history reconciliation" 15 "Record belongs to another initiative."
rm "$orbit_root/history/reconciliation-demo-r0.json"
git -C "$sb" checkout -qb orbit/unknown-cycle
expect "unknown initiative" 15 "No matching plan record"

rm -rf "$sb"
[ "$fail" -eq 0 ] && echo "PASS: records-lint stops on the first fault"
exit "$fail"
