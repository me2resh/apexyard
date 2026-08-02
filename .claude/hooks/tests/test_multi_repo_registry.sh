#!/bin/bash
# Tests for the multi-repo registry project (me2resh/apexyard#1123).
#
# The registry (apexyard.projects.yaml) used to model a project as EXACTLY
# ONE repo (singular `repo: owner/name`). A product split across several
# repos (backend + gateway + workers, say) had no first-class way to
# register as ONE project, and the dangerous consequence was that
# block-private-refs-in-public-repos.sh built its scrub list by reading one
# `repo:` per project — so a project registered under its "primary" repo
# left every OTHER repo's slug unscrubbed, a real disclosure gap.
#
# This file proves:
#   1. [SECURITY, the AC #1123 prioritises] A multi-repo project's
#      NON-primary repo slugs are scrubbed by block-private-refs on a
#      public-repo write — not just the primary/first one.
#   2. Singular `repo:` behaves byte-identically to before this change
#      (backwards compatibility).
#   3. A one-element `repos:` list is equivalent to singular `repo:`.
#   4. Tracker resolution (_tracker_project_value, via tracker_kind) finds
#      a multi-repo project's per-project override regardless of WHICH of
#      its repos is passed — defaults implicitly to "any repo resolves the
#      same project", satisfying "accepts explicit --repo for the others".
#   5. _lib-multi-repo-trace.sh's mrt_resolve_target (tier 4) matches a
#      NON-primary repo slug, and mrt_primary_repo_for / mrt_repos_for
#      resolve correctly for both singular and plural schemas.
#
# Exit 0 = all pass. Exit 1 on first failure.

set -u

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LEAK_HOOK="$HOOK_DIR/block-private-refs-in-public-repos.sh"
TRACKER_LIB="$HOOK_DIR/_lib-tracker.sh"
CONFIG_LIB="$HOOK_DIR/_lib-read-config.sh"
PORTFOLIO_LIB="$HOOK_DIR/_lib-portfolio-paths.sh"
OPSROOT_LIB="$HOOK_DIR/_lib-ops-root.sh"
TRACE_LIB="$HOOK_DIR/_lib-multi-repo-trace.sh"

for f in "$LEAK_HOOK" "$TRACKER_LIB" "$CONFIG_LIB" "$PORTFOLIO_LIB" "$TRACE_LIB"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file not found: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

pass_case() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "   $2" >&2; FAIL=$((FAIL + 1)); FAILED_CASES="${FAILED_CASES}${1}; "; }

# =============================================================================
# Part 1 — leak-scrub coverage (block-private-refs-in-public-repos.sh)
# =============================================================================

LEAK_TMPDIR=$(mktemp -d -t multi-repo-leak.XXXXXX)
trap 'rm -rf "$LEAK_TMPDIR"' EXIT

mkdir -p "$LEAK_TMPDIR/fork/subdir"
cat > "$LEAK_TMPDIR/fork/onboarding.yaml" <<'YAML'
company: test
YAML
cat > "$LEAK_TMPDIR/fork/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: some-platform
    repos:
      - acme/some-platform-backend
      - acme/some-platform-gateway
      - acme/some-platform-worker
    primary: acme/some-platform-backend
    workspace: workspace/some-platform
    status: active
  - name: solo-app
    repo: acme/solo-app
    workspace: workspace/solo-app
    status: active
  - name: one-elem
    repos:
      - acme/one-elem-repo
    workspace: workspace/one-elem
    status: active
  - name: meridian-svc
    repos:  # payments platform services
      - corp/nightshade-api
    workspace: workspace/meridian-svc
    status: active
  - name: both-forms
    repo: acme/both-forms-primary
    repos:
      - acme/both-forms-extra
    workspace: workspace/both-forms
    status: active
  - name: other-key-comment
    tags:  # customer facing, high priority
      - should-not-leak-as-repo
    repo: acme/other-key-comment-repo
    workspace: workspace/other-key-comment
    status: active
  - name: hyphen-key-proj
    repos:
      - acme/hyphen-key-proj-svc
    custom-flag:
      - should-not-leak-via-hyphenated-key
    workspace: workspace/hyphen-key-proj
    status: active
YAML

make_payload() {
  local cmd="$1"
  jq -n --arg c "$cmd" '{tool_input: {command: $c}}'
}

