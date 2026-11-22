#!/bin/bash
# Hold one writer at rename while another writer attempts the same lock.
# Overrides are invoked indirectly by the libraries.
# shellcheck disable=SC2329
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
LIB=${PROGRESS_NOTE_LIB:-$ROOT/.claude/hooks/_lib-progress-note.sh}
# shellcheck source=/dev/null
. "$LIB"
mkdir "$TMP/bin" "$TMP/tree"
git -C "$TMP/tree" init -q
printf 'repo=owner/repo\nnumber=2097\n' > "$TMP/tree/.git/apexyard-ticket"
progress_note_create "$TMP/tree"
REAL_MKDIR=$(command -v mkdir)
export REAL_MKDIR
cat > "$TMP/bin/mkdir" <<'FAKE'
#!/bin/bash
# Model mkdir reporting success for an existing directory.
[ "$#" -ne 1 ] || [ ! -d "$1" ] || exit 0
exec "$REAL_MKDIR" "$@"
FAKE
chmod +x "$TMP/bin/mkdir"
export PATH="$TMP/bin:$PATH"
mkfifo "$TMP/ready" "$TMP/release"
(
  mv() {
    printf 'ready\n' > "$TMP/ready"
    IFS= read -r release < "$TMP/release"
    [ "$release" = release ]
    command mv "$@"
  }
  progress_note_update "$TMP/tree" Completed first
) > "$TMP/first.out" 2>&1 &
first=$!
IFS= read -r ready < "$TMP/ready"
[ "$ready" = ready ]
second=0
progress_note_update "$TMP/tree" Completed second > "$TMP/second.out" 2>&1 || second=$?
printf 'release\n' > "$TMP/release"
first_rc=0
wait "$first" || first_rc=$?
if [ "$second" -eq 0 ]; then
  printf 'FAIL: second writer entered while the first writer held the lock\n' >&2
  exit 1
fi
[ "$first_rc" -eq 0 ]
grep -q first "$TMP/tree/.git/apexyard-progress.md"
[ ! -e "$TMP/tree/.git/apexyard-progress.md.lock" ]
[ ! -e "$TMP/tree/.git/apexyard-progress.md.lock.creating" ]
printf 'PASS: non-atomic mkdir excludes the second writer and cleans the lock\n'

# Owner records retain their directory layout and reject a second holder.
# shellcheck source=/dev/null
. "${WORKTREE_OWNER_LIB:-$ROOT/.claude/hooks/_lib-worktree-owner.sh}"
_wto_operation_identity() { printf -v "$1" '%s' '123|UTC Sat Oct 31 10:00:00 2026|fixture|boot'; }
_wto_lock_identity_state() { printf 'alive\n'; }
command mkdir "$TMP/owner"
_wto_lock "$TMP/owner"
if _wto_lock "$TMP/owner"; then
  printf 'FAIL: owner lock admitted a second holder\n' >&2
  exit 1
fi
_wto_unlock "$TMP/owner"
[ ! -e "$TMP/owner/apexyard-owner.lock" ]
printf 'PASS: owner lock excludes a second holder with non-atomic mkdir\n'

# A pre-existing reaping guard must prevent stale-lock removal.
command mkdir "$TMP/owner/apexyard-owner.lock"
printf '456|unused|dead|boot\n' > "$TMP/owner/apexyard-owner.lock/owner"
command mkdir "$TMP/owner/apexyard-owner.lock/reaping"
_wto_lock_identity_state() { printf 'dead\n'; return 1; }
if _wto_lock "$TMP/owner"; then
  printf 'FAIL: owner lock ignored an existing reaping guard\n' >&2
  exit 1
fi
grep -qx '456|unused|dead|boot' "$TMP/owner/apexyard-owner.lock/owner"
printf 'PASS: non-atomic mkdir preserves an existing reaping guard\n'
