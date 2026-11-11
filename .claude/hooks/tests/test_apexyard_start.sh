#!/usr/bin/env bash
# Offline bin/apexyard and bin/_lib-repo-resolve.sh checks.
# shellcheck disable=SC1091,SC2154
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_lib-apexyard-cli.sh"
sb=$(cd "$sb" && pwd -P)
root=$(cd "$(dirname "$CLI")/.." && pwd)
export APEXYARD_DISABLE_RESOLUTION_CACHE=1
mkdir -p "$sb/ops/.claude/skills" "$sb/ops/bin" "$sb/ops/workspace"
cp -R "$root/.claude/hooks" "$sb/ops/.claude/"
printf 'company: test\n' > "$sb/ops/onboarding.yaml"
printf 'projects:\n  - name: app\n    repo: org/app\n  - name: second\n    repo: org/second\n' > "$sb/ops/apexyard.projects.yaml"
git -C "$sb/ops" init -b main >/dev/null
git clone --bare "$sb/fixture" "$sb/origin.git" >/dev/null 2>&1
clone="$sb/ops/workspace/app"
git clone "$sb/origin.git" "$clone" >/dev/null 2>&1
export APEXYARD_OPS_ROOT="$sb/ops" APEXYARD_START_TICKET="$sb/tools/start"
export START_LOG="$sb/start.log"
cat > "$APEXYARD_START_TICKET" <<'SH'
#!/bin/bash
printf '%s\n' "$PWD" "$@" > "$START_LOG"
touch helper-marker
SH
cat > "$APEXYARD_GH" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
echo '[Feature] Small change'
SH
chmod +x "$APEXYARD_START_TICKET" "$APEXYARD_GH"
run_at() {
  local dir=$1
  shift
  rc=0
  (cd "$dir" && bash "$CLI" "$@") > "$sb/out" 2>&1 || rc=$?
}
# Match both HTTPS and SSH origins without any remote operation.
git -C "$clone" remote set-url origin https://github.com/org/app.git
before=$(git -C "$clone" for-each-ref)
run_at "$clone" start 12 --dry-run
check 'clone resolves' test "$rc" = 0
check repo grep -Fxq 'Repo: org/app' "$sb/out"
check ticket grep -Fxq 'Ticket: org/app#12' "$sb/out"
check branch grep -Fxq 'Branch: feature/GH-12-small-change' "$sb/out"
check 'no refs changed' test "$(git -C "$clone" for-each-ref)" = "$before"
check 'no worktree created' test ! -e "$clone.worktrees"
check 'no helper called' test ! -e "$START_LOG"
check 'no saved config' test ! -e "$XDG_CONFIG_HOME/apexyard/ops-root"
git -C "$clone" worktree add -b feature/GH-99-existing "$sb/existing" >/dev/null 2>&1
git -C "$clone" remote set-url origin git@github.com:org/app.git
run_at "$sb/existing" start 99 --dry-run --json
check 'worktree resolves' test "$rc" = 0
check 'existing branch JSON' grep -Fq '"branch":"feature/GH-99-existing"' "$sb/out"
check 'JSON values' python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["repo"]=="org/app" and d["ticket"]==99 and d["worktree"]==sys.argv[2] and d["clone"]==sys.argv[3]' "$sb/out" "$sb/existing" "$clone"
run_at "$sb/ops" start 12 --dry-run
check 'ops requires choice' test "$rc" = 2
check 'ops lists projects' grep -Fq '1) app (org/app)' "$sb/out"
run_at "$sb/ops" start 12 --json
check 'JSON requires choice' test "$rc" = 2
check 'JSON lists second' grep -Fq '2) second (org/second)' "$sb/out"
run_at "$sb" start 12 --dry-run
check 'outside rejected' test "$rc" = 2
check 'outside one line' test "$(wc -l < "$sb/out" | tr -d ' ')" = 1
check hint grep -Fq -- '--repo' "$sb/out"
run_at "$sb" start app#12 --dry-run
check 'short ticket' test "$rc" = 0
run_at "$sb" start org/app#12 --dry-run
check 'qualified ticket' test "$rc" = 0
run_at "$sb/existing" start 12 --repo second --dry-run
check 'explicit repo wins' grep -Fq 'no clone of org/second' "$sb/out"
run_at "$sb" start 12 --repo org/app --dry-run --agent unsupported
check 'unknown agent' test "$rc" = 2
check 'supported agents' grep -Fq 'Supported agents: claude, codex, cursor-agent, opencode, pi' "$sb/out"
# All mutations use the local bare origin.
git -C "$clone" remote set-url origin "$sb/origin.git"
run_at "$sb" start 12 --repo app --json --agent codex
check 'start succeeds' test "$rc" = 0
wt="$clone.worktrees/gh-12-small-change"
check 'worktree made' test -d "$wt"
check 'helper reused' test -f "$wt/helper-marker"
check 'override slash prompt' grep -Fq '/start-ticket org/app#12' "$FAKE_AGENT_LOG"
check 'helper ticket' grep -Fxq org/app#12 "$START_LOG"
check 'JSON before mutations' grep -Eq '^\{"repo":"org/app"' "$sb/out"
# Test each real launch argument shape through a PATH stub.
export PATH="$sb/tools:$PATH" LAUNCH_LOG="$sb/launch.log"
for agent in claude codex cursor-agent opencode pi; do
  cat > "$sb/tools/$agent" <<'SH'
