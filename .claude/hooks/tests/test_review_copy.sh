#!/bin/bash
# Light review copies (me2resh/apexyard#2070): shallow, one folder, one record each.
# shellcheck source=/dev/null
# shellcheck disable=SC2016
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-copy.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
SCRIPT="$ROOT/.claude/skills/code-review/review-copy.sh"
PASS=0 FAIL=0
check() { local l=$1; shift; if "$@" >"$TMP/out" 2>&1; then printf 'PASS: %s\n' "$l"; PASS=$((PASS+1)); else printf 'FAIL: %s\n' "$l"; sed 's/^/  /' "$TMP/out"; FAIL=$((FAIL+1)); fi; }
rejects() { ! "$@"; }
eq() { [ "$1" = "$2" ]; }

export APEXYARD_REVIEW_COPY_ROOT="$TMP/copies"
export CLAUDE_CODE_SESSION_ID="sess-test-1"
SRC="$TMP/src"
git init -q "$SRC"
git -C "$SRC" config user.email t@example.com
git -C "$SRC" config user.name t
for i in 1 2 3; do echo "$i" > "$SRC/f.txt"; git -C "$SRC" add f.txt; git -C "$SRC" commit -q -m "c$i"; done
SHA=$(git -C "$SRC" rev-parse HEAD)
git -C "$SRC" update-ref refs/pull/7/head "$SHA"
URL="file://$SRC"

COPY=$("$SCRIPT" create "$URL" upstream/demo 7 "$SHA" 2>/dev/null)
check "create prints a path under the root" eq "$COPY" "$(cd "$TMP" && pwd -P)/copies/upstream__demo-pr7"
check "copy is at the PR head" eq "$(git -C "$COPY" rev-parse HEAD)" "$SHA"
check "copy is shallow with one commit" eq "$(git -C "$COPY" rev-list --count HEAD)" 1
check "copy has an origin remote" eq "$(git -C "$COPY" remote get-url origin)" "$URL"
check "git directory is a real directory" test -d "$COPY/.git" -a ! -L "$COPY/.git"
check "record names PR, session, time and sha" jq -e ".pr==7 and .session==\"sess-test-1\" and .head_sha==\"$SHA\" and (.created_at|test(\"^[0-9]{4}-.*Z\$\"))" "$COPY/.git/apexyard-review-copy.json"
check "work tree stays clean" eq "$(git -C "$COPY" status --porcelain)" ""
check "list shows the copy" eq "$("$SCRIPT" list | jq -r .path)" "$COPY"
check "create twice is refused" rejects "$SCRIPT" create "$URL" upstream/demo 7 "$SHA"
check "sha mismatch is refused" rejects "$SCRIPT" create "$URL" upstream/demo 8 deadbeef
check "sha mismatch leaves no folder" test ! -e "$TMP/copies/upstream__demo-pr8"
for repo in demo /demo owner/ a/b/c 'a b/c' 'a/b$' ''; do
  check "bad repo '$repo' is refused" rejects "$SCRIPT" create "$URL" "$repo" 7
done
check "record stores owner/name" jq -e '.repo=="upstream/demo"' "$COPY/.git/apexyard-review-copy.json"
FORK=$("$SCRIPT" create "$URL" fork/demo 7 "$SHA" 2>/dev/null)
check "fork gets its own folder" eq "$FORK" "${COPY%/*}/fork__demo-pr7"
check "upstream still exists" test -d "$COPY"
check "remove fork" "$SCRIPT" remove "$FORK"
jq '.repo="demo"' "$COPY/.git/apexyard-review-copy.json" > "$TMP/old-record"
cp "$TMP/old-record" "$COPY/.git/apexyard-review-copy.json"
check "old repo reads as unknown" eq "$("$SCRIPT" list | jq -r .repo)" unknown
ln -s "$COPY" "$TMP/copies/link"
check "remove refuses symlink copy" rejects "$SCRIPT" remove "$TMP/copies/link/"
mkdir -p "$TMP/copies/nested/child/.git"
cp "$TMP/old-record" "$TMP/copies/nested/child/.git/apexyard-review-copy.json"
check "remove refuses nested copy" rejects "$SCRIPT" remove "$TMP/copies/nested/child"
ln -s "$TMP/copies" "$TMP/link-root"
mkdir -m 777 "$TMP/unsafe-root"
chmod 777 "$TMP/unsafe-root"
for unsafe in "$TMP/link-root" "$TMP/unsafe-root"; do
  for action in create list remove; do
    case "$action" in
      create) args=("$URL" owner/demo 7) ;;
      list) args=() ;;
      remove) args=("$COPY") ;;
    esac
    check "$action refuses unsafe root $unsafe" rejects env APEXYARD_REVIEW_COPY_ROOT="$unsafe" "$SCRIPT" "$action" ${args[@]+"${args[@]}"}
  done
done
check "missing pull ref is refused" rejects "$SCRIPT" create "$URL" upstream/demo 99
check "missing pull ref leaves no folder" test ! -e "$TMP/copies/upstream__demo-pr99"
mkdir -p "$TMP/copies/plain/.git"
check "remove refuses a folder with no record" rejects "$SCRIPT" remove "$TMP/copies/plain"
check "remove refuses a path outside the root" rejects "$SCRIPT" remove "$SRC"
check "remove deletes a recorded copy" "$SCRIPT" remove "$COPY"
check "removed copy is gone" test ! -e "$COPY"
check "default root ends in apexyard-review-copies" bash -c 'unset APEXYARD_REVIEW_COPY_ROOT; case "$("$0" root)" in */apexyard-review-copies) exit 0;; *) exit 1;; esac' "$SCRIPT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
