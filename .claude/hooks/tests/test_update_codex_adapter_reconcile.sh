#!/bin/bash
# Contract test for /update's installed Codex adapter reconciliation (#943).
#
# /update is a markdown skill, so this test pins its documented shell recipe
# and verifies the two required call sites remain ordered around the
# already-current and post-sync success paths.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
GENERATOR="$ROOT/bin/sync-codex-adapter.sh"
SKILL="$ROOT/.claude/skills/update/SKILL.md"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/update-codex-reconcile.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
FAILED=""

pass() { echo "  ok   $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL $1: $2" >&2; FAIL=$((FAIL+1)); FAILED="$FAILED $1"; }

build_root() {
  local root="$TMPROOT/$1"
  mkdir -p "$root/.claude/skills/update" "$root/.claude/agents"
  printf '%s\n' '# update fixture' > "$root/.claude/skills/update/SKILL.md"
  printf '%s\n' '{"hooks":{}}' > "$root/.claude/settings.json"
  printf '%s\n' "$root"
}

run_recipe() {
  local root="$1"
  shift
  (
    cd "$root" || exit 1
    DRY_RUN=0
    SKIP_ADAPTER_SYNC=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --skip-adapter-sync) SKIP_ADAPTER_SYNC=1 ;;
      esac
      shift
    done

    reconcile_installed_codex_adapter() {
      if [ "$SKIP_ADAPTER_SYNC" = "1" ]; then
        echo "Codex adapter reconciliation skipped (--skip-adapter-sync)."
        return 0
      fi
      if [ "$DRY_RUN" = "1" ]; then
        echo "DRY-RUN: would reconcile an installed Codex adapter."
        return 0
      fi

      local script="$GENERATOR"
      if [ ! -f "$script" ]; then
        echo "Codex adapter reconciliation failed: missing $script" >&2
        return 1
      fi
      bash "$script" --root "$root" --reconcile-installed
    }

    reconcile_installed_codex_adapter
  )
}

echo "== /update Codex adapter reconciliation"

NOINSTALL=$(build_root no-install)
if run_recipe "$NOINSTALL" >/tmp/_update_codex_noinstall.out 2>&1; then
  pass "uninstalled fork exits successfully"
else
  fail "uninstalled fork exits successfully" "$(cat /tmp/_update_codex_noinstall.out)"
fi
if [ ! -e "$NOINSTALL/.agents" ] && [ ! -e "$NOINSTALL/.codex" ]; then
  pass "uninstalled fork remains untouched"
else
  fail "uninstalled fork remains untouched" "adapter directories were created"
fi

STALE=$(build_root stale-install)
bash "$GENERATOR" --root "$STALE" >/dev/null
printf '%s\n' '# newly synced update content' >> "$STALE/.claude/skills/update/SKILL.md"
if run_recipe "$STALE" >/tmp/_update_codex_stale.out 2>&1 \
  && grep -q '# newly synced update content' "$STALE/.agents/skills/update/SKILL.md"; then
  pass "already-current recipe refreshes a stale installed skill"
else
  fail "already-current recipe refreshes a stale installed skill" "$(cat /tmp/_update_codex_stale.out)"
fi

DRY=$(build_root dry-run)
bash "$GENERATOR" --root "$DRY" >/dev/null
printf '%s\n' '# dry-run source drift' >> "$DRY/.claude/skills/update/SKILL.md"
if run_recipe "$DRY" --dry-run >/tmp/_update_codex_dry.out 2>&1 \
  && ! grep -q '# dry-run source drift' "$DRY/.agents/skills/update/SKILL.md"; then
  pass "--dry-run reports intent without refreshing output"
else
  fail "--dry-run reports intent without refreshing output" "$(cat /tmp/_update_codex_dry.out)"
fi

SKIP=$(build_root skip-sync)
bash "$GENERATOR" --root "$SKIP" >/dev/null
printf '%s\n' '# skipped source drift' >> "$SKIP/.claude/skills/update/SKILL.md"
if run_recipe "$SKIP" --skip-adapter-sync >/tmp/_update_codex_skip.out 2>&1 \
  && ! grep -q '# skipped source drift' "$SKIP/.agents/skills/update/SKILL.md"; then
  pass "--skip-adapter-sync leaves installed output unchanged"
else
  fail "--skip-adapter-sync leaves installed output unchanged" "$(cat /tmp/_update_codex_skip.out)"
fi

BROKEN=$(build_root broken-install)
bash "$GENERATOR" --root "$BROKEN" >/dev/null
printf '%s\n' '{ invalid json' > "$BROKEN/.claude/settings.json"
if run_recipe "$BROKEN" >/tmp/_update_codex_broken.out 2>&1; then
  fail "explicit reconciliation propagates generator failure" "expected non-zero exit"
else
  pass "explicit reconciliation propagates generator failure"
fi

call_count=$(grep -c '^reconcile_installed_codex_adapter ||' "$SKILL")
early_call=$(grep -n '^reconcile_installed_codex_adapter ||' "$SKILL" | head -n 1 | cut -d: -f1)
current_report=$(grep -n 'echo "Fork is up to date with upstream/main' "$SKILL" | head -n 1 | cut -d: -f1)
late_heading=$(grep -n '^### 8d\. Reconcile an installed Codex adapter' "$SKILL" | cut -d: -f1)
final_heading=$(grep -n '^### 9\. Final state' "$SKILL" | cut -d: -f1)

if [ "$call_count" -eq 2 ]; then
  pass "skill has exactly two strict reconciliation call sites"
else
  fail "skill has exactly two strict reconciliation call sites" "found $call_count"
fi
if [ -n "$early_call" ] && [ -n "$current_report" ] && [ "$early_call" -lt "$current_report" ]; then
  pass "already-current path reconciles before reporting success"
else
  fail "already-current path reconciles before reporting success" "call=$early_call report=$current_report"
fi
if [ -n "$late_heading" ] && [ -n "$final_heading" ] && [ "$late_heading" -lt "$final_heading" ]; then
  pass "post-sync reconciliation precedes final success report"
else
  fail "post-sync reconciliation precedes final success report" "reconcile=$late_heading final=$final_heading"
fi
if grep -q -- '--skip-adapter-sync) SKIP_ADAPTER_SYNC=1' "$SKILL"; then
  pass "skill parser handles --skip-adapter-sync"
else
  fail "skill parser handles --skip-adapter-sync" "parse case missing"
fi

echo
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED" >&2
  exit 1
fi
