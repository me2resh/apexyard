#!/usr/bin/env bash
# Create a local repository for slice PR checks.
# shellcheck source=./_lib-fixtures.sh
. "$(dirname "$0")/_lib-fixtures.sh"
slice_setup() {
  real_root=$(cd "$(dirname "$0")/../../../.." && pwd)
  sb=$(make_sandbox)
  trap 'rm -rf "$sb"' EXIT
  fixtures_write_orbit_root "$sb" >/dev/null
  mkdir -p "$sb/docs"
  mv "$sb/orbit" "$sb/docs/orbit"
  orbit_root="$sb/docs/orbit"
  fixtures_install_mock_orbit "$sb"
  export ORBIT_BIN="$sb/bin/orbit"
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/skills/orbit/lib"
  cp "$real_root"/.claude/hooks/_lib-*.sh "$real_root/.claude/hooks/check-private-refs-runtime.sh" "$sb/.claude/hooks/"
  cp "$real_root"/.claude/skills/orbit/lib/*.sh "$sb/.claude/skills/orbit/lib/"
  lint="$sb/.claude/skills/orbit/lib/records-lint.sh"
  rec="$orbit_root/reconciliations/reconciliation-demo-widget-r1.json"
  jq '.criterionAssessments[0].explanation="Missing: Proof. Next: Test." | .criterionAssessments += [{criterionId:"ac-X",status:"not-verified",evidence:[],explanation:"Missing: Proof. Next: Test."}]' "$rec" > "$rec.t"
  mv "$rec.t" "$rec"
  g init -q
  g checkout -qb dev
  g add docs
  g commit -qm baseline
  g branch base
  g checkout -qb feature/demo
  sha=$(g rev-parse base)
  candidate="$orbit_root/reconciliations/reconciliation-demo-new.json"
}
g() { git -C "$sb" -c user.name=t -c user.email=t@example.com "$@"; }
candidate_write() {
  jq --arg sha "$sha" '.id="reconciliation-demo-new" | .reconciledAt="2026-10-13T00:00:00Z" | .observations=[("Slice PR: #42; dev merge-base " + $sha + ".")]' "$rec" > "$candidate"
}
expect() {
  local want="$1" rc=0 out
  shift
  out=$(bash "$lint" --orbit-root "$orbit_root" --base base "$@" 2>&1) || rc=$?
  [ "$rc" -eq "$want" ] || { echo "FAIL: Expected $want, got $rc: $out"; exit 1; }
  printf '%s\n' "$out"
}
