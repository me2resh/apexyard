#!/bin/bash
# Fixture tests run without a Claude Code session or network access.
set -eu
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REAL_GIT=$(command -v git)
REAL_JQ=$(command -v jq)
export REAL_GIT
PASS=0 FAIL=0
mkdir -p "$TMP/tools" "$TMP/home/.claude"
for tool in bash dirname basename head sed grep uname cat sleep tr awk cut sort wc date stat readlink find xargs env; do
  ln -s "$(command -v "$tool")" "$TMP/tools/$tool"
done
ln -s "$REAL_JQ" "$TMP/tools/jq"
cat > "$TMP/tools/git" <<'STUB'
#!/bin/bash
if [ "${WIN_GIT_ROOT:-}" != '' ] && [ "$*" = 'rev-parse --show-toplevel' ]; then
  echo "$WIN_GIT_ROOT"
else
  exec "$REAL_GIT" "$@"
fi
STUB
cat > "$TMP/tools/gh" <<'STUB'
#!/bin/bash
case "$*" in
  --version) echo 'gh version 2.80.0' ;;
  'auth status') exit "${AUTH_RC:-0}" ;;
  *) exit 99 ;;
esac
STUB
chmod +x "$TMP/tools/git" "$TMP/tools/gh"
fixture() {
  rm -rf "$TMP/fork" "$TMP/home/.claude/settings.json"
  mkdir -p "$TMP/fork/.claude/skills/preflight" "$TMP/fork/.claude/hooks" "$TMP/fork/projects" "$TMP/fork/.githooks" "$TMP/fork/bin"
  cp "$ROOT/.claude/hooks/"_lib-*.sh "$TMP/fork/.claude/hooks/"
  cp "$ROOT/.claude/project-config.defaults.json" "$TMP/fork/.claude/"
  cp "$ROOT/.claude/skills/preflight/preflight.sh" "$TMP/fork/.claude/skills/preflight/"
  cp "$ROOT/bin/apexyard" "$TMP/fork/bin/"
  touch "$TMP/fork/.apexyard-fork"
  printf 'projects: []\n' > "$TMP/fork/apexyard.projects.yaml"
  printf 'company:\n  name: "Example"\n' > "$TMP/fork/onboarding.yaml"
  printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"bash dispatch-bash.sh","timeout":20}]}]}}\n' > "$TMP/fork/.claude/settings.json"
  printf '#!/bin/bash\ncat >/dev/null\nexit "${DISPATCH_RC:-0}"\n' > "$TMP/fork/.claude/hooks/dispatch-bash.sh"
  "$REAL_GIT" -C "$TMP/fork" init -q
  "$REAL_GIT" -C "$TMP/fork" config core.hooksPath .githooks
  "$REAL_GIT" -C "$TMP/fork" remote add upstream https://github.com/me2resh/apexyard.git
  unset AUTH_RC DISPATCH_RC WIN_GIT_ROOT
}
run() {
  RC=0
  OUT=$(cd "$TMP/fork" && PATH="$TMP/tools" HOME="$TMP/home" CLAUDE_CONFIG_DIR="$TMP/home/.claude" CLAUDE_CODE_SESSION_ID=preflight-read-only /bin/bash bin/apexyard doctor 2>&1) || RC=$?
}
check() {
  local label="$1" expected="$2" pattern="$3"
  if [ "$RC" -eq "$expected" ] && printf '%s\n' "$OUT" | grep -Fq "$pattern"; then
    PASS=$((PASS + 1)); echo "PASS $label"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %s: exit=%s expected=%s pattern=%s\n%s\n' "$label" "$RC" "$expected" "$pattern" "$OUT"
  fi
}
fixture
run; check all-good 0 'OK dispatcher-timing'
rm "$TMP/tools/jq"
run; check missing-jq 2 'FAIL jq: missing'
check jq-skips 2 'Skipped: jq unavailable'
ln -s "$REAL_JQ" "$TMP/tools/jq"
mv "$TMP/tools/gh" "$TMP/gh"
run; check missing-gh 1 'WARN gh: missing'
mv "$TMP/gh" "$TMP/tools/gh"
export AUTH_RC=1
run; check gh-not-logged-in 1 'Fix: Run gh auth login.'
unset AUTH_RC
"$REAL_GIT" -C "$TMP/fork" config --unset core.hooksPath
run; check unset-hooksPath 1 'WARN hooksPath: unset'
fixture
rm "$TMP/fork/apexyard.projects.yaml"
run; check missing-split-config 2 'WARN portfolio-config'
fixture
printf '{"portfolio":{"registry":"../missing/registry.yaml"}}\n' > "$TMP/fork/.claude/project-config.json"
run; check broken-portfolio 2 'portfolio.registry resolved to'
printf '{invalid\n' > "$TMP/fork/.claude/project-config.json"
run; check invalid-config 2 'FAIL portfolio-config'
fixture
cp "$TMP/fork/.claude/settings.json" "$TMP/fork/.claude/settings.local.json"
run; check duplicate-local-dispatch 1 'arrays merge, not replace'
rm "$TMP/fork/.claude/settings.local.json"
cp "$TMP/fork/.claude/settings.json" "$TMP/home/.claude/settings.json"
run; check duplicate-user-dispatch 1 'WARN dispatcher-duplicate'
rm "$TMP/home/.claude/settings.json"
export DISPATCH_RC=2
run; check dispatcher-blocked 1 'exit=2'
unset DISPATCH_RC
printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"dispatch-bash.sh","timeout":1}]}]}}\n' > "$TMP/fork/.claude/settings.json"
printf '#!/bin/bash\nsleep 2\n' > "$TMP/fork/.claude/hooks/dispatch-bash.sh"
run; check dispatcher-timeout 1 'WARN dispatcher-timing'
# A child that outlives the dispatcher must die with the probe. It must not write its marker.
marker="$TMP/dispatcher-child-marker"
pidfile="$TMP/dispatcher-child.pid"
rm -f "$marker" "$pidfile"
cat > "$TMP/fork/.claude/hooks/dispatch-bash.sh" <<EOF
#!/bin/bash
(
  printf '%s\n' "\$\$" > "$pidfile"
  sleep 2
  printf 'wrote\n' > "$marker"
) &
sleep 30
EOF
run
if printf '%s\n' "$OUT" | grep -F 'Terminated' >/dev/null; then
  RC=97
  OUT="job notice: $OUT"
