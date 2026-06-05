#!/bin/bash
# Tests for require-architecture-review.sh — the Design->Build gate that blocks
# merging a PR carrying a design artifact (technical design / migration AgDR /
# feature spec) until a <pr>-architecture.approved marker exists at a matching
# HEAD SHA. The non-code analog of require-design-review-for-ui.sh.
#
# Two layers, mirroring test_ui_paths_exclude.sh + the integration shape:
#   A. Inline-replay of the DESIGN_GLOBS matcher + .design_paths_exclude filter.
#   B. End-to-end gate behaviour via a self-contained mock `gh` in a sandbox:
#      - design-artifact PR + no marker        -> BLOCK (exit 2)
#      - design-artifact PR + matching marker  -> ALLOW (exit 0)
#      - non-design PR                          -> ALLOW (exit 0)

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/require-architecture-review.sh"
LIB_MARKERS="$SRC_ROOT/.claude/hooks/_lib-review-markers.sh"

for f in "$HOOK_SRC" "$LIB_MARKERS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done

# Load the marker lib so test helpers use the same path logic as the hook.
# shellcheck source=/dev/null
. "$LIB_MARKERS"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS [$label]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [$label]: want '$want', got '$got'" >&2
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# DESIGN_GLOBS — the default design-artifact patterns the hook ships with.
# Kept in sync with the hook by copying the same list here; the matcher logic
# below replays the hook's case-insensitive grep.
# ---------------------------------------------------------------------------
DESIGN_GLOBS='docs/agdr/AgDR-.*migration.*\.md$
technical-design.*\.md$
tech-design.*\.md$
/designs/
/prds/
prd.*\.md$
feature-spec.*\.md$'

# Returns "match" if FILE matches any DESIGN_GLOBS pattern, else "no-match".
classify_file() {
  local file="$1"
  while IFS= read -r PATTERN; do
    [ -z "$PATTERN" ] && continue
    if echo "$file" | grep -qiE "$PATTERN"; then
      echo "match"; return
    fi
  done <<< "$DESIGN_GLOBS"
  echo "no-match"
}

echo ""
echo "A) DESIGN_GLOBS matching — design artifacts match"
assert_eq "migration AgDR matches"        "match"    "$(classify_file 'workspace/foo/docs/agdr/AgDR-0032-cognito-fresh-pool-migration.md')"
assert_eq "technical-design doc matches"  "match"    "$(classify_file 'projects/foo/docs/technical-design-checkout.md')"
assert_eq "tech-design doc matches"       "match"    "$(classify_file 'docs/tech-design.md')"
assert_eq "designs/ dir matches"          "match"    "$(classify_file 'projects/foo/designs/payments.md')"
assert_eq "prds/ dir matches"             "match"    "$(classify_file 'projects/foo/prds/onboarding.md')"
assert_eq "prd file matches"              "match"    "$(classify_file 'docs/checkout-prd.md')"
assert_eq "feature-spec matches"          "match"    "$(classify_file 'docs/feature-spec-likes.md')"

echo ""
echo "A) DESIGN_GLOBS matching — non-design files do NOT match"
assert_eq "source file no-match"          "no-match" "$(classify_file 'src/handlers/user.ts')"
assert_eq "non-migration AgDR no-match"   "no-match" "$(classify_file 'docs/agdr/AgDR-0050-agent-runtime-overhaul.md')"
assert_eq "readme no-match"               "no-match" "$(classify_file 'README.md')"
assert_eq "test file no-match"            "no-match" "$(classify_file 'tests/export.test.ts')"

# ---------------------------------------------------------------------------
# B) End-to-end gate via self-contained mock gh.
# ---------------------------------------------------------------------------
make_sandbox() {
  local sb
  sb=$(mktemp -d)
  # Mark it as an ops fork root so resolve_ops_root / the walk-up anchors here.
  : > "$sb/.apexyard-fork"
  touch "$sb/onboarding.yaml" "$sb/apexyard.projects.yaml"
  # Make it a git repo so `git rev-parse --show-toplevel` resolves to $sb.
  git -C "$sb" init -q
  git -C "$sb" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session/reviews"
  # Copy libs needed by the hook.
  cp "$SRC_ROOT/.claude/hooks/_lib-extract-pr.sh" "$sb/.claude/hooks/_lib-extract-pr.sh"
  cp "$SRC_ROOT/.claude/hooks/_lib-review-markers.sh" "$sb/.claude/hooks/_lib-review-markers.sh"
  if [ -f "$SRC_ROOT/.claude/hooks/_lib-ops-root.sh" ]; then
    cp "$SRC_ROOT/.claude/hooks/_lib-ops-root.sh" "$sb/.claude/hooks/_lib-ops-root.sh"
  fi
  echo "$sb"
}