run_leak_case() {
  local name="$1" expected_exit="$2" expected_stderr_substr="$3" cmd="$4"
  local workdir="${5:-$LEAK_TMPDIR/fork/subdir}"
  local stderr_file
  stderr_file=$(mktemp)
  ( cd "$workdir" && echo "$(make_payload "$cmd")" | "$LEAK_HOOK" ) 2> "$stderr_file"
  local actual_exit=$? stderr_content
  stderr_content=$(cat "$stderr_file")
  rm -f "$stderr_file"

  local ok=1
  [ "$actual_exit" != "$expected_exit" ] && ok=0
  if [ -n "$expected_stderr_substr" ] && ! echo "$stderr_content" | grep -qF -- "$expected_stderr_substr"; then
    ok=0
  fi

  if [ "$ok" = 1 ]; then
    pass_case "$name"
  else
    fail_case "$name" "expected exit=$expected_exit (got $actual_exit); expected stderr to contain: [$expected_stderr_substr]; stderr was: $stderr_content"
  fi
}

# 1a. THE security AC — a NON-primary repo slug (gateway, not backend) must
#     be scrubbed. Before #1123 this leaked (exit 0, nothing scanned) because
#     only the first `repo:` line per project was ever read.
run_leak_case "multi-repo: NON-primary repo slug (gateway) is scrubbed" \
  2 "project repo: acme/some-platform-gateway" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces on acme/some-platform-gateway too'"

# 1b. A THIRD repo (worker) — not just the second — confirming the fix
#     covers the WHOLE list, not merely "first two".
run_leak_case "multi-repo: third repo slug (worker) is scrubbed" \
  2 "project repo: acme/some-platform-worker" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'seen in acme/some-platform-worker logs'"

# 1c. The PRIMARY repo itself must still be scrubbed too (not a regression
#     introduced by generalising to a list).
run_leak_case "multi-repo: primary repo slug (backend) is still scrubbed" \
  2 "project repo: acme/some-platform-backend" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'crash in acme/some-platform-backend'"

# 1d. The project NAME (shared across all its repos) still scrubs too.
run_leak_case "multi-repo: project name (some-platform) is scrubbed" \
  2 "project name: some-platform" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'found during some-platform rebuild'"

# 1e. Clean body with none of the multi-repo project's slugs → no false positive.
run_leak_case "multi-repo: clean body naming none of the repos → pass" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'a generic framework issue, no project named'"

# 1f. THE LEAK REGRESSION this fix closes — a `repos:` block header with a
#     trailing inline comment (`repos:  # payments platform services`) is
#     valid YAML (yq parses it fine), but the awk-only leak-scrub parser
#     used to require a BARE `repos:` line (nothing else on it) to arm its
#     `current_list` state tracker. A commented header fell through to the
#     generic `key:` rule and disarmed tracking before the first `- slug`
#     line, so every repo under it reached a public write UNSCRUBBED —
#     exactly the disclosure gap this whole file exists to close. This
#     case MUST leak (exit 0) against the pre-fix parser and MUST block
#     (exit 2) against the fix — verified both directions manually (see
#     the fix PR's report), not just asserted here.
run_leak_case "leak regression: repos: block header WITH a trailing comment still scrubs its slug" \
  2 "project repo: corp/nightshade-api" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in corp/nightshade-api, no other identifier mentioned'"

# 1g. A project declaring BOTH singular `repo:` and plural `repos:` scrubs
#     the UNION of both — the leak-scrub parser accumulates every REPO=
#     emitted anywhere in the file into one running scrub list, it never
#     resets per-project. Pre-existing behaviour, unaffected by the
#     comment-tolerance fix; pinned here so a future change doesn't
#     silently narrow it.
run_leak_case "multi-repo: project with BOTH repo: and repos: scrubs the repos: entry too (union)" \
  2 "project repo: acme/both-forms-extra" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme/both-forms-extra'"

# 1h/1i. Over-arm safety — the fix's new `(#.*)?` comment tolerance must
#     apply ONLY to a `repos:` header, never to some OTHER key (`tags:`)
#     that happens to carry a trailing comment too. If the regex were
#     written too loosely, `tags:  # customer facing` would arm the same
#     tracker and leak `should-not-leak-as-repo` as though it were a repo
#     slug. 1h proves that does NOT happen; 1i is the companion control
#     proving the project's real `repo:` field still scrubs normally (so
#     1h's clean result means "not a repo", not "parsing broke").
run_leak_case "over-arm safety: tags: header with a trailing comment is NOT treated as repos:" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'mentions should-not-leak-as-repo, nothing else'"

