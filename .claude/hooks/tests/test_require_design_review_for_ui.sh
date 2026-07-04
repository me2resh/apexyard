#!/bin/bash
# Tests for require-design-review-for-ui.sh — the UI merge gate that blocks
# merging a PR touching UI files until a <pr>-design.approved marker exists at a
# matching HEAD SHA. Mirrors test_require_architecture_review.sh.
#
# Before this file the hook had ZERO end-to-end coverage (only
# test_ui_paths_exclude.sh tested the .ui_paths_exclude filter inline). This
# adds the full-gate path plus the #687 split-portfolio no---repo regression.
#
#   A. Inline-replay of the UI_GLOBS matcher (case-SENSITIVE, like the hook).
#   B. End-to-end gate behaviour via a self-contained mock `gh` in a sandbox.
#   C. Cross-repo collision regression (#485) — same PR# in two repos.
#   D. #687 split-portfolio no---repo merge — repo recovered from the cd-target.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/require-design-review-for-ui.sh"
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
# A) UI_GLOBS — the default UI patterns the hook ships with. Kept in sync with
# the hook by copying the same list; the matcher replays the hook's grep, which
# is case-SENSITIVE (grep -qE, NOT -i) — .tsx$/.jsx$ are exact so they do not
# match plain .ts/.js backend files.
# ---------------------------------------------------------------------------
UI_GLOBS='\.tsx$
\.jsx$
\.vue$
\.svelte$
\.css$
\.scss$
\.sass$
\.less$
design-tokens'

classify_file() {
  local file="$1"
  while IFS= read -r PATTERN; do
    [ -z "$PATTERN" ] && continue
    if echo "$file" | grep -qE "$PATTERN"; then
      echo "match"; return
    fi
  done <<< "$UI_GLOBS"
  echo "no-match"
}

echo ""
echo "A) UI_GLOBS matching — UI files match"
assert_eq "tsx component matches"   "match"    "$(classify_file 'src/components/Button.tsx')"
assert_eq "jsx component matches"   "match"    "$(classify_file 'src/App.jsx')"
assert_eq "vue component matches"   "match"    "$(classify_file 'src/Card.vue')"
assert_eq "svelte component matches" "match"   "$(classify_file 'src/Nav.svelte')"
assert_eq "css matches"             "match"    "$(classify_file 'styles/main.css')"
assert_eq "scss matches"            "match"    "$(classify_file 'styles/theme.scss')"
assert_eq "design-tokens matches"   "match"    "$(classify_file 'src/design-tokens.json')"

echo ""
echo "A) UI_GLOBS matching — non-UI files do NOT match"
assert_eq "plain .ts no-match"      "no-match" "$(classify_file 'src/handlers/user.ts')"
assert_eq "plain .js no-match"      "no-match" "$(classify_file 'scripts/build.js')"
assert_eq "readme no-match"         "no-match" "$(classify_file 'README.md')"
assert_eq "go file no-match"        "no-match" "$(classify_file 'cmd/main.go')"

# ---------------------------------------------------------------------------
# B) End-to-end gate via self-contained mock gh.
# ---------------------------------------------------------------------------
make_sandbox() {
  local sb
  sb=$(mktemp -d)
  : > "$sb/.apexyard-fork"
  touch "$sb/onboarding.yaml" "$sb/apexyard.projects.yaml"
  git -C "$sb" init -q
  git -C "$sb" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session/reviews"
  cp "$SRC_ROOT/.claude/hooks/_lib-extract-pr.sh" "$sb/.claude/hooks/_lib-extract-pr.sh"
  cp "$SRC_ROOT/.claude/hooks/_lib-review-markers.sh" "$sb/.claude/hooks/_lib-review-markers.sh"
  cp "$SRC_ROOT/.claude/hooks/_lib-pr-repo.sh" "$sb/.claude/hooks/_lib-pr-repo.sh"
  if [ -f "$SRC_ROOT/.claude/hooks/_lib-ops-root.sh" ]; then
    cp "$SRC_ROOT/.claude/hooks/_lib-ops-root.sh" "$sb/.claude/hooks/_lib-ops-root.sh"
  fi
  echo "$sb"
}

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

