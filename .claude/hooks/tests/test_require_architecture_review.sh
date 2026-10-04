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

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


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
  *"api"*"pulls/77"*"changed_files"*)
    if [ "\${MOCK_LARGE:-0}" = 1 ]; then printf '%s\n' 3001; else printf '%s\n' 1; fi
    ;;
  *"api"*"pulls/"*"/files"*)
    if [ "\${MOCK_LARGE:-0}" = 1 ]; then
      seq 1 3001 | sed 's|^|src/file-|; s|$|.ts|'
    else
      printf '%s\n' $diff_files
    fi
    ;;
  *"pr view"*headRefOid*)
    printf '%s\n' "$head_sha"
    ;;
  *"pr view"*headRepository*)
    printf '%s\n' "$repo"
    ;;
  *"pr view"*"--json number"*)
    printf '%s\n' 77
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
  input=$(jq -nc --arg c "$command" '{tool_input:{command:$c}}')
  ( cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash "$HOOK_SRC" >/dev/null 2>&1 <<< "$input" )
  echo $?
}

# #1525: data-only heredocs pass, but executable bodies still reach the gate.
sb=$(make_sandbox)
install_mock_gh "$sb" '"projects/foo/docs/technical-design-x.md"' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
code=$(run_gate "$sb" $'cat <<\'EOF\'\ngh pr merge 315 --repo $R\nEOF')
assert_eq "#1525 quoted data heredoc passes" "0" "$code"
code=$(run_gate "$sb" $'sh <<\'EOF\'\ngh pr merge $PR --repo $R\nEOF')
assert_eq "#1525 sh heredoc variable blocks" "2" "$code"
rm -rf "$sb"

SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# B1: the branch PR has a matching architecture approval. An argv merge of
# another PR or a runtime value must not inherit that approval.
for argv_target in "'5'" "os.environ['PR']"; do
  sb=$(make_sandbox)
  install_mock_gh "$sb" '"projects/foo/docs/technical-design-x.md"' "$SHA"
  printf '%s\n' "$SHA" > "$(review_marker_path "o/r" 77 architecture "$sb")"
  code=$(run_gate "$sb" "python3 -c \"import subprocess, os; subprocess.run(['gh','pr','merge',$argv_target])\"")
  assert_eq "argv merge target $argv_target does not use approved branch PR" "2" "$code"
  rm -rf "$sb"
done

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
echo "D) #687 split-portfolio no---repo merge — repo recovered from the cd-target"

# A sibling portfolio repo: its own git tree whose origin is the portfolio slug.
# The merge command is `cd <portfolio> && gh pr merge <N>` with NO --repo — so
# the hook must recover the repo from the cd-target's origin (pr_cmd_cd_target +
# git_origin_repo), set --repo on the diff, AND key the marker on that slug.
make_portfolio() {
  local slug="$1" p
  p=$(mktemp -d)
  git -C "$p" init -q
  git -C "$p" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$p" remote add origin "git@github.com:${slug}.git"
  echo "$p"
}

# Repo-aware mock gh: answers ONLY when the call carries `--repo <portfolio>`
# (or the api `repos/<portfolio>/` path). A BARE call (no --repo) models gh
# resolving against the ops-fork cwd, which does NOT have this PR → empty output.
# That empty output is exactly what makes the PRE-#687 hook silent-bypass; these
# cases therefore fail against the old hook and pass against the fixed one.
install_mock_gh_splitportfolio() {
  local sb="$1" diff_files="$2" head_sha="$3" portfolio="$4"
  mkdir -p "$sb/bin"
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
args="\$*"
case "\$args" in
  *"--repo $portfolio"*|*"repos/$portfolio/"*)
    case "\$args" in
      *"pulls/77"*"changed_files"*) printf '%s\n' 1 ;;
      *"pulls/77/files"*) printf '%s\n' $diff_files ;;
      *"pr view"*headRefOid*)    printf '%s\n' "$head_sha" ;;
      *"pr view"*headRepository*) printf '%s\n' "$portfolio" ;;
      *) exit 0 ;;
    esac
    ;;
  *"pulls/77/files"*) ;;    # bare → no files (ops-fork resolution)
  *"pr view"*headRefOid*) ;;        # bare → empty
  *) exit 0 ;;
esac
EOF
  chmod +x "$sb/bin/gh"
}

PF_SLUG="me2resh/portfolio-x"

echo ""
echo "D) no---repo cd-target + design PR + NO marker -> BLOCK (was a silent-bypass pre-#687)"
sb=$(make_sandbox); pf=$(make_portfolio "$PF_SLUG")
install_mock_gh_splitportfolio "$sb" '"projects/foo/docs/technical-design-x.md"' "$SHA" "$PF_SLUG"
code=$(run_gate "$sb" "cd $pf && gh pr merge 77 --squash")
assert_eq "#687 cd-target: blocks without marker" "2" "$code"
rm -rf "$sb" "$pf"

