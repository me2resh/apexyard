#!/bin/bash
# Tests for the merge-gate PR metadata snapshot (AgDR-0256,
# me2resh/apexyard#1759).
#
# The dispatcher fetches the PR metadata one time, exports the trusted
# scalars to the four merge gates, keeps only a digest-checked file list on
# disk, and reads the head SHA again after the gates pass.
#
# Layer A runs the REAL dispatcher with the REAL four merge gates in a
# sandbox ops root. The other always-on hooks are stubs. A `gh` shim logs
# each call and returns fixed data. Layer B calls the library readers
# directly from a child process whose parent PID is the snapshot owner.
# Layer C makes fault copies of dispatch-bash.sh at test time, from the
# real file, at named anchors. No fault copy is checked in.
#
# The D9 test numbers of AgDR-0256 are in the case labels.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_HOOKS="$(cd "$(dirname "$0")/.." && pwd)"
SRC_ROOT="$(cd "$SRC_HOOKS/../.." && pwd)"
BASH_BIN="${BASH:-/bin/bash}"

PASS=0
FAIL=0
pass() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
fail() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/prmeta-test.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

HEAD_A="1111111111111111111111111111111111111111"
HEAD_B="2222222222222222222222222222222222222222"
REPO="acme/app"
PRN=42

# Hooks that the dispatcher runs on a merge command but that are not under
# test. The sandbox replaces them with a stub that exits 0.
STUBS='block-ambient-tracker-repo.sh block-privileged-escalation.sh require-skill-for-issue-create.sh require-orbit-slice-for-ticket.sh require-migration-ticket.sh require-active-ticket.sh warn-review-marker-write.sh warn-isolated-build-risk.sh block-reviewer-repo-mutation.sh block-reviewer-ci-wait.sh block-forged-menu-approval.sh block-private-refs-in-public-repos.sh block-git-add-all.sh block-main-push.sh validate-branch-name.sh pre-push-gate.sh block-agent-routing-drift.sh check-secrets.sh block-onboarding-in-git.sh verify-commit-refs.sh validate-commit-format.sh require-agdr-for-arch-changes.sh warn-bootstrap-scope.sh'

# --- sandbox ----------------------------------------------------------------

