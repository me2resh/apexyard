#!/bin/bash
# test_tracker_pr_merge.sh — the #711/#759 merge-command abstraction.
#
# tracker_pr_merge dispatches PR/MR merging to the per-project git host CLI,
# mirroring tracker_review_submit (#758) and tracker_create (#670). It is a
# FUNCTION taking args — strategy and delete_branch are both normalised to a
# closed enum BEFORE they ever reach an eval'd string, so there is no
# free-text/untrusted value in a merge call at all (unlike a review body).
# Built-in adapters for gh / glab, a `merge_command` template for the `custom`
# kind, and `kind=none` is a shape-only no-op that returns 3 (no CLI to call,
# no artefact to echo back).
#
# Tests use MOCK CLIs (a fake gh/glab/mycli on PATH) — no real PR/MR is merged.
#
# Cases:
#   1. gh happy path (default strategy=squash, delete_branch=true) → correct flags
#   2. gh strategy=merge (sync-PR case) → --merge, no --squash
#   3. gh strategy=rebase → --rebase
#   4. gh delete_branch=false → no --delete-branch flag
#   5. gh hostile/unknown strategy → normalised to squash BEFORE dispatch (no injection)
#   6. gh failure → the CLI's non-zero exit propagates
#   7. non-numeric PR id → rejected before any dispatch/eval
#   7b/7c. hostile repo charset → rejected before dispatch; legitimate
#      nested-subgroup repo (group/subgroup/repo) still accepted
#   8. kind=none → returns 3, no CLI invoked
#   9. gh success → emits {"sha":...} resolved via a second `gh pr view` call,
#      and that JSON is proven UNCONTAMINATED by the merge CLI's own stdout
#      confirmation text (discarded, not captured)
#  10. per-project glab override → strategy/delete-branch flag mapping [needs YAML]
#  11. per-project custom merge_command → {owner_repo}/{pr}/{strategy}/{delete_branch}
#      substituted safely; a hostile strategy string is normalised away before
#      it ever reaches the eval'd template (no command execution) [needs YAML]
#
# Exit 0 = all pass. Exit 1 on first failure.

set -u
unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACKER_LIB="$HOOK_DIR/_lib-tracker.sh"
CONFIG_LIB="$HOOK_DIR/_lib-read-config.sh"
PORTFOLIO_LIB="$HOOK_DIR/_lib-portfolio-paths.sh"
OPSROOT_LIB="$HOOK_DIR/_lib-ops-root.sh"

PASS=0
FAIL=0
FAILED=""
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; echo "FAIL: $1"; echo "    expected: [$2]"; echo "    actual:   [$3]"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }

HAVE_YAML=no
if command -v yq >/dev/null 2>&1 || python3 -c 'import yaml' >/dev/null 2>&1; then HAVE_YAML=yes; fi

# Build a single-fork sandbox; $1 optional registry body (per-project trackers).
make_sandbox() {
  local sb registry_body="${1:-}"
  sb=$(mktemp -d); sb=$(cd "$sb" && pwd -P)
  mkdir -p "$sb/.claude/hooks" "$sb/bin"
  touch "$sb/onboarding.yaml"
  cp "$TRACKER_LIB"   "$sb/.claude/hooks/_lib-tracker.sh"
  cp "$CONFIG_LIB"    "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$PORTFOLIO_LIB" "$sb/.claude/hooks/_lib-portfolio-paths.sh"
  [ -f "$OPSROOT_LIB" ] && cp "$OPSROOT_LIB" "$sb/.claude/hooks/_lib-ops-root.sh"
  cat > "$sb/.claude/project-config.defaults.json" <<'JSON'
{ "tracker": { "kind": "gh" } }
JSON
  if [ -n "$registry_body" ]; then
    printf '%s\n' "$registry_body" > "$sb/apexyard.projects.yaml"
  else
    printf 'version: 1\nprojects: []\n' > "$sb/apexyard.projects.yaml"
  fi
  echo "$sb"
}

