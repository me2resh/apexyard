#!/usr/bin/env bash
# test_source_snapshot.sh — tests for the /eval-agents source snapshot
# (source-snapshot.sh, #1815).
# Run: bash .claude/skills/eval-agents/tests/test_source_snapshot.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SNAPSHOT="$SCRIPT_DIR/../lib/source-snapshot.sh"

pass=0
fail=0

WORKDIR="$(mktemp -d)"
cleanup() {
  chmod -R u+w "$WORKDIR" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT
OUTFILE="$WORKDIR/last.out"

ok() { echo "✓ $1"; pass=$((pass + 1)); }
bad() { echo "✗ $1"; [ -f "$OUTFILE" ] && cat "$OUTFILE"; fail=$((fail + 1)); }

check() {
  local desc="$1" expect_rc="$2"; shift 2
  "$@" >"$OUTFILE" 2>&1
  local rc=$?
  if [ "$rc" -eq "$expect_rc" ]; then ok "$desc"; else bad "$desc (expected exit $expect_rc, got $rc)"; fi
}

# Fixture repository. "acme-secret" stands in for a private project name.
REPO="$WORKDIR/repo"
mkdir -p "$REPO/acme-secret-docs"
git -C "$REPO" init -q
printf 'Deploy Acme-Secret first.\nThe acme-secret-api calls it.\nKeep this line.\n' > "$REPO/notes.md"
printf 'plain text\n' > "$REPO/acme-secret-docs/readme.md"
printf '$r/.apexyard-fork\n' > "$REPO/walk.sh"
git -C "$REPO" add notes.md acme-secret-docs/readme.md walk.sh
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m clean
CLEAN=$(git -C "$REPO" rev-parse HEAD)
printf 'bin\000acme-secret\000' > "$REPO/blob.bin"
git -C "$REPO" add blob.bin
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m binary
BINARY=$(git -C "$REPO" rev-parse HEAD)

DENY="$WORKDIR/deny.txt"
printf '# private names\n\nacme-secret\n' > "$DENY"

# 1. Usage and input errors fail closed.
check "missing arguments fail with exit 2" 2 bash "$SNAPSHOT"
check "an unknown commit fails with exit 2" 2 bash "$SNAPSHOT" deadbeef "$WORKDIR/o1" "$DENY" "$REPO"
check "a missing deny list fails with exit 2" 2 bash "$SNAPSHOT" "$CLEAN" "$WORKDIR/o2" "$WORKDIR/none.txt" "$REPO"
printf 'ab\n' > "$WORKDIR/short.txt"
check "a deny-list name under 3 characters fails with exit 2" 2 bash "$SNAPSHOT" "$CLEAN" "$WORKDIR/o3" "$WORKDIR/short.txt" "$REPO"
mkdir -p "$WORKDIR/o4" && touch "$WORKDIR/o4/x"
check "a non-empty out-dir fails with exit 2" 2 bash "$SNAPSHOT" "$CLEAN" "$WORKDIR/o4" "$DENY" "$REPO"

# 2. Happy path.
OUT="$WORKDIR/snap"
check "a clean commit builds a snapshot" 0 bash "$SNAPSHOT" "$CLEAN" "$OUT" "$DENY" "$REPO"
if grep -rqiF acme-secret "$OUT"; then bad "no name remains in file text"; else ok "no name remains in file text"; fi
if (cd "$OUT" && find . | grep -qiF acme-secret); then bad "no name remains in a path"; else ok "no name remains in a path"; fi
if [ -f "$OUT/<project>-docs/readme.md" ]; then ok "a directory name is redacted"; else bad "a directory name is redacted"; fi
if grep -qxF 'Deploy <project> first.' "$OUT/notes.md" && grep -qxF 'The <project>-api calls it.' "$OUT/notes.md"; then
  ok "text matches are replaced, case ignored"
else
  bad "text matches are replaced, case ignored"
fi
if grep -qxF 'Keep this line.' "$OUT/notes.md" && grep -qxF '$r/.apexyard-fork' "$OUT/walk.sh"; then
  ok "other text is unchanged"
else
  bad "other text is unchanged"
fi
if [ -e "$OUT/.git" ]; then bad "the snapshot has no .git directory"; else ok "the snapshot has no .git directory"; fi
if [ -n "$(find "$OUT" -perm -u+w | head -1)" ]; then bad "the snapshot is read-only"; else ok "the snapshot is read-only"; fi

# 3. A name that the script cannot redact (inside a binary file) fails closed.
check "a name left in a binary file fails with exit 2" 2 bash "$SNAPSHOT" "$BINARY" "$WORKDIR/snap-bin" "$DENY" "$REPO"
if grep -qF 'remains in' "$OUTFILE"; then ok "the failure names the leak"; else bad "the failure names the leak"; fi

# 4. An empty deny list builds an unredacted snapshot and says so.
: > "$WORKDIR/empty.txt"
check "an empty deny list builds a snapshot" 0 bash "$SNAPSHOT" "$CLEAN" "$WORKDIR/snap-empty" "$WORKDIR/empty.txt" "$REPO"
if grep -qF 'NOTE: the deny list is empty' "$OUTFILE"; then ok "an empty deny list prints a note"; else bad "an empty deny list prints a note"; fi

echo
echo "source-snapshot test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