echo ""
echo "D) ROUND-TRIP: no---repo cd-target + marker under the PORTFOLIO qualifier -> ALLOW"
sb=$(make_sandbox); pf=$(make_portfolio "$PF_SLUG")
install_mock_gh_splitportfolio "$sb" '"projects/foo/docs/technical-design-x.md"' "$SHA" "$PF_SLUG"
# The fixed write side keys the marker on the portfolio slug — prove the fixed
# read side finds it (the symmetry the #687 warning section demands).
printf '%s\n' "$SHA" > "$(review_marker_path "$PF_SLUG" 77 architecture "$sb")"
code=$(run_gate "$sb" "cd $pf && gh pr merge 77 --squash")
assert_eq "#687 round-trip: portfolio-qualified marker allows gate" "0" "$code"
rm -rf "$sb" "$pf"

echo ""
echo "D) negative: marker under the WRONG (ops-fork) qualifier -> BLOCK (qualifier is load-bearing)"
sb=$(make_sandbox); pf=$(make_portfolio "$PF_SLUG")
install_mock_gh_splitportfolio "$sb" '"projects/foo/docs/technical-design-x.md"' "$SHA" "$PF_SLUG"
printf '%s\n' "$SHA" > "$(review_marker_path "me2resh/ops-fork" 77 architecture "$sb")"
code=$(run_gate "$sb" "cd $pf && gh pr merge 77 --squash")
assert_eq "#687 wrong-qualifier marker still blocks" "2" "$code"
rm -rf "$sb" "$pf"

echo ""
echo "E) #1091/#1099 sibling: forge HEAD unresolvable -> the gate must FAIL CLOSED"
#
# require-architecture-review.sh carried the SAME local-HEAD fallback that
# block-unreviewed-merge.sh had (see #1091, fixed for all three gates by
# #1098, which shipped a regression test only for block-unreviewed-merge.sh).
# This is the missing discriminating case for THIS gate (#1099), built on the
# exact construction from test_block_unreviewed_merge.sh's #1091 case
# (~line 832): the mock gh answers `pr diff` (a design artifact is found)
# and `pr view ... headRepository`, but FAILS `pr view ... headRefOid` — the
# one call resolve_pr_head makes. `headRefName` is also wired to answer even
# though this hook never queries it, mirroring the sibling gate's mock so the
# "forge reachable but this ONE field is missing" shape is explicit rather
# than "the whole gh binary is gone".
#
# DISCRIMINATING BY CONSTRUCTION: the marker is written to match THIS
# sandbox's LOCAL HEAD (`git rev-parse HEAD`) — the value the pre-#1098
# fallback would have substituted for the unresolvable forge HEAD. Under the
# removed fallback that makes the SHA comparison succeed and the merge
# ALLOWED (rc=0). Under fail-closed it is BLOCKED (rc=2) regardless of what
# the local HEAD says. A marker at a MISMATCHING local HEAD would block both
# before and after, proving nothing — the exact trap #1099's own issue body
# calls out.

install_mock_gh_headrefoid_fails() {
  local sb="$1" diff_files="$2" repo="${3:-o/r}"
  mkdir -p "$sb/bin"
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
args="\$*"
case "\$args" in
  *"pulls/"*"/files"*)
    if [ "${MOCK_LARGE:-0}" = 1 ]; then
      seq 1 3001 | sed 's|^|src/file-|; s|$|.ts|'
    else
      printf '%s\n' $diff_files
    fi
    ;;
  *"pr view"*headRefOid*)
    exit 1
    ;;
  *"pr view"*headRefName*)
    printf '%s\n' "feature/GH-99-test"
    ;;
  *"pr view"*headRepository*)
    printf '%s\n' "$repo"
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$sb/bin/gh"
}

sb=$(make_sandbox)
install_mock_gh_headrefoid_fails "$sb" '"projects/foo/docs/technical-design-x.md"'
# The sandbox's local HEAD — the value the OLD fallback would have used.
local_head=$(cd "$sb" && git rev-parse HEAD 2>/dev/null)
# Marker written to MATCH that local HEAD: the setup most favourable to a
# bypass, where every comparison passes under the old code.
printf '%s\n' "$local_head" > "$(review_marker_path "o/r" 77 architecture "$sb")"
code=$(run_gate "$sb" "gh pr merge 77 --repo o/r --squash")
assert_eq "#1091: forge HEAD unresolvable + marker matching LOCAL head -> BLOCKED" "2" "$code"
rm -rf "$sb"

echo ""
echo "B) PR over the files API ceiling -> BLOCK (exit 2)"
sb=$(make_sandbox)
install_mock_gh "$sb" '"src/handlers/user.ts"' "$SHA"
code=$(MOCK_LARGE=1 run_gate "$sb" "gh pr merge 77 --repo o/r --squash")
assert_eq "blocks when changed-file count exceeds 3000" "2" "$code"
rm -rf "$sb"

