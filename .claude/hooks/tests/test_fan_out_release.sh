#!/bin/bash
# Exercise /fan-out release through the real preparation and owner library.
# Process inspection is deterministic because these tests cover lifecycle
# behavior. The owner library's suite covers real process liveness.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
set -u

ROOT=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fan-out-release.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
RELEASE_SOURCE=${FAN_OUT_RELEASE_HELPER:-$ROOT/.claude/skills/fan-out/release-worktree-owner.sh}
PASS=0
FAIL=0
check() {
  local label=$1
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n' "$label" >&2
    FAIL=$((FAIL + 1))
  fi
}
result_is() { [ "$RC" -eq "$1" ] && [ "$OUT" = "$2" ]; }
record_is() { jq -e "$1" "$RECORD" >/dev/null; }
record_unchanged() { cmp -s "$RECORD" "$TMP/before"; }
tree_and_branch_remain() {
  [ -d "$WT" ] && [ -f "$WT/.git" ] &&
    [ "$(cat "$WT/retained-content")" = 'keep this file' ] &&
    [ "$(git -C "$SB/workspace/p1" rev-parse "refs/heads/$BRANCH")" = "$BRANCH_TIP" ]
}

SB="$TMP/ops tree"
mkdir -p "$SB/.claude/hooks" "$SB/.claude/skills/fan-out" "$SB/.claude/worktrees" "$SB/workspace" "$TMP/bin"
for lib in "$ROOT"/.claude/hooks/_lib-*.sh; do cp "$lib" "$SB/.claude/hooks/"; done
cp "$ROOT/.claude/project-config.defaults.json" "$SB/.claude/"
cp "$ROOT/.claude/skills/fan-out/prepare-worktree.sh" "$SB/.claude/skills/fan-out/"
if [ -f "$RELEASE_SOURCE" ]; then cp "$RELEASE_SOURCE" "$SB/.claude/skills/fan-out/release-worktree-owner.sh"; fi
: > "$SB/.apexyard-fork"
: > "$SB/onboarding.yaml"
printf 'projects:\n  - name: p1\n    repo: org/p1\n' > "$SB/apexyard.projects.yaml"
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
for repo in "$SB" "$SB/workspace/p1"; do
  git -c init.defaultBranch=main init -q "$repo" || exit 1
  git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm fixture --allow-empty || exit 1
done
printf 'repo=org/p1\nnumber=42\ntitle=Writer task\nurl=https://example.test/42\n' > "$SB/workspace/p1/.git/apexyard-ticket"

cat > "$TMP/bin/ps" <<'SCRIPT'
#!/bin/bash
case "${2:-}" in
  ppid=,comm=)
    if [ "$4" = "$RELEASE_TEST_PID" ]; then printf ' 1 claude\n'
    else printf ' %s /bin/bash\n' "$RELEASE_TEST_PID"; fi ;;
  lstart=) printf ' Sun Nov 1 10:00:00 2026\n' ;;
  *) exit 1 ;;
esac
SCRIPT
cat > "$TMP/bin/sysctl" <<'SCRIPT'
#!/bin/sh
printf '{ sec = 123, usec = 456 }\n'
SCRIPT
chmod +x "$TMP/bin/ps" "$TMP/bin/sysctl"
export PATH="$TMP/bin:$PATH" RELEASE_TEST_PID="$$" CLAUDE_CODE_SESSION_ID=release-owner
unset APEXYARD_WORKTREE_LEASE_TTL_SECONDS

