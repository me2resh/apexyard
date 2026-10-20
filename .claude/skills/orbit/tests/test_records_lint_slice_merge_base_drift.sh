#!/usr/bin/env bash
# Ancestor merge-base R stays valid when plan records did not change (AgDR-0258).
# shellcheck disable=SC2154,SC2034
set -eu
# shellcheck source=./_lib-slice-fixtures.sh
. "$(dirname "$0")/_lib-slice-fixtures.sh"

advance_base_unrelated() {
  g checkout -q base
  printf 'Unrelated base change\n' > "$sb/base-file"
  g add base-file
  g commit -qm 'base moves without record change'
  g checkout -q feature/demo
  g merge -qm refresh base
}

# (a) Ancestor R, no status-dependent change: pass with NOTE.
slice_setup
candidate_write
g add docs
g commit -qm progress
recorded_r=$(g rev-parse base)
advance_base_unrelated
current_m=$(g merge-base base HEAD)
[ "$recorded_r" != "$current_m" ]
out=$(expect 0 --slice slice-demo-widget-o1 --pr 42)
printf '%s\n' "$out" | grep -Fq "NOTE [provenance] Recorded merge-base ${recorded_r}; current merge-base ${current_m}."
echo "PASS (a) ancestor R with no record change: exit 0 and NOTE"

# Fail-before: pin the pre-change lint (this PR's dev merge-base), not
# upstream/dev — after merge those refs hold the fixed lint (Tariq #1802).
lint_path=".claude/skills/orbit/lib/slice-pr-lint.sh"
PRE_FIX_SHA="a791285d974de04359d8b0d1494878651231debc"
unfixed_lib=$(mktemp)
if ! git -C "$real_root" show "${PRE_FIX_SHA}:${lint_path}" > "$unfixed_lib" 2>/dev/null \
  || [ ! -s "$unfixed_lib" ]; then
  rm -f "$unfixed_lib"
  echo "SKIP fail-before: base commit not available"
elif grep -q 'slice_pr_merge_base_ok' "$unfixed_lib"; then
  rm -f "$unfixed_lib"
  echo "SKIP fail-before: copied lint already defines slice_pr_merge_base_ok"
else
  cp "$sb/.claude/skills/orbit/lib/slice-pr-lint.sh" "$sb/.claude/skills/orbit/lib/slice-pr-lint.sh.fixed"
  cp "$unfixed_lib" "$sb/.claude/skills/orbit/lib/slice-pr-lint.sh"
  rm -f "$unfixed_lib"
  before_rc=0
  before_out=$(bash "$lint" --orbit-root "$orbit_root" --base base --slice slice-demo-widget-o1 --pr 42 2>&1) || before_rc=$?
  cp "$sb/.claude/skills/orbit/lib/slice-pr-lint.sh.fixed" "$sb/.claude/skills/orbit/lib/slice-pr-lint.sh"
  rm -f "$sb/.claude/skills/orbit/lib/slice-pr-lint.sh.fixed"
  [ "$before_rc" -eq 19 ] || { echo "FAIL-BEFORE (a): expected exit 19 from ${PRE_FIX_SHA} lint, got $before_rc: $before_out"; exit 1; }
  printf '%s\n' "$before_out" | grep -Fq 'The merge-base SHA does not match.'
  echo "FAIL-BEFORE (a) exact match via ${PRE_FIX_SHA}: exit 19 (1 case)"
fi

# (b) Ancestor R, plan notes / Reconciliation / slice record changed: exit 19.
run_b() {
  local kind="$1"
  slice_setup
  : > "$orbit_root/plans/plan-demo-widget.notes.md"
  g add docs
  g commit -qm 'baseline with notes'
  g branch -f base
  g checkout -q feature/demo
  sha=$(g rev-parse base)
  candidate_write
  g add docs
  g commit -qm progress
  g checkout -q base
  case "$kind" in
    notes)
      printf '\n# Drift touch\n' >> "$orbit_root/plans/plan-demo-widget.notes.md"
      g add docs/orbit/plans/plan-demo-widget.notes.md
      ;;
    reconciliation)
      jq '.observations += ["Drift touch on base."]' \
        "$orbit_root/reconciliations/reconciliation-demo-widget-r1.json" > "$sb/rec.t"
      mv "$sb/rec.t" "$orbit_root/reconciliations/reconciliation-demo-widget-r1.json"
      g add docs/orbit/reconciliations/reconciliation-demo-widget-r1.json
      ;;
    slice)
      jq '.why="Drift touch on base."' \
        "$orbit_root/slices/slice-demo-o1.json" > "$sb/slice.t"
      mv "$sb/slice.t" "$orbit_root/slices/slice-demo-o1.json"
      g add docs/orbit/slices/slice-demo-o1.json
      ;;
    *) echo "unknown kind $kind"; exit 1 ;;
  esac
  g commit -qm "base touches $kind"
  g checkout -q feature/demo
  g merge -qm refresh base
  expect 19 --slice slice-demo-widget-o1 --pr 42 >/dev/null
  echo "PASS (b) record change on $kind: exit 19"
}
run_b notes
run_b reconciliation
run_b slice