run_gate() {
  local sb="$1" command="$2"
  local input
  input=$(printf '{"tool_input":{"command":"%s"}}' "$command")
  ( cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash "$HOOK_SRC" >/dev/null 2>&1 <<< "$input" )
  echo $?
}

SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

echo ""
echo "B) UI PR + NO marker -> BLOCK (exit 2)"
sb=$(make_sandbox)
install_mock_gh "$sb" '"src/components/Button.tsx"' "$SHA"
code=$(run_gate "$sb" "gh pr merge 77 --repo o/r --squash")
assert_eq "blocks without marker" "2" "$code"
rm -rf "$sb"

echo ""
echo "B) UI PR + matching marker -> ALLOW (exit 0)"
sb=$(make_sandbox)
install_mock_gh "$sb" '"src/components/Button.tsx"' "$SHA"
printf '%s\n' "$SHA" > "$(review_marker_path "o/r" 77 design "$sb")"
code=$(run_gate "$sb" "gh pr merge 77 --repo o/r --squash")
assert_eq "allows with matching marker" "0" "$code"
rm -rf "$sb"

echo ""
echo "B) UI PR + STALE marker (SHA mismatch) -> BLOCK (exit 2)"
sb=$(make_sandbox)
install_mock_gh "$sb" '"styles/theme.scss"' "$SHA"
printf '%s\n' "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" > "$(review_marker_path "o/r" 77 design "$sb")"
code=$(run_gate "$sb" "gh pr merge 77 --repo o/r --squash")
assert_eq "blocks on stale marker SHA" "2" "$code"
rm -rf "$sb"

echo ""
echo "B) non-UI PR -> ALLOW (exit 0, gate is a no-op)"
sb=$(make_sandbox)
install_mock_gh "$sb" '"src/handlers/user.ts" "cmd/main.go"' "$SHA"
code=$(run_gate "$sb" "gh pr merge 77 --repo o/r --squash")
assert_eq "no-op on non-UI PR" "0" "$code"
rm -rf "$sb"

echo ""
echo "B) non-merge command -> ALLOW (exit 0, not our concern)"
sb=$(make_sandbox)
install_mock_gh "$sb" '"src/components/Button.tsx"' "$SHA"
code=$(run_gate "$sb" "gh pr view 77")
assert_eq "no-op on non-merge command" "0" "$code"
rm -rf "$sb"

echo ""
echo "B) gh api merge shape + UI PR + no marker -> BLOCK (exit 2)"
sb=$(make_sandbox)
install_mock_gh "$sb" '"src/components/Button.tsx"' "$SHA"
code=$(run_gate "$sb" "gh api repos/o/r/pulls/77/merge -X PUT")
assert_eq "blocks via gh api shape too" "2" "$code"
rm -rf "$sb"

echo ""
echo "C) Cross-repo collision regression (#485) — same PR# in two repos"

echo ""
echo "C) design marker for repo-A's PR#77 does NOT satisfy repo-B's PR#77 gate"
sb=$(make_sandbox)
install_mock_gh "$sb" '"src/components/Button.tsx"' "$SHA" "repo-b/project-b"
printf '%s\n' "$SHA" > "$(review_marker_path "repo-a/project-a" 77 design "$sb")"
code=$(run_gate "$sb" "gh pr merge 77 --repo repo-b/project-b --squash")
assert_eq "cross-repo: repo-A marker blocks repo-B gate (#485)" "2" "$code"
rm -rf "$sb"

echo ""
echo "C) design marker for repo-B's PR#77 DOES satisfy repo-B's PR#77 gate"
sb=$(make_sandbox)
install_mock_gh "$sb" '"src/components/Button.tsx"' "$SHA" "repo-b/project-b"
printf '%s\n' "$SHA" > "$(review_marker_path "repo-b/project-b" 77 design "$sb")"
code=$(run_gate "$sb" "gh pr merge 77 --repo repo-b/project-b --squash")
assert_eq "cross-repo: correct repo marker allows gate (#485)" "0" "$code"
rm -rf "$sb"

