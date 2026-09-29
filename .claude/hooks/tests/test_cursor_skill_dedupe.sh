#!/usr/bin/env bash
# Regression tests for apexyard#1377 — Cursor must not list a custom skill
# override and the framework bak as two entries with the same name.
#
# Acceptance criteria covered:
#   AC1. After an override, listing Cursor-readable skills under the fork
#        shows one entry for the skill name, and that entry is the override.
#   AC2. --duplicates fails when two SKILL.md files with the same
#        frontmatter name reach the harness (duplicate detector works).
#   AC3. Install / sync warn operators to open the fork, not a parent
#        portfolio workspace, and sync writes a managed .cursorignore block.
#
# Each case builds an isolated temporary tree. No git operations touch
# this worktree.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIST="$ROOT/bin/list-cursor-skills.sh"
LINK="$ROOT/.claude/hooks/link-custom-skills.sh"
LIB_CURSOR="$ROOT/.claude/hooks/_lib-cursor-skills.sh"
INSTALL="$ROOT/bin/install-cursor-adapter.sh"
SYNC="$ROOT/bin/sync-cursor-adapter.sh"
LIB_PORTFOLIO="$ROOT/.claude/hooks/_lib-portfolio-paths.sh"
LIB_CONFIG="$ROOT/.claude/hooks/_lib-read-config.sh"
LIB_OPS="$ROOT/.claude/hooks/_lib-ops-root.sh"
DEFAULTS="$ROOT/.claude/project-config.defaults.json"

export APEXYARD_OPS_DISABLE_PIN=1

PASS=0
FAIL=0
SKIP=0
FAILED=""

mark_pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
mark_fail() {
  echo "FAIL: $1 — $2" >&2
  FAIL=$((FAIL + 1))
  FAILED="$FAILED $1"
}
mark_skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }


for req in "$LIST" "$LINK" "$LIB_CURSOR" "$INSTALL" "$SYNC" \
           "$LIB_PORTFOLIO" "$LIB_CONFIG" "$LIB_OPS" "$DEFAULTS"; do
  if [ ! -f "$req" ]; then
    echo "FAIL: missing required file $req" >&2
    exit 1
  fi
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-cursor-skill-dedupe.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

make_fork_with_override() {
  local sb="$1"
  local sib="$2"
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/skills/demo-skill" "$sb/bin"
  touch "$sb/.apexyard-fork"
  cat > "$sb/onboarding.yaml" <<'YAML'
company: Example Org
YAML
  cat > "$sb/apexyard.projects.yaml" <<'YAML'
version: 1
projects: []
YAML
  cp "$LINK" "$sb/.claude/hooks/link-custom-skills.sh"
  cp "$LIB_CURSOR" "$sb/.claude/hooks/_lib-cursor-skills.sh"
  cp "$LIB_PORTFOLIO" "$sb/.claude/hooks/_lib-portfolio-paths.sh"
  cp "$LIB_CONFIG" "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$LIB_OPS" "$sb/.claude/hooks/_lib-ops-root.sh"
  cp "$DEFAULTS" "$sb/.claude/project-config.defaults.json"
  cp "$SYNC" "$sb/bin/sync-cursor-adapter.sh"
  cp "$ROOT/.claude/hooks/cursor-session-pin.sh" "$sb/.claude/hooks/cursor-session-pin.sh"
  chmod +x "$sb/.claude/hooks/link-custom-skills.sh" "$sb/bin/sync-cursor-adapter.sh"

  cat > "$sb/.claude/skills/demo-skill/SKILL.md" <<'MD'
---
name: demo-skill
description: Framework copy of demo-skill
---
# Framework demo-skill
MD

  mkdir -p "$sib/custom-skills/demo-skill"
  cat > "$sib/custom-skills/demo-skill/SKILL.md" <<'MD'
---
name: demo-skill
description: Override copy of demo-skill
---
# Override demo-skill
MD
  cat > "$sb/.claude/project-config.json" <<JSON
{ "portfolio": { "custom_skills_dir": "$sib/custom-skills" } }
JSON
}

echo "== AC1: override leaves one Cursor-visible name (override wins)"

SB1="$TMP/fork1"
SIB1="$TMP/portfolio1"
mkdir -p "$SB1" "$SIB1"
make_fork_with_override "$SB1" "$SIB1"
( cd "$SB1" && bash .claude/hooks/link-custom-skills.sh >/dev/null 2>&1 )

if [ -L "$SB1/.claude/skills/demo-skill" ] \
  && [ -d "$SB1/.claude/skill-framework-bak/demo-skill" ] \
  && [ ! -e "$SB1/.claude/skills/demo-skill.framework.bak" ] \
  && [ -f "$SB1/.claude/skill-framework-bak/demo-skill/SKILL.md" ]; then
  mark_pass "AC1 bak moved outside .claude/skills after override"
else
  mark_fail "AC1 bak moved outside .claude/skills after override" \
    "skills=$(ls -la "$SB1/.claude/skills" 2>&1) bak=$(ls -la "$SB1/.claude/skill-framework-bak" 2>&1)"
fi