fi
check dispatcher-orphan 1 'WARN dispatcher-timing'
child_alive=0
if [ ! -f "$pidfile" ]; then
  child_alive=1
else
  child=$(cat "$pidfile")
  if kill -0 "$child" 2>/dev/null; then
    child_alive=1
    kill -- -"$child" 2>/dev/null || kill "$child" 2>/dev/null || true
  fi
fi
sleep 3
RC=0
OUT='child stopped and marker absent'
if [ "$child_alive" -ne 0 ] || [ -f "$marker" ]; then
  RC=99
  OUT="alive=$child_alive marker=$( [ -f "$marker" ] && printf 'yes' || printf 'no' )"
fi
check dispatcher-orphan-tree 0 'child stopped and marker absent'
rm -f "$marker" "$pidfile"
fixture
# Native host must not run Windows checks.
run; check non-windows 0 'OK portfolio'
if printf '%s\n' "$OUT" | grep -q 'INFO shell:'; then RC=99; else RC=0; fi
OUT='Windows checks absent'; check windows-gating 0 'Windows checks absent'
rm "$TMP/tools/uname"
printf '#!/bin/bash\necho "${TEST_SYSTEM:-MINGW64_NT-10.0}"\n' > "$TMP/tools/uname"
chmod +x "$TMP/tools/uname"
run; check missing-cygpath 1 'WARN cygpath: missing'
export TEST_SYSTEM=MSYS_NT-10.0
run; check msys-gating 1 'INFO shell: MSYS_NT'
export TEST_SYSTEM=CYGWIN_NT-10.0
run; check cygwin-gating 1 'INFO shell: CYGWIN_NT'
unset TEST_SYSTEM
cat > "$TMP/tools/cygpath" <<'STUB'
#!/bin/bash
case "$1" in
  -u)
    shift
    [ "${1:-}" != -- ] || shift
    case "$1" in
      /c/test/fork*) echo "$FIXTURE${1#/c/test/fork}" ;;
      C:/Users/test/AppData/Local/Temp/fork*) echo "$FIXTURE${1#C:/Users/test/AppData/Local/Temp/fork}" ;;
      # Same directory with a different spelling, so the normalized forms differ.
      D:/other/repo) echo "$FIXTURE/." ;;
      *) echo "$1" ;;
    esac ;;
  -m) echo 'C:/Users/test/AppData/Local/Temp/fork' ;;
