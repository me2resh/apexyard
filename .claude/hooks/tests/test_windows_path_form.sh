#!/bin/bash
# Windows path-form regressions.
# #1724 ticket exemptions, #1725 and #1737 hook-install containment.
#
# git.exe prints C:/... and Git Bash pwd -P prints /c/... for one directory.
# Claude Code sends C:\... to Edit and Write. Those translations exist only
# on Windows. This test drives the string transform directly, the same way
# test_portfolio_paths_windows_drive_letter.sh does for #1018.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"

PASS=0
FAIL=0
FAILED=""

record_pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
record_fail() {
  FAIL=$((FAIL + 1))
  FAILED="${FAILED}$1; "
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && echo "  $2" >&2
}

# shellcheck disable=SC1091
. "$HOOK_DIR/_lib-path-resolve.sh"
# shellcheck disable=SC1091
. "$HOOK_DIR/_lib-ticket-path-exemptions.sh"

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    record_pass "$label"
  else
    record_fail "$label" "want=$want got=$got"
  fi
}

assert_eq "drive slash" "/c/Users/a b/repo" "$(_windows_path_to_posix 'C:/Users/a b/repo')"
assert_eq "drive backslash" "/c/Users/x/repo/.claude/project-config.json" \
  "$(_windows_path_to_posix 'C:\Users\x\repo\.claude\project-config.json')"
assert_eq "lower drive" "/d/Projs/fork" "$(_windows_path_to_posix 'd:/Projs/fork')"
assert_eq "posix unchanged" "/Users/x/repo" "$(_windows_path_to_posix '/Users/x/repo')"
assert_eq "drive-relative unchanged" 'C:foo' "$(_windows_path_to_posix 'C:foo')"

if path_is_under_root 'C:/Users/a b/apexyard' '/c/Users/a b/apexyard/.githooks'; then
  record_pass "containment: mixed forms with a space are inside"
else
  record_fail "containment: mixed forms with a space are inside"
fi
if path_is_under_root 'C:/Users/x/apexyard' '/c/Users/x/apexyard'; then
  record_pass "containment: repo root itself is inside"
else
  record_fail "containment: repo root itself is inside"
fi
if path_is_under_root '/Users/x/repo' '/Users/x/repo/.githooks'; then
  record_pass "containment: posix hooks dir is inside"
else
  record_fail "containment: posix hooks dir is inside"
fi
if path_is_under_root 'C:/Users/x/apexyard' '/c/Users/x/other/.githooks'; then
  record_fail "containment: a different tree is outside"
else
  record_pass "containment: a different tree is outside"
fi
if path_is_under_root '/Users/x/repo' '/Users/x/repo-evil/.githooks'; then
  record_fail "containment: prefix trick is outside"
else
  record_pass "containment: prefix trick is outside"
fi
if path_is_under_root '/Users/x/repo' ''; then
  record_fail "containment: empty resolve is outside"
else
  record_pass "containment: empty resolve is outside"
fi

exempt_rc() {
  if ticket_path_is_meta_exempt "$1"; then
    echo 0
  else
    echo 1
  fi
}

assert_eq "exempt windows .claude json" 0 \
  "$(exempt_rc 'C:\Users\x\apexyard\.claude\project-config.json')"
assert_eq "exempt windows docs" 0 \
  "$(exempt_rc 'C:/Users/x/apexyard/docs/guide.md')"
assert_eq "exempt windows readme" 0 \
  "$(exempt_rc 'C:/Users/x/apexyard/README.md')"
assert_eq "gated windows source" 1 \
  "$(exempt_rc 'C:\Users\x\apexyard\src\app.ts')"
assert_eq "gated windows worktree source" 1 \
  "$(exempt_rc 'C:\Users\x\apexyard\.claude\worktrees\feat\src\a.ts')"
assert_eq "drive-relative source stays gated" 1 \
  "$(exempt_rc 'C:src\app.ts')"

# The reported Write payload, with no active ticket, must pass for .claude
# and block for source. The hook under test is this worktree's copy.
SB=$(mktemp -d)
(
  cd "$SB" || exit 1
  git init -q
  git config user.email t@example.com
  git config user.name t
  mkdir -p .claude/hooks src
  printf 'x\n' > src/app.ts
)
for f in require-active-ticket.sh _lib-path-resolve.sh _lib-ticket-path-exemptions.sh \
  _lib-ops-root.sh _lib-active-ticket.sh _lib-awk-fallback.sh _lib-detect-bash-write.sh \
  _lib-read-config.sh _lib-portfolio-paths.sh _lib-fail-closed-json.sh _lib-mask-quoted.sh