# (c) Recorded SHA is not an ancestor of M: exit 19.
slice_setup
candidate_write
g add docs
g commit -qm progress
g checkout --orphan orphan-base
printf 'orphan\n' > "$sb/orphan.txt"
g add orphan.txt
g commit -qm orphan
orphan=$(g rev-parse HEAD)
g checkout -q feature/demo
sha=$orphan
candidate_write
expect 19 --slice slice-demo-widget-o1 --pr 42 >/dev/null
echo "PASS (c) non-ancestor R: exit 19"

# (d) R equals M: pass with no NOTE (same as today).
slice_setup
candidate_write
out=$(expect 0 --slice slice-demo-widget-o1 --pr 42)
if printf '%s\n' "$out" | grep -q 'NOTE \[provenance\]'; then
  echo "FAIL (d): unexpected NOTE when R equals M: $out"
  exit 1
fi
echo "PASS (d) R equals M: exit 0, no NOTE"

# (e) Same-plan Reconciliation that exists only at M: exit 19.
slice_setup
candidate_write
g add docs
g commit -qm progress
recorded_r=$(g rev-parse base)
g checkout -q base
jq '.id="reconciliation-demo-widget-r2" | .reconciledAt="2026-10-19T12:00:00Z" | .observations=["Same-plan only at M."]' \
  "$orbit_root/reconciliations/reconciliation-demo-widget-r1.json" \
  > "$orbit_root/reconciliations/reconciliation-demo-widget-r2.json"
g add docs/orbit/reconciliations/reconciliation-demo-widget-r2.json
g commit -qm 'base adds same-plan Reconciliation'
g checkout -q feature/demo
g merge -qm refresh base
current_m=$(g merge-base base HEAD)
[ "$recorded_r" != "$current_m" ]
out=$(expect 19 --slice slice-demo-widget-o1 --pr 42)
printf '%s\n' "$out" | grep -Fq 'Plan records changed between the recorded merge-base and the current merge-base'
printf '%s\n' "$out" | grep -Fq 'docs/orbit/reconciliations/reconciliation-demo-widget-r2.json'
printf '%s\n' "$out" | grep -Fq 'refresh-slice-record.sh'
echo "PASS (e) same-plan Reconciliation only at M: exit 19 and record-change message"

# (f) Reconciliation of another plan: pass with NOTE.
slice_setup
candidate_write
g add docs
g commit -qm progress
recorded_r=$(g rev-parse base)
g checkout -q base
jq '.id="reconciliation-other-widget-r1" | .planId="plan-other-widget" | .observations=["Other plan."]' \
  "$orbit_root/reconciliations/reconciliation-demo-widget-r1.json" \
  > "$orbit_root/reconciliations/reconciliation-other-widget-r1.json"
g add docs/orbit/reconciliations/reconciliation-other-widget-r1.json
g commit -qm 'base adds other-plan Reconciliation'
g checkout -q feature/demo
g merge -qm refresh base
current_m=$(g merge-base base HEAD)
[ "$recorded_r" != "$current_m" ]
out=$(expect 0 --slice slice-demo-widget-o1 --pr 42)
printf '%s\n' "$out" | grep -Fq "NOTE [provenance] Recorded merge-base ${recorded_r}; current merge-base ${current_m}."
echo "PASS (f) other-plan Reconciliation: exit 0 and NOTE"

# (g) Plan JSON change between R and M: exit 19.
slice_setup
candidate_write
g add docs
g commit -qm progress
recorded_r=$(g rev-parse base)
g checkout -q base
jq '.title="Drifted demo widget plan"' \
  "$orbit_root/plans/plan-demo-widget.r1.json" > "$sb/plan.t"
mv "$sb/plan.t" "$orbit_root/plans/plan-demo-widget.r1.json"
g add docs/orbit/plans/plan-demo-widget.r1.json
g commit -qm 'base changes Plan JSON'
g checkout -q feature/demo
g merge -qm refresh base
current_m=$(g merge-base base HEAD)
[ "$recorded_r" != "$current_m" ]
out=$(expect 19 --slice slice-demo-widget-o1 --pr 42)
printf '%s\n' "$out" | grep -Fq 'Plan records changed between the recorded merge-base and the current merge-base'
printf '%s\n' "$out" | grep -Fq 'docs/orbit/plans/plan-demo-widget.r1.json'
printf '%s\n' "$out" | grep -Fq 'refresh-slice-record.sh'
echo "PASS (g) Plan JSON change: exit 19 and record-change message"