prepare() {
  BRANCH="feature/$1"
  WT="$SB/.claude/worktrees/$1 writer"
  (cd "$SB" && "$BASH" "$SB/.claude/skills/fan-out/prepare-worktree.sh" "$SB/workspace/p1" "$WT" "$BRANCH") > "$TMP/prepare-output" 2>&1 || {
    cat "$TMP/prepare-output" >&2
    return 1
  }
  RECORD="$(git -C "$WT" rev-parse --absolute-git-dir)/apexyard-owner"
  BRANCH_TIP=$(git -C "$SB/workspace/p1" rev-parse "refs/heads/$BRANCH") || return 1
  printf 'keep this file\n' > "$WT/retained-content"
}
release() {
  RC=0
  OUT=$("$BASH" "$SB/.claude/skills/fan-out/release-worktree-owner.sh" "$@" 2>&1) || RC=$?
}

prepare successful || exit 1
check 'preparation acquires generation one for the orchestrator' record_is \
  '.status == "active" and .generation == 1 and .owner.session_id == "release-owner"'
cp "$RECORD" "$TMP/before"
release "$WT"
check 'release prints one success line and exits zero' result_is 0 "released $WT"
check 'release increments generation and records the releasing identity' record_is \
  '.status == "released" and .generation == 2 and .owner == null and .released_by.session_id == "release-owner"'
check 'release preserves worktree contents and branch reference' tree_and_branch_remain
cp "$RECORD" "$TMP/before"
release "$WT"
check 'repeated release prints already released and exits zero' result_is 0 "already released $WT"
check 'repeated release leaves record bytes unchanged' record_unchanged
check 'repeated release preserves worktree contents and branch reference' tree_and_branch_remain
cp "$RECORD" "$TMP/before"
CLAUDE_CODE_SESSION_ID=another-session release "$WT"
check 'already released record reports already released for another session' result_is 0 "already released $WT"
check 'already released record bytes remain unchanged for another session' record_unchanged
export CLAUDE_CODE_SESSION_ID=release-owner

prepare absent || exit 1
mv "$RECORD" "$TMP/absent-record"
release "$WT"
check 'missing record prints no owner record and exits zero' result_is 0 "no owner record $WT"
check 'missing record remains absent' test ! -e "$RECORD"
check 'missing record preserves worktree contents and branch reference' tree_and_branch_remain

prepare other-session || exit 1
cp "$RECORD" "$TMP/before"
CLAUDE_CODE_SESSION_ID=another-session release "$WT"
check 'another live session is refused with exit one' result_is 1 "refused $WT: alive"
check 'another session cannot change record bytes' record_unchanged
check 'refused release preserves worktree contents and branch reference' tree_and_branch_remain

# Session-only owners have unknown liveness. A different session cannot release.
jq '.owner = {session_id:"release-owner",harness:null,pid:null,pid_start:null,boot_id:null}' \
  "$RECORD" > "$TMP/unknown-record" || exit 1
cp "$TMP/unknown-record" "$RECORD"
cp "$RECORD" "$TMP/before"
CLAUDE_CODE_SESSION_ID=another-session release "$WT"
check 'unknown liveness is refused with exit one' result_is 1 "refused $WT: unknown"
check 'unknown owner record bytes remain unchanged' record_unchanged

export CLAUDE_CODE_SESSION_ID=release-owner
prepare dead || exit 1
jq '.owner.pid_start = "UTC Mon Jan 2 03:04:05 2026"' "$RECORD" > "$TMP/dead-record" || exit 1
cp "$TMP/dead-record" "$RECORD"
cp "$RECORD" "$TMP/before"
CLAUDE_CODE_SESSION_ID=another-session release "$WT"
check 'dead owner process is refused with exit one' result_is 1 "refused $WT: dead"
check 'dead owner record bytes remain unchanged' record_unchanged
export CLAUDE_CODE_SESSION_ID=release-owner

printf 'invalid owner record\n' > "$RECORD"
cp "$RECORD" "$TMP/before"
release "$WT"
check 'malformed record reports the library unknown status' result_is 1 "refused $WT: unknown"
check 'malformed record bytes remain unchanged' record_unchanged

