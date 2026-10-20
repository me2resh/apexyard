#!/usr/bin/env bash
# test_source_snapshot.sh — tests for the /eval-agents source snapshot
# (source-snapshot.sh, #1815).
# Run: bash .claude/skills/eval-agents/tests/test_source_snapshot.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SNAPSHOT="$SCRIPT_DIR/../lib/source-snapshot.sh"

pass=0
fail=0

WORKDIR="$(cd "$(mktemp -d)" && pwd -P)"
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
if grep -qF 'binary file' "$OUTFILE"; then ok "the failure names the leak"; else bad "the failure names the leak"; fi

# 3b. Symbolic links fail closed. Fake names only.
ln -s acme-secret-docs "$REPO/linkdir"
git -C "$REPO" add linkdir
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m link1
LINK1=$(git -C "$REPO" rev-parse HEAD)
check "a link to a deny-list name fails with exit 2" 2 bash "$SNAPSHOT" "$LINK1" "$WORKDIR/snap-l1" "$DENY" "$REPO"
git -C "$REPO" rm -q -f linkdir
ln -s /nonexistent/outside-target "$REPO/linkabs"
git -C "$REPO" add linkabs
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m link2
LINK2=$(git -C "$REPO" rev-parse HEAD)
check "a link with an absolute outside target fails with exit 2" 2 bash "$SNAPSHOT" "$LINK2" "$WORKDIR/snap-l2" "$DENY" "$REPO"
git -C "$REPO" rm -q -f linkabs

# 3c. A binary file with no deny-list name is not redacted: fail closed.
printf 'bin\000plain\000' > "$REPO/clean.bin"
git -C "$REPO" rm -q -f blob.bin
git -C "$REPO" add clean.bin
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m cleanbin
CLEANBIN=$(git -C "$REPO" rev-parse HEAD)
check "an unredacted binary file fails with exit 2" 2 bash "$SNAPSHOT" "$CLEANBIN" "$WORKDIR/snap-b2" "$DENY" "$REPO"
if grep -qF 'binary file' "$OUTFILE"; then ok "the failure names the binary file"; else bad "the failure names the binary file"; fi

# 3d. A failed build leaves no tree on disk.
if [ -e "$WORKDIR/snap-bin" ]; then bad "a failed build removes the out-dir"; else ok "a failed build removes the out-dir"; fi

# 3e. An out-dir that cannot be created fails with exit 2.
touch "$WORKDIR/afile"
check "an out-dir under a file fails with exit 2" 2 bash "$SNAPSHOT" "$CLEAN" "$WORKDIR/afile/sub" "$DENY" "$REPO"

# 3f. The out-dir name must not break the path proof (B1). A deny-list name
# with "/" is caught only by the path proof. Fake names only.
REPO2="$WORKDIR/repo2"
mkdir -p "$REPO2/docs/zzz-note"
git -C "$REPO2" init -q
printf 'plain\n' > "$REPO2/docs/zzz-note/a.txt"
git -C "$REPO2" add docs/zzz-note/a.txt
git -C "$REPO2" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m slash
SLASH=$(git -C "$REPO2" rev-parse HEAD)
printf '\n\n' > "$REPO2/newlines.txt"
git -C "$REPO2" add newlines.txt
git -C "$REPO2" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m newlines
NLFILE=$(git -C "$REPO2" rev-parse HEAD)
DENYSLASH="$WORKDIR/denyslash.txt"
printf 'docs/zzz-note\n' > "$DENYSLASH"
check "a path proof catches a name with a slash" 2 bash "$SNAPSHOT" "$SLASH" "$WORKDIR/plain-out" "$DENYSLASH" "$REPO2"
if grep -qF 'remains in a path' "$OUTFILE"; then ok "the failure names the path leak"; else bad "the failure names the path leak"; fi
check "an out-dir name with a pipe still runs the path proof" 2 bash "$SNAPSHOT" "$SLASH" "$WORKDIR/pi|pe/out" "$DENYSLASH" "$REPO2"
if grep -qF 'remains in a path' "$OUTFILE"; then ok "the pipe out-dir failure names the path leak"; else bad "the pipe out-dir failure names the path leak"; fi
check "an out-dir name with a bracket still runs the path proof" 2 bash "$SNAPSHOT" "$SLASH" "$WORKDIR/br[ack/out" "$DENYSLASH" "$REPO2"
if grep -qF 'remains in a path' "$OUTFILE"; then ok "the bracket out-dir failure names the path leak"; else bad "the bracket out-dir failure names the path leak"; fi

# 3g. A scan error (grep exit 2) fails closed, in the text scan and in the
# path proof. The fake grep fails only for the chosen scan.
REALGREP=$(command -v grep)
FAKE1="$WORKDIR/fake1"; FAKE2="$WORKDIR/fake2"
mkdir -p "$FAKE1" "$FAKE2"
printf '#!/bin/sh\nexit 2\n' > "$FAKE1/grep"
printf '#!/bin/sh\ncase "$1" in -iF) exit 2 ;; esac\nexec %s "$@"\n' "$REALGREP" > "$FAKE2/grep"
chmod +x "$FAKE1/grep" "$FAKE2/grep"
check "a text scan error fails with exit 2" 2 env PATH="$FAKE1:$PATH" bash "$SNAPSHOT" "$CLEAN" "$WORKDIR/snap-g1" "$DENY" "$REPO"
if grep -qF 'scan failed' "$OUTFILE"; then ok "the text scan failure is named"; else bad "the text scan failure is named"; fi
check "a path proof scan error fails with exit 2" 2 env PATH="$FAKE2:$PATH" bash "$SNAPSHOT" "$CLEAN" "$WORKDIR/snap-g2" "$DENY" "$REPO"
if grep -qF 'path proof scan failed' "$OUTFILE"; then ok "the path proof failure is named"; else bad "the path proof failure is named"; fi