echo ""
echo "D) #687 split-portfolio no---repo merge — repo recovered from the cd-target"

# A sibling portfolio repo whose origin is the portfolio slug. The merge command
# is `cd <portfolio> && gh pr merge <N>` with NO --repo — so the hook must
# recover the repo from the cd-target's origin (pr_cmd_cd_target +
# git_origin_repo), set --repo on the diff, AND key the marker on that slug.
make_portfolio() {
  local slug="$1" p
  p=$(mktemp -d)
  git -C "$p" init -q
  git -C "$p" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$p" remote add origin "git@github.com:${slug}.git"
  echo "$p"
}

# Repo-aware mock gh: answers ONLY when the call carries `--repo <portfolio>`.
# A BARE call (no --repo) models gh resolving against the ops-fork cwd, which
# does NOT have this PR → empty output — exactly what makes the PRE-#687 hook
# silent-bypass. So these cases fail against the old hook, pass against the fix.
install_mock_gh_splitportfolio() {
  local sb="$1" diff_files="$2" head_sha="$3" portfolio="$4"
  mkdir -p "$sb/bin"
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
args="\$*"
case "\$args" in
  *"--repo $portfolio"*|*"repos/$portfolio/"*)
    case "\$args" in
      *"pr diff"*"--name-only"*) printf '%s\n' $diff_files ;;
      *"pr view"*headRefOid*)    printf '%s\n' "$head_sha" ;;
      *"pr view"*headRepository*) printf '%s\n' "$portfolio" ;;
      *) exit 0 ;;
    esac
    ;;
  *"pr diff"*"--name-only"*) ;;    # bare → no files (ops-fork resolution)
  *"pr view"*headRefOid*) ;;        # bare → empty
  *) exit 0 ;;
esac
EOF
  chmod +x "$sb/bin/gh"
}

PF_SLUG="me2resh/portfolio-x"

echo ""
echo "D) no---repo cd-target + UI PR + NO marker -> BLOCK (was a silent-bypass pre-#687)"
sb=$(make_sandbox); pf=$(make_portfolio "$PF_SLUG")
install_mock_gh_splitportfolio "$sb" '"src/components/Button.tsx"' "$SHA" "$PF_SLUG"
code=$(run_gate "$sb" "cd $pf && gh pr merge 77 --squash")
assert_eq "#687 cd-target: blocks without marker" "2" "$code"
rm -rf "$sb" "$pf"

echo ""
echo "D) ROUND-TRIP: no---repo cd-target + marker under the PORTFOLIO qualifier -> ALLOW"
sb=$(make_sandbox); pf=$(make_portfolio "$PF_SLUG")
install_mock_gh_splitportfolio "$sb" '"src/components/Button.tsx"' "$SHA" "$PF_SLUG"
printf '%s\n' "$SHA" > "$(review_marker_path "$PF_SLUG" 77 design "$sb")"
code=$(run_gate "$sb" "cd $pf && gh pr merge 77 --squash")
assert_eq "#687 round-trip: portfolio-qualified marker allows gate" "0" "$code"
rm -rf "$sb" "$pf"

echo ""
echo "D) negative: marker under the WRONG (ops-fork) qualifier -> BLOCK (qualifier is load-bearing)"
sb=$(make_sandbox); pf=$(make_portfolio "$PF_SLUG")
install_mock_gh_splitportfolio "$sb" '"src/components/Button.tsx"' "$SHA" "$PF_SLUG"
printf '%s\n' "$SHA" > "$(review_marker_path "me2resh/ops-fork" 77 design "$sb")"
code=$(run_gate "$sb" "cd $pf && gh pr merge 77 --squash")
assert_eq "#687 wrong-qualifier marker still blocks" "2" "$code"
rm -rf "$sb" "$pf"

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