run_leak_case "over-arm safety companion: other-key-comment project's repo: still scrubs" \
  2 "project repo: acme/other-key-comment-repo" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme/other-key-comment-repo'"

# 1j. Hardening nit (Rex, non-blocking, fails SAFE — over-capture not a leak)
#     — the generic `key:` disarm rule only matched keys made of
#     [a-zA-Z0-9_], so a HYPHENATED custom key (`custom-flag:`) right
#     after a `repos:` block didn't disarm `current_list`, and the next
#     `- item` under the unrelated hyphenated key got misread as a repo.
#     Widened the character class to `[a-zA-Z0-9_-]` so hyphenated keys
#     disarm correctly too.
run_leak_case "hardening: hyphenated custom key after repos: disarms tracking (no over-capture)" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'mentions should-not-leak-via-hyphenated-key, nothing else'"

run_leak_case "hardening companion: hyphen-key-proj's real repos: entry still scrubs" \
  2 "project repo: acme/hyphen-key-proj-svc" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme/hyphen-key-proj-svc'"

# 2. Backwards compatibility — singular `repo:` project (solo-app) behaves
#    exactly as it did before this change: bare slug leak still blocks.
run_leak_case "backwards-compat: singular repo: project still scrubs its slug" \
  2 "project repo: acme/solo-app" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme/solo-app'"

# 3. Equivalence — a ONE-ELEMENT `repos:` list scrubs identically to a
#    singular `repo:` project (case 2 above). Same assertion shape, proving
#    the two schemas are byte-equivalent in the scrub list they produce.
run_leak_case "equivalence: one-element repos: list scrubs its sole slug" \
  2 "project repo: acme/one-elem-repo" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme/one-elem-repo'"

# 4. Explicit backward-compat proof — an ALL-singular-`repo:` registry (the
#    shape every existing adopter has today; no `repos:` line anywhere) is
#    exercised on a FRESH, separate fixture so nothing above it (which does
#    use `repos:`) can mask a regression. The comment-tolerance fix only
#    changes the awk arm that fires on a line starting with `repos:` — a
#    registry with no such line never reaches that arm at all, so a clean
#    pass here is the strongest available proof the fix does not disturb
#    the common case.
SINGULAR_TMPDIR=$(mktemp -d -t multi-repo-singular.XXXXXX)
mkdir -p "$SINGULAR_TMPDIR/subdir"
cat > "$SINGULAR_TMPDIR/onboarding.yaml" <<'YAML'
company: test
YAML
cat > "$SINGULAR_TMPDIR/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: alpha-app
    repo: acme/alpha-app
    workspace: workspace/alpha-app
    status: active
  - name: beta-service
    repo: acme/beta-service
    workspace: workspace/beta-service
    status: active
YAML

run_leak_case "backward-compat: all-singular repo: registry — first project's slug scrubs" \
  2 "project repo: acme/alpha-app" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme/alpha-app'" \
  "$SINGULAR_TMPDIR/subdir"

run_leak_case "backward-compat: all-singular repo: registry — second project's slug scrubs" \
  2 "project repo: acme/beta-service" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme/beta-service'" \
  "$SINGULAR_TMPDIR/subdir"

run_leak_case "backward-compat: all-singular repo: registry — clean body → pass" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'a generic framework issue, no project named'" \
  "$SINGULAR_TMPDIR/subdir"

rm -rf "$SINGULAR_TMPDIR"

# =============================================================================
# Part 2 — tracker resolution defaults to primary, accepts --repo for others
# =============================================================================

TRACKER_TMPDIR=$(mktemp -d -t multi-repo-tracker.XXXXXX)

mkdir -p "$TRACKER_TMPDIR/.claude/hooks"
touch "$TRACKER_TMPDIR/onboarding.yaml"
cp "$TRACKER_LIB"   "$TRACKER_TMPDIR/.claude/hooks/_lib-tracker.sh"
cp "$CONFIG_LIB"    "$TRACKER_TMPDIR/.claude/hooks/_lib-read-config.sh"
cp "$PORTFOLIO_LIB" "$TRACKER_TMPDIR/.claude/hooks/_lib-portfolio-paths.sh"
[ -f "$OPSROOT_LIB" ] && cp "$OPSROOT_LIB" "$TRACKER_TMPDIR/.claude/hooks/_lib-ops-root.sh"