do
  cp "$HOOK_DIR/$f" "$SB/.claude/hooks/$f"
done
cp "$SRC_ROOT/.claude/project-config.defaults.json" "$SB/.claude/project-config.defaults.json"

run_hook() {
  local path="$1" rc=0
  local input
  input=$(jq -nc --arg fp "$path" '{tool_name:"Write", tool_input:{file_path:$fp, content:"x"}}')
  (
    cd "$SB" || exit 99
    bash "$SB/.claude/hooks/require-active-ticket.sh" <<<"$input" >/dev/null 2>&1
  ) || rc=$?
  echo "$rc"
}

assert_eq "hook allows windows .claude write" 0 \
  "$(run_hook 'C:\Users\x\apexyard\.claude\project-config.json')"
assert_eq "hook blocks windows source write" 2 \
  "$(run_hook 'C:\Users\x\apexyard\src\app.ts')"
assert_eq "hook still allows posix .claude write" 0 \
  "$(run_hook "$SB/.claude/project-config.json")"
assert_eq "hook still blocks posix source write" 2 \
  "$(run_hook "$SB/src/app.ts")"

NONGIT=$(mktemp -d /tmp/apex-nongit.XXXXXX)
if git -C "$NONGIT" rev-parse --show-toplevel >/dev/null 2>&1; then
  record_fail "nongit dir is inside a git repo" "$NONGIT"
fi

run_hook_from() {
  local dir="$1" path="$2" rc=0
  local input
  input=$(jq -nc --arg fp "$path" '{tool_name:"Write", tool_input:{file_path:$fp, content:"x"}}')
  (
    cd "$dir" || exit 99
    env -u CLAUDE_CODE_SESSION_ID APEXYARD_OPS_DISABLE_PIN=1 \
      bash "$SB/.claude/hooks/require-active-ticket.sh" <<<"$input" >/dev/null 2>&1
  ) || rc=$?
  echo "$rc"
}

assert_eq "nongit cwd blocks windows source" 2 \
  "$(run_hook_from "$NONGIT" 'C:\Users\x\apexyard\src\app.ts')"
assert_eq "nongit cwd allows windows .claude" 0 \
  "$(run_hook_from "$NONGIT" 'C:\Users\x\apexyard\.claude\project-config.json')"
assert_eq "nongit cwd blocks posix source in a repo" 2 \
  "$(run_hook_from "$NONGIT" "$SB/src/app.ts")"
assert_eq "nongit cwd allows a path outside git" 0 \
  "$(run_hook_from "$NONGIT" "$NONGIT/notes.txt")"

classify_state=$(
  repo=$(mktemp -d /tmp/apex-cls-repo.XXXXXX)
  outside=$(mktemp -d /tmp/apex-cls-out.XXXXXX)
  mkdir -p "$outside/company-hooks"
  git -C "$repo" init -q
  git -C "$repo" config core.hooksPath 'C:/outside/company-hooks'
  # shellcheck disable=SC1091
  . "$HOOK_DIR/_lib-git-hooks-path.sh"
  eval "$(declare -f _resolve_real_path | sed '1s/_resolve_real_path/_resolve_real_path_orig/')"
  _resolve_real_path() {
    if [ "$1" = "/c/outside/company-hooks" ]; then
      printf '%s' "$outside/company-hooks"
      return 0
    fi
    _resolve_real_path_orig "$1"
  }
  ghp_classify "$repo" .githooks
  rm -rf "$repo" "$outside"
)
case "$classify_state" in
  third-party:*)
    record_pass "classify keeps an existing drive-letter hooks dir"
    ;;
  *)
    record_fail "classify keeps an existing drive-letter hooks dir" "$classify_state"
    ;;
esac

rm -rf "$SB" "$NONGIT"

# ---------------------------------------------------------------------------
# #1743: Git Bash mounts C:/Users/<u>/AppData/Local/Temp at /tmp.
# pwd -P prints /tmp. The string transform prints /c/Users/.../Temp.
# These cases put a stub cygpath on PATH. macOS has no cygpath and no mount.
# ---------------------------------------------------------------------------
assert_eq "no cygpath keeps the Temp string form" \
  "/c/Users/u/AppData/Local/Temp/repo" \
  "$(_windows_path_to_posix 'C:/Users/u/AppData/Local/Temp/repo')"

