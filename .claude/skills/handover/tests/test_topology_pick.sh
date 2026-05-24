#!/bin/bash
# Smoke test for the /handover skill's topology-pick step introduced in
# me2resh/apexyard#297.
#
# Pins the documentation + filesystem contracts that AgDR-0048 promises:
#   1. SKILL.md mentions the topology-pick step (1.5)
#   2. SKILL.md mentions the bundle-instantiation step (5.5)
#   3. SKILL.md documents the --topology CLI flag in Usage
#   4. SKILL.md summary line includes the `Topology bundle:` field
#   5. All three v1 topology directories exist
#   6. Each topology has a VERSION file containing a valid semver
#   7. Each topology has a README.md
#   8. Each topology has at least one handbook under architecture/
#   9. Each topology has at least one handbook under language/<lang>/
#  10. Each topology has at least 3 handbooks under domain/
#  11. Each topology has at least one CI pipeline under golden-paths/
#  12. Each topology has at least one AgDR template under templates/
#  13. Each domain handbook has a `paths:` frontmatter block (or documented
#      always-load — handbook README convention)
#  14. AgDR-0048 exists, has body-H1 only (no YAML frontmatter),
#      and contains the "In the context of..." one-liner
#  15. CLAUDE.md QUICK REFERENCE table includes a `topologies/` row
#  16. /update SKILL.md mentions topology drift detection (step 8c)
#  17. topologies/README.md lists all three v1 topologies
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
HANDOVER_SKILL="$SRC_ROOT/.claude/skills/handover/SKILL.md"
UPDATE_SKILL="$SRC_ROOT/.claude/skills/update/SKILL.md"
AGDR="$SRC_ROOT/docs/agdr/AgDR-0048-topology-templates.md"
CLAUDE_MD="$SRC_ROOT/CLAUDE.md"
TOPOLOGIES_DIR="$SRC_ROOT/topologies"
TOPOLOGIES_README="$TOPOLOGIES_DIR/README.md"

TOPOLOGIES=(typescript-nextjs python-fastapi go-data-pipeline)

FAIL=0

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

fail() {
  red "FAIL: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  green "PASS: $1"
}

for f in "$HANDOVER_SKILL" "$UPDATE_SKILL" "$AGDR" "$CLAUDE_MD" "$TOPOLOGIES_README"; do
  if [ ! -f "$f" ]; then
    fail "expected file missing: $f"
  fi
done

# 1. SKILL.md mentions the topology-pick step (1.5)
if grep -q "### 1.5. Pick a topology" "$HANDOVER_SKILL"; then
  pass "handover SKILL.md has step 1.5 (topology pick)"
else
  fail "handover SKILL.md missing step 1.5 — topology pick"
fi

# 2. SKILL.md mentions the bundle-instantiation step (5.5)
if grep -q "### 5.5. Instantiate the topology bundle" "$HANDOVER_SKILL"; then
  pass "handover SKILL.md has step 5.5 (bundle instantiation)"
else
  fail "handover SKILL.md missing step 5.5 — bundle instantiation"
fi

# 3. SKILL.md documents the --topology CLI flag
if grep -q -- '--topology' "$HANDOVER_SKILL"; then
  pass "handover SKILL.md documents --topology flag"
else
  fail "handover SKILL.md missing --topology flag documentation"
fi

# 4. SKILL.md summary line includes Topology bundle field
if grep -q "^Topology bundle:" "$HANDOVER_SKILL"; then
  pass "handover SKILL.md summary includes Topology bundle field"
else
  fail "handover SKILL.md summary missing Topology bundle field"
fi