esac
STUB
chmod +x "$TMP/tools/cygpath"
export FIXTURE
FIXTURE=$(cd "$TMP/fork" && pwd -P)
export WIN_GIT_ROOT='C:/Users/test/AppData/Local/Temp/fork'
run; check git-bash-paths 0 'OK windows-paths'
check git-bash-raw-form 0 'git=C:/Users/test/AppData/Local/Temp/fork'
export WIN_GIT_ROOT=/c/test/fork
run; check drive-mount-form 0 'OK windows-paths'
export WIN_GIT_ROOT='D:/other/repo'
run; check mount-path-mismatch 1 'WARN windows-paths'
check path-fix-link 1 'https://github.com/me2resh/apexyard/issues/1743'
unset WIN_GIT_ROOT
run; check windows-matching 0 'OK windows-paths'
"$REAL_GIT" -C "$TMP/fork" config core.autocrlf true
run; check autocrlf 1 'WARN crlf'
"$REAL_GIT" -C "$TMP/fork" config core.autocrlf false
printf '#!/bin/bash\r\necho test\r\n' > "$TMP/fork/crlf.sh"
"$REAL_GIT" -C "$TMP/fork" add crlf.sh
run; check tracked-crlf 1 'INFO crlf-file: crlf.sh'
# Check that every problem has exactly one fix row.
problems=$(printf '%s\n' "$OUT" | grep -cE '^(WARN|FAIL) ')
fixes=$(printf '%s\n' "$OUT" | grep -c '^  Fix: ')
RC=0; [ "$problems" -eq "$fixes" ] || RC=99
OUT='one fix per problem'; check fixes 0 'one fix per problem'
rm "$TMP/tools/uname" "$TMP/tools/cygpath"
ln -s "$(command -v uname)" "$TMP/tools/uname"
fixture
# Exercise the real dispatcher and all its gates on the trivial payload.
cp "$ROOT/.claude/hooks/"*.sh "$TMP/fork/.claude/hooks/"
# Include git and user state, plus session cache destinations in the snapshot.
snapshot() {
  {
    find "$TMP/fork" "$TMP/home" -type d
    find "$TMP/fork" "$TMP/home" -type f -exec shasum {} \;
  } | sort
}
before=$(snapshot)
run; check real-dispatcher 0 'OK dispatcher-timing'
after=$(snapshot)
RC=0; [ "$before" = "$after" ] || RC=99
OUT='No file changes'; check read-only 0 'No file changes'
fixture
mv "$TMP/tools/git" "$TMP/git"
run; check missing-git 2 'FAIL git: missing'
mv "$TMP/git" "$TMP/tools/git"
mv "$TMP/tools/bash" "$TMP/bash"
run; check missing-bash 2 'FAIL bash: missing'
mv "$TMP/bash" "$TMP/tools/bash"
# Minimum supported jq version remains valid.
mv "$TMP/tools/jq" "$TMP/jq"
cat > "$TMP/tools/jq" <<STUB
#!/bin/bash
if [ "\$*" = --version ]; then echo jq-1.6; else exec "$REAL_JQ" "\$@"; fi
STUB
chmod +x "$TMP/tools/jq"
run; check jq-1.6 0 'OK jq: jq-1.6'
sed 's/jq-1.6/jq-1.5/' "$TMP/tools/jq" > "$TMP/old-jq"
cp "$TMP/old-jq" "$TMP/tools/jq"
run; check old-jq 2 'FAIL jq: Unsupported version'
rm "$TMP/tools/jq"
mv "$TMP/jq" "$TMP/tools/jq"
# Skill and CLI share the same helper and document its statuses.
RC=0
OUT=$(cat "$ROOT/.claude/skills/preflight/SKILL.md")
check skill-helper 0 'bash .claude/skills/preflight/preflight.sh'
check skill-exits 0 '2 = at least one FAIL'
# No anchor: the CLI must still print a FAIL and exit 2.
rm "$TMP/fork/.apexyard-fork" "$TMP/fork/onboarding.yaml"
run; check outside-fork 2 'FAIL fork'
fixture
"$REAL_GIT" -C "$TMP/fork" remote set-url upstream 'ssh://git@github.com/me2resh/apexyard'
run; check upstream-ssh 0 'OK upstream: ssh://git@github.com/me2resh/apexyard'
"$REAL_GIT" -C "$TMP/fork" remote set-url upstream 'ssh://git@github.com/me2resh/apexyard.git'
run; check upstream-ssh-dot-git 0 'OK upstream: ssh://git@github.com/me2resh/apexyard.git'
"$REAL_GIT" -C "$TMP/fork" config user.email 'preflight@example.com'
"$REAL_GIT" -C "$TMP/fork" config user.name 'Preflight Test'
"$REAL_GIT" -C "$TMP/fork" config commit.gpgsign false
"$REAL_GIT" -C "$TMP/fork" commit --allow-empty -q -m init
"$REAL_GIT" -C "$TMP/fork" worktree add -q "$TMP/linked-worktree" HEAD
main_fork=$(cd "$TMP/fork" && pwd -P)
RC=0
OUT=$(cd "$TMP/linked-worktree" && PATH="$TMP/tools" HOME="$TMP/home" CLAUDE_CONFIG_DIR="$TMP/home/.claude" /bin/bash "$TMP/fork/bin/apexyard" doctor 2>&1) || RC=$?
check linked-worktree 0 "OK fork: $main_fork"
rm -rf "$TMP/linked-worktree"
mkdir -p "$TMP/pathbin" "$TMP/outside"
ln -s "$TMP/fork/bin/apexyard" "$TMP/pathbin/apexyard"
RC=0
OUT=$(cd "$TMP/outside" && PATH="$TMP/tools" HOME="$TMP/home" CLAUDE_CONFIG_DIR="$TMP/home/.claude" /bin/bash "$TMP/pathbin/apexyard" doctor 2>&1) || RC=$?
check symlink-outside-fork 2 'FAIL fork'
rm -f "$TMP/fork/.claude/skills/preflight/preflight.sh"
RC=0
OUT=$(cd "$TMP/fork" && PATH="$TMP/tools" HOME="$TMP/home" CLAUDE_CONFIG_DIR="$TMP/home/.claude" /bin/bash bin/apexyard doctor 2>&1) || RC=$?
check missing-preflight 2 'preflight helper not found'
RC=0
OUT=$(cd "$TMP/outside" && PATH="$TMP/tools" HOME="$TMP/home" CLAUDE_CONFIG_DIR="$TMP/home/.claude" /bin/bash "$TMP/pathbin/apexyard" doctor 2>&1) || RC=$?
check missing-preflight-symlink 2 'preflight helper not found'
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
