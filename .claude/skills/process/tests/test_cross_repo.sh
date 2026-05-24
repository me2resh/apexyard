#!/usr/bin/env bash
# /process cross-repo.sh test — registry-driven cross-repo handoff resolution.
#
# Builds a fake ops-fork with:
#   - .apexyard-fork marker (v2 anchor)
#   - apexyard.projects.yaml registering identity-svc and onboarding-svc
#   - workspace/identity-svc/.git/ present
#   - workspace/onboarding-svc/.git/ absent (tests "missing" code path)
#
# Asserts cross-repo.sh returns:
#   - registered:identity-svc:cloned:... for the cloned target
#   - registered:onboarding-svc:missing:... for the missing target
#   - external for an unregistered target (Stripe)
#   - external for a target with no registry at all

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

assert_prefix() {
  local label="$1" want_prefix="$2" got="$3"
  case "$got" in
    "$want_prefix"*)
      echo "  PASS: $label  (got: $got)"
      PASS=$((PASS + 1))
      ;;
    *)
      echo "  FAIL: $label  (want prefix: $want_prefix, got: $got)"
      FAIL=$((FAIL + 1))
      ;;
  esac
}

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "  PASS: $label  (got: $got)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label  (want: $want, got: $got)"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Build a fake ops-fork
# ---------------------------------------------------------------------------
FORK=$(mktemp -d -t process-cross-fork-XXXXXX)
trap 'rm -rf "$FORK"' EXIT

mkdir -p "$FORK/workspace/identity-svc/.git" "$FORK/.claude/hooks"
touch "$FORK/.apexyard-fork"
touch "$FORK/onboarding.yaml"

cat > "$FORK/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: identity-svc
    repo: example-org/identity-svc
    workspace: workspace/identity-svc
    docs: projects/identity-svc
    status: active
  - name: onboarding-svc
    repo: example-org/onboarding-svc
    workspace: workspace/onboarding-svc
    docs: projects/onboarding-svc
    status: active
YAML

# ---------------------------------------------------------------------------
# Test 1: registered + cloned target by short name
# ---------------------------------------------------------------------------
echo ""
echo "1) Registered + cloned target (by short name)"
RESULT=$("$SKILL_DIR/cross-repo.sh" --target=identity-svc --registry="$FORK/apexyard.projects.yaml")
assert_prefix "identity-svc → registered:cloned" "registered:identity-svc:cloned" "$RESULT"

# ---------------------------------------------------------------------------
# Test 2: registered + cloned target by owner/repo slug
# ---------------------------------------------------------------------------
echo ""
echo "2) Registered + cloned target (by owner/repo slug)"
RESULT=$("$SKILL_DIR/cross-repo.sh" --target=example-org/identity-svc --registry="$FORK/apexyard.projects.yaml")
assert_prefix "example-org/identity-svc → registered:cloned" "registered:identity-svc:cloned" "$RESULT"

# ---------------------------------------------------------------------------
# Test 3: registered + missing target
# ---------------------------------------------------------------------------
echo ""
echo "3) Registered + missing workspace clone"
RESULT=$("$SKILL_DIR/cross-repo.sh" --target=onboarding-svc --registry="$FORK/apexyard.projects.yaml")
assert_prefix "onboarding-svc → registered:missing" "registered:onboarding-svc:missing" "$RESULT"

# ---------------------------------------------------------------------------
# Test 4: external — target not in registry
# ---------------------------------------------------------------------------
echo ""
echo "4) Unregistered target (third party)"
RESULT=$("$SKILL_DIR/cross-repo.sh" --target=stripe --registry="$FORK/apexyard.projects.yaml")
assert_eq "stripe → external" "external" "$RESULT"

RESULT=$("$SKILL_DIR/cross-repo.sh" --target=https://api.stripe.com/v1/charges --registry="$FORK/apexyard.projects.yaml")
assert_eq "URL-formed unregistered target → external" "external" "$RESULT"

# ---------------------------------------------------------------------------
# Test 5: no registry at all
# ---------------------------------------------------------------------------
echo ""
echo "5) No registry available"
RESULT=$("$SKILL_DIR/cross-repo.sh" --target=identity-svc --registry=/dev/null/missing)
assert_eq "missing registry → external" "external" "$RESULT"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "----------------------------------------"
echo "Total: $((PASS + FAIL))   Passed: $PASS   Failed: $FAIL"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo ""
echo "OK: cross-repo.sh registry lookup verified."
exit 0