cat > "$TRACKER_TMPDIR/.claude/project-config.defaults.json" <<'JSON'
{ "tracker": { "kind": "gh", "id_pattern": "^(#[0-9]+|GH-[0-9]+)$" } }
JSON

cat > "$TRACKER_TMPDIR/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: some-platform
    repos:
      - acme/some-platform-backend
      - acme/some-platform-gateway
    primary: acme/some-platform-backend
    tracker:
      kind: jira
      id_pattern: "^PLAT-[0-9]+$"
  - name: single-proj
    repo: acme/single-proj
YAML

HAVE_YAML=no
if command -v yq >/dev/null 2>&1; then HAVE_YAML=yes; fi

if [ "$HAVE_YAML" = yes ]; then
  (
    cd "$TRACKER_TMPDIR" || exit 1
    unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$TRACKER_TMPDIR/.claude/hooks/_lib-tracker.sh"

    tracker_clear_cache
    got=$(tracker_kind "acme/some-platform-backend")
    [ "$got" = "jira" ] && echo "OK:primary" || echo "MISMATCH:primary:$got"

    tracker_clear_cache
    got=$(tracker_kind "acme/some-platform-gateway")
    [ "$got" = "jira" ] && echo "OK:non-primary" || echo "MISMATCH:non-primary:$got"

    tracker_clear_cache
    got=$(tracker_id_pattern "acme/some-platform-gateway")
    [ "$got" = "^PLAT-[0-9]+\$" ] && echo "OK:id-pattern-non-primary" || echo "MISMATCH:id-pattern-non-primary:$got"

    tracker_clear_cache
    got=$(tracker_kind "acme/single-proj")
    [ "$got" = "gh" ] && echo "OK:singular-fallback" || echo "MISMATCH:singular-fallback:$got"
  ) > "$TRACKER_TMPDIR/results.txt" 2>/dev/null

  if grep -q "^OK:primary$" "$TRACKER_TMPDIR/results.txt"; then
    pass_case "tracker_kind <multi-repo primary> → per-project override (jira)"
  else
    fail_case "tracker_kind <multi-repo primary> → per-project override (jira)" "$(grep MISMATCH:primary "$TRACKER_TMPDIR/results.txt")"
  fi

  if grep -q "^OK:non-primary$" "$TRACKER_TMPDIR/results.txt"; then
    pass_case "tracker_kind <multi-repo NON-primary> → SAME per-project override (jira) — the #1123 AC"
  else
    fail_case "tracker_kind <multi-repo NON-primary> → SAME per-project override (jira) — the #1123 AC" "$(grep MISMATCH:non-primary "$TRACKER_TMPDIR/results.txt")"
  fi

  if grep -q "^OK:id-pattern-non-primary$" "$TRACKER_TMPDIR/results.txt"; then
    pass_case "tracker_id_pattern <multi-repo NON-primary> → per-project override"
  else
    fail_case "tracker_id_pattern <multi-repo NON-primary> → per-project override" "$(grep MISMATCH:id-pattern-non-primary "$TRACKER_TMPDIR/results.txt")"
  fi

  if grep -q "^OK:singular-fallback$" "$TRACKER_TMPDIR/results.txt"; then
    pass_case "tracker_kind <singular repo:, no override> → global default (unaffected)"
  else
    fail_case "tracker_kind <singular repo:, no override> → global default (unaffected)" "$(grep MISMATCH:singular-fallback "$TRACKER_TMPDIR/results.txt")"
  fi
else
  echo "SKIP: tracker per-project multi-repo cases (no yq installed)"
fi

rm -rf "$TRACKER_TMPDIR"

# =============================================================================
# Part 3 — _lib-multi-repo-trace.sh: tier-4 match on a non-primary repo, and
# the primary/repos resolver helpers.
# =============================================================================

