#!/bin/bash
# Tests for pr_base_repo (+ its interaction with review_marker_path) in
# _lib-review-markers.sh — the cross-fork approval-marker fix (me2resh/apexyard#765)
# and the scoping fix for the same-repo-fork-PR regression (me2resh/apexyard#887).
#
# pr_base_repo resolves a PR's BASE repo (the canonical marker key) by SCOPING
# its gh query to a REQUIRED <repo> arg — the repo the caller already knows
# hosts the PR — and parsing the base out of the returned PR URL. It no longer
# accepts an optional "hint" queried unscoped: #887 showed that an unscoped
# `gh pr view` can SUCCEED with the WRONG repo whenever gh's ambient default
# (which prefers the parent/upstream) doesn't match the PR's true base — e.g. a
# same-repo fork PR opened against the fork's own main. Scoping to the repo the
# caller enumerated the PR from turns "wrong repo" into a clean gh failure
# instead of a silently wrong answer.
#
# gh is mocked via a file-driven stub (no env-export subtleties): the stub
# prints the contents of $MOCKBIN/url when queried --repo-scoped to the URL's
# own base, exits non-zero when scoped to any other repo (mirroring real gh
# refusing to resolve a base-numbered PR through an unrelated repo's API path),
# and — to make the #887 regression provable — returns $MOCKBIN/wrong-url
# instead when called WITHOUT --repo at all (modelling gh's ambient default
# wrongly-but-successfully resolving to the parent). If pr_base_repo ever stops
# passing --repo, the wrong-url path fires and the assertions below catch it.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$SRC_ROOT/.claude/hooks/_lib-review-markers.sh"
# shellcheck source=/dev/null
. "$LIB"

PASS=0; FAIL=0; FAILED=""
assert_eq() { # <label> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1));
  else echo "FAIL [$1]: want [$2] got [$3]" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}$1 "; fi
}

MOCKBIN=$(mktemp -d)
cat > "$MOCKBIN/gh" <<EOF
#!/bin/bash
# mock gh (--repo-aware, #887-aware):
#   - --repo omitted            → return \$MOCKBIN/wrong-url if set (models gh's
#                                  ambient/parent-preferring default resolving
#                                  successfully to the WRONG PR), else \$url.
#                                  A fixed implementation must never hit this
#                                  branch — pr_base_repo always passes --repo.
#   - --repo == the URL's base  → success, prints \$url.
#   - --repo == anything else   → fails (gh 404, as real gh would for a PR
#                                  number that doesn't belong to that repo).
[ -s "$MOCKBIN/url" ] || exit 1
url="\$(cat "$MOCKBIN/url")"
base="\$(printf '%s' "\$url" | sed -E 's#^https?://[^/]+/(.+)/(pull|-/merge_requests)/[0-9].*#\1#')"
repo=""
scoped=0
while [ \$# -gt 0 ]; do
  case "\$1" in
    --repo) repo="\$2"; scoped=1; shift 2 ;;
    *) shift ;;
  esac
done
if [ "\$scoped" -eq 0 ]; then
  if [ -s "$MOCKBIN/wrong-url" ]; then cat "$MOCKBIN/wrong-url"; else printf '%s' "\$url"; fi
  exit 0
fi
if [ "\$repo" != "\$base" ]; then exit 1; fi
printf '%s' "\$url"
EOF
chmod +x "$MOCKBIN/gh"
export PATH="$MOCKBIN:$PATH"
seturl() { printf '%s' "$1" > "$MOCKBIN/url"; }
setwrongurl() { printf '%s' "$1" > "$MOCKBIN/wrong-url"; }
clearwrongurl() { rm -f "$MOCKBIN/wrong-url"; }

# 1. Caller passes the repo it's confident hosts the PR (the base) → the
#    scoped query confirms it and parses the canonical form from the URL.
seturl 'https://github.com/me2resh/apexyard/pull/762'
assert_eq "caller-known base repo → confirmed via scoped query" "me2resh/apexyard" \
  "$(pr_base_repo 762 me2resh/apexyard)"

# 2. same-repo → base == head (UNCHANGED — the provable no-op from #765).
seturl 'https://github.com/me2resh/apexyard/pull/5'
assert_eq "same-repo → unchanged" "me2resh/apexyard" \
  "$(pr_base_repo 5 me2resh/apexyard)"

