#!/bin/bash
# Regression cases for quoted data, heredocs, and mixed Bash writes (#1459).
set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOKS="${HOOKS_OVERRIDE:-$ROOT/.claude/hooks}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0

check() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "PASS [$label]"; pass=$((pass + 1))
  else
    echo "FAIL [$label]: expected $want, got $got" >&2; fail=$((fail + 1))
  fi
}

# shellcheck source=/dev/null
. "$HOOKS/_lib-detect-bash-write.sh"
write_result() {
  if bash_command_appears_to_write "$1"; then printf write; else printf read; fi
}
check 'quoted redirect' read "$(write_result "git log --format='%h > %s'")"
# awk is outside the data-only allowlist, so the scrubber returns raw and the
# write detector keeps today's conservative raw-text verdict (false write).
check 'quoted comparison' write "$(write_result "awk '\$1 > 0' data.txt")"
check 'quoted grep pattern' read "$(write_result "grep -E '^>' data.txt")"
check 'double-quoted redirect text' read "$(write_result 'echo "> src/app.ts"')"
check 'quoted command name' read "$(write_result "echo 'sed -i s/a/b/ src/app.ts'")"
check 'quoted tee command is data' read "$(write_result "echo 'tee src/app.ts'")"
check 'real redirect' write "$(write_result 'echo x > src/app.ts')"
# $( outside singles forces raw. The redirect inside the substitution still writes.
check 'redirect inside command substitution executes' write \
  "$(write_result 'x="$(echo hi > src/app.ts)"')"
check 'eval of quoted shell code is conservative' write \
  "$(write_result "eval 'echo hi > src/app.ts'")"
check 'nested shell code is conservative' write \
  "$(write_result "bash -c 'echo hi > src/app.ts'")"
check 'comment apostrophes do not hide redirect' write \
  "$(write_result "$(printf "echo hi;# don't\necho x > src/app.ts;# it's fine")")"
check 'unterminated quote falls back' write "$(write_result "echo 'x > src/app.ts")"

heredoc_cmd=$(printf "cat <<'TEXT'\n> src/app.ts\ngh pr create --title x\nTEXT")
check 'heredoc body is data' read "$(write_result "$heredoc_cmd")"
# $( outside singles forces raw, so the redirect inside stays visible.
substitution_heredoc=$(printf 'gh issue create --body "$(cat <<\047TEXT\047\n> src/app.ts\ngh pr create --title x\nTEXT\n)"')
check 'heredoc inside command substitution falls back to raw' write \
  "$(write_result "$substitution_heredoc")"
for opener in '<<"TEXT"' '<<TEXT' '<<-TEXT'; do
  check "heredoc $opener body is data" read \
    "$(write_result "$(printf "cat %s\n> src/app.ts\nTEXT" "$opener")")"
done
unterminated=$(printf "cat <<'TEXT'\n> src/app.ts")
check 'unterminated heredoc falls back' write "$(write_result "$unterminated")"
ambiguous_delimiter=$(printf "cat <<'X'Y\npayload\nXY\necho x > src/app.ts\nX")
check 'unsupported delimiter falls back' write \
  "$(write_result "$ambiguous_delimiter")"
check 'adjacent redirects yield both targets' '/tmp/x,src/app.ts' \
  "$(bash_extract_write_targets 'echo x >/tmp/x>src/app.ts' | paste -sd, -)"

# A quoted tracker mention and a heredoc body fire the ambient-repo gate
# again because that matcher reads the raw command (AgDR-0181).
mkdir -p "$TMP/.claude/session"
: > "$TMP/onboarding.yaml"
: > "$TMP/apexyard.projects.yaml"
printf 'repo=acme-org/example\n' > "$TMP/.claude/session/current-ticket"
(cd "$TMP" && git init -q --template=)
export APEXYARD_OPS_DISABLE_PIN=1
unset CLAUDE_CODE_SESSION_ID || true
tracker_result() {
  local payload rc
  payload=$(jq -nc --arg c "$1" '{tool_input:{command:$c}}')
  (cd "$TMP" && printf '%s' "$payload" | APEXYARD_OPS_DISABLE_PIN=1 bash "$HOOKS/block-ambient-tracker-repo.sh" >/dev/null 2>&1)
  rc=$?
  printf '%s' "$rc"
}
check 'quoted tracker text' 2 "$(tracker_result "printf '%s' 'gh pr create --title x'")"
check 'double-quoted tracker text' 2 "$(tracker_result 'printf "%s" "gh pr create --title x"')"
check 'heredoc tracker text' 2 "$(tracker_result "$heredoc_cmd")"
check 'real tracker command' 2 "$(tracker_result 'gh pr create --title x')"
check 'malformed quote falls back for tracker' 2 \
  "$(tracker_result "printf 'gh pr create --title x")"
check 'unterminated heredoc falls back for tracker' 2 \
  "$(tracker_result "$(printf "cat <<'TEXT'\ngh pr create --title x")")"