# Mock gh: capture argv (one per line) to $GH_CAPTURE for `pr merge`, and answer
# `pr view --json mergeCommit` with a fixed SHA so the post-merge lookup has
# something deterministic to resolve.
install_gh_mock() {
  local sb="$1"
  cat > "$sb/bin/gh" <<'EOF'
#!/bin/bash
# Real `gh pr view ... --jq EXPR` applies the jq filter itself and prints only
# the extracted value — emulate that (the lib's _tracker_merge_resolve_sha
# does NOT re-parse gh's output with jq, it trusts --jq already did it).
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo 'deadbeef00000000000000000000000000000000'
  exit 0
fi
[ -n "${GH_CAPTURE:-}" ] && printf '%s\n' "$@" > "$GH_CAPTURE"
# Real `gh pr merge` prints a human-readable confirmation to STDOUT on
# success (e.g. "✓ Squashed and merged pull request #42 …") — reproduce
# that here so the tests prove _tracker_merge_gh's own stdout does NOT leak
# into tracker_pr_merge's returned {"sha":...} JSON (it must be discarded,
# not captured — see the >/dev/null on the merge call itself).
echo "✓ Squashed and merged pull request #42 (some title)"
exit 0
EOF
  chmod +x "$sb/bin/gh"
}

# ---------------------------------------------------------------------------
SB=$(make_sandbox)
install_gh_mock "$SB"
cd "$SB" || { echo "FAIL: cd sandbox"; exit 1; }
# shellcheck source=/dev/null
. "$SB/.claude/hooks/_lib-tracker.sh"

