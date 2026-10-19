#!/bin/bash
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
set -uo pipefail

# Each caller has its own fixture. Run the three callers concurrently so the
# complete matrix stays within the hook-suite runner's time limit.
if [ -z "${D17_MATRIX_AGENT:-}" ]; then
  matrix_results=$(mktemp -d)
  trap 'rm -rf "$matrix_results"' EXIT
  matrix_pids=()
  matrix_roles=(main platform-engineer code-reviewer)
  for matrix_role in "${matrix_roles[@]}"; do
    D17_MATRIX_AGENT="$matrix_role" /bin/bash "${BASH_SOURCE[0]:-$0}" > "$matrix_results/$matrix_role" 2>&1 &
    matrix_pids[${#matrix_pids[@]}]=$!
  done
  matrix_bad=0
  for matrix_pid in "${matrix_pids[@]}"; do wait "$matrix_pid" || matrix_bad=1; done
  matrix_pass=0; matrix_fail=0
  for matrix_role in "${matrix_roles[@]}"; do
    IFS=' ' read -r worker_pass worker_word worker_fail worker_end < <(tail -1 "$matrix_results/$matrix_role")
    case "$worker_pass:$worker_fail" in *[!0-9:]*|:*|*:) cat "$matrix_results/$matrix_role"; exit 1 ;; esac
    if [ "$worker_word" != passed, ] || [ "$worker_end" != failed ]; then cat "$matrix_results/$matrix_role"; exit 1; fi
    matrix_pass=$((matrix_pass+worker_pass)); matrix_fail=$((matrix_fail+worker_fail))
    if [ "$worker_fail" != 0 ]; then cat "$matrix_results/$matrix_role"; fi
  done
  printf '%s passed, %s failed\n' "$matrix_pass" "$matrix_fail"
  [ "$matrix_bad" = 0 ] && [ "$matrix_fail" = 0 ]
  exit $?
fi
case "$D17_MATRIX_AGENT" in main|platform-engineer|code-reviewer) ;; *) echo 'FAIL: unknown caller fixture'; exit 1 ;; esac
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d)
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" CLAUDE_PROJECT_DIR="$TMP/live" CLAUDE_CODE_SESSION_ID=d17
export APEXYARD_OPS_PIN_DIR="$HOME/.claude/apexyard"
mkdir -p "$HOME/.claude" "$APEXYARD_OPS_PIN_DIR" "$TMP/live/.claude/hooks" "$TMP/scratch/.claude/hooks"
mkdir -p "$TMP/live/.git" "$TMP/scratch/.git"
touch "$TMP/live/.apexyard-fork" "$TMP/live/.claude/hooks/x.sh"
printf '%s\n' "$TMP/live" > "$APEXYARD_OPS_PIN_DIR/ops-root-d17"
printf '{}\n' > "$TMP/live/.claude/settings.json"
PASS=0 FAIL=0
check() {
  local want="$1" label="$2" rc=0
  shift 2
  "$@" > "$TMP/out" 2> "$TMP/err" || rc=$?
  if [ "$rc" = "$want" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL %s expected=%s actual=%s\n' "$label" "$want" "$rc"; cat "$TMP/err"; fi
}
finish() { printf '%s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]; }

run_bash() {
  jq -cn --arg cwd "$CASE_CWD" --arg cmd "$1" --arg agent "$agent" '{tool_name:"Bash",cwd:$cwd,agent_type:$agent,tool_input:{command:$cmd}}' | /bin/bash "$ROOT/block-protected-target-writes.sh"
}
run_edit() {
  jq -cn --arg cwd "$TMP/live" --arg file "$2" --arg tool "$1" --arg agent "$agent" '{tool_name:$tool,cwd:$cwd,agent_type:$agent,tool_input:{file_path:$file,notebook_path:$file}}' | /bin/bash "$ROOT/block-protected-target-writes.sh"
}
ln -s "$TMP/live/.claude/hooks/x.sh" "$TMP/link"
# A worker runs exactly one caller fixture.
# shellcheck disable=SC2066
for agent in "$D17_MATRIX_AGENT"; do
CASE_CWD="$TMP/live"
for tool in Edit Write MultiEdit NotebookEdit; do
  for file in "$TMP/live/.claude/settings.json" "$TMP/live/.claude/settings.local.json" "$TMP/live/.claude/hooks/x.sh" "$HOME/.claude/settings.json" "$HOME/.claude/session-env/x" "$HOME/.claude/shell-snapshots/x" "$APEXYARD_OPS_PIN_DIR/ops-root-x" "$APEXYARD_OPS_PIN_DIR/gate-session-x/snapshot.json"; do
    check 2 "$agent $tool $file" run_edit "$tool" "$file"
  done
  check 0 "$agent $tool temp" run_edit "$tool" "$TMP/temp/x.sh"
  check 2 "$agent $tool dotdot" run_edit "$tool" "$TMP/live/.claude/../.claude/hooks/x.sh"
  check 2 "$agent $tool double slash" run_edit "$tool" "$TMP/live/.claude//hooks/x.sh"
  check 2 "$agent $tool slash dot" run_edit "$tool" "$TMP/live/.claude/./hooks/x.sh"
  check 2 "$agent $tool symlink" run_edit "$tool" "$TMP/link"
  check 0 "$agent $tool scratch" run_edit "$tool" "$TMP/scratch/.claude/hooks/x.sh"
done
c='mv __FIXTURE__/live/.claude/hooks /tmp/x'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 0 $agent: $c" run_bash "$c"
c='rm -rf .claude/hooks'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 1 $agent: $c" run_bash "$c"
c='rm -rf .claude'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 2 $agent: $c" run_bash "$c"
c='rm .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 3 $agent: $c" run_bash "$c"
c='ln -sf /tmp/x .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 4 $agent: $c" run_bash "$c"
c='git rm -r .claude/hooks'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 5 $agent: $c" run_bash "$c"
c='git mv .claude/hooks h'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 6 $agent: $c" run_bash "$c"
c='rsync -a /tmp/x/ .claude/hooks/'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 7 $agent: $c" run_bash "$c"
c='truncate -s 0 .claude/settings.json'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 8 $agent: $c" run_bash "$c"
c='chmod -x .claude/hooks/dispatch-bash.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 9 $agent: $c" run_bash "$c"
c='chown x .claude'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 10 $agent: $c" run_bash "$c"
c='unzip -o x.zip -d .claude/hooks'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 11 $agent: $c" run_bash "$c"
c='ditto /tmp/x .claude/hooks'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 12 $agent: $c" run_bash "$c"
c='tar -x -C .claude -f x.tar'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 13 $agent: $c" run_bash "$c"
c='cp x.sh .claude/hooks/'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 14 $agent: $c" run_bash "$c"
c='cp -R /tmp/tpl/* .'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 15 $agent: $c" run_bash "$c"
c='cp -t .claude/hooks x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 16 $agent: $c" run_bash "$c"
c='cp --target-directory=.claude/hooks x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 17 $agent: $c" run_bash "$c"
c='mv -t .claude/hooks x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 18 $agent: $c" run_bash "$c"
c='install -t .claude/hooks x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 19 $agent: $c" run_bash "$c"
c='install -D x.sh .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 20 $agent: $c" run_bash "$c"
c='dd if=/tmp/x of=.claude/settings.json'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 21 $agent: $c" run_bash "$c"
c='rsync -a --remove-source-files .claude/hooks/ /tmp/x/'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 22 $agent: $c" run_bash "$c"
c='tar --remove-files -cf /tmp/h.tar .claude/hooks'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 23 $agent: $c" run_bash "$c"
c='rmdir .claude/hooks'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 24 $agent: $c" run_bash "$c"
c='unlink .claude/settings.json'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 25 $agent: $c" run_bash "$c"
c='shred .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 26 $agent: $c" run_bash "$c"
c='chgrp x .claude'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 27 $agent: $c" run_bash "$c"
c='chflags uchg .claude/settings.json'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 28 $agent: $c" run_bash "$c"
c='xattr -w a b .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 29 $agent: $c" run_bash "$c"
c='setfacl -m u:x:r .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 30 $agent: $c" run_bash "$c"
c='touch .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 31 $agent: $c" run_bash "$c"
c='perl -pi -e '"'"'s/a/b/'"'"' .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 32 $agent: $c" run_bash "$c"
c='ruby -i -pe '"'"'1'"'"' .claude/settings.json'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 33 $agent: $c" run_bash "$c"
c='printf '"'"',d\nw\n'"'"' | ed .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 34 $agent: $c" run_bash "$c"
c='cat x | sponge .claude/settings.json'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 35 $agent: $c" run_bash "$c"
c='base64 -d -o .claude/hooks/x.sh x.b64'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 36 $agent: $c" run_bash "$c"
c='openssl enc -d -in x -out .claude/settings.json'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 37 $agent: $c" run_bash "$c"
c='iconv -f a -t b -o .claude/settings.json x'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 38 $agent: $c" run_bash "$c"
c='plutil -convert json .claude/settings.json'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 39 $agent: $c" run_bash "$c"
c='gzip .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 40 $agent: $c" run_bash "$c"
c='find .claude/hooks -name '"'"'block-*'"'"' -exec chmod -x {} +'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 41 $agent: $c" run_bash "$c"
c='find .claude -execdir rm {} \;'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 42 $agent: $c" run_bash "$c"
c='printf '"'"'%s\n'"'"' .claude/hooks/x.sh | xargs chmod -x'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 43 $agent: $c" run_bash "$c"
c='env chmod -x .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 44 $agent: $c" run_bash "$c"
c='command rm .claude/settings.json'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 45 $agent: $c" run_bash "$c"
c='nohup mv .claude/hooks /tmp/x'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 46 $agent: $c" run_bash "$c"
c='time rm -rf .claude'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 47 $agent: $c" run_bash "$c"
c='p=.claude/hooks/x.sh; echo evil > "$p"'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 48 $agent: $c" run_bash "$c"
c='echo x > ~/.claude/apexyard/ops-root-abc'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 49 $agent: $c" run_bash "$c"
c='echo x > $HOME/.claude/settings.json'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 50 $agent: $c" run_bash "$c"
c='echo /tmp/decoy > "${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-$CLAUDE_CODE_SESSION_ID"'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 51 $agent: $c" run_bash "$c"
c='echo x > "$D/.claude/settings.local.json"'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 52 $agent: $c" run_bash "$c"
c='rm -rf "$R/.claude"'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 54 $agent: $c" run_bash "$c"
c='git checkout HEAD -- .claude/settings.local.json'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 55 $agent: $c" run_bash "$c"
c='git checkout HEAD .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 56 $agent: $c" run_bash "$c"
c='git checkout -b tmp HEAD -- .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 57 $agent: $c" run_bash "$c"
c='git restore .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 58 $agent: $c" run_bash "$c"
c='git restore -s HEAD~1 .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 59 $agent: $c" run_bash "$c"
c='git restore --source=HEAD~1 .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 60 $agent: $c" run_bash "$c"
c='git checkout -p -- .claude'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 61 $agent: $c" run_bash "$c"
c='git checkout --theirs .claude/settings.json'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 62 $agent: $c" run_bash "$c"
c='git restore .'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 63 $agent: $c" run_bash "$c"
c='git restore :/'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 64 $agent: $c" run_bash "$c"
c='git restore '"'"':(top).claude'"'"''; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 65 $agent: $c" run_bash "$c"
c='git restore '"'"'.claude/*'"'"''; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 66 $agent: $c" run_bash "$c"
c='git restore --pathspec-from-file=list'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 67 $agent: $c" run_bash "$c"
c='git checkout-index -f -a'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 68 $agent: $c" run_bash "$c"
c='git checkout-index -f .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 69 $agent: $c" run_bash "$c"
c='git read-tree -u -m HEAD'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 70 $agent: $c" run_bash "$c"
c='git -C .claude restore hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 71 $agent: $c" run_bash "$c"
c='cd .claude/hooks && git restore x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 72 $agent: $c" run_bash "$c"
c='git --work-tree=__FIXTURE__/live checkout HEAD -- .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 73 $agent: $c" run_bash "$c"
c='GIT_WORK_TREE=__FIXTURE__/live git checkout HEAD -- .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 74 $agent: $c" run_bash "$c"
c='git -C "$D" restore x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 75 $agent: $c" run_bash "$c"
c='mytool .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 76 $agent: $c" run_bash "$c"
c='bash .claude/hooks/pin-ops-root.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 77 $agent: $c" run_bash "$c"
c='echo '"'"'{}'"'"' | bash .claude/hooks/write-session-snapshot.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 78 $agent: $c" run_bash "$c"
c='bash .claude/hooks/record-subagent-start.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 79 $agent: $c" run_bash "$c"
c='source .claude/hooks/dispatch-session-start.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 80 $agent: $c" run_bash "$c"
c='bash -c '"'"'cd .claude/hooks && touch x.sh'"'"''; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 81 $agent: $c" run_bash "$c"
c='( ( cd .claude/hooks; touch x ) )'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 82 $agent: $c" run_bash "$c"
c='bash -c '"'"'cd .claude && cd hooks && python3 -c "open(\"x\",\"w\")"'"'"''; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 83 $agent: $c" run_bash "$c"
c='cd .claude/hooks && python3 -c "open('"'"'x.sh'"'"','"'"'w'"'"')"'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 84 $agent: $c" run_bash "$c"
c='popd; rm -rf .claude'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 85 $agent: $c" run_bash "$c"
c='git apply x.patch'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 86 $agent: $c" run_bash "$c"
c='git am x.mbox'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 87 $agent: $c" run_bash "$c"
c='patch -p1 < x.patch'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 88 $agent: $c" run_bash "$c"
c='git -c alias.co=checkout co HEAD -- .claude/hooks/x.sh'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 89 $agent: $c" run_bash "$c"
c='python3 -c "open('"'"'.claude/settings.local.json'"'"','"'"'w'"'"').write('"'"'{}'"'"')"'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 90 $agent: $c" run_bash "$c"
c='node -e "require('"'"'fs'"'"').writeFileSync('"'"'.claude/settings.local.json'"'"','"'"'{}'"'"')"'; c=${c//__FIXTURE__/$TMP}; check 2 "2 case 91 $agent: $c" run_bash "$c"
c='cp .claude/settings.json /tmp/bak'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 0 $agent: $c" run_bash "$c"
c='dd if=.claude/settings.json of=/tmp/x'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 1 $agent: $c" run_bash "$c"
c='rsync -a __FIXTURE__/live/ __FIXTURE__/scratch/'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 2 $agent: $c" run_bash "$c"
c='tar -C .claude -cf /tmp/h.tar hooks'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 3 $agent: $c" run_bash "$c"
c='ln -s __FIXTURE__/live/.claude/hooks/x.sh /tmp/l'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 4 $agent: $c" run_bash "$c"
c='cp x ~'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 5 $agent: $c" run_bash "$c"
c='cp -t /tmp/bak .claude/settings.json'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 7 $agent: $c" run_bash "$c"
c='rsync -a --delete __FIXTURE__/live/ __FIXTURE__/scratch/'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 8 $agent: $c" run_bash "$c"
c='echo x > "$ops_root/.claude/session/active-issue-skill"'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 9 $agent: $c" run_bash "$c"
c='bash .claude/hooks/tests/test_x.sh'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 12 $agent: $c" run_bash "$c"
c='bash .claude/hooks/write-rule-excludes.sh'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 13 $agent: $c" run_bash "$c"
c='wc -l .claude/hooks/*.sh'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 14 $agent: $c" run_bash "$c"
c='git log -- .claude/hooks'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 15 $agent: $c" run_bash "$c"
c='python3 -c "print(1)"'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 16 $agent: $c" run_bash "$c"
c='grep -n '"'"'.claude/settings.json'"'"' docs/x.md'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 17 $agent: $c" run_bash "$c"
c='jq . .claude/settings.json'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 18 $agent: $c" run_bash "$c"
c='( cd /tmp; python3 -c "open('"'"'x'"'"','"'"'w'"'"')" )'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 19 $agent: $c" run_bash "$c"
c='( cd .claude/hooks ); touch x'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 20 $agent: $c" run_bash "$c"
c='git checkout -b feature'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 21 $agent: $c" run_bash "$c"
c='git apply --check x.patch'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 22 $agent: $c" run_bash "$c"
c='APEXYARD_OPS_PIN_DIR=/tmp/sb bash .claude/hooks/pin-ops-root.sh'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 23 $agent: $c" run_bash "$c"
c='source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"; python3 -c "open('"'"'/tmp/x'"'"','"'"'w'"'"')"'; c=${c//__FIXTURE__/$TMP}; check 0 "0 case 24 $agent: $c" run_bash "$c"
check 2 'worktree writer script' run_bash "bash $TMP/scratch/.claude/hooks/pin-ops-root.sh"
check 2 'token join slash' run_bash "python3 -c \"open('.claude//hooks/x','w')\""
check 2 'source token plus write token' run_bash ". .claude/hooks/_lib-x.sh; python3 -c \"open('.claude/hooks/x','w')\""
check 2 'unsafe patch paths' run_bash 'git apply --unsafe-paths x.patch'
check 0 'archive into literal scratch' run_bash "git archive HEAD .claude/hooks | tar -x -C $TMP/scratch"
check 2 'archive multiple cd' run_bash 'tar -x -C a -C b .claude/hooks'
check 2 'archive absolute names' run_bash 'tar -xP -C /tmp .claude/hooks'
c='cat > "$REVIEW_BODY_FILE"'; check 0 'literal review body file' run_bash "REVIEW_BODY_FILE=$TMP/scratch/review; $c"
CASE_CWD="$TMP/scratch"
check 0 'non-live recursive copy' run_bash 'cp -R /tmp/tpl/* .'
check 0 'non-live unknown verb' run_bash 'mytool .claude/hooks/x.sh'
check 0 'non-live patch' run_bash 'git apply x.patch'
check 2 'unsafe patch paths outside live' run_bash 'git apply --unsafe-paths x.patch'
check 2 'patch explicit live file' run_bash "patch $TMP/live/.claude/hooks/x.sh x.diff"
check 2 'patch live output' run_bash "patch -o $TMP/live/.claude/hooks/x.sh a b.diff"
printf '%s\n' '--- /dev/null' "+++ $TMP/live/.claude/hooks/x.sh" > "$TMP/header.patch"
check 2 'absolute patch header' run_bash "patch -i $TMP/header.patch"
check 2 'nonliteral patch input token' run_bash 'printf data | patch .claude/hooks/x.sh'

CASE_CWD="$TMP/live/.claude/hooks"
check 2 'protected cwd interpreter' run_bash "python3 -c \"open('x','w')\""

# cb <want> <label> <command>: __LIVE__ and __SCRATCH__ name the fixture roots.
cb() {
  local c="$3"
  c=${c//__LIVE__/$TMP/live}; c=${c//__SCRATCH__/$TMP/scratch}
  check "$1" "$agent $2: $c" run_bash "$c"
}
# Section B.12 items that the numbered cases above do not cover.
CASE_CWD="$TMP/live"
cb 2 'sed in place on a live hook' "sed -i '' 's/a/b/' .claude/hooks/require-active-ticket.sh"
cb 2 'tar extract into live hooks' 'tar -x -C .claude/hooks -f x.tar'
cb 0 'marker write through a computed ops root' 'ops_root=$(git rev-parse --show-toplevel); echo x > "$ops_root/.claude/session/active-issue-skill"'
cb 2 'pushd into hooks then interpreter write' "pushd .claude/hooks; python3 -c \"open('x','w')\""
cb 2 'unresolved cd then relative settings write' 'cd "$X" && echo x > .claude/settings.json'
cb 0 'scrubbed git apply mention' "grep -n 'git apply' file"
cb 2 'git apply inside bash -c' "bash -c 'git apply x.patch'"
# Section B.14 item 2: directory scope. A directory change inside a child
# shell, a nested subshell, a pipeline stage or a background list stays there.
CASE_CWD="$TMP/scratch"
cb 0 'relative removal in a non-live directory' 'rm -rf .claude'
cb 2 'popd with an empty stack uses the live root' 'popd; rm -rf .claude'
cb 0 'cd inside bash -c does not leak' "bash -c 'cd __LIVE__'; rm -rf .claude"
cb 2 'cd inside bash -c applies inside' "bash -c 'cd __LIVE__ && rm -rf .claude'"
cb 0 'cd in a nested subshell does not leak' '( ( cd __LIVE__ ) ); rm -rf .claude'
cb 2 'cd in a nested subshell applies inside' '( ( cd __LIVE__; rm -rf .claude ) )'
cb 0 'cd in a pipeline stage does not leak' 'cd __LIVE__ | cat; rm -rf .claude'
cb 0 'cd in a background command does not leak' 'cd __LIVE__ & rm -rf .claude'
cb 0 'cd in a background and-or list does not leak' 'cd __LIVE__ && true & rm -rf .claude'
cb 2 'cd in a background and-or list applies inside' 'cd __LIVE__ && rm -rf .claude &'
cb 0 'pushd in a subshell does not leak' '( pushd __LIVE__ ); rm -rf .claude'
cb 0 'assignment in a subshell does not leak' '( p=__LIVE__/.claude ); rm -rf "$p"'
cb 2 'assignment in this shell applies' 'p=__LIVE__/.claude; rm -rf "$p"'
# A cd that can fail leaves the old directory in effect after ";" and "||".
CASE_CWD="$TMP/live"
cb 0 'cd then && runs in the new directory' 'cd __SCRATCH__ && rm -rf .claude'
cb 0 'cd guarded by exit' 'cd __SCRATCH__ || exit 1; rm -rf .claude'
cb 2 'cd then ; can run in the old directory' 'cd __SCRATCH__; rm -rf .claude'
cb 2 'cd then || runs only in the old directory' 'cd __SCRATCH__ || rm -rf .claude'
cb 2 'negated cd in if' 'if ! cd __SCRATCH__; then rm -rf .claude; fi'
# Command substitutions run as commands.
cb 2 'write inside $()' 'echo $(rm -rf .claude)'
cb 2 'write inside backticks' 'x=`chmod -x .claude/hooks/x.sh`'
cb 0 'single-quoted substitution text is data' "echo '\$(rm -rf .claude)'"
cb 2 'substitution in an unquoted heredoc body' $'cat <<EOF\n$(touch .claude/hooks/x.sh)\nEOF'
cb 0 'substitution text in a quoted heredoc body' $'cat <<\'EOF\'\n$(touch .claude/hooks/x.sh)\nEOF'
cb 2 'substitution in a case word' 'case $(touch .claude/hooks/x.sh) in a) ;; esac'
# Case patterns are syntax. Case bodies are commands.
cb 0 'case statement with patterns' 'case "$x" in a|b) echo ok ;; (c) echo c ;; esac'
cb 2 'write in a case body' 'case a in a) rm -rf .claude ;; esac'
cb 2 'write after a blank line in a case body' $'case a in\n  a)\n    echo hi\n\n    rm -rf .claude\n    ;;\nesac'
cb 2 'write in a nested case body' 'case a in a) case b in b) touch .claude/hooks/x.sh ;; esac ;; esac'
# Shell option clusters, eval and prefix options.
cb 2 'bash -ec program' "bash -ec 'rm -rf .claude'"
cb 2 'bash -o pipefail -c program' "bash -o pipefail -c 'rm -rf .claude'"
cb 2 'eval program' "eval 'rm -rf .claude'"
cb 2 'nice with a priority value' 'nice -n 10 rm -rf .claude'
cb 2 'timeout with a duration' 'timeout 5 rm -rf .claude'
cb 2 'sudo with a user value' 'sudo -u me rm -rf .claude'
cb 2 'env with an unset value' 'env -u X rm -rf .claude'
cb 2 'env split string' "env -S 'rm -rf .claude'"
cb 2 'piped shell program names protected state' "echo 'chmod -x .claude/hooks/x.sh' | bash"
cb 0 'piped shell program without protected state' "echo 'echo hi' | bash"
cb 2 'sourced process substitution names protected state' "source <(echo 'chmod -x .claude/hooks/x.sh')"
# Patch forms from outside the live root.
CASE_CWD="$TMP/scratch"
cb 2 'patch -d into the live root' 'patch -d __LIVE__ -p1 < x.patch'
cb 2 'patch of a live hook after cd /tmp' 'cd /tmp && patch __LIVE__/.claude/hooks/dispatch-bash.sh x.diff'
printf '%s\n' '--- /dev/null' '+++ ../live/.claude/hooks/x.sh' > "$TMP/scratch/dotdot.patch"
cb 2 'dotdot patch header' "patch -p0 -i $TMP/scratch/dotdot.patch"
printf '%s\n' '--- /dev/null' '+++ ../scratch/y.sh' > "$TMP/scratch/safe-dotdot.patch"
cb 0 'dotdot patch header outside protected paths' "patch -p0 -i $TMP/scratch/safe-dotdot.patch"
CASE_CWD="$TMP/live"
done
# Escaped JSON keys and values decode before the edit-channel check.
agent=main
printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_\\u0070ath":"%s/live/.claude/settings.local.json"}}' "$TMP/live" "$TMP" > "$TMP/escaped-key.json"
check 2 'escaped file_path key' /bin/bash "$ROOT/block-protected-target-writes.sh" < "$TMP/escaped-key.json"
printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s/live/.claude/settings.\\u006cocal.json"}}' "$TMP/live" "$TMP" > "$TMP/split-key.json"
check 2 'escaped settings.local.json path' /bin/bash "$ROOT/block-protected-target-writes.sh" < "$TMP/split-key.json"
check 0 'edit under /tmp' run_edit Edit "/tmp/d17-edit-$$.sh"
# Configured aliases use a real fixture repository.
git init -q "$TMP/live" || exit 1
git -C "$TMP/live" config alias.rs restore || exit 1
CASE_CWD="$TMP/live"
check 2 'configured restore alias' run_bash 'git rs .claude/hooks/x.sh'
check 2 'tar create output' run_bash 'tar -cf .claude/settings.json x'
check 0 'xattr read-only' run_bash 'xattr -p a .claude/hooks/x.sh'
export CLAUDE_CONFIG_DIR="$TMP/config"
export CLAUDE_ENV_FILE="$TMP/env-file"
check 2 'configured user settings' run_edit Edit "$CLAUDE_CONFIG_DIR/settings.json"
check 2 'configured shell snapshot' run_edit Edit "$CLAUDE_CONFIG_DIR/shell-snapshots/x"
check 2 'harness environment file' run_edit Edit "$CLAUDE_ENV_FILE"
# A snapshot, rather than a per-call environment value, fixes the live roots.
printf '{"source":"startup","session_id":"d17"}\n' | /bin/bash "$ROOT/write-session-snapshot.sh" || exit 1
export CLAUDE_PROJECT_DIR="$TMP/scratch"
check 0 'subagent worktree remains non-live' run_edit Edit "$TMP/scratch/.claude/hooks/x.sh"
check 2 'original root remains live' run_edit Edit "$TMP/live/.claude/hooks/x.sh"
# The worktree is live when the session starts there.
export CLAUDE_CODE_SESSION_ID=worktree
printf '{"source":"startup","session_id":"worktree"}\n' | /bin/bash "$ROOT/write-session-snapshot.sh" || exit 1
check 2 'worktree session hooks' run_edit Edit "$TMP/scratch/.claude/hooks/x.sh"
check 2 'worktree session settings' run_edit Edit "$TMP/scratch/.claude/settings.json"
finish
