#!/bin/bash
# Smoke test for the role-derived sub-agent wrappers shipped under
# me2resh/apexyard#347, plus the `## Activation mode` section coverage
# on every active role file. Per AgDR-0050 Axis 1 (WRAP), Axis 2 (default
# model matrix), and Axis 6 (HYBRID role-trigger integration). AgDR-0301
# reduced the roster to 15 agents and 12 active role files.
#
# Wave history:
#   - #347 PR 1 (merged): engineering dept (7 agents) + `## Activation
#     mode` section on all 19 role files.
#   - #2027: 23 agents became 15 (AgDR-0301). Eight role files became
#     redirect stubs for one release.
#   - #347 PR 2: product + design depts (6 agents) — covered here.
#   - #347 PR 3 (upcoming): security + data depts (6 agents).
#   - #347 PR 4 (upcoming): utility-agent `model:` frontmatter
#     (Rex / Hatim / Munir / Tariq / Idris).
#
# Invariants pinned here:
#
#   1. All currently-shipped role-derived agent files exist at
#      .claude/agents/<slug>.md
#   2. Each agent file has the required frontmatter fields:
#      name, description, model, tools, persona_name
#   3. Each model value is one of `opus | sonnet | haiku`
#   4. Each agent file's body references the role file
#      `@roles/<dept>/<role>.md` (the WRAP contract — agent files
#      are thin wrappers that delegate identity to roles/)
#   5. All active role files have a `## Activation mode` section
#   6. Each role file's `## Activation mode` section declares a `Class:`
#      value matching the AgDR-0050 § Axis 6 table exactly
#   7. The roster holds exactly 15 agent files (AgDR-0301)
#   8. Each redirect stub names its receiver and has no
#      `## Activation mode` section, and no agent file remains for it
#
# Test style follows the framework convention (set -u, ROOT from
# dirname, red/green helpers, FAIL counter, exit 0/1). No external
# test framework.
#
# Usage: bash .claude/agents/tests/test_agent_wrap_shape.sh
# Exit 0 on success, 1 on any failure.

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"

AGENTS_DIR="$ROOT/.claude/agents"
ROLES_DIR="$ROOT/roles"

FAIL=0

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

# 10 role-derived agents after the 23-to-15 roster change (AgDR-0301).
# Format: "<slug>:<expected_model>:<expected_persona_name>:<dept>"
# <dept> is the subdir under roles/ that hosts the canonical role file.
# The agent body must reference `@roles/<dept>/<slug>.md`.
ROLE_AGENTS=(
  # PR 1 — engineering dept
  "tech-lead:opus:Hisham:engineering"
  "backend-engineer:sonnet:Karim:engineering"
  "frontend-engineer:sonnet:Yasmin:engineering"
  "qa-engineer:sonnet:Salim:engineering"
  "platform-engineer:sonnet:Adel:engineering"
  "sre:opus:Saif:engineering"
  # PR 2 — product dept
  "product-manager:sonnet:Mariam:product"
  # PR 2 — design dept
  "ui-designer:sonnet:Nour:design"
  # PR 3 — security dept (security-reviewer.md is the Hakim/Hatim consolidation,
  # checked separately below — it keeps its non-standard filename so /security-review
  # and the auto-fire hook keep working)
  "penetration-tester:opus:Hamza:security"
  # PR 3 — data dept
  "data-engineer:sonnet:Anwar:data"
)

# Utility agents — no canonical role file under roles/<dept>/, but the model
# baseline is set by AgDR-0050 § Axis 2 and locked in by this PR (Wave 2 PR 4
# of #347). Each entry carries a `# routing-config:override` comment in its
# YAML frontmatter so block-agent-routing-drift.sh accepts the intentional
# inherit→<model> framework-default change. security-reviewer.md is included
# here because PR 3's Hatim→Hakim consolidation already promoted it to opus
# with the same escape-hatch shape.
# Format: "<slug>:<expected_model>:<expected_persona_name>"
UTILITY_AGENTS=(
  "code-reviewer:opus:Rex"
  "security-reviewer:opus:Hakim"
  "dependency-auditor:sonnet:Munir"
)