# 3. GitLab MR URL with a nested group → group/subgroup/project, confirmed via
#    the correct repo (not a head/fork guess).
seturl 'https://gitlab.com/grp/sub/proj/-/merge_requests/12'
assert_eq "glab nested MR → base confirmed via scoped query" "grp/sub/proj" \
  "$(pr_base_repo 12 grp/sub/proj)"

# 4. gh fails (no URL queued) → fall back to the passed-in repo.
seturl ''
assert_eq "gh fail → repo fallback" "me2resh/apexyard" \
  "$(pr_base_repo 999 me2resh/apexyard)"

# 5. unparseable URL → repo fallback (sed leaves it unchanged → base==url →
#    the mock's own base/repo comparison fails closed → repo fallback fires).
seturl 'https://github.com/not-a-pr-url'
assert_eq "bad URL → repo fallback" "owner/repo" \
  "$(pr_base_repo 1 owner/repo)"

# 6. no pr number → repo (guard, no gh call).
assert_eq "no pr → repo" "owner/repo" "$(pr_base_repo '' owner/repo)"

# 7. no repo passed (pr given) → required-arg guard fires; empty stdout, no
#    unscoped gh call is attempted as a substitute.
seturl 'https://github.com/me2resh/apexyard/pull/5'
assert_eq "missing repo w/ pr → empty (error path, not a silent guess)" "" \
  "$(pr_base_repo 5 2>/dev/null)"

# 8. wrong repo passed (e.g. the head/fork of a genuine cross-fork PR) → the
#    scoped query fails closed and returns the passed repo itself — NOT an
#    ambient guess at some unrelated repo. Documents the contract: callers
#    must pass the repo they're confident hosts the PR; passing the wrong one
#    degrades safely rather than silently returning wrong data.
seturl 'https://github.com/me2resh/apexyard/pull/762'
assert_eq "wrong (head/fork) repo passed → fails closed, returns itself" \
  "AbdElrahmaN31/apexyard" "$(pr_base_repo 762 AbdElrahmaN31/apexyard)"

# 9. self-hosted GitHub Enterprise host → base still parsed (host-agnostic),
#    confirmed via the correct repo.
seturl 'https://github.example.com/team/svc/pull/8'
assert_eq "GHE host → base confirmed via scoped query" "team/svc" \
  "$(pr_base_repo 8 team/svc)"

# 10. THE #887 REGRESSION GUARD: a same-repo fork PR, where an unscoped
#     ambient gh call would succeed but return the WRONG (parent) repo. The
#     caller passes the repo it actually knows hosts the PR (its own fork);
#     the fixed implementation must return THAT, never the ambient "wrong"
#     answer the ungoverned mock branch would produce.
seturl 'https://github.com/atlas-apex/apexyard/pull/900'
setwrongurl 'https://github.com/me2resh/apexyard/pull/900'
assert_eq "#887 same-repo-fork-PR: scoped call ignores ambient parent-preferring default" \
  "atlas-apex/apexyard" "$(pr_base_repo 900 atlas-apex/apexyard)"
clearwrongurl

# --- discriminating: the marker PATH keyed via pr_base_repo ---
MH=$(mktemp -d)
# cross-fork → marker keyed on BASE (the #765 fix), repo passed is the base.
seturl 'https://github.com/me2resh/apexyard/pull/762'
CF=$(review_marker_path "$(pr_base_repo 762 me2resh/apexyard)" 762 rex "$MH")
assert_eq "cross-fork marker keyed on BASE" \
  "$MH/.claude/session/reviews/me2resh__apexyard__762-rex.approved" "$CF"
# same-repo → marker path UNCHANGED from the pre-#765 (base==head) behaviour.
seturl 'https://github.com/me2resh/apexyard/pull/5'
SR=$(review_marker_path "$(pr_base_repo 5 me2resh/apexyard)" 5 rex "$MH")
assert_eq "same-repo marker path unchanged" \
  "$MH/.claude/session/reviews/me2resh__apexyard__5-rex.approved" "$SR"

rm -rf "$MOCKBIN" "$MH"
echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS  FAIL: 0"; exit 0
else
  echo "PASS: $PASS  FAIL: $FAIL  (failed: $FAILED)"; exit 1
fi
