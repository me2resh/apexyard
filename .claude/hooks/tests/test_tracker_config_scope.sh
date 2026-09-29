#!/bin/bash
# Tracker config reads must use the current context, even after another reader
# ran in a long-lived shell. Each fixture owns its own temporary git repository.

set -u
unset CLAUDE_CODE_SESSION_ID APEXYARD_OPS_PIN_DIR 2>/dev/null || true

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACKER_LIB_SOURCE="${TRACKER_LIB_SOURCE:-$HOOK_DIR/_lib-tracker.sh}"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s (expected [%s], got [%s])\n' "$1" "$2" "$3"
  fi
}

make_repo() {
  local repo="$1" kind="$2"
  mkdir -p "$repo/.claude/hooks" "$repo/bin"
  git -C "$repo" init -q || return 1
  touch "$repo/.apexyard-fork"
  printf '{"tracker":{"kind":"%s"}}\n' "$kind" > "$repo/.claude/project-config.defaults.json"
  cp "$TRACKER_LIB_SOURCE" "$repo/.claude/hooks/_lib-tracker.sh"
  cp "$HOOK_DIR/_lib-read-config.sh" "$repo/.claude/hooks/_lib-read-config.sh"
  cp "$HOOK_DIR/_lib-ops-root.sh" "$repo/.claude/hooks/_lib-ops-root.sh"
  cp "$HOOK_DIR/_lib-portfolio-paths.sh" "$repo/.claude/hooks/_lib-portfolio-paths.sh"
  cp "$HOOK_DIR/_lib-resolution-cache.sh" "$repo/.claude/hooks/_lib-resolution-cache.sh"
}

EARLY="$TMP_ROOT/early"
LATE="$TMP_ROOT/late"
make_repo "$EARLY" gh || exit 1
make_repo "$LATE" glab || exit 1

cat > "$LATE/bin/gh" <<'SH'
#!/bin/bash
printf 'gh\n' > "$TRACKER_CAPTURE"
printf '[]\n'
SH
cat > "$LATE/bin/glab" <<'SH'
#!/bin/bash
printf 'glab\n' > "$TRACKER_CAPTURE"
printf '[]\n'
SH
chmod +x "$LATE/bin/gh" "$LATE/bin/glab"

# A tracker config read in one shell must not install a reader in that shell.
reader_state=$(
  cd "$EARLY" || exit 1
  . "$EARLY/.claude/hooks/_lib-tracker.sh"
  tracker_id_pattern >/dev/null
  if command -v config_get_or >/dev/null 2>&1; then
    printf 'leaked\n'
  else
    printf 'absent\n'
  fi
)
assert_eq 'tracker read leaves no config reader in caller' absent "$reader_state"

# A reader sourced by another caller can carry an earlier root cache. The
# tracker must still use the later repository for both kind and list dispatch.
result=$(
  cd "$EARLY" || exit 1
  . "$EARLY/.claude/hooks/_lib-tracker.sh"
  . "$EARLY/.claude/hooks/_lib-read-config.sh"
  _config_repo_root >/dev/null
  cd "$LATE" || exit 1
  tracker_issue_kind
  TRACKER_CAPTURE="$TMP_ROOT/dispatch" PATH="$LATE/bin:$PATH" tracker_list 'sample/repo' >/dev/null
  cat "$TMP_ROOT/dispatch"
)
resolved_kind=$(printf '%s\n' "$result" | sed -n '1p')
dispatched_cli=$(printf '%s\n' "$result" | sed -n '2p')
assert_eq 'inherited reader does not change later tracker kind' glab "$resolved_kind"
assert_eq 'inherited reader does not change tracker_list dispatch' glab "$dispatched_cli"

printf 'RESULT: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