echo ""
echo "E) #1091/#1099 control: forge healthy, marker at forge HEAD -> still ALLOWED"
# Guards against over-blocking: proves the fail-closed change didn't also
# start blocking the ordinary healthy-forge path.
sb=$(make_sandbox)
install_mock_gh "$sb" '"projects/foo/docs/technical-design-x.md"' "$SHA"
printf '%s\n' "$SHA" > "$(review_marker_path "o/r" 77 architecture "$sb")"
code=$(run_gate "$sb" "gh pr merge 77 --repo o/r --squash")
assert_eq "#1091 control: gh healthy, marker at forge HEAD -> still ALLOWED" "0" "$code"
rm -rf "$sb"

echo ""
echo "F) #1151 explicit wrapper repo outranks a leading cd target"
sb=$(make_sandbox); pf=$(make_portfolio "me2resh/wrong-ops-repo")
install_mock_gh_splitportfolio "$sb" '"projects/foo/docs/technical-design-x.md"' "$SHA" "$PF_SLUG"
code=$(run_gate "$sb" "cd $pf && tracker_pr_merge \"$PF_SLUG\" \"77\" \"squash\" true")
assert_eq "#1151 wrapper repo wins over cd-target and blocks" "2" "$code"
rm -rf "$sb" "$pf"

echo ""
echo "F) #1151 unexpanded wrapper repo fails closed"
sb=$(make_sandbox)
install_mock_gh "$sb" '"projects/foo/docs/technical-design-x.md"' "$SHA"
code=$(run_gate "$sb" 'tracker_pr_merge "$PR_HOST_REPO" "77" "squash" true')
assert_eq "#1151 variable wrapper target blocks" "2" "$code"
rm -rf "$sb"

echo ""
echo "F) #1151 unavailable diff fails closed"
sb=$(make_sandbox)
mkdir -p "$sb/bin"
printf '%s\n' '#!/bin/bash' 'exit 1' > "$sb/bin/gh"
chmod +x "$sb/bin/gh"
code=$(run_gate "$sb" "gh pr merge 77 --repo o/r --squash")
assert_eq "#1151 unresolvable diff blocks" "2" "$code"
rm -rf "$sb"

echo ""
echo "G) missing required library blocks (me2resh/apexyard#1405 H2)"
# me2resh/apexyard#1405 second-round review, Hakim H2: a missing required
# library must BLOCK in DEFAULT bash, not just under POSIXLY_CORRECT — see
# block-unreviewed-merge.sh's own copy of this test for the full
# rationale. Runs an independent, self-contained copy of the hook (own
# HOOK_DIR) so removing a library here cannot affect the real repo.
# _lib-pr-repo.sh is included here (unlike its optional treatment in
# block-unreviewed-merge.sh / block-merge-on-red-ci.sh) because this hook
# has always sourced it unconditionally and now guards it the same way.
for lib in _lib-extract-pr.sh _lib-review-markers.sh _lib-pr-repo.sh; do
  for mode in default posix; do
    sb=$(mktemp -d)
    mkdir -p "$sb/.claude/hooks"
    cp "$HOOK_SRC" "$sb/.claude/hooks/require-architecture-review.sh"
    cp "$SRC_ROOT/.claude/hooks/_lib-extract-pr.sh" "$sb/.claude/hooks/_lib-extract-pr.sh"
    cp "$SRC_ROOT/.claude/hooks/_lib-review-markers.sh" "$sb/.claude/hooks/_lib-review-markers.sh"
    cp "$SRC_ROOT/.claude/hooks/_lib-pr-repo.sh" "$sb/.claude/hooks/_lib-pr-repo.sh"
    chmod +x "$sb/.claude/hooks/require-architecture-review.sh"
    rm -f "$sb/.claude/hooks/$lib"
    input=$(printf '{"tool_input":{"command":"%s"}}' "gh pr merge 500 --repo o/r --squash")
    if [ "$mode" = "posix" ]; then
      got_stderr=$(cd "$sb" && bash -c "echo '$input' | POSIXLY_CORRECT=1 bash .claude/hooks/require-architecture-review.sh" 2>&1 >/dev/null)
    else
      got_stderr=$(cd "$sb" && bash -c "echo '$input' | bash .claude/hooks/require-architecture-review.sh" 2>&1 >/dev/null)
    fi
    got_rc=$?
    rm -rf "$sb"
    label="missing-$lib-blocks-in-$mode-bash"
    if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -qi "BLOCKED"; then
      echo "PASS [$label]"; PASS=$((PASS+1))
    else
      echo "FAIL [$label]: want rc=2 + BLOCKED, got rc=$got_rc stderr=${got_stderr:0:300}" >&2
      FAIL=$((FAIL+1))
    fi
  done
done

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