TRACE_TMPDIR=$(mktemp -d -t multi-repo-trace.XXXXXX)
mkdir -p "$TRACE_TMPDIR/.claude/hooks"
touch "$TRACE_TMPDIR/onboarding.yaml"
cp "$CONFIG_LIB"    "$TRACE_TMPDIR/.claude/hooks/_lib-read-config.sh"
cp "$PORTFOLIO_LIB" "$TRACE_TMPDIR/.claude/hooks/_lib-portfolio-paths.sh"
cp "$TRACE_LIB"     "$TRACE_TMPDIR/.claude/hooks/_lib-multi-repo-trace.sh"
[ -f "$OPSROOT_LIB" ] && cp "$OPSROOT_LIB" "$TRACE_TMPDIR/.claude/hooks/_lib-ops-root.sh"

cat > "$TRACE_TMPDIR/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: some-platform
    repos:
      - acme/some-platform-backend
      - acme/some-platform-gateway
    primary: acme/some-platform-backend
    workspace: workspace/some-platform
  - name: single-proj
    repo: acme/single-proj
    workspace: workspace/single-proj
YAML

(
  cd "$TRACE_TMPDIR" || exit 1
  unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$TRACE_TMPDIR/.claude/hooks/_lib-read-config.sh"
  # shellcheck source=/dev/null
  . "$TRACE_TMPDIR/.claude/hooks/_lib-portfolio-paths.sh"
  # shellcheck source=/dev/null
  . "$TRACE_TMPDIR/.claude/hooks/_lib-multi-repo-trace.sh"

  echo "resolve_nonprimary=$(mrt_resolve_target 'github.com/acme/some-platform-gateway')"
  echo "resolve_primary=$(mrt_resolve_target 'github.com/acme/some-platform-backend')"
  echo "primary_repo=$(mrt_primary_repo_for 'some-platform')"
  echo "repos_count=$(mrt_repos_for 'some-platform' | wc -l | tr -d ' ')"
  echo "singular_primary=$(mrt_primary_repo_for 'single-proj')"
  echo "singular_repos_count=$(mrt_repos_for 'single-proj' | wc -l | tr -d ' ')"
) > "$TRACE_TMPDIR/results.txt" 2>/dev/null

if grep -q "^resolve_nonprimary=some-platform$" "$TRACE_TMPDIR/results.txt"; then
  pass_case "mrt_resolve_target: tier-4 matches a NON-primary repo slug"
else
  fail_case "mrt_resolve_target: tier-4 matches a NON-primary repo slug" "$(cat "$TRACE_TMPDIR/results.txt")"
fi

if grep -q "^resolve_primary=some-platform$" "$TRACE_TMPDIR/results.txt"; then
  pass_case "mrt_resolve_target: tier-4 still matches the primary repo slug"
else
  fail_case "mrt_resolve_target: tier-4 still matches the primary repo slug" "$(cat "$TRACE_TMPDIR/results.txt")"
fi

if grep -q "^primary_repo=acme/some-platform-backend$" "$TRACE_TMPDIR/results.txt"; then
  pass_case "mrt_primary_repo_for: resolves the explicit primary: field"
else
  fail_case "mrt_primary_repo_for: resolves the explicit primary: field" "$(cat "$TRACE_TMPDIR/results.txt")"
fi

if grep -q "^repos_count=2$" "$TRACE_TMPDIR/results.txt"; then
  pass_case "mrt_repos_for: enumerates all repos of a multi-repo project"
else
  fail_case "mrt_repos_for: enumerates all repos of a multi-repo project" "$(cat "$TRACE_TMPDIR/results.txt")"
fi

if grep -q "^singular_primary=acme/single-proj$" "$TRACE_TMPDIR/results.txt"; then
  pass_case "mrt_primary_repo_for: singular repo: project unaffected"
else
  fail_case "mrt_primary_repo_for: singular repo: project unaffected" "$(cat "$TRACE_TMPDIR/results.txt")"
fi

if grep -q "^singular_repos_count=1$" "$TRACE_TMPDIR/results.txt"; then
  pass_case "mrt_repos_for: singular repo: project normalises to a one-element list"
else
  fail_case "mrt_repos_for: singular repo: project normalises to a one-element list" "$(cat "$TRACE_TMPDIR/results.txt")"
fi

rm -rf "$TRACE_TMPDIR"

# =============================================================================
# Part 3b — _lib-multi-repo-trace.sh awk fallback: same comment-header defect
# shape as Part 1's leak-hook case, lower severity (resolution, not
# disclosure) and only ever reachable when yq is ABSENT (_mrt_parse_registry
# prefers yq when installed). Force the fallback by stripping every
# yq-bearing directory out of PATH for this subshell only, so the case is
# meaningful on a machine that happens to have yq installed too. Degrades to
# a SKIP (not a failure) if that stripping can't hide yq on this machine.
# =============================================================================