# All 12 active role files (path under roles/) + expected Activation mode Class.
# Per AgDR-0050 § Axis 6 (HYBRID integration table) and AgDR-0301
# (the 23-to-15 roster). The solution architect role has its own test.
ROLE_CLASSES=(
  "engineering/tech-lead.md:isolated-work-class"
  "engineering/backend-engineer.md:in-flow-class"
  "engineering/frontend-engineer.md:in-flow-class"
  "engineering/qa-engineer.md:isolated-work-class"
  "engineering/platform-engineer.md:in-flow-class"
  "engineering/sre.md:isolated-work-class"
  "product/product-manager.md:in-flow-class"
  "design/ui-designer.md:in-flow-class"
  "security/security-auditor.md:isolated-work-class"
  "security/penetration-tester.md:isolated-work-class"
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

# Optional effort accepts the supported values without changing model routing.
valid_effort() {
  case "$1" in low|medium|high|xhigh|max) return 0 ;; *) return 1 ;; esac
}
for value in low medium high xhigh max; do
  if ! valid_effort "$value"; then
    red "FAIL: supported effort rejected: $value"
    FAIL=$((FAIL + 1))
  fi
done
for value in '' inherit extreme HIGH; do
  if valid_effort "$value"; then
    red "FAIL: invalid effort accepted: $value"
    FAIL=$((FAIL + 1))
  fi
