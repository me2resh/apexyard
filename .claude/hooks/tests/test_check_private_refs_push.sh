#!/bin/bash
# Push-time private-reference leak scan (me2resh/apexyard#1528 / AgDR-0220).
#
# Covers:
#   - private origin (stubbed): commit allowed; push to that origin allowed
#   - same commits to a public-class remote → blocked (framework list,
#     upstream remote, public:true registry entry, stubbed-public slug)
#   - cherry-pick onto a new branch → still blocked on public push
#   - new remote branch with no remote-tracking refs → scanned
#   - visibility lookup fail / timeout / non-GitHub URL → scanned
#   - clean commits → push allowed; delete refs → no scan
#   - multiple refs in one push; commit-message leak; public:true exempt
#   - protected-branch guard still fires when origin is private
#   - visibility cache: fresh private → no lookup; stale → lookup again
#   - destination refs (ls-remote of push URL): history already on the dest
#     is excluded for a new-branch push; a new leak still blocks; ls-remote
#     failure fails closed; a missing local sha is ignored; B1/B2 still block
#   - clean-scan records: only full-history-clean tips are recorded (Rex B-1);
#     a mirror push that used dest exclusions must not let a private tip
#     through to a public remote; a no-exclusion push still records and
#     reuses; a dest-exclusion push writes no record line for that tip
#
# Remotes use GitHub-form URLs. A local bare repo is the real transport via
# `url.<bare>.insteadOf`. Visibility is stubbed with
# APEXYARD_LEAK_VISIBILITY_CMD (test-only; see _lib-leak-remote-visibility.sh).
# Destination ls-remote uses the real local bare path ($2); failure is stubbed
# with APEXYARD_LEAK_LS_REMOTE_CMD when needed. No network. No SKIP lines.
#
set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
STAGED_SRC="$ROOT/.claude/hooks/check-private-refs-staged.sh"
PUSH_SRC="$ROOT/.claude/hooks/check-private-refs-push.sh"
MATCH_SRC="$ROOT/.claude/hooks/_lib-private-refs-match.sh"
VIS_SRC="$ROOT/.claude/hooks/_lib-leak-remote-visibility.sh"
PARSER_SRC="$ROOT/.claude/hooks/_lib-registry-parser.sh"
PRE_COMMIT_SRC="$ROOT/.githooks/pre-commit"
PRE_PUSH_SRC="$ROOT/.githooks/pre-push"
PROTECTED_SRC="$ROOT/.claude/hooks/_lib-protected-branches.sh"
READ_CONFIG_SRC="$ROOT/.claude/hooks/_lib-read-config.sh"
OPS_ROOT_SRC="$ROOT/.claude/hooks/_lib-ops-root.sh"

PASS=0
FAIL=0
pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s: %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

PRIVATE_ORIGIN_SLUG='adopter/private-ops'
PUBLIC_FRAMEWORK_SLUG='me2resh/apexyard'
PUBLIC_REG_SLUG='acme/marketing-site'
STUB_PUBLIC_SLUG='other-org/looks-private'
UPSTREAM_SLUG='acme-framework/framework'

REGISTRY_YAML='projects:
  - name: amber-lantern
    repo: acme/amber-lantern
    workspace: workspace/amber-lantern
  - name: marketing-site
    repo: acme/marketing-site
    workspace: workspace/marketing-site
    public: true
'

# ---------------------------------------------------------------------------
# Visibility stub — prints true|false|fail based on a control file.
# ---------------------------------------------------------------------------
write_vis_stub() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/bin/bash
# TEST ONLY — APEXYARD_LEAK_VISIBILITY_CMD stub for #1528 tests.
set -u
slug=$1
ctrl_dir=${APEXYARD_LEAK_VIS_STUB_DIR:-}
if [ -z "$ctrl_dir" ] || [ ! -d "$ctrl_dir" ]; then
  echo "stub misconfigured" >&2
  exit 1
fi
printf '%s\n' "$slug" >> "$ctrl_dir/lookups.log"
mode_file="$ctrl_dir/mode"
mode=fail
if [ -f "$mode_file" ]; then
  mode=$(cat "$mode_file")
fi
case_file="$ctrl_dir/by-slug/$(printf '%s' "$slug" | tr '/' '_')"
if [ -f "$case_file" ]; then
  mode=$(cat "$case_file")
fi
case "$mode" in
  true) printf 'true\n'; exit 0 ;;
  false) printf 'false\n'; exit 0 ;;
  timeout)
    # exec: the timeout kill must hit the sleeping process itself, not a
    # parent shell that leaves the sleep holding the output pipe.
    exec sleep 30
    ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$path"
}

install_leak_hooks() {
  local work="$1"
  mkdir -p "$work/.claude/hooks" "$work/.githooks" "$work/bin" "$work/.claude"
  cp "$STAGED_SRC" "$work/.claude/hooks/check-private-refs-staged.sh"
  cp "$PUSH_SRC" "$work/.claude/hooks/check-private-refs-push.sh"
  cp "$MATCH_SRC" "$work/.claude/hooks/_lib-private-refs-match.sh"
  cp "$VIS_SRC" "$work/.claude/hooks/_lib-leak-remote-visibility.sh"
  cp "$PARSER_SRC" "$work/.claude/hooks/_lib-registry-parser.sh"
  cp "$PROTECTED_SRC" "$work/.claude/hooks/_lib-protected-branches.sh"
  cp "$READ_CONFIG_SRC" "$work/.claude/hooks/_lib-read-config.sh"
  [ -f "$OPS_ROOT_SRC" ] && cp "$OPS_ROOT_SRC" "$work/.claude/hooks/_lib-ops-root.sh"
  cp "$PRE_COMMIT_SRC" "$work/.githooks/pre-commit"
  cp "$PRE_PUSH_SRC" "$work/.githooks/pre-push"
  chmod +x "$work/.claude/hooks/check-private-refs-staged.sh" \
    "$work/.claude/hooks/check-private-refs-push.sh" \
    "$work/.githooks/pre-commit" "$work/.githooks/pre-push"
  printf '#!/bin/bash\nexit 0\n' > "$work/bin/run-pre-push-checks.sh"
  chmod +x "$work/bin/run-pre-push-checks.sh"
  printf '%s\n' '{"leak_protection":{"public_framework_repos":["me2resh/apexyard"]}}' \
    > "$work/.claude/project-config.defaults.json"
  printf '%s\n' "$REGISTRY_YAML" > "$work/apexyard.projects.yaml"
}

# Build work + bare remote. Origin URL is a GitHub-form slug; transport is local.
# Args: dir github_slug [vis_mode]
build_pair() {
  local dir="$1" slug="$2" vis_mode="${3:-fail}"
  local work bare stub_dir stub
  work="$dir/work"
  bare="$dir/remote.git"
  stub_dir="$dir/vis-stub"
  mkdir -p "$work" "$stub_dir/by-slug"
  printf '%s\n' "$vis_mode" > "$stub_dir/mode"
  : > "$stub_dir/lookups.log"
  stub="$stub_dir/vis.sh"
  write_vis_stub "$stub"

  install_leak_hooks "$work"
  (
    cd "$work" || exit 1
    git init -q -b main
    git config user.email test@example.com
    git config user.name Test
    git config core.hooksPath .githooks
    git add apexyard.projects.yaml .claude/project-config.defaults.json
    # Bypass hooks for the seed commit (registry itself names private projects).
    git commit -q -m 'chore: seed' --no-verify
  )
  git clone -q --bare "$work" "$bare"
  git -C "$bare" config receive.denyDeleteCurrent ignore

  git -C "$work" remote add origin "https://github.com/${slug}.git"
  git -C "$work" config "url.${bare}.insteadOf" "https://github.com/${slug}.git"
  git -C "$work" fetch -q origin
  git -C "$work" branch -q --set-upstream-to=origin/main main

  # Export stub for child hook processes.
  printf '%s\n' "$stub_dir" > "$dir/stub_dir_path"
  printf '%s\n' "$stub" > "$dir/stub_path"
}