# 5-12. Per-topology assertions
for topology in "${TOPOLOGIES[@]}"; do
  TDIR="$TOPOLOGIES_DIR/$topology"

  # 5. Directory exists
  if [ ! -d "$TDIR" ]; then
    fail "topology dir missing: $TDIR"
    continue
  fi

  # 6. VERSION file with valid semver
  if [ -f "$TDIR/VERSION" ]; then
    ver=$(cat "$TDIR/VERSION" | tr -d '[:space:]')
    if echo "$ver" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
      pass "$topology VERSION ($ver) is valid semver"
    else
      fail "$topology VERSION not valid semver: '$ver'"
    fi
  else
    fail "$topology missing VERSION file"
  fi

  # 7. README.md
  if [ -f "$TDIR/README.md" ]; then
    pass "$topology has README.md"
  else
    fail "$topology missing README.md"
  fi

  # 8. At least one architecture handbook
  arch_count=$(find "$TDIR/handbooks/architecture" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ "$arch_count" -ge 1 ]; then
    pass "$topology has $arch_count architecture handbook(s)"
  else
    fail "$topology missing architecture handbooks"
  fi

  # 9. At least one language handbook
  lang_count=$(find "$TDIR/handbooks/language" -mindepth 2 -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ "$lang_count" -ge 1 ]; then
    pass "$topology has $lang_count language handbook(s)"
  else
    fail "$topology missing language handbooks"
  fi

  # 10. At least 3 domain handbooks
  domain_count=$(find "$TDIR/handbooks/domain" -mindepth 2 -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ "$domain_count" -ge 3 ]; then
    pass "$topology has $domain_count domain handbook(s)"
  else
    fail "$topology has $domain_count domain handbooks (need >= 3)"
  fi

  # 11. At least one CI pipeline
  ci_count=$(find "$TDIR/golden-paths" -maxdepth 1 -name '*.yml' 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ "$ci_count" -ge 1 ]; then
    pass "$topology has $ci_count CI pipeline(s)"
  else
    fail "$topology missing CI pipelines"
  fi

  # 12. At least one AgDR template
  tmpl_count=$(find "$TDIR/templates" -maxdepth 1 -name 'agdr-*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ "$tmpl_count" -ge 1 ]; then
    pass "$topology has $tmpl_count AgDR template(s)"
  else
    fail "$topology missing AgDR templates"
  fi

  # 13. Each domain handbook has paths: frontmatter
  for domain_hb in "$TDIR/handbooks/domain"/*/*.md; do
    [ -f "$domain_hb" ] || continue
    if head -10 "$domain_hb" | grep -q "^paths:"; then
      :  # ok
    else
      fail "domain handbook missing 'paths:' frontmatter: $domain_hb"
    fi
  done
done

# 14. AgDR-0048 exists, body-H1, contains one-liner
if [ -f "$AGDR" ]; then
  # Body-H1 means: first non-empty line starts with `# `
  first_line=$(awk 'NF{print; exit}' "$AGDR")
  if echo "$first_line" | grep -q '^# '; then
    pass "AgDR-0048 starts with body-H1 (no YAML frontmatter)"
  else
    fail "AgDR-0048 first non-empty line is not body-H1: '$first_line'"
  fi
  if grep -q "In the context of" "$AGDR"; then
    pass "AgDR-0048 contains the canonical 'In the context of...' one-liner"
  else
    fail "AgDR-0048 missing 'In the context of...' one-liner"
  fi
else
  fail "AgDR-0048 missing"
fi

# 15. CLAUDE.md QUICK REFERENCE has topologies/ row
if grep -q "topologies/" "$CLAUDE_MD"; then
  pass "CLAUDE.md mentions topologies/"
else
  fail "CLAUDE.md missing topologies/ reference"
fi

# 16. /update SKILL.md mentions topology drift detection
if grep -q "Topology drift detection\|topology drift" "$UPDATE_SKILL"; then
  pass "/update SKILL.md mentions topology drift detection"
else
  fail "/update SKILL.md missing topology drift detection"
fi

# 17. topologies/README.md lists all three v1 topologies
for topology in "${TOPOLOGIES[@]}"; do
  if grep -q "$topology" "$TOPOLOGIES_README"; then
    :
  else
    fail "topologies/README.md doesn't mention $topology"
  fi
done

if [ "$FAIL" -eq 0 ]; then
  green "All topology smoke tests passed."
  exit 0
else
  red "$FAIL test(s) failed."
  exit 1
fi