done
for agent_file in "$AGENTS_DIR"/*.md; do
  slug=$(basename "$agent_file" .md)
  actual_effort=$(get_frontmatter_value "$agent_file" effort)
  expected_effort=
  case "$slug" in
    # The tier map in .claude/harness-models.json sets these values
    # (me2resh/apexyard#2033). This list pins the decisions a second time.
    # tech-lead moved to high when it took the engineering-standards
    # work of the former head agent (AgDR-0301).
    code-reviewer|security-reviewer|solution-architect|contrarian|tech-lead)
      expected_effort=high ;;
    backend-engineer|frontend-engineer|platform-engineer|data-engineer|sre|ui-designer|product-manager|qa-engineer)
      expected_effort=medium ;;
  esac
  if [ -n "$actual_effort" ] && ! valid_effort "$actual_effort"; then
    red "FAIL: $slug has invalid effort: $actual_effort"
    FAIL=$((FAIL + 1))
  fi
  if [ "$actual_effort" != "$expected_effort" ]; then
    red "FAIL: $slug effort=$actual_effort (expected $expected_effort)"
    FAIL=$((FAIL + 1))
  fi
done

# -----------------------------------------------------------------------------
# Invariant 1 + 2 + 3 + 4 — role-derived agent files: existence, frontmatter,
# model value in matrix, role-file reference present (per-dept path).
# -----------------------------------------------------------------------------
echo "== Role-derived agent wrap-shape (AgDR-0050 § Axis 1 + 2)"
for entry in "${ROLE_AGENTS[@]}"; do
  # Parse the 4-field entry safely (slug, model, persona, dept).
  IFS=':' read -r slug expected_model expected_persona dept <<<"$entry"
  agent_file="$AGENTS_DIR/${slug}.md"

  # Invariant 1: file exists
  if [ ! -f "$agent_file" ]; then
    red "  FAIL: missing agent file $agent_file"
    FAIL=$((FAIL + 1))
    continue
  fi

  # Invariant 2: required frontmatter keys present
  missing=""
  for key in name description model tools persona_name; do
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

  # Invariant 4: body references @roles/<dept>/<slug>.md
  # Note: the SRE role file is at roles/engineering/sre.md (no -engineer
  # suffix); the agent slug matches. All others map 1:1.
  if ! grep -q "@roles/${dept}/${slug}.md" "$agent_file"; then
    red "  FAIL: $slug — missing @roles/${dept}/${slug}.md reference in body"
    FAIL=$((FAIL + 1))
    continue
  fi

  green "  PASS: $slug (dept=$dept, model=$actual_model, persona=$actual_persona)"
done

# -----------------------------------------------------------------------------
# Invariant 4b — utility agents: model + persona + escape-hatch comment.
# Per AgDR-0050 § Axis 2, the 3 utility agents have explicit model: values
# (not `inherit`) and carry a `# routing-config:override` comment in YAML
# frontmatter so the drift guard accepts the intentional framework-default
# change.
# -----------------------------------------------------------------------------
echo
echo "== Utility-agent model + escape-hatch comment (AgDR-0050 § Axis 2)"
for entry in "${UTILITY_AGENTS[@]}"; do
  IFS=':' read -r slug expected_model expected_persona <<<"$entry"
  agent_file="$AGENTS_DIR/${slug}.md"

  if [ ! -f "$agent_file" ]; then
    red "  FAIL: missing utility-agent file $agent_file"
    FAIL=$((FAIL + 1))
    continue
  fi

  actual_model=$(get_frontmatter_value "$agent_file" "model")
  if [ "$actual_model" = "inherit" ] || [ -z "$actual_model" ]; then
    red "  FAIL: $slug — model=$actual_model (must be an explicit opus|sonnet|haiku per Axis 2; inherit is a regression)"
    FAIL=$((FAIL + 1))
    continue
  fi
  if [ "$actual_model" != "$expected_model" ]; then
    red "  FAIL: $slug — model=$actual_model (expected $expected_model per matrix)"
    FAIL=$((FAIL + 1))
    continue
  fi

  actual_persona=$(get_frontmatter_value "$agent_file" "persona_name")
  if [ "$actual_persona" != "$expected_persona" ]; then
    red "  FAIL: $slug — persona_name=$actual_persona (expected $expected_persona)"
    FAIL=$((FAIL + 1))
    continue
  fi

  # Escape-hatch comment in the YAML frontmatter (between the two `---`
  # markers, `#`-prefixed). The drift guard requires it for any agent file
  # whose model: differs from the dev-baseline `inherit`. Uses POSIX char
  # classes — \S isn't portable across awk implementations.
  if ! awk '
    /^---[[:space:]]*$/ { fm_count++; if (fm_count == 2) exit }
    fm_count == 1 && /^[[:space:]]*#[[:space:]]*routing-config:override[[:space:]]+[^[:space:]]/ { found = 1 }
    END { exit !found }
  ' "$agent_file"; then
    red "  FAIL: $slug — missing '# routing-config:override <reason>' comment in YAML frontmatter (drift guard will block any commit)"
    FAIL=$((FAIL + 1))
    continue
  fi

  green "  PASS: $slug (utility, model=$actual_model, persona=$actual_persona, escape-hatch present)"
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

# -----------------------------------------------------------------------------
# Invariant 7 — the roster holds exactly 15 agent files (AgDR-0301).
# -----------------------------------------------------------------------------
echo
echo "== Roster count (AgDR-0301)"
agent_count=0
for agent_file in "$AGENTS_DIR"/*.md; do
  [ -f "$agent_file" ] && agent_count=$((agent_count + 1))
done
if [ "$agent_count" -eq 15 ]; then
  green "  PASS: 15 agent files"
else
  red "  FAIL: $agent_count agent files (expected 15 per AgDR-0301)"
  FAIL=$((FAIL + 1))
fi

# -----------------------------------------------------------------------------
# Invariant 8 — redirect stubs (AgDR-0301). Each stub names its receiver
# role file, has no `## Activation mode` section, and has no agent file.
# Format: "<stub path under roles/>:<receiver path under roles/>"
# Remove this list with the stubs in the release after AgDR-0301.
# -----------------------------------------------------------------------------
REDIRECT_STUBS=(
  "engineering/head-of-engineering.md:engineering/tech-lead.md"
  "product/head-of-product.md:product/product-manager.md"
  "product/product-analyst.md:product/product-manager.md"
  "security/head-of-security.md:security/security-auditor.md"
  "design/head-of-design.md:design/ui-designer.md"
  "design/ux-designer.md:design/ui-designer.md"
  "data/head-of-data.md:data/data-engineer.md"
  "data/data-analyst.md:data/data-engineer.md"
)
echo
echo "== Redirect stubs (AgDR-0301)"
for entry in "${REDIRECT_STUBS[@]}"; do
  stub="${entry%%:*}"
  receiver="${entry#*:}"
  stub_file="$ROLES_DIR/$stub"
  slug=$(basename "$stub" .md)
  if [ ! -f "$stub_file" ]; then
    red "  FAIL: missing redirect stub $stub_file"
    FAIL=$((FAIL + 1))
    continue
  fi
  if grep -q '^## Activation mode' "$stub_file"; then
    red "  FAIL: $stub — a redirect stub must not declare an Activation mode"
    FAIL=$((FAIL + 1))
    continue
  fi
  if ! grep -qF "roles/$receiver" "$stub_file"; then
    red "  FAIL: $stub — does not name its receiver roles/$receiver"
    FAIL=$((FAIL + 1))
    continue
  fi
  if [ -f "$AGENTS_DIR/$slug.md" ]; then
    red "  FAIL: $stub — agent file .claude/agents/$slug.md still exists"
    FAIL=$((FAIL + 1))
    continue
  fi
  green "  PASS: $stub -> $receiver"
done

echo
if [ "$FAIL" -gt 0 ]; then
  red "FAIL: $FAIL invariant(s) failed"
  exit 1
fi
green "PASS: role-derived agent wrap-shape + utility-agent Axis 2 baselines + Activation mode coverage + 15-agent roster + redirect stubs"
exit 0