LIST_OUT=$(bash "$LIST" --root "$SB1" 2>/dev/null || true)
NAME_COUNT=$(printf '%s\n' "$LIST_OUT" | awk -F '\t' '$2 == "demo-skill" { c++ } END { print c+0 }')
UNIQUE_OUT=$(bash "$LIST" --root "$SB1" --unique 2>/dev/null || true)
UNIQUE_PATH=$(printf '%s\n' "$UNIQUE_OUT" | awk -F '\t' '$2 == "demo-skill" { print $1; exit }')
if [ "$NAME_COUNT" = "1" ] \
  && [ -n "$UNIQUE_PATH" ] \
  && grep -q 'Override demo-skill' "$UNIQUE_PATH"; then
  mark_pass "AC1 list shows one demo-skill and unique winner is the override"
else
  mark_fail "AC1 list shows one demo-skill and unique winner is the override" \
    "count=$NAME_COUNT list=[$LIST_OUT] unique=[$UNIQUE_OUT] path=[$UNIQUE_PATH]"
fi

if bash "$LIST" --root "$SB1" --duplicates >/dev/null 2>&1; then
  mark_pass "AC1 --duplicates passes on fork after override"
else
  mark_fail "AC1 --duplicates passes on fork after override" "exit non-zero"
fi

echo "== AC2: duplicate detector fails when two same names reach the harness"

SB2="$TMP/dup-root"
mkdir -p "$SB2/.claude/skills/alpha" "$SB2/.claude/skills/alpha-copy"
cat > "$SB2/.claude/skills/alpha/SKILL.md" <<'MD'
---
name: shared-name
description: First copy
---
# First
MD
cat > "$SB2/.claude/skills/alpha-copy/SKILL.md" <<'MD'
---
name: shared-name
description: Second copy
---
# Second
MD

if bash "$LIST" --root "$SB2" --duplicates >/dev/null 2>&1; then
  mark_fail "AC2 --duplicates fails on duplicate names" "expected non-zero exit"
else
  mark_pass "AC2 --duplicates fails on duplicate names"
fi

echo "== AC3: install and sync warn about parent portfolio workspaces"

if grep -Fq "Open the ops fork directory in Cursor" "$INSTALL" \
  && grep -Fq "parent folder" "$INSTALL" \
  && grep -Fq ".claude/skills/" "$INSTALL"; then
  mark_pass "AC3 install script warns to open the fork not the parent"
else
  mark_fail "AC3 install script warns to open the fork not the parent" "missing warning text in install script"
fi

RULES_MDC="$ROOT/.cursor/rules/apexyard.mdc"
if grep -Fq "Open this ops fork directory in Cursor" "$RULES_MDC" \
  && grep -Fq "AgDR-0187" "$RULES_MDC" \
  && grep -Fq ".claude/skills/" "$RULES_MDC"; then
  mark_pass "AC3 committed rules bridge documents fork-only workspace"
else
  mark_fail "AC3 committed rules bridge documents fork-only workspace" \
    "$(cat "$RULES_MDC" 2>&1)"
fi

echo "== AC3: sync writes managed .cursorignore block on a temp fork"

SB3="$TMP/fork-sync"
mkdir -p "$SB3/.claude/hooks"
touch "$SB3/.apexyard-fork"
cp "$ROOT/.claude/hooks/cursor-session-pin.sh" "$SB3/.claude/hooks/cursor-session-pin.sh"
cp "$LIB_OPS" "$SB3/.claude/hooks/_lib-ops-root.sh"
cp "$LIB_CURSOR" "$SB3/.claude/hooks/_lib-cursor-skills.sh"
chmod +x "$SB3/.claude/hooks/cursor-session-pin.sh"
cat > "$SB3/.claude/hooks/pin-ops-root.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$SB3/.claude/hooks/pin-ops-root.sh"

SYNC_OUT="$TMP/sync-ac3.out"
if ! mkdir -p "$SB3/.cursor/rules" 2>/dev/null; then
  mark_skip "AC3 sync write path blocked in this environment (mkdir .cursor)"
else
  rmdir "$SB3/.cursor/rules" 2>/dev/null || true
  rmdir "$SB3/.cursor" 2>/dev/null || true
  if bash "$SYNC" --root "$SB3" >"$SYNC_OUT" 2>&1; then
    if [ -f "$SB3/.cursorignore" ] \
      && grep -Fq "BEGIN apexyard-cursor-skills" "$SB3/.cursorignore" \
      && grep -Fq ".claude/skill-framework-bak/" "$SB3/.cursorignore" \
      && ! grep -Eq '^custom-skills/|^\*\*/custom-skills/' "$SB3/.cursorignore"; then
      mark_pass "AC3 sync writes managed .cursorignore excluding skill-framework-bak"
    else
      mark_fail "AC3 sync writes managed .cursorignore excluding skill-framework-bak" \
        "cursorignore=$(cat "$SB3/.cursorignore" 2>&1) sync=$(cat "$SYNC_OUT" 2>&1)"
    fi
  else
    mark_fail "AC3 sync writes managed .cursorignore excluding skill-framework-bak" \
      "sync exit non-zero: $(cat "$SYNC_OUT" 2>&1)"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -ne 0 ]; then
  echo "Failed cases:$FAILED" >&2
  exit 1
fi
exit 0
