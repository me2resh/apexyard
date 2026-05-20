#!/bin/bash
# Smoke test for the 7 engineering-department sub-agent wrappers shipped
# in me2resh/apexyard#347 PR 1, plus the `## Activation mode` section
# coverage on all 19 role files. Per AgDR-0050 Axis 1 (WRAP), Axis 2
# (default model matrix), and Axis 6 (HYBRID role-trigger integration).
#
# Invariants pinned here:
#
#   1. All 7 engineering agent files exist at .claude/agents/<slug>.md
#   2. Each engineering agent file has the required frontmatter fields:
#      name, description, model, allowed-tools, persona_name
#   3. Each model value is one of `opus | sonnet | haiku`
#   4. Each agent file's body references the role file
#      `@roles/engineering/<role>.md` (the WRAP contract — agent files
#      are thin wrappers that delegate identity to roles/)
#   5. All 19 role files have a `## Activation mode` section
#   6. Each role file's `## Activation mode` section declares a `Class:`
#      value matching the AgDR-0050 § Axis 6 table exactly
#
# Test style follows the framework convention (set -u, ROOT from
# dirname, red/green helpers, FAIL counter, exit 0/1). No external
# test framework.
#
# Usage: bash .claude/agents/tests/test_engineering_agents_wrap_shape.sh
# Exit 0 on success, 1 on any failure.

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"

AGENTS_DIR="$ROOT/.claude/agents"
ROLES_DIR="$ROOT/roles"

FAIL=0

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

# 7 engineering agents shipped in #347 PR 1.
# Format: "<slug>:<expected_model>:<expected_persona_name>"
ENG_AGENTS=(
  "head-of-engineering:opus:Khalid"
  "tech-lead:opus:Hisham"
  "backend-engineer:sonnet:Karim"
  "frontend-engineer:sonnet:Yasmin"
  "qa-engineer:haiku:Salim"
  "platform-engineer:sonnet:Adel"
  "sre:opus:Saif"
)

# All 19 role files (path under roles/) + expected Activation mode Class.
# Per AgDR-0050 § Axis 6 (HYBRID integration table).
ROLE_CLASSES=(
  "engineering/head-of-engineering.md:isolated-work-class"
  "engineering/tech-lead.md:isolated-work-class"
  "engineering/backend-engineer.md:in-flow-class"
  "engineering/frontend-engineer.md:in-flow-class"
  "engineering/qa-engineer.md:isolated-work-class"
  "engineering/platform-engineer.md:in-flow-class"
  "engineering/sre.md:isolated-work-class"
  "product/head-of-product.md:isolated-work-class"
  "product/product-manager.md:in-flow-class"
  "product/product-analyst.md:isolated-work-class"
  "design/head-of-design.md:isolated-work-class"
  "design/ui-designer.md:in-flow-class"
  "design/ux-designer.md:in-flow-class"
  "security/head-of-security.md:isolated-work-class"
  "security/security-auditor.md:isolated-work-class"
  "security/penetration-tester.md:isolated-work-class"
  "data/head-of-data.md:isolated-work-class"
  "data/data-analyst.md:isolated-work-class"
  "data/data-engineer.md:in-flow-class"
)

# Helper: extract the value of a YAML frontmatter key from the first
# `---`-delimited block of a file. Trims surrounding whitespace.
# Returns empty string if not found.
get_frontmatter_value() {
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN { in_fm = 0; fm_count = 0 }
    /^---[[:space:]]*$/ {
      fm_count++
      if (fm_count == 1) { in_fm = 1; next }
      if (fm_count == 2) { in_fm = 0; exit }
    }
    in_fm == 1 {
      # Match "key: value" (allow leading whitespace, key boundary)
      if (match($0, "^[[:space:]]*" key "[[:space:]]*:")) {
        # Strip everything up to and including the first colon
        sub("^[[:space:]]*" key "[[:space:]]*:[[:space:]]*", "")
        print
        exit
      }
    }
  ' "$file"
}