review_result() {
  local payload rc
  payload=$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:""}}')
  (cd "$TMP" && printf '%s' "$payload" | bash "$HOOKS/auto-code-review.sh" >/dev/null 2>&1)
  rc=$?
  printf '%s' "$rc"
}
check 'quoted PR text does not trigger review' 0 "$(review_result "printf '%s' 'gh pr create --title x'")"
check 'heredoc PR text does not trigger review' 0 "$(review_result "$heredoc_cmd")"
# $( outside singles forces raw for the scrubber auto-code-review uses, so the
# embedded gh pr create stays visible and the review trigger fires.
check 'substitution heredoc PR text falls back and triggers review' 2 \
  "$(review_result "$substitution_heredoc")"
check 'real PR command triggers review' 2 "$(review_result 'gh pr create --title x')"

# The ticket gate must evaluate an unextractable write even when another
# redirect names an exempt scratch target.
rm -f "$TMP/.claude/session/current-ticket"
mkdir -p "$TMP/.claude/hooks"
for file in require-active-ticket.sh _lib-detect-bash-write.sh \
  _lib-command-scrub.sh _lib-mask-quoted.sh _lib-read-config.sh \
  _lib-path-resolve.sh _lib-active-ticket.sh _lib-ops-root.sh; do
  [ -f "$HOOKS/$file" ] && cp "$HOOKS/$file" "$TMP/.claude/hooks/$file"
done
cp "$ROOT/.claude/project-config.defaults.json" "$TMP/.claude/project-config.defaults.json"
if [ ! -d "$TMP/.git" ]; then
  (cd "$TMP" && git init -q --template=)
fi
ticket_result() {
  local payload rc
  payload=$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')
  (cd "$TMP" && printf '%s' "$payload" | APEXYARD_OPS_DISABLE_PIN=1 bash .claude/hooks/require-active-ticket.sh >/dev/null 2>&1)
  rc=$?
  printf '%s' "$rc"
}
check 'sed edit plus exempt redirect' 2 \
  "$(ticket_result 'sed -i "s/a/b/" src/app.ts > /dev/null')"
check 'sibling quoted operand does not name sed target' 2 \
  "$(ticket_result "sed -i \"s/a/b/\" src/app.ts; echo 'x' /tmp/run.log > /dev/null")"
check 'quoted sed file beside exempt redirect' 2 \
  "$(ticket_result "sed -i 's/a/b/' 'src/app.ts' > /dev/null")"
check 'python write plus exempt redirect' 2 \
  "$(ticket_result "python3 -c \"open('src/app.ts','w').write('x')\" > /tmp/run.log")"
check 'awk edit plus exempt redirect' 2 \
  "$(ticket_result 'awk -i inplace 1 src/app.ts; echo done > /tmp/run.log')"
check 'python plus both-stream redirect' 2 \
  "$(ticket_result "python3 -c \"open('src/app.ts','w').write('x')\" >&/dev/null")"
check 'python plus exempt sed edit' 2 \
  "$(ticket_result "python3 -c \"open('src/app.ts','w').write('x')\"; sed -Ei 's/a/b/' /tmp/x")"
check 'curl equals output plus exempt redirect' 2 \
  "$(ticket_result 'curl --output=src/app.ts https://example.com > /tmp/run.log')"
check 'wget equals output plus exempt redirect' 2 \
  "$(ticket_result 'wget --output-document=src/app.ts https://example.com > /tmp/run.log')"
check 'copy destination beside exempt redirect' 2 \
  "$(ticket_result 'cp /tmp/input src/app.ts > /dev/null')"
check 'move destination beside exempt redirect' 2 \
  "$(ticket_result 'mv /tmp/input src/app.ts > /dev/null')"
check 'exempt copy destination and redirect' 0 \
  "$(ticket_result 'cp /tmp/input /tmp/output > /dev/null')"
check 'adjacent redirect to source' 2 \
  "$(ticket_result 'echo x >/tmp/x>src/app.ts')"
check 'only exempt redirect' 0 "$(ticket_result 'echo x > /tmp/run.log')"
check 'quoted redirect destination' 2 "$(ticket_result 'echo x > "src/app.ts"')"
check 'heredoc prose with scratch write' 0 \
  "$(ticket_result "$(printf "cat > /tmp/run.log <<'TEXT'\n> src/app.ts\nTEXT")")"
check 'quoted tee beside scratch write is data' 0 \
  "$(ticket_result "echo 'tee src/app.ts' > /tmp/run.log")"

# #1480: allowlisted writers that still write (scrubbed view must detect).
check 'git log --output= tracked file' 2 \
  "$(ticket_result 'git log --output=src/app.ts')"
check 'git log --output space tracked file' 2 \
  "$(ticket_result 'git log --output src/app.ts')"
check 'git diff --output= tracked file' 2 \
  "$(ticket_result 'git diff --output=src/app.ts')"
check 'sort -o tracked file' 2 \
  "$(ticket_result 'sort -o src/app.ts input.txt')"
check 'yq -i tracked file' 2 \
  "$(ticket_result 'yq -i ".a=1" src/app.ts')"
check 'python3 -Bc open w tracked file' 2 \
  "$(ticket_result "python3 -Bc \"open('src/app.ts','w').write('x')\"")"
# Scrubbed allowlist false-positive neighbour still passes.
check 'git log format stays allowed' 0 \
  "$(ticket_result "git log --format='%h > %s'")"

printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