# 3h. A symbolic out-dir is refused.
mkdir -p "$WORKDIR/realdir"
ln -s "$WORKDIR/realdir" "$WORKDIR/linkout"
check "a symbolic out-dir fails with exit 2" 2 bash "$SNAPSHOT" "$CLEAN" "$WORKDIR/linkout" "$DENY" "$REPO"
if [ -z "$(ls -A "$WORKDIR/realdir")" ]; then ok "a symbolic out-dir target stays empty"; else bad "a symbolic out-dir target stays empty"; fi

# 3i. A file that holds only newlines is text, not binary.
check "a newline-only file is not binary" 0 bash "$SNAPSHOT" "$NLFILE" "$WORKDIR/snap-nl" "$DENY" "$REPO2"

# 3j. CDPATH must not change the out-dir test (B2). A folder on CDPATH that
# holds an empty folder with the out-dir name must not make the check pass.
mkdir -p "$WORKDIR/cdp/cdout" "$WORKDIR/cdrun"
(cd "$WORKDIR/cdrun" && CDPATH="$WORKDIR/cdp" bash "$SNAPSHOT" "$SLASH" cdout "$DENYSLASH" "$REPO2") >"$OUTFILE" 2>&1
rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'remains in a path' "$OUTFILE"; then ok "CDPATH does not change a relative out-dir"; else bad "CDPATH does not change a relative out-dir (exit $rc)"; fi

# 3k. A symbolic out-dir with trailing slashes and a symbolic parent are refused.
# Each check has its own link and target, so no result depends on order.
for k in one two par; do
  mkdir -p "$WORKDIR/k-$k-real"
  ln -s "$WORKDIR/k-$k-real" "$WORKDIR/k-$k-link"
done
check "a symbolic out-dir with a trailing slash fails with exit 2" 2 bash "$SNAPSHOT" "$CLEAN" "$WORKDIR/k-one-link/" "$DENY" "$REPO"
if [ -z "$(ls -A "$WORKDIR/k-one-real")" ]; then ok "a one-slash link target stays empty"; else bad "a one-slash link target stays empty"; fi
check "a symbolic out-dir with two trailing slashes fails with exit 2" 2 bash "$SNAPSHOT" "$CLEAN" "$WORKDIR/k-two-link//" "$DENY" "$REPO"
if [ -z "$(ls -A "$WORKDIR/k-two-real")" ]; then ok "a two-slash link target stays empty"; else bad "a two-slash link target stays empty"; fi
check "an out-dir under a symbolic parent fails with exit 2" 2 bash "$SNAPSHOT" "$CLEAN" "$WORKDIR/k-par-link/sub" "$DENY" "$REPO"
if grep -qF 'symbolic link' "$OUTFILE"; then ok "the symbolic parent failure is named"; else bad "the symbolic parent failure is named"; fi
if [ -z "$(ls -A "$WORKDIR/k-par-real")" ]; then ok "a symbolic parent target stays empty"; else bad "a symbolic parent target stays empty"; fi

# 3l. A ".." segment after a symbolic link must resolve physically (B3).
# An empty folder with the out-dir name sits next to the link. A logical cd
# would go there and hide the real target.
mkdir -p "$WORKDIR/l-far/target" "$WORKDIR/l-run/xq" "$WORKDIR/l-run/xt"
ln -s "$WORKDIR/l-far/target" "$WORKDIR/l-run/link"
check "link/../name fails with exit 2" 2 bash "$SNAPSHOT" "$CLEAN" "$WORKDIR/l-run/link/../xq" "$DENY" "$REPO"
if [ "$(ls -A "$WORKDIR/l-far")" = "target" ] && [ -z "$(ls -A "$WORKDIR/l-far/target")" ]; then ok "link/../name leaves the physical place untouched"; else bad "link/../name leaves the physical place untouched"; fi
if [ -z "$(ls -A "$WORKDIR/l-run/xq")" ]; then ok "link/../name leaves the logical folder empty"; else bad "link/../name leaves the logical folder empty"; fi
(cd "$WORKDIR/l-run/link" && bash "$SNAPSHOT" "$CLEAN" ../xt "$DENY" "$REPO") >"$OUTFILE" 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then ok "../name from a working folder behind a link fails with exit 2"; else bad "../name from a working folder behind a link fails with exit 2 (exit $rc)"; fi
if [ -z "$(ls -A "$WORKDIR/l-far/target")" ] && [ "$(ls -A "$WORKDIR/l-far")" = "target" ]; then ok "the working-folder case leaves the targets untouched"; else bad "the working-folder case leaves the targets untouched"; fi

# 4. An empty deny list builds an unredacted snapshot and says so.
: > "$WORKDIR/empty.txt"
check "an empty deny list builds a snapshot" 0 bash "$SNAPSHOT" "$CLEAN" "$WORKDIR/snap-empty" "$WORKDIR/empty.txt" "$REPO"
if grep -qF 'NOTE: the deny list is empty' "$OUTFILE"; then ok "an empty deny list prints a note"; else bad "an empty deny list prints a note"; fi

echo
echo "source-snapshot test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
