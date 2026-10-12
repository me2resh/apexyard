#!/usr/bin/env bash
# Check shared skill blocks and merge instructions.
set -u
# Isolate this test from the live session.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=${SKILL_SHARED_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
FAIL=0
check() {
  if "$@"; then printf 'PASS: %s\n' "$*"; else printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); fi
}
for doc in writing-rule ops-root; do check test -f "$ROOT/docs/skills/shared/$doc.md"; done
for sentence in \
  'When this skill writes a durable artifact, read .claude/rules/writing-standard.md.' \
  'Use the controlled technical writing profile from .claude/rules/writing-standard.md for each artifact.' \
  'ops_root="$PWD"; r="$PWD"'; do
  if grep -F "$sentence" "$ROOT"/.claude/skills/*/SKILL.md; then FAIL=$((FAIL + 1)); fi
done
# The long pin snippet lives in the shared file only. Skills carry the one-line form.
if grep -l 'pin_file=' "$ROOT"/.claude/skills/*/SKILL.md; then FAIL=$((FAIL + 1)); fi
# Run the one-line form from a skill: valid pin, missing pin.
line=$(grep -m1 -F 'ops_root=$(. ' "$ROOT/.claude/skills/feature/SKILL.md")
check test -n "$line"
pt=$(mktemp -d)
mkdir -p "$pt/fork/.claude/hooks" "$pt/pins"
cp "$ROOT/.claude/hooks/_lib-ops-root.sh" "$pt/fork/.claude/hooks/"
touch "$pt/fork/.apexyard-fork"
printf '%s\n' "$pt/fork" > "$pt/pins/ops-root-ok"
printf '%s\n' "$line" 'echo "$ops_root" > "$OUT"' > "$pt/line.sh"
check env APEXYARD_OPS_DISABLE_PIN= CLAUDE_CODE_SESSION_ID=ok APEXYARD_OPS_PIN_DIR="$pt/pins" OUT="$pt/out" bash "$pt/line.sh"
check test "$(cat "$pt/out" 2>/dev/null)" = "$pt/fork"
if env APEXYARD_OPS_DISABLE_PIN= CLAUDE_CODE_SESSION_ID=none APEXYARD_OPS_PIN_DIR="$pt/pins" OUT="$pt/out2" bash "$pt/line.sh" 2>/dev/null; then FAIL=$((FAIL + 1)); printf 'FAIL: missing pin must stop\n'; fi
rm -rf "$pt"
# This list records the 45 consumers before the sweep.
for skill in compliance-check extract-features geo-audit split-portfolio tech-vision tasks tutorial decide seo-audit inbox audit-deps spike-close docs-audit validate-idea projects mutation-test approve-architecture setup codify-rule feature-diagram pdf approve-merge bug status onboard monitoring-audit journey start-ticket performance-audit fan-out accessibility-audit approve-design agdr task design-sync c4 feature analytics-audit write-spec challenge prototype-close eval-agents security-review process debug; do
  file="$ROOT/.claude/skills/$skill/SKILL.md"
  count=$(grep -xc 'Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.' "$file" || true)
  check test "$count" -eq 1
  check test "$(head -n 1 "$file")" = '---'
  check test "$(awk '/^---$/{n++; if(n==2){print n;exit}}' "$file")" = 2
done
for skill in approve-merge approve-design code-review task start-ticket; do
  cap=16000; [ "$skill" != approve-merge ] || cap=14000
  check test "$(wc -c < "$ROOT/.claude/skills/$skill/SKILL.md")" -le "$cap"
done
merge="$ROOT/.claude/skills/approve-merge/SKILL.md"
check grep -qx 'disable-model-invocation: true' "$merge"
check grep -q '^tracker_pr_merge ' "$merge"
if grep -E '\$\(tracker_pr_merge|`tracker_pr_merge' "$merge"; then FAIL=$((FAIL + 1)); fi
for strategy in squash merge rebase; do check grep -q "$strategy" "$merge"; done
check grep -qx 'Next: run /compact to free context before the next task.' "$merge"
orbit="$ROOT/.claude/skills/orbit/SKILL.md"
check grep -qF 'Run `/challenge` by default on Plan and Execution Slice drafts.' "$orbit"
check grep -qF 'only when a status changes against the previous Reconciliation or the operator asks.' "$orbit"
check grep -qF 'Run Naqid only when a status changes or the operator asks.' "$orbit"
# Execute the shared snippet with no pin, a valid pin, and a stale pin.
if [ -f "$ROOT/docs/skills/shared/ops-root.md" ]; then
  sandbox=$(mktemp -d "${ROOT}/.shared-block-test.XXXXXX")
  mkdir -p "$sandbox/fork/.claude/hooks" "$sandbox/fork/workspace/project" "$sandbox/pins" "$sandbox/portfolio"
  git -C "$sandbox/fork" init -q
  git -C "$sandbox/fork/workspace/project" init -q
  git -C "$sandbox/portfolio" init -q
  cp "$ROOT/.claude/hooks/_lib-ops-root.sh" "$sandbox/fork/.claude/hooks/"
  touch "$sandbox/fork/.apexyard-fork" "$sandbox/portfolio/onboarding.yaml" "$sandbox/portfolio/apexyard.projects.yaml"
  awk '/^```bash$/{on=1;next} /^```$/{on=0} on' "$ROOT/docs/skills/shared/ops-root.md" > "$sandbox/snippet.sh"
  printf '\n[ "$ops_root" = "$EXPECTED_ROOT" ]\n' >> "$sandbox/snippet.sh"
  check env APEXYARD_OPS_DISABLE_PIN=1 EXPECTED_ROOT="$sandbox/fork" bash -c 'cd "$1" && bash "$2"' _ "$sandbox/fork/workspace/project" "$sandbox/snippet.sh"
  printf '%s\n' "$sandbox/fork" > "$sandbox/pins/ops-root-test"
  check env APEXYARD_OPS_DISABLE_PIN= CLAUDE_CODE_SESSION_ID=test APEXYARD_OPS_PIN_DIR="$sandbox/pins" EXPECTED_ROOT="$sandbox/fork" bash -c 'cd "$1" && bash "$2"' _ "$sandbox/portfolio" "$sandbox/snippet.sh"
  printf '%s\n' "$sandbox/missing" > "$sandbox/pins/ops-root-test"
  check env APEXYARD_OPS_DISABLE_PIN= CLAUDE_CODE_SESSION_ID=test APEXYARD_OPS_PIN_DIR="$sandbox/pins" EXPECTED_ROOT="$sandbox/fork" bash -c 'cd "$1" && bash "$2"' _ "$sandbox/fork/workspace/project" "$sandbox/snippet.sh"
  rm -rf "$sandbox"
fi
[ "$FAIL" -eq 0 ]