MOUNT_SB=$(mktemp -d)
MOUNT=$(cd "$MOUNT_SB" && pwd -P)
MOUNT_REPO="$MOUNT/repo"
MOUNT_WIN='C:/Users/u/AppData/Local/Temp/repo'
mkdir -p "$MOUNT_REPO/.githooks" "$MOUNT/outside-hooks" "$MOUNT/bin"
printf '#!/bin/sh\nexit 0\n' > "$MOUNT_REPO/.githooks/pre-push"
git -C "$MOUNT_REPO" init -q
GIT_REAL=$(command -v git)

cat > "$MOUNT/bin/cygpath" <<'EOF'
#!/bin/bash
path=""
for arg in "$@"; do
  case "$arg" in
    -u|--|-*) ;;
    *) path="$arg" ;;
  esac
done
if [ -n "${CYGPATH_LOG:-}" ]; then
  printf '%s\n' "$path" >> "$CYGPATH_LOG"
fi
if [ "${CYGPATH_FORCE+set}" = "set" ]; then
  printf '%s' "$CYGPATH_FORCE"
  exit 0
fi
if [ "${CYGPATH_EMPTY:-}" = "1" ]; then
  exit 0
fi
case "$path" in
  /*)
    printf '%s' "$path"
    exit 0
    ;;
esac
norm=$(printf '%s' "$path" | tr '\\' '/')
prefix="C:/Users/u/AppData/Local/Temp"
mount="${CYGPATH_MOUNT:?}"
case "$norm" in
  "$prefix"|"$prefix"/*)
    rest="${norm#"$prefix"}"
    printf '%s%s' "$mount" "$rest"
    exit 0
    ;;
esac
case "$norm" in
  [A-Za-z]:/*)
    drive=$(printf '%.1s' "$norm" | tr '[:upper:]' '[:lower:]')
    rest="${norm#?:}"
    printf '/%s%s' "$drive" "$rest"
    exit 0
    ;;
esac
printf '%s' "$path"
EOF

cat > "$MOUNT/bin/git" <<'EOF'
#!/bin/bash
real="${GIT_REAL:?}"
win="${GIT_WINDOWS_TOPLEVEL:?}"
prev=""
for arg in "$@"; do
  if [ "$prev" = "rev-parse" ] && [ "$arg" = "--show-toplevel" ]; then
    printf '%s\n' "$win"
    exit 0
  fi
  prev="$arg"
done
exec "$real" "$@"
EOF
chmod +x "$MOUNT/bin/cygpath" "$MOUNT/bin/git"

OLD_PATH=$PATH
export PATH="$MOUNT/bin:$PATH"
hash -r
export CYGPATH_MOUNT="$MOUNT"
export CYGPATH_LOG="$MOUNT/cygpath.log"
unset CYGPATH_EMPTY CYGPATH_FORCE

: > "$CYGPATH_LOG"
assert_eq "cygpath maps the Temp prefix to the fixture" \
  "$MOUNT_REPO" "$(_windows_path_to_posix "$MOUNT_WIN")"
assert_eq "cygpath maps a backslash Temp path" \
  "$MOUNT_REPO" \
  "$(_windows_path_to_posix 'C:\Users\u\AppData\Local\Temp\repo')"
assert_eq "cygpath maps another drive" "/e/a" "$(_windows_path_to_posix 'E:/a')"

: > "$CYGPATH_LOG"
assert_eq "posix path is unchanged while cygpath is present" \
  "/tmp" "$(_windows_path_to_posix /tmp)"
if [ -s "$CYGPATH_LOG" ]; then
  record_fail "cygpath is not called for a POSIX path" "$(cat "$CYGPATH_LOG")"
else
  record_pass "cygpath is not called for a POSIX path"
fi

if path_is_under_root "$MOUNT_WIN" "$MOUNT_REPO/.githooks"; then
  record_pass "containment: mounted Windows root contains the hooks dir"
else
  record_fail "containment: mounted Windows root contains the hooks dir"
fi
if path_is_under_root "$MOUNT_WIN" "$MOUNT/repo-evil/.githooks"; then
  record_fail "containment: mounted prefix trick is outside"
else
  record_pass "containment: mounted prefix trick is outside"
fi

export CYGPATH_EMPTY=1
if path_is_under_root "$MOUNT_WIN" "$MOUNT_REPO/.githooks"; then
  record_fail "containment: silent cygpath fails closed"
else
  record_pass "containment: silent cygpath fails closed"
fi
unset CYGPATH_EMPTY

export CYGPATH_FORCE=relative
assert_eq "cygpath output without a leading slash uses the string form" \
  "/c/Users/u/AppData/Local/Temp/repo" \
  "$(_windows_path_to_posix "$MOUNT_WIN")"
if path_is_under_root "$MOUNT_WIN" "$MOUNT_REPO/.githooks"; then
  record_fail "containment: non-posix cygpath output fails closed"
else
  record_pass "containment: non-posix cygpath output fails closed"
fi
unset CYGPATH_FORCE

run_mount_installer() {
  PATH="$MOUNT/bin:$PATH" \
    GIT_REAL="$GIT_REAL" \
    GIT_WINDOWS_TOPLEVEL="$MOUNT_WIN" \
    CYGPATH_MOUNT="$MOUNT" \
    bash "$SRC_ROOT/bin/install-git-hooks.sh" "$@" 2>&1
}

inst_out=$(run_mount_installer --repo-dir "$MOUNT_REPO" --hooks-dir ../outside-hooks)
inst_rc=$?
assert_eq "installer: mounted outside hooks dir exits 2" "2" "$inst_rc"
if printf '%s' "$inst_out" | grep -q 'outside'; then
  record_pass "installer: mounted outside hooks dir says outside"
else
  record_fail "installer: mounted outside hooks dir says outside" "$inst_out"
fi
assert_eq "installer: mounted outside hooks dir leaves config unset" "" \
  "$("$GIT_REAL" -C "$MOUNT_REPO" config --get core.hooksPath 2>/dev/null || true)"

inst_out=$(CYGPATH_EMPTY=1 run_mount_installer --repo-dir "$MOUNT_REPO")
inst_rc=$?
assert_eq "installer: silent cygpath fails closed" "2" "$inst_rc"
if [ "$inst_rc" != "2" ]; then
  echo "  $inst_out" >&2
fi
assert_eq "installer: silent cygpath leaves config unset" "" \
  "$("$GIT_REAL" -C "$MOUNT_REPO" config --get core.hooksPath 2>/dev/null || true)"

inst_out=$(run_mount_installer --repo-dir "$MOUNT_REPO")
inst_rc=$?
assert_eq "installer: mounted Windows toplevel exits 0" "0" "$inst_rc"
assert_eq "installer: mounted Windows toplevel sets core.hooksPath" ".githooks" \
  "$("$GIT_REAL" -C "$MOUNT_REPO" config --get core.hooksPath 2>/dev/null || true)"

classify_mount=$(
  PATH="$MOUNT/bin:$PATH" \
    GIT_REAL="$GIT_REAL" \
    GIT_WINDOWS_TOPLEVEL="$MOUNT_WIN" \
    CYGPATH_MOUNT="$MOUNT" \
    bash -c '
      # shellcheck disable=SC1090
      . "$1"
      ghp_classify "$2" .githooks
    ' _ "$HOOK_DIR/_lib-git-hooks-path.sh" "$MOUNT_WIN"
)
case "$classify_mount" in
  "correct")
    record_pass "classify: mounted Windows toplevel with .githooks is correct"
    ;;
  *)
    record_fail "classify: mounted Windows toplevel with .githooks is correct" \
      "$classify_mount"
    ;;
esac

mkdir -p "$MOUNT_REPO/custom-hooks"
"$GIT_REAL" -C "$MOUNT_REPO" config core.hooksPath custom-hooks
classify_mount=$(
  PATH="$MOUNT/bin:$PATH" \
    GIT_REAL="$GIT_REAL" \
    GIT_WINDOWS_TOPLEVEL="$MOUNT_WIN" \
    CYGPATH_MOUNT="$MOUNT" \
    bash -c '
      # shellcheck disable=SC1090
      . "$1"
      ghp_classify "$2" .githooks
    ' _ "$HOOK_DIR/_lib-git-hooks-path.sh" "$MOUNT_WIN"
)
case "$classify_mount" in
  third-party:custom-hooks:"$MOUNT_REPO"/custom-hooks)
    record_pass "classify: mounted inside hooks dir stays inside"
    ;;
  *)
    record_fail "classify: mounted inside hooks dir stays inside" "$classify_mount"
    ;;
esac

PATH=$OLD_PATH
hash -r
unset CYGPATH_MOUNT CYGPATH_LOG CYGPATH_EMPTY CYGPATH_FORCE
rm -rf "$MOUNT_SB"

echo ""
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
