#!/bin/bash
# Smoke tests for .claude/hooks/link-custom-skills.sh — the SessionStart
# hook that surfaces private custom skills (split-portfolio v2 + #243) to
# Claude Code by symlinking them into the public fork's .claude/skills/.
#
# Cases:
#   1. No private custom-skills dir → no-op (silent, exit 0, no symlinks)
#   2. Private dir with two custom skills → both symlinked, summary printed
#   3. Custom skill name collides with framework skill → custom wins;
#      framework dir moved to <name>.framework.bak; warning printed
#   4. Windows OS detection → graceful decline with manual-install pointer
#   5. Idempotency — re-running with the same private dir is a no-op
#      (same target, same name, no spurious warnings)
#   6. Subdir without SKILL.md is skipped (no symlink created)
#
# Each case builds an isolated sandbox under $TMPDIR with the v2
# `.apexyard-fork` marker + the project-config helpers + the hook itself.

set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/link-custom-skills.sh"
LIB_PORTFOLIO_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-portfolio-paths.sh"
LIB_CONFIG_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-read-config.sh"
LIB_OPS_ROOT_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-ops-root.sh"
DEFAULTS_SRC="$(cd "$(dirname "$0")/../.." && pwd)/project-config.defaults.json"

if [ ! -f "$HOOK_SRC" ]; then
  echo "FAIL: hook not found at $HOOK_SRC" >&2
  exit 1
fi
if [ ! -f "$LIB_PORTFOLIO_SRC" ] || [ ! -f "$LIB_CONFIG_SRC" ] || [ ! -f "$LIB_OPS_ROOT_SRC" ] || [ ! -f "$DEFAULTS_SRC" ]; then
  echo "FAIL: prerequisite libs / defaults missing" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

# --------------------------------------------------------------------------
# make_fork [--no-ops-root-lib]: build an isolated apexyard fork sandbox
# with the v2 marker, the hook script, the portfolio + config libs, and
# the defaults file. By default also copies _lib-ops-root.sh so the
# refactor's primary lib-sourcing path is exercised. Pass
# --no-ops-root-lib to omit it and force the graceful-degradation
# fallback path (covered by case 7).
# Returns the sandbox path on stdout.
# --------------------------------------------------------------------------
make_fork() {
  local copy_ops_root=1
  if [ "${1:-}" = "--no-ops-root-lib" ]; then
    copy_ops_root=0
  fi
  local sb
  sb=$(mktemp -d)
  sb=$(cd "$sb" && pwd -P)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name  "test"

    # v2 anchor — the new layout. Using v2 means we don't also need the
    # legacy onboarding.yaml + apexyard.projects.yaml pair, but adding
    # them too keeps validate happy if the test happens to invoke it.
    touch .apexyard-fork onboarding.yaml
    cat > apexyard.projects.yaml <<'YAML'
version: 1
projects: []
YAML
    mkdir -p projects
    cat > projects/ideas-backlog.md <<'MD'
# ideas
MD

    mkdir -p .claude/hooks .claude/skills
    cp "$HOOK_SRC"          .claude/hooks/link-custom-skills.sh
    cp "$LIB_PORTFOLIO_SRC" .claude/hooks/_lib-portfolio-paths.sh
    cp "$LIB_CONFIG_SRC"    .claude/hooks/_lib-read-config.sh
    if [ "$copy_ops_root" -eq 1 ]; then
      cp "$LIB_OPS_ROOT_SRC" .claude/hooks/_lib-ops-root.sh
    fi
    cp "$DEFAULTS_SRC"      .claude/project-config.defaults.json
    chmod +x .claude/hooks/link-custom-skills.sh

    git add -A
    git commit -q -m "test fixture"
  )
  echo "$sb"
}

# --------------------------------------------------------------------------
# run_hook <sandbox> [extra-env-prefix]
# Runs the hook from inside the sandbox and prints stdout+stderr.
# --------------------------------------------------------------------------
run_hook() {
  local sb="$1"
  local prefix="${2:-}"
  ( cd "$sb" || exit 99
    eval "$prefix bash .claude/hooks/link-custom-skills.sh 2>&1" )
}