# -----------------------------------------------------------------------------
# Invariant 1 + 2 + 3 + 4 — engineering agent files: existence, frontmatter,
# model value in matrix, role-file reference present.
# -----------------------------------------------------------------------------
echo "== Engineering agent wrap-shape (AgDR-0050 § Axis 1 + 2)"
for entry in "${ENG_AGENTS[@]}"; do
  slug="${entry%%:*}"
  rest="${entry#*:}"
  expected_model="${rest%%:*}"
  expected_persona="${rest#*:}"
  agent_file="$AGENTS_DIR/${slug}.md"

  # Invariant 1: file exists
  if [ ! -f "$agent_file" ]; then
    red "  FAIL: missing agent file $agent_file"
    FAIL=$((FAIL + 1))
    continue
  fi

  # Invariant 2: required frontmatter keys present
  missing=""
  for key in name description model allowed-tools persona_name; do
    val=$(get_frontmatter_value "$agent_file" "$key")
    if [ -z "$val" ]; then
      missing="$missing $key"
    fi
  done
  if [ -n "$missing" ]; then
    red "  FAIL: $slug — missing frontmatter keys:$missing"
    FAIL=$((FAIL + 1))
    continue
  fi

  # Invariant 3: model value is one of opus / sonnet / haiku
  actual_model=$(get_frontmatter_value "$agent_file" "model")
  case "$actual_model" in
    opus|sonnet|haiku) ;;
    *)
      red "  FAIL: $slug — model=$actual_model (must be opus|sonnet|haiku)"
      FAIL=$((FAIL + 1))
      continue
      ;;
  esac
  if [ "$actual_model" != "$expected_model" ]; then
    red "  FAIL: $slug — model=$actual_model (expected $expected_model per matrix)"
    FAIL=$((FAIL + 1))
    continue
  fi

  # Invariant 3b: persona_name matches the matrix
  actual_persona=$(get_frontmatter_value "$agent_file" "persona_name")
  if [ "$actual_persona" != "$expected_persona" ]; then
    red "  FAIL: $slug — persona_name=$actual_persona (expected $expected_persona)"
    FAIL=$((FAIL + 1))
    continue
  fi

  # Invariant 4: body references @roles/engineering/<slug>.md
  # Note: the SRE role file is at roles/engineering/sre.md (no -engineer
  # suffix); the agent slug matches. All others map 1:1.
  if ! grep -q "@roles/engineering/${slug}.md" "$agent_file"; then
    red "  FAIL: $slug — missing @roles/engineering/${slug}.md reference in body"
    FAIL=$((FAIL + 1))
    continue
  fi

  green "  PASS: $slug (model=$actual_model, persona=$actual_persona)"
done

# -----------------------------------------------------------------------------
# Invariant 5 + 6 — every role file has `## Activation mode` and declares
# the matrix-correct Class value.
# -----------------------------------------------------------------------------
echo
echo "== Role-file ## Activation mode coverage (AgDR-0050 § Axis 6)"
for entry in "${ROLE_CLASSES[@]}"; do
  rel="${entry%%:*}"
  expected_class="${entry#*:}"
  role_file="$ROLES_DIR/$rel"

  if [ ! -f "$role_file" ]; then
    red "  FAIL: missing role file $role_file"
    FAIL=$((FAIL + 1))
    continue
  fi

  if ! grep -q '^## Activation mode' "$role_file"; then
    red "  FAIL: $rel — missing '## Activation mode' section"
    FAIL=$((FAIL + 1))
    continue
  fi

  # Extract the Class value. Format in the file:
  #   **Class**: <class-value>
  # Look from the Activation-mode section to end-of-file.
  actual_class=$(awk '
    /^## Activation mode/ { in_section = 1; next }
    in_section && /^\*\*Class\*\*:/ {
      sub("^\\*\\*Class\\*\\*:[[:space:]]*", "")
      print
      exit
    }
  ' "$role_file")

  if [ -z "$actual_class" ]; then
    red "  FAIL: $rel — '## Activation mode' present but '**Class**:' line missing"
    FAIL=$((FAIL + 1))
    continue
  fi

  if [ "$actual_class" != "$expected_class" ]; then
    red "  FAIL: $rel — Class=$actual_class (expected $expected_class per AgDR-0050 § Axis 6)"
    FAIL=$((FAIL + 1))
    continue
  fi

  green "  PASS: $rel ($actual_class)"
done

echo
if [ "$FAIL" -gt 0 ]; then
  red "FAIL: $FAIL invariant(s) failed"
  exit 1
fi
green "PASS: engineering agent wrap-shape + 19-role Activation mode coverage"
exit 0