TRACE_NOYQ_TMPDIR=$(mktemp -d -t multi-repo-trace-noyq.XXXXXX)
mkdir -p "$TRACE_NOYQ_TMPDIR/.claude/hooks"
touch "$TRACE_NOYQ_TMPDIR/onboarding.yaml"
cp "$CONFIG_LIB"    "$TRACE_NOYQ_TMPDIR/.claude/hooks/_lib-read-config.sh"
cp "$PORTFOLIO_LIB" "$TRACE_NOYQ_TMPDIR/.claude/hooks/_lib-portfolio-paths.sh"
cp "$TRACE_LIB"     "$TRACE_NOYQ_TMPDIR/.claude/hooks/_lib-multi-repo-trace.sh"
[ -f "$OPSROOT_LIB" ] && cp "$OPSROOT_LIB" "$TRACE_NOYQ_TMPDIR/.claude/hooks/_lib-ops-root.sh"

cat > "$TRACE_NOYQ_TMPDIR/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: meridian-svc
    repos:  # payments platform services
      - corp/nightshade-api
    workspace: workspace/meridian-svc
YAML

# Build a "no-yq" bin dir: symlink every executable currently on PATH EXCEPT
# `yq` into a temp dir, then point PATH at just that dir so `command -v yq`
# fails inside the sourced lib (forcing its awk fallback) WITHOUT removing any
# other tool.
#
# The naive approach — dropping every PATH directory that contains yq — silently
# wipes `awk` too on systems where yq and awk share a directory (Ubuntu CI's
# /usr/bin holds both). That left the awk fallback with no `awk` to run, so it
# produced nothing and this exact case failed on CI while passing on macOS
# (where brew's yq lives in a different dir than /usr/bin/awk). Symlinking every
# binary except yq keeps awk (and grep/sed/etc.) reachable regardless of layout.
NOYQ_BIN=$(mktemp -d)
OLD_IFS="$IFS"
IFS=':'
for d in $PATH; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  for exe in "$d"/*; do
    { [ -x "$exe" ] && [ ! -d "$exe" ]; } || continue
    base=${exe##*/}
    [ "$base" = yq ] && continue
    [ -e "$NOYQ_BIN/$base" ] && continue   # first on PATH wins (preserve precedence)
    ln -s "$exe" "$NOYQ_BIN/$base" 2>/dev/null || true
  done
done
IFS="$OLD_IFS"

(
  cd "$TRACE_NOYQ_TMPDIR" || exit 1
  unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true
  PATH="$NOYQ_BIN"
  export PATH
  if command -v yq >/dev/null 2>&1; then
    echo "SKIP:could-not-hide-yq"
    exit 0
  fi
  # shellcheck source=/dev/null
  . "$TRACE_NOYQ_TMPDIR/.claude/hooks/_lib-read-config.sh"
  # shellcheck source=/dev/null
  . "$TRACE_NOYQ_TMPDIR/.claude/hooks/_lib-portfolio-paths.sh"
  # shellcheck source=/dev/null
  . "$TRACE_NOYQ_TMPDIR/.claude/hooks/_lib-multi-repo-trace.sh"
  echo "resolve_commented=$(mrt_resolve_target 'github.com/corp/nightshade-api')"
) > "$TRACE_NOYQ_TMPDIR/results.txt" 2>/dev/null

if grep -q "^SKIP:could-not-hide-yq$" "$TRACE_NOYQ_TMPDIR/results.txt"; then
  echo "SKIP: trace-lib awk-fallback comment-header case (could not hide yq on this machine)"
elif grep -q "^resolve_commented=meridian-svc$" "$TRACE_NOYQ_TMPDIR/results.txt"; then
  pass_case "trace-lib awk fallback: repos: block header WITH a trailing comment resolves (leak-fix parity)"
else
  fail_case "trace-lib awk fallback: repos: block header WITH a trailing comment resolves (leak-fix parity)" "$(cat "$TRACE_NOYQ_TMPDIR/results.txt")"
fi

rm -rf "$TRACE_NOYQ_TMPDIR" "$NOYQ_BIN"

# =============================================================================
# Result
# =============================================================================

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases: $FAILED_CASES" >&2
  exit 1
fi
exit 0