assert() {
  local name="$1"
  local cond_rc="$2"
  if [ "$cond_rc" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "PASS: $name"
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  - $name"
    echo "FAIL: $name"
  fi
}

# ==========================================================================
# Case 1 — no private custom-skills dir → no-op silent
# ==========================================================================
SB=$(make_fork)
# No custom-skills dir created anywhere; no project-config override.
out=$(run_hook "$SB")
rc=$?
# Should be exit 0, empty output, no symlinks created.
ok=1
[ "$rc" -eq 0 ] || ok=0
[ -z "$out" ] || ok=0
[ -z "$(ls -A "$SB/.claude/skills" 2>/dev/null)" ] || ok=0
[ "$ok" -eq 1 ] && rc2=0 || rc2=1
assert "case 1: no private custom-skills dir → no-op silent (no symlinks, no output)" "$rc2"
rm -rf "$SB"

# ==========================================================================
# Case 2 — private custom-skills dir with two skills → both symlinked
# ==========================================================================
SB=$(make_fork)
SIB=$(mktemp -d)
SIB=$(cd "$SIB" && pwd -P)
mkdir -p "$SIB/custom-skills/file-internal-bug" "$SIB/custom-skills/check-policy"
cat > "$SIB/custom-skills/file-internal-bug/SKILL.md" <<'MD'
---
name: file-internal-bug
description: File a bug in the internal tracker
---
# /file-internal-bug
MD
cat > "$SIB/custom-skills/check-policy/SKILL.md" <<'MD'
---
name: check-policy
description: Check against the internal compliance corpus
---
# /check-policy
MD
cat > "$SB/.claude/project-config.json" <<JSON
{ "portfolio": { "custom_skills_dir": "$SIB/custom-skills" } }
JSON

out=$(run_hook "$SB")
rc=$?
# Should: exit 0, summary line printed mentioning 2, both symlinks present
# pointing into the sibling, AND both symlinks resolve to a SKILL.md.
ok=1
[ "$rc" -eq 0 ] || ok=0
echo "$out" | grep -q "linked 2 custom skill" || ok=0
[ -L "$SB/.claude/skills/file-internal-bug" ] || ok=0
[ -L "$SB/.claude/skills/check-policy" ] || ok=0
[ -f "$SB/.claude/skills/file-internal-bug/SKILL.md" ] || ok=0
[ -f "$SB/.claude/skills/check-policy/SKILL.md" ] || ok=0
[ "$ok" -eq 1 ] && rc2=0 || rc2=1
assert "case 2: private dir with 2 custom skills → both symlinked, summary printed" "$rc2"
if [ "$ok" -ne 1 ]; then echo "  out: $out"; fi
rm -rf "$SB" "$SIB"

# ==========================================================================
# Case 3 — custom skill name collides with framework skill → custom wins
# ==========================================================================
SB=$(make_fork)
SIB=$(mktemp -d)
SIB=$(cd "$SIB" && pwd -P)
# Pre-populate a "framework" skill at the target name.
mkdir -p "$SB/.claude/skills/feature"
cat > "$SB/.claude/skills/feature/SKILL.md" <<'MD'
---
name: feature
---
# Framework /feature
MD
# Now create a custom skill of the same name in the private repo.
mkdir -p "$SIB/custom-skills/feature"
cat > "$SIB/custom-skills/feature/SKILL.md" <<'MD'
---
name: feature
description: Custom feature skill (overrides framework default)
---
# Custom /feature
MD
cat > "$SB/.claude/project-config.json" <<JSON
{ "portfolio": { "custom_skills_dir": "$SIB/custom-skills" } }
JSON

out=$(run_hook "$SB")
rc=$?
ok=1
[ "$rc" -eq 0 ] || ok=0
# Framework dir moved to <name>.framework.bak.
[ -d "$SB/.claude/skills/feature.framework.bak" ] || ok=0
# Custom symlink in place.
[ -L "$SB/.claude/skills/feature" ] || ok=0
# Symlink resolves to the custom SKILL.md (the body says "Custom").
grep -q 'Custom /feature' "$SB/.claude/skills/feature/SKILL.md" || ok=0
# Warning surfaced naming the override.
echo "$out" | grep -q "override framework skill" || ok=0
echo "$out" | grep -q "feature" || ok=0
[ "$ok" -eq 1 ] && rc2=0 || rc2=1
assert "case 3: name collision → custom wins; framework moved to .bak; warning printed" "$rc2"
if [ "$ok" -ne 1 ]; then echo "  out: $out"; fi
rm -rf "$SB" "$SIB"

# ==========================================================================
# Case 4 — Windows OS detection → graceful decline
# ==========================================================================
SB=$(make_fork)
SIB=$(mktemp -d)
SIB=$(cd "$SIB" && pwd -P)
mkdir -p "$SIB/custom-skills/file-internal-bug"
cat > "$SIB/custom-skills/file-internal-bug/SKILL.md" <<'MD'
---
name: file-internal-bug
---
MD
cat > "$SB/.claude/project-config.json" <<JSON
{ "portfolio": { "custom_skills_dir": "$SIB/custom-skills" } }
JSON

# Force Windows path: set OSTYPE to "msys" so the hook hits the Windows
# branch. We pass the env via the run_hook prefix.
out=$(run_hook "$SB" "OSTYPE=msys")
rc=$?
ok=1
[ "$rc" -eq 0 ] || ok=0
# Decline message printed.
echo "$out" | grep -q "not supported on Windows" || ok=0
echo "$out" | grep -q "Manual workaround" || ok=0
# No symlinks created.
[ ! -L "$SB/.claude/skills/file-internal-bug" ] || ok=0
[ "$ok" -eq 1 ] && rc2=0 || rc2=1
assert "case 4: Windows OS → graceful decline with manual-install pointer; no symlinks" "$rc2"
if [ "$ok" -ne 1 ]; then echo "  out: $out"; fi
rm -rf "$SB" "$SIB"

# ==========================================================================
# Case 5 — idempotency: re-run is a no-op (no spurious warnings, no rework)
# ==========================================================================
SB=$(make_fork)
SIB=$(mktemp -d)
SIB=$(cd "$SIB" && pwd -P)
mkdir -p "$SIB/custom-skills/check-policy"
cat > "$SIB/custom-skills/check-policy/SKILL.md" <<'MD'
---
name: check-policy
---
MD
cat > "$SB/.claude/project-config.json" <<JSON
{ "portfolio": { "custom_skills_dir": "$SIB/custom-skills" } }
JSON

# First run — should link.
out1=$(run_hook "$SB")
# Second run — should be silent (no work to do).
out2=$(run_hook "$SB")
ok=1
[ -L "$SB/.claude/skills/check-policy" ] || ok=0
echo "$out1" | grep -q "linked 1 custom skill" || ok=0
[ -z "$out2" ] || ok=0
[ "$ok" -eq 1 ] && rc2=0 || rc2=1
assert "case 5: idempotent — second run is silent, symlink remains correct" "$rc2"
if [ "$ok" -ne 1 ]; then echo "  out1: $out1"; echo "  out2: $out2"; fi
rm -rf "$SB" "$SIB"

# ==========================================================================
# Case 6 — subdir without SKILL.md is skipped
# ==========================================================================
SB=$(make_fork)
SIB=$(mktemp -d)
SIB=$(cd "$SIB" && pwd -P)
mkdir -p "$SIB/custom-skills/no-skill-md/scratch"
echo "not a skill" > "$SIB/custom-skills/no-skill-md/notes.txt"
mkdir -p "$SIB/custom-skills/real-skill"
cat > "$SIB/custom-skills/real-skill/SKILL.md" <<'MD'
---
name: real-skill
---
MD
cat > "$SB/.claude/project-config.json" <<JSON
{ "portfolio": { "custom_skills_dir": "$SIB/custom-skills" } }
JSON

out=$(run_hook "$SB")
ok=1
# Only the real skill is linked.
[ -L "$SB/.claude/skills/real-skill" ] || ok=0
[ ! -e "$SB/.claude/skills/no-skill-md" ] || ok=0
# Summary line says 1.
echo "$out" | grep -q "linked 1 custom skill" || ok=0
[ "$ok" -eq 1 ] && rc2=0 || rc2=1
assert "case 6: subdir without SKILL.md is skipped; only valid skills linked" "$rc2"
if [ "$ok" -ne 1 ]; then echo "  out: $out"; fi
rm -rf "$SB" "$SIB"

# ==========================================================================
# Case 7: Graceful-degradation fallback — sandbox has NO _lib-ops-root.sh
# (simulating an old framework version or a stripped-down adopter
# install). The hook should fall back to its inline walk-up and still
# link custom skills correctly.
#
# This case is the COMPLEMENT to cases 1-6: those exercise the primary
# lib-sourcing path (because make_fork copies _lib-ops-root.sh by
# default). Together they pin BOTH branches of the
#   if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then ... else ... fi
# discovery shape that link-custom-skills.sh (and several other hooks)
# share.
# ==========================================================================
SB=$(make_fork --no-ops-root-lib)
# Verify the lib really is missing in this sandbox.
[ ! -f "$SB/.claude/hooks/_lib-ops-root.sh" ] || {
  echo "FAIL: case 7 setup — _lib-ops-root.sh unexpectedly present"
  exit 1
}
SIB=$(mktemp -d)
SIB=$(cd "$SIB" && pwd -P)
mkdir -p "$SIB/custom-skills/fallback-skill"
cat > "$SIB/custom-skills/fallback-skill/SKILL.md" <<'MD'
---
name: fallback-skill
---
MD
cat > "$SB/.claude/project-config.json" <<JSON
{ "portfolio": { "custom_skills_dir": "$SIB/custom-skills" } }
JSON

out=$(run_hook "$SB")
ok=1
[ -L "$SB/.claude/skills/fallback-skill" ] || ok=0
echo "$out" | grep -q "linked 1 custom skill" || ok=0
[ "$ok" -eq 1 ] && rc2=0 || rc2=1
assert "case 7: graceful-degradation fallback works when _lib-ops-root.sh is absent" "$rc2"
if [ "$ok" -ne 1 ]; then echo "  out: $out"; fi
rm -rf "$SB" "$SIB"

# ==========================================================================
# Summary
# ==========================================================================
echo
echo "===== test_link_custom_skills.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0