make_template() {
  local sb="$WORK/template" s
  mkdir -p "$sb/gitdir/objects" "$sb/gitdir/refs/heads" "$sb/.claude/session/reviews" "$sb/bin" "$sb/tmp"
  printf 'ref: refs/heads/main\n' > "$sb/gitdir/HEAD"
  printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n' > "$sb/gitdir/config"
  (
    cd "$sb" || exit 1
    export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
    git config user.email test@example.com
    git config user.name test
    : > onboarding.yaml
    : > .apexyard-fork
    git add onboarding.yaml .apexyard-fork
    git commit -q -m init
  ) || return 1
  mkdir -p "$sb/.claude/hooks"
  for s in "$SRC_HOOKS"/*.sh; do
    cp "$s" "$sb/.claude/hooks/"
  done
  [ -f "$SRC_ROOT/.claude/project-config.defaults.json" ] \
    && cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/"
  for s in $STUBS; do
    printf '#!/bin/bash\ncat >/dev/null\nexit 0\n' > "$sb/.claude/hooks/$s"
  done
  chmod +x "$sb/.claude/hooks/"*.sh
  # Bash 3.2 runs the dispatcher when the test runs under /bin/bash.
  ln -s "$BASH_BIN" "$sb/bin/bash"

  # The gh shim. T_* variables choose the answers. Every call is logged.
  cat > "$sb/bin/gh" <<'EOF'
#!/bin/bash
sb=${0%/bin/gh}
printf '%s\n' "$*" >> "$sb/gh.log"
args="$*"
files() { cat "$sb/files.txt"; }
case "$args" in
  "pr view "*"--json headRefOid,headRefName,baseRefName,changedFiles"*)
    [ "${T_VIEW:-ok}" = fail ] && exit 1
    printf '{"headRefOid":"%s","headRefName":"%s","baseRefName":"dev","changedFiles":%s}\n' \
      "${T_HEAD}" "${T_BRANCH:-feature/GH-42-x}" "${T_COUNT}"
    ;;
  "pr view "*"--json headRefOid -q .headRefOid"*)
    case "${T_RECHECK:-same}" in
      same) echo "$T_HEAD" ;;
      moved) echo "${T_HEAD_NEW}" ;;
      fail) exit 1 ;;
      bad) echo "not-a-sha" ;;
    esac
    ;;
  "pr view "*"headRefOid"*) echo "$T_HEAD" ;;
  "pr view "*"headRefName"*) echo "${T_BRANCH:-feature/GH-42-x}" ;;
  "pr view "*"baseRefName"*) echo dev ;;
  "pr view "*"mergeStateStatus"*) echo CLEAN ;;
  "pr view "*"headRepository"*) echo "acme/app" ;;
  "pr checks "*)
    if [ "${T_CHECKS:-pass}" = none ]; then
      echo "no checks reported on the 'feature' branch"; exit 1
    fi
    printf 'build\tpass\t1m\thttps://x\n'
    ;;
  *"--paginate"*"/files?per_page=100"*)
    case "${T_FILES_MODE:-ok}" in
      ok) files ;;
      fail) exit 1 ;;
      empty) : ;;
      short) files | sed -n 1p ;;
      prefetch_only_empty)
        if [ ! -f "$sb/files.once" ]; then : > "$sb/files.once"; else files; fi ;;
    esac
    ;;
  "api repos/"*"/pulls/"[0-9]*" --jq .changed_files"*) echo "${T_COUNT_GATE:-$T_COUNT}" ;;
  *"actions/workflows"*) echo '{"total_count":0,"workflows":[]}' ;;
  *"actions/runs?head_sha="*)
    echo '{"total_count":1,"workflow_runs":[{"event":"pull_request","workflow_id":1,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":"Build PR","status":"completed","conclusion":"success"}]}'
    ;;
  *"compare/"*) echo 0 ;;
  *) ;;
esac
exit 0
EOF
  chmod +x "$sb/bin/gh"
  # An rm shim that can fail on purpose (D9 test 15).
  cat > "$sb/bin/rm" <<'EOF'
#!/bin/bash
if [ "${T_RM_FAIL:-0}" = 1 ]; then exit 1; fi
exec /bin/rm "$@"
EOF
  chmod +x "$sb/bin/rm"
  echo "$sb"
}

TEMPLATE=$(make_template) || { echo "FAIL: cannot build sandbox" >&2; exit 1; }

# new_sb <files...>: copy the template and write the PR file list.
new_sb() {
  local sb
  sb=$(mktemp -d "$WORK/sb.XXXXXX")
  cp -R "$TEMPLATE/." "$sb/"
  : > "$sb/files.txt"
  for f in "$@"; do printf '%s\n' "$f" >> "$sb/files.txt"; done
  echo "$sb"
}

# tmp_has <sb> <glob>: true when the sandbox TMPDIR holds a matching entry.
tmp_has() {
  [ -n "$(find "$1/tmp" -mindepth 1 -maxdepth 1 -name "$2" 2>/dev/null)" ]
}

marker() { # marker <sb> <role> <sha>
  local name
  name=".claude/session/reviews/acme__app__${PRN}-$2.approved"
  if [ "$2" = ceo ]; then
    printf 'sha=%s\napproved_by=user\napproved_at=2026-10-19T00:00:00Z\nskill_version=2\napproval_summary="t"\n' "$3" > "$1/$name"
  else
    printf '%s\n' "$3" > "$1/$name"
  fi
}

# dispatch <sb> <command>: run the sandbox dispatcher. Sets RC, ERR, CALLS.
dispatch() {
  local sb="$1" cmd="$2" input
  input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  : > "$sb/gh.log"
  ERR=$(cd "$sb" && printf '%s' "$input" | env GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" \
    TMPDIR="$sb/tmp" PATH="$sb/bin:$PATH" "$BASH_BIN" "$sb/.claude/hooks/dispatch-bash.sh" 2>&1 >/dev/null)
  RC=$?
  CALLS=$(wc -l < "$sb/gh.log" | tr -d ' ')
}

MERGE="gh pr merge $PRN --repo $REPO --merge"
SQUASH="gh pr merge $PRN --repo $REPO --squash"

export T_HEAD="$HEAD_A" T_HEAD_NEW="$HEAD_B" T_COUNT=1

echo ""
echo "A) Real dispatcher, real gates"

# D9 1: cache hit, plain merge, checks present -> 5 calls, exit 0.
sb=$(new_sb src/server/main.go)
marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"
dispatch "$sb" "$MERGE"
if [ "$RC" = 0 ] && [ "$CALLS" = 5 ]; then pass "1 hit, plain merge, checks: 5 calls"; else fail "1 plain" "rc=$RC calls=$CALLS err=${ERR:0:400}"; fi
# D9 25: normal pass exits 0 (completion flag set on the normal path).
[ "$RC" = 0 ] && pass "25 normal pass exits 0" || fail "25" "rc=$RC"
# D9 22: no apexyard-pr-files.* temp file and no snapshot dir left behind.
if tmp_has "$sb" 'apexyard-pr-files*' || tmp_has "$sb" 'apexyard-prmeta*'; then fail "22 temp files" "$(ls "$sb/tmp")"; else pass "22 no temp file list left in TMPDIR"; fi

# D9 1: no checks -> 6 calls.
sb=$(new_sb src/server/main.go)
marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"
T_CHECKS=none dispatch "$sb" "$MERGE"
if [ "$RC" = 0 ] && [ "$CALLS" = 6 ]; then pass "1 hit, no checks: 6 calls"; else fail "1 no checks" "rc=$RC calls=$CALLS err=${ERR:0:400}"; fi

# D9 1: squash merge, UI and design files, markers present -> 5 calls.
sb=$(new_sb src/components/Button.tsx docs/tech-design.md)
marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"; marker "$sb" design "$HEAD_A"; marker "$sb" architecture "$HEAD_A"
T_COUNT=2 dispatch "$sb" "$SQUASH"
if [ "$RC" = 0 ] && [ "$CALLS" = 5 ]; then pass "1 hit, squash, UI + design: 5 calls"; else fail "1 squash" "rc=$RC calls=$CALLS err=${ERR:0:400}"; fi
# Paired unsafe case: the same PR with no design marker still blocks.
sb=$(new_sb src/components/Button.tsx docs/tech-design.md)
marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"; marker "$sb" architecture "$HEAD_A"
T_COUNT=2 dispatch "$sb" "$SQUASH"
if [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -q 'design'; then pass "1 unsafe pair: UI PR with no design marker blocks on a hit"; else fail "1 unsafe pair" "rc=$RC err=${ERR:0:300}"; fi
# Paired unsafe case: stale Rex marker still blocks on a hit.
sb=$(new_sb src/server/main.go)
marker "$sb" rex "$HEAD_B"; marker "$sb" ceo "$HEAD_A"
dispatch "$sb" "$MERGE"
[ "$RC" = 2 ] && pass "1 unsafe pair: stale Rex marker blocks on a hit" || fail "1 stale rex" "rc=$RC"

# D9 10: head moves between prefetch and recheck -> exit 2, HEAD moved.
sb=$(new_sb src/server/main.go)
marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"
T_RECHECK=moved dispatch "$sb" "$MERGE"
if [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -q 'HEAD moved during gate evaluation' && printf '%s' "$ERR" | grep -q "$HEAD_B"; then pass "10 head moved -> exit 2"; else fail "10" "rc=$RC err=${ERR:0:300}"; fi

# D9 11: recheck call fails, or returns a bad SHA -> exit 2.
for mode in fail bad; do
  sb=$(new_sb src/server/main.go)
  marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"
  T_RECHECK=$mode dispatch "$sb" "$MERGE"
  if [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -q 'could not confirm PR #42 HEAD'; then pass "11 recheck $mode -> exit 2"; else fail "11 $mode" "rc=$RC err=${ERR:0:300}"; fi
done

# D9 12: a non-merge gh api call makes no prefetch call.
sb=$(new_sb src/server/main.go)
dispatch "$sb" "gh api repos/acme/app/pulls/42/comments"
if ! grep -q 'changedFiles' "$sb/gh.log"; then pass "12 non-merge gh api: no prefetch"; else fail "12" "$(cat "$sb/gh.log")"; fi

# No --repo, a variable target, or glab: no prefetch, no recheck.
for cmd in "gh pr merge 42 --merge" 'gh pr merge $PR --repo acme/app' "glab mr merge 42 -R acme/app" "gh pr merge 42 --repo acme/app --repo other/app"; do
  sb=$(new_sb src/server/main.go)
  dispatch "$sb" "$cmd"
  if ! grep -q 'changedFiles' "$sb/gh.log" && ! grep -q -- '-q .headRefOid' "$sb/gh.log"; then pass "D1 no prefetch: $cmd"; else fail "D1 $cmd" "$(cat "$sb/gh.log")"; fi
done

# D9 13: a gate exits 2 -> dispatcher exits 2 (no markers at all).
sb=$(new_sb src/server/main.go)
dispatch "$sb" "$MERGE"
[ "$RC" = 2 ] && pass "13 gate exit 2 stays 2" || fail "13" "rc=$RC"

# D9 14: prefetch fails (gh fails, or mktemp has no TMPDIR): gates fetch.
sb=$(new_sb src/server/main.go)
marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"
T_VIEW=fail dispatch "$sb" "$MERGE"
if [ "$RC" = 0 ] && grep -q 'headRefOid --jq' "$sb/gh.log" && ! grep -q -- '-q .headRefOid' "$sb/gh.log"; then pass "14 prefetch gh fails: gates fetch, no recheck"; else fail "14 gh" "rc=$RC log=$(tr '\n' '|' < "$sb/gh.log")"; fi
sb=$(new_sb src/server/main.go)
marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"
rmdir "$sb/tmp"; : > "$sb/tmp"
dispatch "$sb" "$MERGE"
if [ "$RC" = 0 ] && [ "$(grep -c 'pulls/42/files' "$sb/gh.log")" = 3 ]; then pass "14 mktemp fails: scalars stay, gates fetch the list"; else fail "14 mktemp" "rc=$RC calls=$CALLS err=${ERR:0:300}"; fi

# D9 15: the trap cannot remove the directory: exit status does not change.
sb=$(new_sb src/server/main.go)
marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"
T_RM_FAIL=1 dispatch "$sb" "$MERGE"
[ "$RC" = 0 ] && pass "15 rm fails, pass stays 0" || fail "15 pass" "rc=$RC"
sb=$(new_sb src/server/main.go)
T_RM_FAIL=1 dispatch "$sb" "$MERGE"
[ "$RC" = 2 ] && pass "15 rm fails, block stays 2" || fail "15 block" "rc=$RC"

# D9 20: COUNT=0 -> no file list; the gates fetch and block on the empty list.
sb=$(new_sb)
marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"
T_COUNT=0 dispatch "$sb" "$MERGE"
if [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -q "could not determine the PR's changed files"; then pass "20 COUNT=0 blocks"; else fail "20 count0" "rc=$RC err=${ERR:0:300}"; fi
# D9 20 (F1): files call gives exit 0 and empty output with changedFiles=1.
sb=$(new_sb src/server/main.go)
marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"
T_FILES_MODE=empty dispatch "$sb" "$MERGE"
if [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -q "could not determine the PR's changed files" && ! tmp_has "$sb" 'apexyard-prmeta*'; then pass "20 empty list: no file, gate blocks"; else fail "20 empty" "rc=$RC err=${ERR:0:300}"; fi

# D9 21: scalars pass, file list fails: gates fetch only the list.
sb=$(new_sb src/server/main.go)
marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"
T_FILES_MODE=prefetch_only_empty dispatch "$sb" "$MERGE"
if [ "$RC" = 0 ] && ! grep -q 'headRefOid --jq' "$sb/gh.log" && [ "$(grep -c 'pulls/42 --jq .changed_files' "$sb/gh.log")" = 2 ]; then pass "21 list fails, scalars still used"; else fail "21" "rc=$RC log=$(tr '\n' '|' < "$sb/gh.log")"; fi

# D9 27: files response line count differs from COUNT -> no file written.
sb=$(new_sb src/server/main.go docs/readme.txt)
marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"
T_COUNT=2 T_FILES_MODE=short T_COUNT_GATE=2 dispatch "$sb" "$MERGE"
if [ "$(grep -c 'pulls/42 --jq .changed_files' "$sb/gh.log")" = 2 ] && ! tmp_has "$sb" 'apexyard-prmeta*'; then pass "27 writer count check: no file, gates fetch"; else fail "27" "rc=$RC log=$(tr '\n' '|' < "$sb/gh.log")"; fi

# D9 28: HOST/OWNER/REPO passes --hostname HOST to gh api.
sb=$(new_sb src/server/main.go)
dispatch "$sb" "gh pr merge 42 --repo ghe.example.com/acme/app --merge"
if grep -q -- '--hostname ghe.example.com --paginate repos/acme/app/pulls/42/files' "$sb/gh.log" \
  && grep -q -- 'pr view 42 --repo ghe.example.com/acme/app --json headRefOid,headRefName' "$sb/gh.log"; then
  pass "28 enterprise host split"
else
  fail "28" "$(tr '\n' '|' < "$sb/gh.log")"
fi

# D9 8: APEXYARD_PRMETA_* set before the dispatcher starts are removed.
sb=$(new_sb src/server/main.go)
cat > "$sb/.claude/hooks/block-unreviewed-merge.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
env | grep '^APEXYARD_PRMETA_' > "${0%/.claude/hooks/*}/seen.env"
exit 2
EOF
chmod +x "$sb/.claude/hooks/block-unreviewed-merge.sh"
APEXYARD_PRMETA_HEAD=$HEAD_B APEXYARD_PRMETA_OWNER_PID=1 APEXYARD_PRMETA_EXTRA_SEAM=1 dispatch "$sb" "gh pr merge 42 --merge"
if [ -f "$sb/seen.env" ] && [ ! -s "$sb/seen.env" ]; then pass "8 inherited APEXYARD_PRMETA_* removed"; else fail "8" "$(cat "$sb/seen.env" 2>/dev/null)"; fi

# D9 32: inherited control variables.
sb=$(new_sb src/server/main.go)
mkdir -p "$WORK/victim"
marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"
_prmeta_dir="$WORK/victim" _prmeta_have_snapshot=1 dispatch "$sb" "$MERGE"
if [ -d "$WORK/victim" ] && [ "$RC" = 0 ]; then pass "32 inherited _prmeta_dir and _prmeta_have_snapshot ignored"; else fail "32 dir" "rc=$RC victim=$([ -d "$WORK/victim" ] && echo kept || echo removed)"; fi

echo ""
echo "B) Library readers"

LIB="$TEMPLATE/.claude/hooks/_lib-extract-pr.sh"
READER="$WORK/reader.sh"
cat > "$READER" <<EOF
#!/bin/bash
. "$TEMPLATE/.claude/hooks/_lib-awk-fallback.sh"
. "$LIB"
"\$@"
EOF

# owned <cmd...>: run a reader in a child whose parent PID is the owner.
owned() {
  "$BASH_BIN" -c 'export APEXYARD_PRMETA_OWNER_PID=$$; "$0" "$@"; exit $?' "$BASH_BIN" "$READER" "$@"
}
# write_list <dir> <list>: the dispatcher writer's canonical bytes.
write_list() {
  mkdir -p "$1"; chmod 700 "$1"
  printf '%s\n' "$2" > "$1/files"
}
digest_of() { printf '%s\n' "$1" | "$BASH_BIN" "$READER" prmeta_sha256; }

LIST=$(printf 'src/a.go\nsrc/b.go')
D="$WORK/d1"
write_list "$D" "$LIST"
snap() {
  local sum
  sum=$(digest_of "$LIST")
  export APEXYARD_PRMETA_REPO=$REPO APEXYARD_PRMETA_PR=$PRN APEXYARD_PRMETA_HEAD=$HEAD_A \
    APEXYARD_PRMETA_BRANCH=feature/x APEXYARD_PRMETA_BASE=dev APEXYARD_PRMETA_COUNT=2 \
    APEXYARD_PRMETA_DIR="$D" APEXYARD_PRMETA_FILES_SHA256="$sum"
}
snap

got=$(owned prmeta_get head $PRN $REPO) && [ "$got" = "$HEAD_A" ] && pass "B hit head" || fail "B hit head" "$got"
got=$(owned prmeta_file_list $PRN $REPO) && [ "$got" = "$LIST" ] && pass "B hit file list" || fail "B hit list" "$got"

# D9 2: wrong repo or PR.
owned prmeta_get head $PRN other/app >/dev/null && fail "2 wrong repo" "hit" || pass "2 wrong repo -> miss"
owned prmeta_get head 43 $REPO >/dev/null && fail "2 wrong pr" "hit" || pass "2 wrong PR -> miss"
# D9 3: no snapshot.
( unset APEXYARD_PRMETA_OWNER_PID APEXYARD_PRMETA_HEAD; "$BASH_BIN" "$READER" prmeta_get head $PRN $REPO >/dev/null ) && fail "3" "hit" || pass "3 no snapshot -> miss"
# D9 9: forged values with a wrong OWNER_PID (a direct gate run).
APEXYARD_PRMETA_OWNER_PID=1 "$BASH_BIN" "$READER" prmeta_get head $PRN $REPO >/dev/null && fail "9" "hit" || pass "9 wrong OWNER_PID -> miss"
# D9 4: invalid values.
for bad in "APEXYARD_PRMETA_HEAD=XYZ" "APEXYARD_PRMETA_HEAD=${HEAD_A}0" "APEXYARD_PRMETA_COUNT=3001" "APEXYARD_PRMETA_COUNT=2x" "APEXYARD_PRMETA_COUNT=02" "APEXYARD_PRMETA_BRANCH=" "APEXYARD_PRMETA_BASE=$(printf 'a\tb')"; do
  if env "$bad" "$BASH_BIN" -c 'export APEXYARD_PRMETA_OWNER_PID=$$; "$0" "$@"; exit $?' "$BASH_BIN" "$READER" prmeta_get head $PRN $REPO >/dev/null; then
    fail "4 invalid $bad" "hit"
  else
    pass "4 invalid ${bad%%=*} -> miss"
  fi
done
# D9 5 / 17: file rewritten after the write -> digest fails.
printf 'src/a.go\nsrc/c.go\n' > "$D/files"
owned prmeta_file_list $PRN $REPO >/dev/null && fail "5 rewrite" "hit" || pass "5/17 rewritten file -> miss"
# Appended NUL bytes and newlines change nothing: the reader uses what it hashed.
write_list "$D" "$LIST"; printf '\n\n' >> "$D/files"
got=$(owned prmeta_file_list $PRN $REPO) && [ "$got" = "$LIST" ] && pass "19 trailing newlines stripped, same value" || fail "19 trailing" "$got"
# D9 6: line count differs from COUNT (a valid digest of a 3-line list).
L3=$(printf 'a\nb\nc'); write_list "$D" "$L3"
APEXYARD_PRMETA_FILES_SHA256=$(digest_of "$L3") owned prmeta_file_list $PRN $REPO >/dev/null && fail "6" "hit" || pass "6 line count differs -> miss"
write_list "$D" "$LIST"
# D9 7: directory is a symlink, or mode is not 0700.
ln -s "$D" "$WORK/dlink"
APEXYARD_PRMETA_DIR="$WORK/dlink" owned prmeta_file_list $PRN $REPO >/dev/null && fail "7 symlink" "hit" || pass "7 symlinked dir -> miss"
chmod 755 "$D"
owned prmeta_file_list $PRN $REPO >/dev/null && fail "7 mode" "hit" || pass "7 dir mode 0755 -> miss"
chmod 700 "$D"
if [ "$(id -u)" = 0 ]; then pass "7 foreign owner (skipped as root)"; else
  # /tmp-like dirs owned by root fail the owner check.
  APEXYARD_PRMETA_DIR=/ owned prmeta_file_list $PRN $REPO >/dev/null && fail "7 owner" "hit" || pass "7 foreign-owned dir -> miss"
fi
# D9 19: FIFO, symlink to /dev/zero, larger than 4 MiB -> no hang, miss.
D2="$WORK/d2"; mkdir -p "$D2"; chmod 700 "$D2"
mkfifo "$D2/files"
APEXYARD_PRMETA_DIR="$D2" owned prmeta_file_list $PRN $REPO >/dev/null && fail "19 fifo" "hit" || pass "19 FIFO -> miss, no hang"
rm -f "$D2/files"; ln -s /dev/zero "$D2/files"
APEXYARD_PRMETA_DIR="$D2" owned prmeta_file_list $PRN $REPO >/dev/null && fail "19 zero" "hit" || pass "19 symlink to /dev/zero -> miss"
rm -f "$D2/files"
BIG=$(head -c 4194400 /dev/zero | tr '\0' 'a')
printf '%s\n' "$BIG" > "$D2/files"
APEXYARD_PRMETA_DIR="$D2" APEXYARD_PRMETA_COUNT=1 APEXYARD_PRMETA_FILES_SHA256=$(digest_of "$BIG") \
  owned prmeta_file_list $PRN $REPO >/dev/null && fail "19 big" "hit" || pass "19 file over 4 MiB -> miss"
unset BIG
# D9 20: an empty file with a valid digest of printf '%s\n' "" is a miss.
printf '\n' > "$D2/files"
APEXYARD_PRMETA_DIR="$D2" APEXYARD_PRMETA_COUNT=1 APEXYARD_PRMETA_FILES_SHA256=$(digest_of "") \
  owned prmeta_file_list $PRN $REPO >/dev/null && fail "20 empty" "hit" || pass "20 empty file with valid digest -> miss"
APEXYARD_PRMETA_COUNT=0 owned prmeta_file_list $PRN $REPO >/dev/null && fail "20 count0" "hit" || pass "20 COUNT=0 -> miss"

# D9 18: writer and reader agree on the digest, over the whole file.
# The dispatcher writer hashes printf '%s\n' "$L" in memory. Compare that
# with an independent SHA-256 of every byte that the writer put on disk.
for case_list in "one/path.go" "$(printf 'a/1\nb/2\nc/3\nd/4')" "$(printf 'x/1\ny/2\n')" "$(printf 'p q/r s.md\nt\xc3\xa9st/u.go')"; do
  D3="$WORK/d3"; rm -rf "$D3"; write_list "$D3" "$case_list"
  w=$(printf '%s\n' "$case_list" | "$BASH_BIN" "$READER" prmeta_sha256)
  f=$( (command -v shasum >/dev/null && shasum -a 256 < "$D3/files" || sha256sum < "$D3/files") | awk '{print $1}')
  n=$(printf '%s\n' "$case_list" | wc -l | tr -d ' ')
  r=$(APEXYARD_PRMETA_DIR="$D3" APEXYARD_PRMETA_COUNT="$n" APEXYARD_PRMETA_FILES_SHA256="$w" owned prmeta_file_list $PRN $REPO)
  if [ "$w" = "$f" ] && [ "$r" = "$case_list" ]; then pass "18 digest agrees ($n lines)"; else fail "18 ($n lines)" "w=$w f=$f r=$r"; fi
done
# Digest of a prefix must not match the whole file.
D3="$WORK/d3"; rm -rf "$D3"; write_list "$D3" "$(printf 'a\nb')"; printf 'c\n' >> "$D3/files"
APEXYARD_PRMETA_DIR="$D3" APEXYARD_PRMETA_COUNT=2 APEXYARD_PRMETA_FILES_SHA256=$(digest_of "$(printf 'a\nb')") \
  owned prmeta_file_list $PRN $REPO >/dev/null && fail "18 prefix" "hit" || pass "18 digest covers the whole file, not a prefix"

# D9 16: a 3000-path list stays out of the environment.
sb=$(new_sb)
i=1; while [ "$i" -le 3000 ]; do printf 'very/long/directory/name/for/the/test/of/the/environment/limit/file-%04d.go\n' "$i"; i=$((i + 1)); done > "$sb/files.txt"
cat > "$sb/.claude/hooks/block-unreviewed-merge.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
env > "${0%/.claude/hooks/*}/seen.env"
exit 2
EOF
chmod +x "$sb/.claude/hooks/block-unreviewed-merge.sh"
T_COUNT=3000 dispatch "$sb" "$MERGE"
envsize=$(wc -c < "$sb/seen.env" | tr -d ' ')
if grep -q '^APEXYARD_PRMETA_DIR=' "$sb/seen.env" && ! grep -q 'file-0001.go' "$sb/seen.env" && [ "$envsize" -lt 131072 ]; then pass "16 3000 paths stay out of the environment"; else fail "16" "size=$envsize"; fi

# D9 26: hit-path final guard. A list that the reader rejects (empty, or
# COUNT above 3000) leads to a fetch, and the gate blocks on the bad data.
sb=$(new_sb)
marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"
T_COUNT=3001 dispatch "$sb" "$MERGE"
if [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -q "could not determine the PR's changed files"; then pass "26 COUNT above 3000 blocks"; else fail "26 3001" "rc=$RC err=${ERR:0:300}"; fi

echo ""
echo "C) Fault copies of the real dispatcher"

# fault <sb> <anchor> <line>: edit the sandbox copy of the dispatcher and
# insert <line> after the first line that starts with the literal <anchor>.
fault() {
  local sb="$1" anchor="$2" line="$3" f="$1/.claude/hooks/dispatch-bash.sh"
  # An anchor that starts with "<" inserts the line BEFORE the anchor line.
  awk -v a="$anchor" -v l="$line" 'BEGIN{d=0; b=0; if (substr(a,1,1) == "<") { b=1; a=substr(a,2) } }
    (!d && index($0, a) == 1 && b){print l; d=1}
    {print}
    (!d && index($0, a) == 1 && !b){print l; d=1}
    END{if(!d) exit 3}' "$f" > "$f.new" \
    || return 1
  mv "$f.new" "$f"; chmod +x "$f"
}
faultcase() { # faultcase <label> <anchor> <line> [env...]
  local label="$1" anchor="$2" line="$3"; shift 3
  sb=$(new_sb src/server/main.go)
  marker "$sb" rex "$HEAD_A"; marker "$sb" ceo "$HEAD_A"
  if ! fault "$sb" "$anchor" "$line"; then fail "$label" "anchor not found: $anchor"; return; fi
  if [ "$#" -gt 0 ]; then
    # shellcheck disable=SC2163
    ( export "$@"; dispatch "$sb" "$MERGE"; echo "$RC" > "$sb/rc" )
    RC=$(cat "$sb/rc")
  else
    dispatch "$sb" "$MERGE"
  fi
  [ "$RC" = 2 ] && pass "$label -> exit 2" || fail "$label" "rc=$RC err=${ERR:0:200}"
}
A_PRE='prefetch_pr_metadata() {'
A_RE='recheck_pr_head() {'
A_D1='<  if has_conflicting_repo_flags "$cmd"; then'
A_TRAP="  trap '_rc="

faultcase "23 unset read in prefetch (f || true)"   "$A_PRE" '  : "$T_UNSET_1759"'
faultcase "23b unset read in an if condition"         "$A_PRE" '  if [ -n "$T_UNSET_1759" ]; then :; fi'
faultcase "23c unset read in an && list"              "$A_PRE" '  [ -n "$T_UNSET_1759" ] && :'
faultcase "24 unset read in the recheck"              "$A_RE"  '  : "$T_UNSET_1759"'
faultcase "30 bare grep -qE no match in the recheck"  "$A_RE"  '  grep -qE zzz_no_match /dev/null'
faultcase "30b bare failing capture in the recheck"   "$A_RE"  '  _h=$(false)'
faultcase "30c pipefail abort in the recheck"         "$A_RE"  '  false | cat'
faultcase "31 unset read in the D1 checks"            "$A_D1"  '  : "$T_UNSET_1759"'
faultcase "31c unset read in a D1 condition"          "$A_D1"  '  if [ "$T_UNSET_1759" = x ]; then :; fi'
faultcase "31b unset read right after the trap"       "$A_TRAP" '  : "$T_UNSET_1759"'
faultcase "32 inherited _dispatch_complete=1 + crash" "$A_PRE" '  : "$T_UNSET_1759"' _dispatch_complete=1

echo ""
echo "D) Static checks"

DISPATCH="$SRC_HOOKS/dispatch-bash.sh"
# D9 33: every exit in the dispatcher is `exit 2`, except the trap's own
# `exit "$_rc"`. A planned exit 0 would need _dispatch_complete=1 first.
bad_exits=$(grep -n -E '(^|[;&|[:space:]])exit([[:space:]]|$|;)' "$DISPATCH" | grep -v -E '^[0-9]+:[[:space:]]*#' \
  | grep -v -E 'exit 2([^0-9]|$)' | grep -v -F 'exit "$_rc"' || true)
[ -z "$bad_exits" ] && pass "33 no exit other than exit 2 after the trap" || fail "33" "$bad_exits"
last=$(grep -v -E '^[[:space:]]*(#|$)' "$DISPATCH" | tail -1)
[ "$last" = "_dispatch_complete=1" ] && pass "33 _dispatch_complete=1 is the last statement" || fail "33 last" "$last"
# The trap is the first statement of run_merge_gates.
first=$(awk '/^run_merge_gates\(\) \{/{f=1; next} f && $0 !~ /^[[:space:]]*#/ {print; exit}' "$DISPATCH")
case "$first" in "  trap '_rc=\$?;"*) pass "D5 trap is the first statement of run_merge_gates" ;; *) fail "D5 trap" "$first" ;; esac
# The settings timeout advice for settings.local.json stays removed.
if grep -rn -i 'settings.local.json' "$SRC_ROOT/docs/hooks-fail-closed.md" "$SRC_ROOT/docs/perf/hook-fail-closed-profile-2026-10.md" | grep -i 'timeout' | grep -v 'No document gives'; then
  fail "D7 no settings.local.json timeout advice" "found"
else
  pass "D7 no settings.local.json timeout advice"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
