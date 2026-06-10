#!/bin/bash
# Regression test for Codex renderer private-boundary handling:
#   - local .claude/project-config.json must not render to tracked .codex/
#   - private custom-skill symlinks must not be preserved in .agents/skills/

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PROBE="__private-symlink-probe"
PRIVATE_ROOT=$(mktemp -d)
PRIVATE_SKILL="$PRIVATE_ROOT/$PROBE"
SOURCE_LINK="$ROOT/.claude/skills/$PROBE"
GENERATED_SKILL="$ROOT/.agents/skills/$PROBE"
LOCK_DIR="${TMPDIR:-/tmp}/apexyard-codex-render-private-boundaries.lock"
PASS=0
FAIL=0
LOCK_HELD=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

mark_pass() { PASS=$((PASS + 1)); green "PASS: $1"; }
mark_fail() { FAIL=$((FAIL + 1)); red "FAIL: $1"; [ -n "${2:-}" ] && echo "  detail: $2"; }

cleanup() {
  rm -f "$SOURCE_LINK"
  rm -rf "$PRIVATE_ROOT"
  (cd "$ROOT" && ./bin/apexyard codex render >/dev/null 2>&1 || true)
  if [ "$LOCK_HELD" = "1" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_HELD=1
    break
  fi
  sleep 1
done

if [ "$LOCK_HELD" != "1" ]; then
  mark_fail "acquire render test lock" "$LOCK_DIR"
  echo
  echo "===== test_codex_render_private_boundaries.sh ====="
  echo "Passed: $PASS"
  echo "Failed: $FAIL"
  exit 1
fi
mark_pass "acquire render test lock"

if [ -e "$SOURCE_LINK" ] || [ -L "$SOURCE_LINK" ]; then
  mark_fail "probe source path is available" "$SOURCE_LINK already exists"
else
  mark_pass "probe source path is available"
fi

mkdir -p "$PRIVATE_SKILL"
cat > "$PRIVATE_SKILL/SKILL.md" <<'MD'
---
name: private-probe
description: Private custom skill probe that must not render into Codex output.
---

# Private probe
MD

ln -s "$PRIVATE_SKILL" "$SOURCE_LINK"

if (cd "$ROOT" && ./bin/apexyard codex render >/dev/null); then
  mark_pass "codex renderer completes with a private custom-skill symlink present"
else
  mark_fail "codex renderer completes with a private custom-skill symlink present"
fi

if [ ! -e "$GENERATED_SKILL" ] && [ ! -L "$GENERATED_SKILL" ]; then
  mark_pass "renderer skips private custom-skill symlink"
else
  mark_fail "renderer skips private custom-skill symlink" "$GENERATED_SKILL exists"
fi

generated_symlinks=$(find "$ROOT/.agents/skills" "$ROOT/.codex" -type l -print 2>/dev/null)
if [ -z "$generated_symlinks" ]; then
  mark_pass "generated Codex adapter contains no symlinks"
else
  mark_fail "generated Codex adapter contains no symlinks" "$(printf '%s' "$generated_symlinks" | sed -n '1,5p')"
fi

if [ ! -e "$ROOT/.codex/project-config.json" ] && [ ! -L "$ROOT/.codex/project-config.json" ]; then
  mark_pass "renderer does not write .codex/project-config.json"
else
  mark_fail "renderer does not write .codex/project-config.json"
fi

echo
echo "===== test_codex_render_private_boundaries.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