# Case 1 — gh happy path: default strategy (squash) + delete_branch=true.
tracker_clear_cache
: > "$SB/c1"
OUT1=$(PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/c1" tracker_pr_merge "o/r" 42 squash true); rc=$?
assert_eq "gh squash → exit 0"                     "0"      "$rc"
assert_eq "gh squash → 'pr merge' subcommand"      "merge"  "$(sed -n '2p' "$SB/c1")"
assert_eq "gh squash → PR number passed"           "42"     "$(sed -n '3p' "$SB/c1")"
assert_eq "gh squash → --squash present"           "1"      "$(grep -c -- '--squash' "$SB/c1")"
assert_eq "gh squash → --delete-branch present"    "1"      "$(grep -c -- '--delete-branch' "$SB/c1")"
assert_eq "gh squash → no --merge flag"             "0"      "$(grep -c -- '^--merge$' "$SB/c1")"
assert_eq "gh squash → emits sha JSON"             "deadbeef00000000000000000000000000000000" "$(printf '%s' "$OUT1" | jq -r '.sha')"
# The gh mock also prints a confirmation line to stdout on the merge call
# itself (real `gh pr merge` does the same) — OUT1 must be CLEAN, valid JSON
# with nothing before it. If _tracker_merge_gh's stdout ever leaked through
# instead of being discarded, this would fail (`jq -e` rejects leading junk).
assert_eq "gh squash → OUT1 is valid, uncontaminated JSON (no leaked CLI stdout)" \
  "valid" "$(printf '%s' "$OUT1" | jq -e . >/dev/null 2>&1 && echo valid || echo invalid)"

# Case 2 — strategy=merge (the sync-PR case): --merge, no --squash.
tracker_clear_cache
: > "$SB/c2"
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/c2" tracker_pr_merge "o/r" 42 merge true >/dev/null
assert_eq "gh merge → --merge present"   "1" "$(grep -c -- '^--merge$' "$SB/c2")"
assert_eq "gh merge → no --squash"       "0" "$(grep -c -- '--squash' "$SB/c2")"

# Case 3 — strategy=rebase.
tracker_clear_cache
: > "$SB/c3"
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/c3" tracker_pr_merge "o/r" 42 rebase true >/dev/null
assert_eq "gh rebase → --rebase present" "1" "$(grep -c -- '--rebase' "$SB/c3")"

# Case 4 — delete_branch=false → no --delete-branch flag.
tracker_clear_cache
: > "$SB/c4"
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/c4" tracker_pr_merge "o/r" 42 squash false >/dev/null
assert_eq "gh delete_branch=false → no --delete-branch" "0" "$(grep -c -- '--delete-branch' "$SB/c4")"

# Case 5 — a hostile/unknown strategy string is normalised to squash BEFORE
# dispatch — never reaches an eval'd string, never executes as a command.
tracker_clear_cache
: > "$SB/c5"
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/c5" tracker_pr_merge "o/r" 42 'squash; touch PWNED' true >/dev/null
assert_eq "gh hostile strategy → normalised to squash" "1" "$(grep -c -- '--squash' "$SB/c5")"
assert_eq "gh hostile strategy → no injected token leaks into argv" "0" "$(grep -c 'PWNED' "$SB/c5")"
assert_eq "gh hostile strategy → no PWNED file created" "no" "$([ -e "$SB/PWNED" ] && echo yes || echo no)"

# Case 6 — the CLI's non-zero exit propagates.
cat > "$SB/bin/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$SB/bin/gh"
tracker_clear_cache
PATH="$SB/bin:$PATH" tracker_pr_merge "o/r" 42 squash true; rc=$?
assert_eq "gh failure → non-zero exit propagates" "1" "$rc"

# Case 7 — a non-numeric PR id is rejected before any dispatch/eval.
install_gh_mock "$SB"
tracker_clear_cache
: > "$SB/c7"
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/c7" tracker_pr_merge "o/r" '9; rm -rf /' squash true; rc=$?
assert_eq "non-numeric PR id → rejected (non-zero)" "1" "$rc"
assert_eq "non-numeric PR id → no CLI invoked" "" "$(cat "$SB/c7" 2>/dev/null)"

# Case 7b — a repo outside the safe owner/repo charset is rejected before any
# dispatch/eval too (the {pr} guard's sibling — Hakim's LOW finding: repo had
# no charset guard even though it's substituted into the SAME eval'd custom
# template). This check runs BEFORE the kind dispatch, so it protects gh/glab
# as well, not just custom.
tracker_clear_cache
: > "$SB/c7b"
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/c7b" tracker_pr_merge 'o/r; touch PWNED' 42 squash true; rc=$?
assert_eq "hostile repo charset → rejected (non-zero)" "1" "$rc"
assert_eq "hostile repo charset → no CLI invoked" "" "$(cat "$SB/c7b" 2>/dev/null)"
assert_eq "hostile repo charset → no PWNED file" "no" "$([ -e "$SB/PWNED" ] && echo yes || echo no)"
# A legitimate nested-subgroup-shaped repo (GitLab group/subgroup/repo) must
# still be accepted — the guard must not be so strict it rejects real values.
: > "$SB/c7c"
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/c7c" tracker_pr_merge 'grp/sub/repo' 42 squash true >/dev/null; rc=$?
assert_eq "legitimate nested-subgroup repo → accepted" "0" "$rc"
rm -rf "$SB"

# Case 8 — kind=none: no CLI call; returns 3. Shape-only, not a failure path.
SBN=$(make_sandbox)
cat > "$SBN/.claude/project-config.defaults.json" <<'JSON'
{ "tracker": { "kind": "none" } }
JSON
(
  cd "$SBN" || exit 1
  # shellcheck source=/dev/null
  . "$SBN/.claude/hooks/_lib-tracker.sh"
  tracker_clear_cache
  out=$(tracker_pr_merge "o/r" 42 squash true); rc=$?
  printf '%s|%s\n' "$rc" "$out"
) > "$SBN/r"
IFS="|" read -r n_rc n_out < "$SBN/r"
assert_eq "kind=none → exit 3 (shape-only, not a CLI error)" "3" "$n_rc"
assert_eq "kind=none → empty stdout"                          "" "$n_out"
rm -rf "$SBN"

# Case 9 — per-project glab override dispatches glab with the right flags.
if [ "$HAVE_YAML" = yes ]; then
  SB2=$(make_sandbox "version: 1
projects:
  - name: gl
    repo: g/p
    tracker:
      kind: glab")
  cat > "$SB2/bin/glab" <<'EOF'
#!/bin/bash
if [ "$1" = "mr" ] && [ "$2" = "view" ]; then
  echo '{"merge_commit_sha":"cafef00d0000000000000000000000000000000f"}'
  exit 0
fi
[ -n "${GLAB_CAPTURE:-}" ] && printf '%s\n' "$@" > "$GLAB_CAPTURE"
exit 0
EOF
  chmod +x "$SB2/bin/glab"
  (
    cd "$SB2" || exit 1
    # shellcheck source=/dev/null
    . "$SB2/.claude/hooks/_lib-tracker.sh"

    # squash + delete_branch=true
    tracker_clear_cache
    : > "$SB2/capsq"
    out_sq=$(PATH="$SB2/bin:$PATH" GLAB_CAPTURE="$SB2/capsq" tracker_pr_merge "g/p" 7 squash true); rc_sq=$?
    squash_c=$(grep -c -- '--squash' "$SB2/capsq")
    remove_c=$(grep -c -- '--remove-source-branch' "$SB2/capsq")
    sha_sq=$(printf '%s' "$out_sq" | jq -r '.sha')

    # plain merge → no --squash, no --rebase
    tracker_clear_cache
    : > "$SB2/capmg"
    PATH="$SB2/bin:$PATH" GLAB_CAPTURE="$SB2/capmg" tracker_pr_merge "g/p" 7 merge true >/dev/null
    nosquash_c=$(grep -c -- '--squash' "$SB2/capmg")
    norebase_c=$(grep -c -- '--rebase' "$SB2/capmg")

    # delete_branch=false → no --remove-source-branch
    tracker_clear_cache
    : > "$SB2/capnodel"
    PATH="$SB2/bin:$PATH" GLAB_CAPTURE="$SB2/capnodel" tracker_pr_merge "g/p" 7 squash false >/dev/null
    nodel_c=$(grep -c -- '--remove-source-branch' "$SB2/capnodel")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rc_sq" "$squash_c" "$remove_c" "$sha_sq" "$nosquash_c" "$norebase_c" "$nodel_c"
  ) > "$SB2/result"
  IFS=$'\t' read -r g_rc g_squash g_remove g_sha g_nosquash g_norebase g_nodel < "$SB2/result"
  assert_eq "glab squash → exit 0"                         "0" "$g_rc"
  assert_eq "glab squash → --squash present"               "1" "$g_squash"
  assert_eq "glab squash+delete → --remove-source-branch"  "1" "$g_remove"
  assert_eq "glab squash → emits sha JSON"                 "cafef00d0000000000000000000000000000000f" "$g_sha"
  assert_eq "glab merge → no --squash"                     "0" "$g_nosquash"
  assert_eq "glab merge → no --rebase"                     "0" "$g_norebase"
  assert_eq "glab delete_branch=false → no --remove-source-branch" "0" "$g_nodel"
  rm -rf "$SB2"
else
  echo "SKIP: glab per-project case (no yq / python3+PyYAML)"
fi

# Case 10 — per-project custom merge_command. {owner_repo}/{pr}/{strategy}/
# {delete_branch} are all validated enums/numerics by the time they reach the
# eval'd template — a hostile strategy string is normalised to squash BEFORE
# substitution, so it can never inject a command even though this adapter
# substitutes it directly (no env-indirection needed, unlike the review body).
if [ "$HAVE_YAML" = yes ]; then
  SB3=$(make_sandbox "version: 1
projects:
  - name: cu
    repo: c/u
    tracker:
      kind: custom
      merge_command: 'mycli merge -R {owner_repo} --pr {pr} --strategy {strategy} --delete {delete_branch}'")
  cat > "$SB3/bin/mycli" <<'EOF'
#!/bin/bash
[ -n "${MYCLI_CAPTURE:-}" ] && printf '%s\n' "$@" > "$MYCLI_CAPTURE"
exit 0
EOF
  chmod +x "$SB3/bin/mycli"
  (
    cd "$SB3" || exit 1
    # shellcheck source=/dev/null
    . "$SB3/.claude/hooks/_lib-tracker.sh"

    # Happy path — placeholders substituted correctly.
    tracker_clear_cache
    PATH="$SB3/bin:$PATH" MYCLI_CAPTURE="$SB3/cap" tracker_pr_merge "c/u" 9 rebase false >/dev/null; rc=$?
    strategy_seen=$(awk 'p{print;exit} /^--strategy$/{p=1}' "$SB3/cap")
    pr_seen=$(awk 'p{print;exit} /^--pr$/{p=1}' "$SB3/cap")
    delete_seen=$(awk 'p{print;exit} /^--delete$/{p=1}' "$SB3/cap")

    # Injection attempt — a hostile strategy string must be normalised to
    # squash before it ever reaches the eval'd template. No PWNED file, no
    # extra command execution.
    tracker_clear_cache
    PATH="$SB3/bin:$PATH" MYCLI_CAPTURE="$SB3/cap2" tracker_pr_merge "c/u" 9 'squash; touch PWNED' true >/dev/null
    strategy2_seen=$(awk 'p{print;exit} /^--strategy$/{p=1}' "$SB3/cap2")
    pwned=no; [ -e "$SB3/PWNED" ] && pwned=yes

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rc" "$strategy_seen" "$pr_seen" "$delete_seen" "$strategy2_seen" "$pwned"
  ) > "$SB3/result"
  IFS=$'\t' read -r c_rc c_strategy c_pr c_delete c_strategy2 c_pwned < "$SB3/result"
  assert_eq "custom → exit 0"                                   "0"      "$c_rc"
  assert_eq "custom → {strategy} substituted"                   "rebase" "$c_strategy"
  assert_eq "custom → {pr} substituted"                         "9"      "$c_pr"
  assert_eq "custom → {delete_branch} substituted"              "false"  "$c_delete"
  assert_eq "custom → hostile strategy normalised to squash"    "squash" "$c_strategy2"
  assert_eq "custom → NO shell injection from strategy (no PWNED)" "no"  "$c_pwned"
  rm -rf "$SB3"
else
  echo "SKIP: custom per-project case (no yq / python3+PyYAML)"
fi

echo "=========================================="
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then printf "Failed:%b\n" "$FAILED"; exit 1; fi
exit 0