with_vis_env() {
  # Usage: with_vis_env DIR command...
  local dir="$1"
  shift
  local stub stub_dir
  stub_dir=$(cat "$dir/stub_dir_path")
  stub=$(cat "$dir/stub_path")
  env APEXYARD_LEAK_VISIBILITY_CMD="$stub" \
    APEXYARD_LEAK_VIS_STUB_DIR="$stub_dir" \
    "$@"
}

lookup_count() {
  local dir="$1"
  local stub_dir
  stub_dir=$(cat "$dir/stub_dir_path")
  if [ -f "$stub_dir/lookups.log" ]; then
    wc -l < "$stub_dir/lookups.log" | tr -d ' '
  else
    printf '0'
  fi
}

reset_lookups() {
  local dir="$1"
  local stub_dir
  stub_dir=$(cat "$dir/stub_dir_path")
  : > "$stub_dir/lookups.log"
}

# True when tip is present in any clean-scan record under the work repo.
tip_in_clean_record() {
  local work="$1" tip="$2" common
  common=$(git -C "$work" rev-parse --git-common-dir)
  case "$common" in
    /*) ;;
    *) common=$(CDPATH="" cd "$work/$common" && pwd) ;;
  esac
  [ -d "$common/apexyard-leak-scanned" ] || return 1
  grep -qxF "$tip" "$common/apexyard-leak-scanned/"* 2>/dev/null
}


# ---------------------------------------------------------------------------
# Private origin: commit allowed; push allowed
# ---------------------------------------------------------------------------
echo "== Private origin (stubbed private)"

sb=$(mktemp -d)
build_pair "$sb" "$PRIVATE_ORIGIN_SLUG" true
git -C "$sb/work" checkout -q -b feature/private-ok
printf 'Private reference: amber-lantern\n' > "$sb/work/notes.md"
git -C "$sb/work" add notes.md
commit_out=$(with_vis_env "$sb" git -C "$sb/work" commit -m 'feat: name a private project' 2>&1)
commit_rc=$?
if [ "$commit_rc" -eq 0 ]; then
  pass "private origin: commit naming a registered project is allowed"
else
  fail "private origin: commit naming a registered project is allowed" "$commit_out"
fi
push_out=$(with_vis_env "$sb" git -C "$sb/work" push -u origin HEAD 2>&1)
push_rc=$?
if [ "$push_rc" -eq 0 ]; then
  pass "private origin: push of those commits is allowed"
else
  fail "private origin: push of those commits is allowed" "$push_out"
fi
rm -rf "$sb"

# ---------------------------------------------------------------------------
# Public-class destinations block
# ---------------------------------------------------------------------------
echo "== Public-class remotes block a leaking push"

block_public_push() {
  local label="$1" slug="$2" vis_mode="$3"
  local d out rc
  d=$(mktemp -d)
  build_pair "$d" "$slug" "$vis_mode"
  git -C "$d/work" checkout -q -b "feature/pub-$(printf '%s' "$label" | tr -c 'a-z0-9\n' '-')"
  printf 'Private reference: amber-lantern\n' > "$d/work/leak.md"
  git -C "$d/work" add leak.md
  with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: leak' --no-verify
  out=$(with_vis_env "$d" git -C "$d/work" push -u origin HEAD 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'private portfolio reference' \
    && printf '%s' "$out" | grep -qF 'file: leak.md' \
    && ! printf '%s' "$out" | grep -qF 'amber-lantern'; then
    pass "$label"
  else
    fail "$label" "rc=$rc out=$out"
  fi
  rm -rf "$d"
}

block_public_push "public_framework_repos entry blocks" "$PUBLIC_FRAMEWORK_SLUG" false
block_public_push "stubbed-public slug blocks" "$STUB_PUBLIC_SLUG" false

# Upstream remote classifies the destination as public-class even when the
# origin slug would otherwise look private.
d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" true
git -C "$d/work" remote add upstream "https://github.com/${UPSTREAM_SLUG}.git"
# Point a second bare at upstream and push there.
git clone -q --bare "$d/work" "$d/upstream.git"
git -C "$d/work" config "url.${d}/upstream.git.insteadOf" "https://github.com/${UPSTREAM_SLUG}.git"
git -C "$d/work" checkout -q -b feature/via-upstream
printf 'Private reference: amber-lantern\n' > "$d/work/leak.md"
git -C "$d/work" add leak.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: leak' --no-verify
out=$(with_vis_env "$d" git -C "$d/work" push -u upstream HEAD 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'private portfolio reference'; then
  pass "upstream remote (public-class) blocks"
else
  fail "upstream remote (public-class) blocks" "rc=$rc out=$out"
fi
rm -rf "$d"

# public:true registry entry whose repo equals the push remote → public-class.
d=$(mktemp -d)
build_pair "$d" "$PUBLIC_REG_SLUG" true
git -C "$d/work" checkout -q -b feature/pub-reg
printf 'Private reference: amber-lantern\n' > "$d/work/leak.md"
git -C "$d/work" add leak.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: leak' --no-verify
out=$(with_vis_env "$d" git -C "$d/work" push -u origin HEAD 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'private portfolio reference'; then
  pass "public:true registry remote is public-class and blocks"
else
  fail "public:true registry remote is public-class and blocks" "rc=$rc out=$out"
fi
rm -rf "$d"

# ---------------------------------------------------------------------------
# Cherry-pick onto a new branch still blocks on public push
# ---------------------------------------------------------------------------
echo "== Cherry-pick / new remote branch"

d=$(mktemp -d)
build_pair "$d" "$PUBLIC_FRAMEWORK_SLUG" false
git -C "$d/work" checkout -q -b feature/original
printf 'Private reference: amber-lantern\n' > "$d/work/leak.md"
git -C "$d/work" add leak.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: leak' --no-verify
leak_sha=$(git -C "$d/work" rev-parse HEAD)
git -C "$d/work" checkout -q main
git -C "$d/work" checkout -q -b feature/cherry
git -C "$d/work" cherry-pick "$leak_sha" >/dev/null 2>&1
out=$(with_vis_env "$d" git -C "$d/work" push -u origin HEAD 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'private portfolio reference'; then
  pass "cherry-picked leak on a new branch blocks on public push"
else
  fail "cherry-picked leak on a new branch blocks on public push" "rc=$rc out=$out"
fi
rm -rf "$d"

# New remote branch when the remote has no remote-tracking refs yet.
d=$(mktemp -d)
build_pair "$d" "$PUBLIC_FRAMEWORK_SLUG" false
# Drop remote-tracking refs so the push path takes the "no remotes" branch.
git -C "$d/work" remote remove origin
git -C "$d/work" remote add origin "https://github.com/${PUBLIC_FRAMEWORK_SLUG}.git"
git -C "$d/work" config "url.${d}/remote.git.insteadOf" "https://github.com/${PUBLIC_FRAMEWORK_SLUG}.git"
# Do not fetch — leave zero refs/remotes/origin/*.
git -C "$d/work" checkout -q -b feature/first-push
printf 'Private reference: amber-lantern\n' > "$d/work/leak.md"
git -C "$d/work" add leak.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: leak' --no-verify
out=$(with_vis_env "$d" git -C "$d/work" push -u origin HEAD 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'private portfolio reference'; then
  pass "new remote branch with no remote-tracking refs is scanned"
else
  fail "new remote branch with no remote-tracking refs is scanned" "rc=$rc out=$out"
fi
rm -rf "$d"

# ---------------------------------------------------------------------------
# Lookup fail / non-GitHub → scan; commit-time scan still runs
# ---------------------------------------------------------------------------
echo "== Fail-closed classification"

d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" fail
git -C "$d/work" checkout -q -b feature/lookup-fail
printf 'Private reference: amber-lantern\n' > "$d/work/notes.md"
git -C "$d/work" add notes.md
# Lookup fails → staged scan runs → commit blocked.
commit_out=$(with_vis_env "$d" git -C "$d/work" commit -m 'feat: should block at commit' 2>&1)
commit_rc=$?
if [ "$commit_rc" -ne 0 ] && printf '%s' "$commit_out" | grep -qF 'File: notes.md'; then
  pass "visibility lookup fail: commit-time scan still runs"
else
  fail "visibility lookup fail: commit-time scan still runs" "rc=$commit_rc out=$commit_out"
fi
# Force the commit, then push — push must also scan/block.
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: forced leak' --no-verify
out=$(with_vis_env "$d" git -C "$d/work" push -u origin HEAD 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'private portfolio reference'; then
  pass "visibility lookup fail: push is scanned and blocked"
else
  fail "visibility lookup fail: push is scanned and blocked" "rc=$rc out=$out"
fi
rm -rf "$d"

# Non-GitHub URL (local path as the only remote URL) → scan.
d=$(mktemp -d)
mkdir -p "$d/work"
install_leak_hooks "$d/work"
(
  cd "$d/work" || exit 1
  git init -q -b main
  git config user.email test@example.com
  git config user.name Test
  git config core.hooksPath .githooks
  git add apexyard.projects.yaml .claude/project-config.defaults.json
  git commit -q -m 'chore: seed' --no-verify
)
git clone -q --bare "$d/work" "$d/remote.git"
git -C "$d/work" remote add origin "$d/remote.git"
git -C "$d/work" fetch -q origin
git -C "$d/work" branch -q --set-upstream-to=origin/main main
git -C "$d/work" checkout -q -b feature/local-url
printf 'Private reference: amber-lantern\n' > "$d/work/leak.md"
git -C "$d/work" add leak.md
git -C "$d/work" commit -q -m 'feat: leak' --no-verify
out=$(git -C "$d/work" push -u origin HEAD 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'private portfolio reference'; then
  pass "non-GitHub remote URL: push is scanned and blocked"
else
  fail "non-GitHub remote URL: push is scanned and blocked" "rc=$rc out=$out"
fi
# Commit-time: unknown/non-GitHub origin → scan runs.
printf 'Private reference: amber-lantern\n' > "$d/work/again.md"
git -C "$d/work" add again.md
commit_out=$(git -C "$d/work" commit -m 'feat: again' 2>&1)
commit_rc=$?
if [ "$commit_rc" -ne 0 ] && printf '%s' "$commit_out" | grep -qF 'File: again.md'; then
  pass "non-GitHub origin: commit-time scan still runs"
else
  fail "non-GitHub origin: commit-time scan still runs" "rc=$commit_rc out=$commit_out"
fi
rm -rf "$d"

# Lookup times out → treated as unknown → push is scanned and blocked.
d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" timeout
git -C "$d/work" checkout -q -b feature/lookup-timeout
printf 'Private reference: amber-lantern\n' > "$d/work/leak.md"
git -C "$d/work" add leak.md
APEXYARD_LEAK_VISIBILITY_TIMEOUT=1 with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: forced leak' --no-verify
out=$(APEXYARD_LEAK_VISIBILITY_TIMEOUT=1 with_vis_env "$d" git -C "$d/work" push -u origin HEAD 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'private portfolio reference'; then
  pass "visibility lookup timeout: push is scanned and blocked"
else
  fail "visibility lookup timeout: push is scanned and blocked" "rc=$rc out=$out"
fi
rm -rf "$d"

# ---------------------------------------------------------------------------
# Clean push / deletes / multi-ref / commit message / public:true name
# ---------------------------------------------------------------------------
echo "== Clean push, deletes, multi-ref, message, public:true"

d=$(mktemp -d)
build_pair "$d" "$PUBLIC_FRAMEWORK_SLUG" false
git -C "$d/work" checkout -q -b feature/clean
printf 'No private identifiers here.\n' > "$d/work/clean.md"
git -C "$d/work" add clean.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: clean' --no-verify
out=$(with_vis_env "$d" git -C "$d/work" push -u origin HEAD 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "clean commits: public-class push allowed"
else
  fail "clean commits: public-class push allowed" "rc=$rc out=$out"
fi
# Delete a non-protected feature ref — no scan, no error.
out=$(with_vis_env "$d" git -C "$d/work" push origin --delete feature/clean 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "deleted refs: no scan, no error"
else
  fail "deleted refs: no scan, no error" "rc=$rc out=$out"
fi
rm -rf "$d"

# Commit message containing a registered name → blocked on public push.
d=$(mktemp -d)
build_pair "$d" "$PUBLIC_FRAMEWORK_SLUG" false
git -C "$d/work" checkout -q -b feature/msg-leak
printf 'Clean body.\n' > "$d/work/body.md"
git -C "$d/work" add body.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: touch amber-lantern briefly' --no-verify
out=$(with_vis_env "$d" git -C "$d/work" push -u origin HEAD 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'commit message' \
  && ! printf '%s' "$out" | grep -qF 'amber-lantern'; then
  pass "commit message with registered name blocks on public push"
else
  fail "commit message with registered name blocks on public push" "rc=$rc out=$out"
fi
rm -rf "$d"

# public:true registry names never block.
d=$(mktemp -d)
build_pair "$d" "$PUBLIC_FRAMEWORK_SLUG" false
git -C "$d/work" checkout -q -b feature/pub-name
printf 'Reference: marketing-site is fine.\n' > "$d/work/pub.md"
git -C "$d/work" add pub.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: mention marketing-site' --no-verify
out=$(with_vis_env "$d" git -C "$d/work" push -u origin HEAD 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "public:true registry names never block on push"
else
  fail "public:true registry names never block on push" "rc=$rc out=$out"
fi
rm -rf "$d"

# Multiple refs in one push — one clean, one leaking → whole push blocked.
d=$(mktemp -d)
build_pair "$d" "$PUBLIC_FRAMEWORK_SLUG" false
git -C "$d/work" checkout -q -b feature/multi-clean
printf 'Clean.\n' > "$d/work/c.md"
git -C "$d/work" add c.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: clean' --no-verify
git -C "$d/work" checkout -q -b feature/multi-leak main
printf 'Private reference: amber-lantern\n' > "$d/work/l.md"
git -C "$d/work" add l.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: leak' --no-verify
out=$(with_vis_env "$d" git -C "$d/work" push origin feature/multi-clean feature/multi-leak 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'private portfolio reference'; then
  pass "multiple refs in one push: leak in any ref blocks"
else
  fail "multiple refs in one push: leak in any ref blocks" "rc=$rc out=$out"
fi
rm -rf "$d"

# ---------------------------------------------------------------------------
# Protected-branch guard still fires when origin is private
# ---------------------------------------------------------------------------
echo "== Protected-branch guard with private origin"

d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" true
# Stay on main (protected). A clean commit must still be blocked by the
# protected-branch guard even though the staged leak scan is skipped.
printf 'Safe content.\n' > "$d/work/safe.md"
git -C "$d/work" add safe.md
out=$(with_vis_env "$d" git -C "$d/work" commit -m 'chore: on main' 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "protected branch 'main'"; then
  pass "protected-branch guard still fires when origin is private"
else
  fail "protected-branch guard still fires when origin is private" "rc=$rc out=$out"
fi
rm -rf "$d"

# ---------------------------------------------------------------------------
# Cache: fresh private → no lookup; stale → lookup again
# ---------------------------------------------------------------------------
echo "== Visibility cache"

d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" true
git -C "$d/work" checkout -q -b feature/cache
printf 'Private reference: amber-lantern\n' > "$d/work/notes.md"
git -C "$d/work" add notes.md
# First commit: live lookup (no cache yet) → private → skip scan → allow.
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: first'
first_lookups=$(lookup_count "$d")
reset_lookups "$d"
# Second commit: fresh private cache → no lookup.
printf 'More: amber-lantern\n' > "$d/work/notes2.md"
git -C "$d/work" add notes2.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: second'
second_lookups=$(lookup_count "$d")
if [ "$first_lookups" -ge 1 ] && [ "$second_lookups" -eq 0 ]; then
  pass "fresh private cache: no visibility lookup on second commit"
else
  fail "fresh private cache: no visibility lookup on second commit" \
    "first=$first_lookups second=$second_lookups"
fi

# Stale the cache (epoch far in the past) → lookup again.
git -C "$d/work" config --local "apexyard-leak.${PRIVATE_ORIGIN_SLUG}.state" "private 1"
reset_lookups "$d"
printf 'Again: amber-lantern\n' > "$d/work/notes3.md"
git -C "$d/work" add notes3.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: third'
stale_lookups=$(lookup_count "$d")
if [ "$stale_lookups" -ge 1 ]; then
  pass "stale private cache: visibility lookup runs again"
else
  fail "stale private cache: visibility lookup runs again" "lookups=$stale_lookups"
fi
rm -rf "$d"

# ---------------------------------------------------------------------------
# Object-based scan: pre-review blockers B1-B7 and advisories A2-A5
# ---------------------------------------------------------------------------
echo "== Object scan: B1-B7"

# A push is "blocked for the right reason" only when the leak diagnostic is
# printed and the matched identifier is withheld. A crash also exits non-zero
# and must not pass as a block.
assert_blocked() {
  local label="$1" rc="$2" out="$3"
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'private portfolio reference' \
    && ! printf '%s' "$out" | grep -qF 'amber-lantern'; then
    pass "$label"
  else
    fail "$label" "rc=$rc out=$out"
  fi
}

add_remote() {
  # add_remote DIR NAME SLUG [noname] — bare repo reachable as the GitHub URL.
  local d="$1" name="$2" slug="$3"
  git init -q --bare "$d/$name.git"
  git -C "$d/work" config "url.$d/$name.git.insteadOf" "https://github.com/$slug.git"
  [ "${4:-}" = noname ] || git -C "$d/work" remote add "$name" "https://github.com/$slug.git"
  # The sandbox default says "private"; this remote is public.
  printf 'false\n' > "$(cat "$d/stub_dir_path")/by-slug/$(printf '%s' "$slug" | tr '/' '_')"
}

# A private origin where a leaking commit is allowed and pushed.
d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" true
git -C "$d/work" checkout -q -b feature/leak-on-private
printf 'Private reference: amber-lantern\n' > "$d/work/leak.md"
git -C "$d/work" add leak.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: leak on private'
with_vis_env "$d" git -C "$d/work" push -q -u origin HEAD 2>/dev/null

# B1a: brand-new public remote, no tracking refs, commit already on origin.
add_remote "$d" pubb someone/pub-b
out=$(with_vis_env "$d" git -C "$d/work" push pubb feature/leak-on-private:refs/heads/feature/leak-on-private 2>&1)
assert_blocked "B1: new public remote with no tracking refs scans commits already on origin" $? "$out"

# B1b: push by URL (no configured remote name).
add_remote "$d" pubc someone/pub-c noname
out=$(with_vis_env "$d" git -C "$d/work" push https://github.com/someone/pub-c.git feature/leak-on-private:refs/heads/feature/leak-on-private 2>&1)
assert_blocked "B1: push by URL scans commits already on origin" $? "$out"

# B1c: tag push.
git -C "$d/work" tag v-leak feature/leak-on-private
add_remote "$d" pubf someone/pub-f
out=$(with_vis_env "$d" git -C "$d/work" push pubf v-leak 2>&1)
assert_blocked "B1: tag push to a new public remote is scanned" $? "$out"

# Annotated tag message.
git -C "$d/work" tag -a t-msg -m 'release notes: amber-lantern' main
out=$(with_vis_env "$d" git -C "$d/work" push pubf t-msg 2>&1)
assert_blocked "annotated tag message is scanned" $? "$out"

# B2: force-push over a remote tip that does not exist locally.
add_remote "$d" pubd someone/pub-d
oc=$(mktemp -d)
git clone -q "$d/pubd.git" "$oc/c" 2>/dev/null
(
  cd "$oc/c" || exit 1
  git -c user.email=t@e -c user.name=T checkout -q -b feature/over 2>/dev/null
  echo other > o.txt
  git add o.txt
  git -c user.email=t@e -c user.name=T commit -q --no-verify -m other
  git push -q --no-verify origin feature/over 2>/dev/null
)
rm -rf "$oc"
git -C "$d/work" checkout -q -b feature/over2 feature/leak-on-private
printf 'second: amber-lantern\n' > "$d/work/leak2.md"
git -C "$d/work" add leak2.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: second'
out=$(with_vis_env "$d" git -C "$d/work" push -f pubd feature/over2:refs/heads/feature/over 2>&1)
assert_blocked "B2: force-push over an unknown remote tip is scanned (no 'nothing to scan')" $? "$out"

# B3: private GitHub url with a non-GitHub pushurl (a public mirror).
git init -q --bare "$d/gitlab.git"
git -C "$d/work" config remote.origin.pushurl "https://gitlab.com/someone/public-mirror.git"
git -C "$d/work" config "url.$d/gitlab.git.insteadOf" "https://gitlab.com/someone/public-mirror.git"
out=$(with_vis_env "$d" git -C "$d/work" push origin feature/over2:refs/heads/feature/mirror 2>&1)
assert_blocked "B3: private url with a non-GitHub pushurl is scanned" $? "$out"
git -C "$d/work" config --unset remote.origin.pushurl
rm -rf "$d"

# B4-B7 and friends: content shapes, pushed to a public remote that has
# tracking refs (so the range is exact).
d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" true
add_remote "$d" pub someone/pub
git -C "$d/work" push -q --no-verify pub main 2>/dev/null
git -C "$d/work" fetch -q pub

shape_push() {
  # shape_push LABEL BRANCH — push the branch to the public remote.
  local out rc
  out=$(with_vis_env "$d" git -C "$d/work" push pub "$2:refs/heads/$2" 2>&1)
  rc=$?
  assert_blocked "$1" "$rc" "$out"
}

# B4: identifier only in a conflict-resolution merge.
git -C "$d/work" checkout -q -b feature/m1 main
echo base > "$d/work/c.txt"; git -C "$d/work" add c.txt
git -C "$d/work" commit -q --no-verify -m base
git -C "$d/work" checkout -q -b feature/m1side
echo side > "$d/work/c.txt"; git -C "$d/work" commit -q --no-verify -am side
git -C "$d/work" checkout -q feature/m1
echo mine > "$d/work/c.txt"; git -C "$d/work" commit -q --no-verify -am mine
git -C "$d/work" merge -q feature/m1side >/dev/null 2>&1
echo 'resolved: amber-lantern' > "$d/work/c.txt"
git -C "$d/work" add c.txt
git -C "$d/work" commit -q --no-verify --no-edit
shape_push "B4: identifier only in a merge commit's resolution" feature/m1

# B6a: binary file (NUL byte) containing the identifier.
git -C "$d/work" checkout -q -b feature/m2 main
printf 'hdr\000\001 amber-lantern tail\n' > "$d/work/blob.bin"
git -C "$d/work" add blob.bin
git -C "$d/work" commit -q --no-verify -m bin
shape_push "B6: binary file with a NUL byte is scanned" feature/m2

# B6b: text file marked -diff.
git -C "$d/work" checkout -q -b feature/m3 main
echo '*.txt -diff' > "$d/work/.gitattributes"
echo 'plain text amber-lantern' > "$d/work/notes.txt"
git -C "$d/work" add .gitattributes notes.txt
git -C "$d/work" commit -q --no-verify -m attr
shape_push "B6: file marked -diff is scanned" feature/m3

# B7: file name beginning with a colon.
git -C "$d/work" checkout -q -b feature/m4 main
echo 'x amber-lantern' > "$d/work/:leak.md"
git -C "$d/work" add -- ':(literal):leak.md'
git -C "$d/work" commit -q --no-verify -m colon
shape_push "B7: file named ':leak.md' is scanned" feature/m4

# B5: invalid UTF-8 bytes before the identifier under a UTF-8 locale.
git -C "$d/work" checkout -q -b feature/m5 main
printf 'caf\351 \377\376 amber-lantern\n' > "$d/work/m5.md"
git -C "$d/work" add m5.md
git -C "$d/work" commit -q --no-verify -m m5
out=$(LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 with_vis_env "$d" git -C "$d/work" push pub feature/m5:refs/heads/feature/m5 2>&1)
assert_blocked "B5: invalid UTF-8 bytes before the identifier are scanned" $? "$out"

# What the destination reports holding (the remote sha on stdin) is not
# rescanned: a leaking commit already on the public remote stays excluded.
git -C "$d/work" checkout -q -b feature/known main
printf 'known: amber-lantern\n' > "$d/work/known.md"
git -C "$d/work" add known.md
git -C "$d/work" commit -q --no-verify -m known
git -C "$d/work" push -q --no-verify pub feature/known:refs/heads/feature/known 2>/dev/null
git -C "$d/work" checkout -q -b feature/known-next feature/known
printf 'clean\n' > "$d/work/clean2.md"
git -C "$d/work" add clean2.md
git -C "$d/work" commit -q --no-verify -m clean
out=$(with_vis_env "$d" git -C "$d/work" push pub feature/known-next:refs/heads/feature/known 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "the destination's own remote sha is excluded from the scan"
else
  fail "the destination's own remote sha is excluded from the scan" "rc=$rc out=$out"
fi
rm -rf "$d"

# A5: a repo with no registry never calls the visibility lookup.
d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" true
rm -f "$d/work/apexyard.projects.yaml"
git -C "$d/work" checkout -q -b feature/noreg
echo clean > "$d/work/a.md"
git -C "$d/work" add a.md
reset_lookups "$d"
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: clean'
with_vis_env "$d" git -C "$d/work" push -q -u origin HEAD 2>/dev/null
n=$(lookup_count "$d")
if [ "$n" -eq 0 ]; then
  pass "A5: no registry means no visibility lookup at commit or push"
else
  fail "A5: no registry means no visibility lookup at commit or push" "lookups=$n"
fi
rm -rf "$d"

echo "== Classification: A2-A4"

d=$(mktemp -d)
build_pair "$d" "adopter/2024_ops" true
# A3: a slug with an underscore and a leading digit caches.
git -C "$d/work" checkout -q -b feature/a3
echo clean > "$d/work/a.md"
git -C "$d/work" add a.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: one'
echo clean2 > "$d/work/b.md"
git -C "$d/work" add b.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: two'
n=$(lookup_count "$d")
if [ "$n" -eq 1 ]; then
  pass "A3: cache works for owner/2024_ops (one lookup over two commits)"
else
  fail "A3: cache works for owner/2024_ops (one lookup over two commits)" "lookups=$n"
fi

# A4: slug normaliser anchors the host.
cls() {
  (
    cd "$d/work" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-leak-remote-visibility.sh
    APEXYARD_LEAK_VIS_STUB_DIR=$(cat "$d/stub_dir_path")
    export APEXYARD_LEAK_VIS_STUB_DIR APEXYARD_LEAK_VISIBILITY_CMD
    APEXYARD_LEAK_VISIBILITY_CMD=$(cat "$d/stub_path")
    if leak_remote_is_confirmed_private "$1"; then echo private; else echo scan; fi
  )
}
norm() {
  (
    cd "$d/work" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-leak-remote-visibility.sh
    leak_normalize_github_slug "$1"
  )
}
stub_dir=$(cat "$d/stub_dir_path")
printf 'true\n' > "$stub_dir/by-slug/o_r"
for u in https://evilgithub.com/o/r https://gitlab.com/g/github.com/o/r \
  https://github.com.mirror.example/o/r o/r /tmp/o/r; do
  got=$(cls "$u")
  if [ "$got" = "scan" ]; then
    pass "A4: $u is not a GitHub remote (scan)"
  else
    fail "A4: $u is not a GitHub remote (scan)" "got=$got"
  fi
done
for pair in 'https://GitHub.com/O/R.git=o/r' 'git@github.com:o/r.git=o/r' \
  'ssh://git@github.com:22/o/r=o/r' 'https://user@github.com/o/r/=o/r'; do
  u=${pair%%=*}
  want=${pair#*=}
  got=$(norm "$u")
  if [ "$got" = "$want" ]; then
    pass "A4: $u normalises to $want"
  else
    fail "A4: $u normalises to $want" "got=$got"
  fi
done
rm -rf "$d"

# A2: a failed lookup is negative-cached; a hanging lookup is cut off even
# with no timeout or gtimeout binary (bash-native watchdog).
d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" fail
git -C "$d/work" checkout -q -b feature/a2
echo clean > "$d/work/a.md"
git -C "$d/work" add a.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: one'
echo clean2 > "$d/work/b.md"
git -C "$d/work" add b.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: two'
n=$(lookup_count "$d")
if [ "$n" -eq 1 ]; then
  pass "A2: a failed lookup is negative-cached (one lookup over two commits)"
else
  fail "A2: a failed lookup is negative-cached (one lookup over two commits)" "lookups=$n"
fi
rm -rf "$d"

d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" timeout
git -C "$d/work" checkout -q -b feature/a2w
echo clean > "$d/work/a.md"
git -C "$d/work" add a.md
t0=$(date +%s)
APEXYARD_LEAK_FORCE_WATCHDOG=1 APEXYARD_LEAK_VISIBILITY_TIMEOUT=1 with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: one'
rc=$?
t1=$(date +%s)
if [ "$rc" -eq 0 ] && [ $((t1 - t0)) -lt 15 ]; then
  pass "A2: watchdog cuts off a hanging lookup without timeout/gtimeout"
else
  fail "A2: watchdog cuts off a hanging lookup without timeout/gtimeout" "rc=$rc elapsed=$((t1 - t0))s"
fi
rm -rf "$d"

# ---------------------------------------------------------------------------
# Second pre-review: stale tracking refs, paths, ref names, headers,
# fail-closed tools, and clean-scan records
# ---------------------------------------------------------------------------
echo "== Second review: B1-B3, A2-A4, clean-scan record"

# B1: origin re-pointed from a private repo to a public one. The tracking refs
# still describe the old private repo and must not exclude the leak.
d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" true
git -C "$d/work" checkout -q -b feature/repoint
printf 'Private reference: amber-lantern\n' > "$d/work/leak.md"
git -C "$d/work" add leak.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: leak on private'
with_vis_env "$d" git -C "$d/work" push -q -u origin HEAD 2>/dev/null
git init -q --bare "$d/newpub.git"
git -C "$d/work" remote set-url origin https://github.com/adopter/new-public.git
git -C "$d/work" config "url.$d/newpub.git.insteadOf" https://github.com/adopter/new-public.git
printf 'false\n' > "$(cat "$d/stub_dir_path")/by-slug/adopter_new-public"
out=$(with_vis_env "$d" git -C "$d/work" push origin feature/repoint 2>&1)
assert_blocked "B1: origin repointed private to public ignores stale tracking refs" $? "$out"
rm -rf "$d"

# B2: private url with a public pushurl (triangular). Tracking refs describe
# the fetch URL, not the push destination.
d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" true
git -C "$d/work" checkout -q -b feature/tri
printf 'Private reference: amber-lantern\n' > "$d/work/leak.md"
git -C "$d/work" add leak.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: leak on private'
with_vis_env "$d" git -C "$d/work" push -q -u origin HEAD 2>/dev/null
git -C "$d/work" fetch -q origin
git init -q --bare "$d/tri.git"
git -C "$d/work" config remote.origin.pushurl https://github.com/adopter/tri-public.git
git -C "$d/work" config "url.$d/tri.git.insteadOf" https://github.com/adopter/tri-public.git
printf 'false\n' > "$(cat "$d/stub_dir_path")/by-slug/adopter_tri-public"
out=$(with_vis_env "$d" git -C "$d/work" push origin feature/tri 2>&1)
assert_blocked "B2: private url with a public pushurl ignores fetch-side tracking refs" $? "$out"
rm -rf "$d"

# B3 + A2 + A3 + A4 share a public remote.
d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" true
add_remote "$d" pub someone/pub

# B3: a file named like the registry plus a prefix is not exempt.
git -C "$d/work" checkout -q -b feature/b3 main
echo 'ref amber-lantern' > "$d/work/x apexyard.projects.yaml"
git -C "$d/work" add -- 'x apexyard.projects.yaml'
git -C "$d/work" commit -q --no-verify -m b3
out=$(with_vis_env "$d" git -C "$d/work" push pub feature/b3:refs/heads/feature/b3 2>&1)
assert_blocked "B3: 'x apexyard.projects.yaml' is not exempt (exact path compare)" $? "$out"

# A2: a project name only in a directory name.
git -C "$d/work" checkout -q -b feature/a2path main
mkdir -p "$d/work/projects/amber-lantern"
echo 'clean doc' > "$d/work/projects/amber-lantern/README.md"
git -C "$d/work" add projects
git -C "$d/work" commit -q --no-verify -m a2
out=$(with_vis_env "$d" git -C "$d/work" push pub feature/a2path:refs/heads/feature/a2path 2>&1)
assert_blocked "A2: project name only in a file path is blocked" $? "$out"

# A3: the pushed ref name, and an author email, name a project.
git -C "$d/work" checkout -q -b feature/a3 main
echo clean > "$d/work/a3.md"
git -C "$d/work" add a3.md
git -C "$d/work" commit -q --no-verify -m a3
out=$(with_vis_env "$d" git -C "$d/work" push pub feature/a3:refs/heads/feature/amber-lantern-launch 2>&1)
assert_blocked "A3: a ref name that carries a project name is blocked" $? "$out"
git -C "$d/work" checkout -q -b feature/a3b main
echo clean2 > "$d/work/a3b.md"
git -C "$d/work" add a3b.md
GIT_AUTHOR_EMAIL='bot@amber-lantern.io' git -C "$d/work" commit -q --no-verify -m a3b
out=$(with_vis_env "$d" git -C "$d/work" push pub feature/a3b:refs/heads/feature/a3b 2>&1)
assert_blocked "A3: an author email that carries a project name is blocked" $? "$out"

# A4: a failing scan tool must fail closed (exit 2), never "clean".
git -C "$d/work" checkout -q -b feature/a4 main
echo clean3 > "$d/work/a4.md"
git -C "$d/work" add a4.md
git -C "$d/work" commit -q --no-verify -m a4
a4_sha=$(git -C "$d/work" rev-parse HEAD)
for tool in cut split; do
  stubbin="$d/stubbin-$tool"
  mkdir -p "$stubbin"
  printf '#!/bin/bash\nexit 3\n' > "$stubbin/$tool"
  chmod +x "$stubbin/$tool"
  out=$(
    cd "$d/work" || exit 1
    printf 'refs/heads/feature/a4 %s refs/heads/feature/a4 0000000000000000000000000000000000000000\n' "$a4_sha" \
      | PATH="$stubbin:$PATH" with_vis_env "$d" .claude/hooks/check-private-refs-push.sh origin https://github.com/someone/pub.git 2>&1
  )
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'could not complete'; then
    pass "A4: a failing '$tool' fails closed with exit 2"
  else
    fail "A4: a failing '$tool' fails closed with exit 2" "rc=$rc out=$out"
  fi
done
rm -rf "$d"

# Clean-scan record: a tip scanned clean for one remote is not rescanned for
# another; a registry change invalidates the record.
d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" true
add_remote "$d" pub1 someone/pub-one
add_remote "$d" pub2 someone/pub-two
add_remote "$d" pub3 someone/pub-three
trace="$d/trace.log"
: > "$trace"
git -C "$d/work" checkout -q -b feature/rec main
echo clean > "$d/work/rec.md"
git -C "$d/work" add rec.md
git -C "$d/work" commit -q --no-verify -m rec
APEXYARD_LEAK_PUSH_TRACE="$trace" with_vis_env "$d" git -C "$d/work" push -q pub1 feature/rec:refs/heads/feature/rec 2>/dev/null
first_n=$(sed -n '1p' "$trace" | sed 's/.*objects=//')
APEXYARD_LEAK_PUSH_TRACE="$trace" with_vis_env "$d" git -C "$d/work" push -q pub2 feature/rec:refs/heads/feature/rec 2>/dev/null
second_n=$(sed -n '2p' "$trace" | sed 's/.*objects=//')
if [ -n "$first_n" ] && [ "$first_n" -gt 0 ] && [ "$second_n" = "0" ]; then
  pass "clean-scan record: the same clean tip pushed to another remote is not rescanned"
else
  fail "clean-scan record: the same clean tip pushed to another remote is not rescanned" "first=$first_n second=$second_n"
fi
# Registry change (a new project name) invalidates the record.
printf '  - name: new-project-zz\n    repo: acme/new-project-zz\n    workspace: workspace/new-project-zz\n' >> "$d/work/apexyard.projects.yaml"
git -C "$d/work" add apexyard.projects.yaml
git -C "$d/work" commit -q --no-verify -m 'chore: registry change'
total=$(git -C "$d/work" rev-list --objects HEAD | wc -l | tr -d ' ')
APEXYARD_LEAK_PUSH_TRACE="$trace" with_vis_env "$d" git -C "$d/work" push -q pub3 feature/rec:refs/heads/feature/rec 2>/dev/null
third_n=$(sed -n '3p' "$trace" | sed 's/.*objects=//')
if [ "$third_n" = "$total" ]; then
  pass "clean-scan record: a registry change invalidates it (full rescan)"
else
  fail "clean-scan record: a registry change invalidates it (full rescan)" "third=$third_n total=$total"
fi
rm -rf "$d"

# ---------------------------------------------------------------------------
# Rex B-1: record only full-history-clean tips (no destination exclusions)
# ---------------------------------------------------------------------------
echo "== Rex B-1: full-history clean records only"

# 1. Private origin holds a leak. A filesystem mirror of that bare repo has
# the same history (visibility unknown → scan). A clean tip pushed to the
# mirror uses dest exclusions and must NOT be recorded. Pushing that tip to
# a public remote must then BLOCK (without the mirror step it already does).
d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" true
git -C "$d/work" checkout -q -b feature/b1-mirror
printf 'Private reference: amber-lantern\n' > "$d/work/leak.md"
git -C "$d/work" add leak.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: leak on private'
with_vis_env "$d" git -C "$d/work" push -q -u origin HEAD 2>/dev/null
cp -a "$d/remote.git" "$d/mirror.git"
git -C "$d/work" remote add mirror "https://github.com/adopter/unknown-mirror.git"
git -C "$d/work" config "url.$d/mirror.git.insteadOf" "https://github.com/adopter/unknown-mirror.git"
printf 'fail\n' > "$(cat "$d/stub_dir_path")/by-slug/adopter_unknown-mirror"
printf 'clean\n' > "$d/work/clean.md"
git -C "$d/work" add clean.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: clean'
mirror_tip=$(git -C "$d/work" rev-parse HEAD)
with_vis_env "$d" git -C "$d/work" push -q mirror feature/b1-mirror:refs/heads/feature/b1-mirror 2>/dev/null
if tip_in_clean_record "$d/work" "$mirror_tip"; then
  fail "B-1 mirror path: clean tip after dest-exclusion push is not recorded" \
    "tip $mirror_tip was recorded"
else
  pass "B-1 mirror path: clean tip after dest-exclusion push is not recorded"
fi
add_remote "$d" pubb1 someone/pub-b1
out=$(with_vis_env "$d" git -C "$d/work" push pubb1 feature/b1-mirror:refs/heads/feature/b1-mirror 2>&1)
assert_blocked "B-1: private tip via unknown mirror still blocks on public push" $? "$out"
rm -rf "$d"

# 2. A push with no destination exclusion still writes a record; a second
# push of the same clean tip to another public remote scans 0 objects.
d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" true
add_remote "$d" pub1b someone/pub-one-b
add_remote "$d" pub2b someone/pub-two-b
trace="$d/trace-b1.log"
: > "$trace"
git -C "$d/work" checkout -q -b feature/rec-full main
echo clean > "$d/work/rec-full.md"
git -C "$d/work" add rec-full.md
git -C "$d/work" commit -q --no-verify -m rec-full
full_tip=$(git -C "$d/work" rev-parse HEAD)
APEXYARD_LEAK_PUSH_TRACE="$trace" with_vis_env "$d" git -C "$d/work" push -q pub1b feature/rec-full:refs/heads/feature/rec-full 2>/dev/null
first_n=$(sed -n '1p' "$trace" | sed 's/.*objects=//')
if tip_in_clean_record "$d/work" "$full_tip" && [ -n "$first_n" ] && [ "$first_n" -gt 0 ]; then
  pass "B-1: no-dest-exclusion push writes a full-history clean record"
else
  fail "B-1: no-dest-exclusion push writes a full-history clean record" \
    "recorded=$(tip_in_clean_record "$d/work" "$full_tip" && echo yes || echo no) first=$first_n"
fi
APEXYARD_LEAK_PUSH_TRACE="$trace" with_vis_env "$d" git -C "$d/work" push -q pub2b feature/rec-full:refs/heads/feature/rec-full 2>/dev/null
second_n=$(sed -n '2p' "$trace" | sed 's/.*objects=//')
if [ "$second_n" = "0" ]; then
  pass "B-1: recorded full-history tip reused on another public remote (0 objects)"
else
  fail "B-1: recorded full-history tip reused on another public remote (0 objects)" \
    "second=$second_n"
fi
rm -rf "$d"

# 3. A push that used destination exclusions writes NO record for that tip.
d=$(mktemp -d)
build_pair "$d" "$PUBLIC_FRAMEWORK_SLUG" false
git -C "$d/work" config core.hooksPath /dev/null
git -C "$d/work" checkout -q -b feature/seed-for-rec
printf 'Private reference: amber-lantern\n' > "$d/work/old-leak.md"
git -C "$d/work" add old-leak.md
git -C "$d/work" commit -q -m 'feat: already on dest'
with_vis_env "$d" git -C "$d/work" push -q origin feature/seed-for-rec:refs/heads/dev
git -C "$d/work" checkout -q -b feature/clean-no-rec feature/seed-for-rec
printf 'clean new work\n' > "$d/work/clean.md"
git -C "$d/work" add clean.md
git -C "$d/work" commit -q -m 'feat: clean only'
no_rec_tip=$(git -C "$d/work" rev-parse HEAD)
git -C "$d/work" config core.hooksPath .githooks
# Clear any prior records so we only assert this push's effect.
common=$(git -C "$d/work" rev-parse --git-common-dir)
case "$common" in
  /*) ;;
  *) common=$(CDPATH="" cd "$d/work/$common" && pwd) ;;
esac
rm -rf "$common/apexyard-leak-scanned"
out=$(with_vis_env "$d" git -C "$d/work" push -u origin HEAD 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && ! tip_in_clean_record "$d/work" "$no_rec_tip"; then
  pass "B-1: dest-exclusion push writes no clean-scan record for that tip"
else
  fail "B-1: dest-exclusion push writes no clean-scan record for that tip" \
    "rc=$rc recorded=$(tip_in_clean_record "$d/work" "$no_rec_tip" && echo yes || echo no) out=$out"
fi
rm -rf "$d"

# ---------------------------------------------------------------------------
# Destination refs (exclusion c): ls-remote of the push URL (#1528 follow-up)
# ---------------------------------------------------------------------------
echo "== Destination refs from ls-remote"

# 1. Destination already holds a leaking commit (e.g. on its own main/dev).
# A NEW branch from that history with only clean new commits must be allowed —
# without exclusion (c) the all-zero remote sha would scan the whole history.
d=$(mktemp -d)
build_pair "$d" "$PUBLIC_FRAMEWORK_SLUG" false
git -C "$d/work" config core.hooksPath /dev/null
git -C "$d/work" checkout -q -b feature/seed-leak
printf 'Private reference: amber-lantern\n' > "$d/work/old-leak.md"
git -C "$d/work" add old-leak.md
git -C "$d/work" commit -q -m 'feat: already on dest names amber-lantern'
with_vis_env "$d" git -C "$d/work" push -q origin feature/seed-leak:refs/heads/dev
git -C "$d/work" checkout -q -b feature/new-clean feature/seed-leak
printf 'clean new work\n' > "$d/work/clean.md"
git -C "$d/work" add clean.md
git -C "$d/work" commit -q -m 'feat: clean only'
git -C "$d/work" config core.hooksPath .githooks
out=$(with_vis_env "$d" git -C "$d/work" push -u origin HEAD 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "dest already has a leak: new clean branch push is allowed"
else
  fail "dest already has a leak: new clean branch push is allowed" "rc=$rc out=$out"
fi
rm -rf "$d"

# 2. Same setup, but the new branch adds a leaking commit → blocked.
d=$(mktemp -d)
build_pair "$d" "$PUBLIC_FRAMEWORK_SLUG" false
git -C "$d/work" config core.hooksPath /dev/null
git -C "$d/work" checkout -q -b feature/seed-leak2
printf 'Private reference: amber-lantern\n' > "$d/work/old-leak.md"
git -C "$d/work" add old-leak.md
git -C "$d/work" commit -q -m 'feat: already on dest names amber-lantern'
with_vis_env "$d" git -C "$d/work" push -q origin feature/seed-leak2:refs/heads/dev
git -C "$d/work" checkout -q -b feature/new-leak feature/seed-leak2
printf 'new leak: amber-lantern\n' > "$d/work/new-leak.md"
git -C "$d/work" add new-leak.md
git -C "$d/work" commit -q -m 'feat: new leak'
git -C "$d/work" config core.hooksPath .githooks
out=$(with_vis_env "$d" git -C "$d/work" push -u origin HEAD 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'private portfolio reference' \
  && printf '%s' "$out" | grep -qF 'file: new-leak.md' \
  && ! printf '%s' "$out" | grep -qF 'amber-lantern'; then
  pass "dest already has a leak: new leaking commit still blocks"
else
  fail "dest already has a leak: new leaking commit still blocks" "rc=$rc out=$out"
fi
rm -rf "$d"

# 3. ls-remote fails → full scan → blocked when history contains a match,
# with the stderr note.
d=$(mktemp -d)
build_pair "$d" "$PUBLIC_FRAMEWORK_SLUG" false
git -C "$d/work" config core.hooksPath /dev/null
git -C "$d/work" checkout -q -b feature/ls-fail
printf 'Private reference: amber-lantern\n' > "$d/work/old-leak.md"
git -C "$d/work" add old-leak.md
git -C "$d/work" commit -q -m 'feat: already on dest names amber-lantern'
with_vis_env "$d" git -C "$d/work" push -q origin feature/ls-fail:refs/heads/dev
git -C "$d/work" checkout -q -b feature/ls-fail-clean feature/ls-fail
printf 'clean\n' > "$d/work/clean.md"
git -C "$d/work" add clean.md
git -C "$d/work" commit -q -m 'feat: clean only'
git -C "$d/work" config core.hooksPath .githooks
fail_ls="$d/fail-ls-remote.sh"
printf '#!/bin/bash\nexit 1\n' > "$fail_ls"
chmod +x "$fail_ls"
out=$(APEXYARD_LEAK_LS_REMOTE_CMD="$fail_ls" with_vis_env "$d" \
  git -C "$d/work" push -u origin HEAD 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'private portfolio reference' \
  && printf '%s' "$out" | grep -qF "could not read the destination's refs" \
  && ! printf '%s' "$out" | grep -qF 'amber-lantern'; then
  pass "ls-remote failure: full scan blocks and prints the stderr note"
else
  fail "ls-remote failure: full scan blocks and prints the stderr note" "rc=$rc out=$out"
fi
rm -rf "$d"

# 4. Destination advertises a sha not present locally → ignored, no error.
d=$(mktemp -d)
build_pair "$d" "$PUBLIC_FRAMEWORK_SLUG" false
# Create a commit only on the bare (via a throwaway clone), so work lacks it.
oc=$(mktemp -d)
git clone -q "$d/remote.git" "$oc/c"
(
  cd "$oc/c" || exit 1
  git -c user.email=t@e -c user.name=T checkout -q -b feature/remote-only
  echo only-on-dest > only.txt
  git add only.txt
  git -c user.email=t@e -c user.name=T commit -q -m 'only on dest'
  git push -q origin feature/remote-only:refs/heads/feature/remote-only
)
rm -rf "$oc"
git -C "$d/work" checkout -q -b feature/local-clean
printf 'No private identifiers here.\n' > "$d/work/clean.md"
git -C "$d/work" add clean.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: clean' --no-verify
out=$(with_vis_env "$d" git -C "$d/work" push -u origin HEAD 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "dest ref sha missing locally is ignored (clean push allowed)"
else
  fail "dest ref sha missing locally is ignored (clean push allowed)" "rc=$rc out=$out"
fi
rm -rf "$d"

# 5. B1 and B2 still blocked: ls-remote of the *push* destination (empty /
# unrelated) must not be replaced by stale refs/remotes/*.
d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" true
git -C "$d/work" checkout -q -b feature/repoint2
printf 'Private reference: amber-lantern\n' > "$d/work/leak.md"
git -C "$d/work" add leak.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: leak on private'
with_vis_env "$d" git -C "$d/work" push -q -u origin HEAD 2>/dev/null
git init -q --bare "$d/newpub2.git"
git -C "$d/work" remote set-url origin https://github.com/adopter/new-public-2.git
git -C "$d/work" config "url.$d/newpub2.git.insteadOf" https://github.com/adopter/new-public-2.git
printf 'false\n' > "$(cat "$d/stub_dir_path")/by-slug/adopter_new-public-2"
out=$(with_vis_env "$d" git -C "$d/work" push origin feature/repoint2 2>&1)
assert_blocked "B1 (dest ls-remote): origin repointed private to public still blocks" $? "$out"
rm -rf "$d"

d=$(mktemp -d)
build_pair "$d" "$PRIVATE_ORIGIN_SLUG" true
git -C "$d/work" checkout -q -b feature/tri2
printf 'Private reference: amber-lantern\n' > "$d/work/leak.md"
git -C "$d/work" add leak.md
with_vis_env "$d" git -C "$d/work" commit -q -m 'feat: leak on private'
with_vis_env "$d" git -C "$d/work" push -q -u origin HEAD 2>/dev/null
git -C "$d/work" fetch -q origin
git init -q --bare "$d/tri2.git"
git -C "$d/work" config remote.origin.pushurl https://github.com/adopter/tri-public-2.git
git -C "$d/work" config "url.$d/tri2.git.insteadOf" https://github.com/adopter/tri-public-2.git
printf 'false\n' > "$(cat "$d/stub_dir_path")/by-slug/adopter_tri-public-2"
out=$(with_vis_env "$d" git -C "$d/work" push origin feature/tri2 2>&1)
assert_blocked "B2 (dest ls-remote): private url with public pushurl still blocks" $? "$out"
rm -rf "$d"

echo
echo "push private-refs (#1528): PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