prepare locked || exit 1
cp "$RECORD" "$TMP/before"
mkdir "${RECORD}.lock"
printf 'unverifiable lock holder\n' > "${RECORD}.lock/owner"
release "$WT"
check 'held owner lock prevents release' result_is 1 "refused $WT: alive"
check 'held owner lock keeps record bytes unchanged' record_unchanged
check 'held owner lock remains intact' test -f "${RECORD}.lock/owner"
check 'held owner lock preserves worktree contents and branch reference' tree_and_branch_remain

release "$SB/workspace/p1"
check 'main working tree is refused with exit one' result_is 1 "refused $SB/workspace/p1: unknown"
check 'main working tree creates no owner record' test ! -e "$SB/workspace/p1/.git/apexyard-owner"
mkdir "$TMP/plain directory"
release "$TMP/plain directory"
check 'non-repository path is refused with exit one' result_is 1 "refused $TMP/plain directory: unknown"
check 'non-repository path creates no owner record' test ! -e "$TMP/plain directory/apexyard-owner"
check 'refused non-repository directory remains on disk' test -d "$TMP/plain directory"

mkdir -p "$TMP/isolated/.claude/skills/fan-out"
cp "$SB/.claude/skills/fan-out/release-worktree-owner.sh" "$TMP/isolated/.claude/skills/fan-out/release-worktree-owner.sh"
cp "$RECORD" "$TMP/before"
RC=0
OUT=$("$BASH" "$TMP/isolated/.claude/skills/fan-out/release-worktree-owner.sh" "$WT" 2>&1) || RC=$?
check 'missing hooks directory prints refused unknown and exits one' result_is 1 "refused $WT: unknown"
check 'missing hooks directory leaves record bytes unchanged' record_unchanged
mkdir -p "$TMP/isolated/.claude/hooks"
cp "$RECORD" "$TMP/before"
RC=0
OUT=$("$BASH" "$TMP/isolated/.claude/skills/fan-out/release-worktree-owner.sh" "$WT" 2>&1) || RC=$?
check 'missing owner library prints refused unknown and exits one' result_is 1 "refused $WT: unknown"
check 'missing owner library leaves record bytes unchanged' record_unchanged
cat > "$TMP/isolated/.claude/hooks/_lib-worktree-owner.sh" <<'STUB'
worktree_owner_release() { return 1; }
worktree_owner_status() { printf '%s\n' "unexpected status text"; return 2; }
STUB
cp "$RECORD" "$TMP/before"
RC=0
OUT=$("$BASH" "$TMP/isolated/.claude/skills/fan-out/release-worktree-owner.sh" "$WT" 2>&1) || RC=$?
check 'unexpected status text prints refused unknown and exits one' result_is 1 "refused $WT: unknown"
check 'unexpected status text leaves record bytes unchanged' record_unchanged
cat > "$TMP/isolated/.claude/hooks/_lib-worktree-owner.sh" <<'STUB'
worktree_owner_release() { return 1; }
worktree_owner_status() { return 2; }
STUB
cp "$RECORD" "$TMP/before"
RC=0
OUT=$("$BASH" "$TMP/isolated/.claude/skills/fan-out/release-worktree-owner.sh" "$WT" 2>&1) || RC=$?
check 'empty status output prints refused unknown and exits one' result_is 1 "refused $WT: unknown"
check 'empty status output leaves record bytes unchanged' record_unchanged

cp "$RECORD" "$TMP/before"
RC=0
OUT=$("$BASH" "$SB/.claude/skills/fan-out/release-worktree-owner.sh" 2>&1) || RC=$?
check 'missing argument prints usage and exits two' result_is 2 'usage: release-worktree-owner.sh <worktree-path>'
release "$WT" extra
check 'extra argument prints usage and exits two' result_is 2 'usage: release-worktree-owner.sh <worktree-path>'
release ""
check 'empty argument prints usage and exits two' result_is 2 'usage: release-worktree-owner.sh <worktree-path>'
check 'usage errors leave record bytes unchanged' record_unchanged

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