#!/bin/bash
printf '%s\n' "$PWD" "$@" > "$LAUNCH_LOG"
SH
  chmod +x "$sb/tools/$agent"
  rc=0
  (unset APEXYARD_AGENT_CMD; cd "$sb"; bash "$CLI" start 12 --repo app --agent "$agent") > "$sb/out" 2>&1 || rc=$?
  check "$agent starts" test "$rc" = 0
  check "$agent cwd" test "$(head -1 "$LAUNCH_LOG")" = "$wt"
  if [ "$agent" = claude ]; then prompt='/start-ticket org/app#12'
  else prompt='Run the start-ticket workflow for org/app#12'; fi
  check "$agent prompt" grep -Fxq "$prompt" "$LAUNCH_LOG"
  if [ "$agent" = opencode ]; then check 'opencode prompt option' grep -Fxq -- --prompt "$LAUNCH_LOG"; fi
done
# Reuse the created worktree through each implicit origin context.
git -C "$clone" remote set-url origin https://github.com/org/app.git
run_at "$clone" start 12
check 'clone starts numeric ticket' test "$rc" = 0
run_at "$wt" start 12
check 'worktree starts numeric ticket' test "$rc" = 0
# Exercise the terminal prompt with a PTY, even though stdin is normally closed.
python3 - "$CLI" "$sb/ops" "$sb/pty.out" <<'PY'
import errno, os, pty, select, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.chdir(sys.argv[2])
    os.execv('/bin/bash', ['bash', sys.argv[1], 'start', '15', '--dry-run'])
data = b''
sent = False
deadline = time.monotonic() + 15
while time.monotonic() < deadline:
    if select.select([fd], [], [], 0.2)[0]:
        try:
            part = os.read(fd, 65536)
        except OSError as e:
            if e.errno == errno.EIO:
                break
            raise
        if not part:
            break
        data += part
        if b'Project number:' in data and not sent:
            os.write(fd, b'1\n')
            sent = True
else:
    os.kill(pid, 9)
_, status = os.waitpid(pid, 0)
open(sys.argv[3], 'wb').write(data)
assert sent and os.waitstatus_to_exitcode(status) == 0, data
PY
check 'terminal selection' grep -Fq 'Ticket: org/app#15' "$sb/pty.out"
# Inspect help and case labels. Do not treat arbitrary skill text as commands.
command_surface_safe() {
  local cli=$1 help labels
  help=$(bash "$cli" --help) || return 1
  labels=$(sed -nE 's/^[[:space:]]*([^#[:space:]][^)]*)\).*/\1/p' "$cli")
  if printf '%s\n' "$help" "$labels" | grep -Eq '(^|[[:space:]|])(merge|approve|skip)([[:space:]|]|$)|--(no-verify|skip-gates|force-gates|no-gates?)([[:space:]=]|$)'; then
    return 1
  fi
}
check 'command surface safe' command_surface_safe "$CLI"
mkdir -p "$sb/cli"
cp "$CLI" "$sb/cli/apexyard"
cp "$root/bin/_lib-telemetry.sh" "$sb/cli/"
# Insert a case label in a valid command dispatcher.
python3 - "$sb/cli/apexyard" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace('case "$cmd" in', 'case "$cmd" in\n  merge) exit 0 ;;', 1)
open(p, 'w').write(s)
PY
if command_surface_safe "$sb/cli/apexyard"; then bad=0; else bad=1; fi
check 'merge fixture fails safety check' test "$bad" = 1
for forbidden in approve skip; do
  sed "s/merge) exit 0/$(printf '%s' "$forbidden")) exit 0/" "$sb/cli/apexyard" > "$sb/cli/check"
  if command_surface_safe "$sb/cli/check"; then bad=0; else bad=1; fi
  check "$forbidden fixture fails safety check" test "$bad" = 1
done
for flag in --no-verify --skip-gates --force-gates --no-gate; do
  sed "s/merge) exit 0/$flag) exit 0/" "$sb/cli/apexyard" > "$sb/cli/check"
  if command_surface_safe "$sb/cli/check"; then bad=0; else bad=1; fi
  check "$flag fixture fails safety check" test "$bad" = 1
done
finish