# Install a mock gh that answers:
#   gh pr diff <N> ... --name-only      -> file list from $MOCK_DIFF_FILES
#   gh pr view <N> ... headRefOid       -> $MOCK_HEAD_SHA
#   gh pr view <N> ... headRepository   -> "o/r" (from the merge command repo)
install_mock_gh() {
  local sb="$1" diff_files="$2" head_sha="$3" repo="${4:-o/r}"
  mkdir -p "$sb/bin"
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
args="\$*"
case "\$args" in
  *"pr diff"*"--name-only"*)
    printf '%s\n' $diff_files
    ;;
  *"pr view"*headRefOid*)
    printf '%s\n' "$head_sha"
    ;;
  *"pr view"*headRepository*)
    printf '%s\n' "$repo"
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$sb/bin/gh"
}

# Run the hook inside the sandbox with the mock gh on PATH. Echoes the exit code.
# APEXYARD_OPS_DISABLE_PIN=1 forces walk-up ops-root resolution so the marker
# resolves to the sandbox, not the real ops fork via a session pin (apexyard#381).
run_gate() {
  local sb="$1" command="$2"
  local input
  input=$(printf '{"tool_input":{"command":"%s"}}' "$command")
  ( cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash "$HOOK_SRC" >/dev/null 2>&1 <<< "$input" )
  echo $?
}

SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

echo ""
echo "B) design-artifact PR + NO marker -> BLOCK (exit 2)"
sb=$(make_sandbox)
install_mock_gh "$sb" '"projects/foo/docs/technical-design-x.md"' "$SHA"
code=$(run_gate "$sb" "gh pr merge 77 --repo o/r --squash")
assert_eq "blocks without marker" "2" "$code"
rm -rf "$sb"

echo ""
echo "B) design-artifact PR + matching marker -> ALLOW (exit 0)"
sb=$(make_sandbox)
install_mock_gh "$sb" '"projects/foo/docs/technical-design-x.md"' "$SHA"
# Use the repo-qualified marker path (AgDR-0060/#485).
printf '%s\n' "$SHA" > "$(review_marker_path "o/r" 77 architecture "$sb")"
code=$(run_gate "$sb" "gh pr merge 77 --repo o/r --squash")
assert_eq "allows with matching marker" "0" "$code"
rm -rf "$sb"

echo ""
echo "B) design-artifact PR + STALE marker (SHA mismatch) -> BLOCK (exit 2)"
sb=$(make_sandbox)
install_mock_gh "$sb" '"projects/foo/docs/technical-design-x.md"' "$SHA"
printf '%s\n' "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" > "$(review_marker_path "o/r" 77 architecture "$sb")"
code=$(run_gate "$sb" "gh pr merge 77 --repo o/r --squash")
assert_eq "blocks on stale marker SHA" "2" "$code"
rm -rf "$sb"

echo ""
echo "B) non-design PR -> ALLOW (exit 0, gate is a no-op)"
sb=$(make_sandbox)
install_mock_gh "$sb" '"src/handlers/user.ts" "tests/user.test.ts"' "$SHA"
code=$(run_gate "$sb" "gh pr merge 77 --repo o/r --squash")
assert_eq "no-op on non-design PR" "0" "$code"
rm -rf "$sb"

echo ""
echo "B) non-merge command -> ALLOW (exit 0, not our concern)"
sb=$(make_sandbox)
install_mock_gh "$sb" '"projects/foo/docs/technical-design-x.md"' "$SHA"
code=$(run_gate "$sb" "gh pr view 77")
assert_eq "no-op on non-merge command" "0" "$code"
rm -rf "$sb"

echo ""
echo "B) gh api merge shape + design PR + no marker -> BLOCK (exit 2)"
sb=$(make_sandbox)
install_mock_gh "$sb" '"projects/foo/docs/technical-design-x.md"' "$SHA"
code=$(run_gate "$sb" "gh api repos/o/r/pulls/77/merge -X PUT")
assert_eq "blocks via gh api shape too" "2" "$code"
rm -rf "$sb"

echo ""
echo "C) Cross-repo collision regression (#485) — same PR# in two repos"

echo ""
echo "C) architecture marker for repo-A's PR#77 does NOT satisfy repo-B's PR#77 gate"
sb=$(make_sandbox)
install_mock_gh "$sb" '"projects/foo/docs/technical-design-x.md"' "$SHA" "repo-b/project-b"
# Write marker for repo-A's PR#77 only.
printf '%s\n' "$SHA" > "$(review_marker_path "repo-a/project-a" 77 architecture "$sb")"
code=$(run_gate "$sb" "gh pr merge 77 --repo repo-b/project-b --squash")
assert_eq "cross-repo: repo-A marker blocks repo-B gate (#485)" "2" "$code"
rm -rf "$sb"

echo ""
echo "C) architecture marker for repo-B's PR#77 DOES satisfy repo-B's PR#77 gate"
sb=$(make_sandbox)
install_mock_gh "$sb" '"projects/foo/docs/technical-design-x.md"' "$SHA" "repo-b/project-b"
printf '%s\n' "$SHA" > "$(review_marker_path "repo-b/project-b" 77 architecture "$sb")"
code=$(run_gate "$sb" "gh pr merge 77 --repo repo-b/project-b --squash")
assert_eq "cross-repo: correct repo marker allows gate (#485)" "0" "$code"
rm -rf "$sb"

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
