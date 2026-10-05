#!/bin/bash
# #1531 / AgDR-0219: path exemptions must use the file's OWN worktree top,
# not the AgDR-0141 main-clone rewrite of REPO_ROOT.
#
# Acceptance criteria:
#   AC1  no marker + write to <repo>/.claude/worktrees/x/src/a.ts → exit 2
#   AC2  ≥15-path table with the expected exit code for every row. Only the
#        wt-src row differs from the pre-fix gate (it allowed it, rc=0); every
#        other row asserts the pre-fix result, so the fix is not too wide.
#        The test needs no git remote: CI checkouts have no upstream/dev. The
#        before/after comparison against the pre-fix hook is in PR evidence.
#   AC3  worktree .claude/, worktree docs/, ops .claude/, projects/*/docs/,
#        *.md stay exempt with no ticket
#   AC4  same exemption verdicts via require-migration-ticket.sh (for paths
#        that hook gates — migration-shaped or meta)
#   Also: valid ticket marker (ops fallback + tier-0) still ALLOWS worktree
#   source writes; Bash redirect into a worktree source uses the same logic.
#
# Exit 0 if all cases pass; 1 on first failure cluster.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_ACTIVE="$SRC_ROOT/.claude/hooks/require-active-ticket.sh"
HOOK_MIG="$SRC_ROOT/.claude/hooks/require-migration-ticket.sh"
DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"

PASS=0
FAIL=0
FAILED_CASES=""

record_pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
record_fail() {
  FAIL=$((FAIL + 1))
  FAILED_CASES="${FAILED_CASES}${1}; "
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && echo "  $2" >&2
}

# Copy every lib the head hooks may source into a sandbox hooks dir.
install_libs() {
  local dest="$1"
  local defaults_dest
  mkdir -p "$dest"
  local f
  for f in _lib-detect-bash-write.sh _lib-path-resolve.sh _lib-ops-root.sh \
           _lib-active-ticket.sh _lib-ticket-path-exemptions.sh \
           _lib-read-config.sh _lib-portfolio-paths.sh _lib-mask-quoted.sh \
           _lib-tracker.sh _lib-fail-closed-json.sh; do
    [ -f "$SRC_ROOT/.claude/hooks/$f" ] && cp "$SRC_ROOT/.claude/hooks/$f" "$dest/$f"
  done
  defaults_dest="$(cd "$dest/.." && pwd)/project-config.defaults.json"
  cp "$DEFAULTS" "$defaults_dest"
}

# Ops-fork sandbox with a linked worktree under .claude/worktrees/feat-x
# and a second linked worktree outside the repo tree.
make_ops_with_worktrees() {
  local sb wt_out
  sb=$(mktemp -d)
  sb=$(cd "$sb" && pwd -P)
  wt_out=$(mktemp -d)
  wt_out=$(cd "$wt_out" && pwd -P)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    : > onboarding.yaml
    : > apexyard.projects.yaml
    printf '' > .apexyard-fork
    mkdir -p docs projects/demo/docs src migrations .claude
    printf 'ops\n' > docs/ops.md
    printf 'proj\n' > projects/demo/docs/note.md
    printf 'src\n' > src/main.ts
    printf 'mig\n' > migrations/001_init.sql
    printf '{}\n' > .claude/settings.json
    git add -A
    git commit -q -m "init"
    mkdir -p .claude/worktrees
    git worktree add -q -b feat-x .claude/worktrees/feat-x >/dev/null 2>&1
    git worktree add -q -b feat-ext "$wt_out/ext-wt" >/dev/null 2>&1
  )
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session"
  install_libs "$sb/.claude/hooks"
  # Ensure worktree trees have the dirs we write into (worktree add copies
  # committed files; create untracked targets as needed in callers).
  mkdir -p "$sb/.claude/worktrees/feat-x/src" \
           "$sb/.claude/worktrees/feat-x/docs" \
           "$sb/.claude/worktrees/feat-x/.claude" \
           "$sb/.claude/worktrees/feat-x/migrations" \
           "$wt_out/ext-wt/src" \
           "$wt_out/ext-wt/docs" \
           "$wt_out/ext-wt/.claude"
  # Stash external worktree path for callers.
  printf '%s\n' "$wt_out/ext-wt" > "$sb/.test-ext-wt"
  echo "$sb"
}

run_active() {
  local hook="$1" sb="$2" file_path="$3" tool="${4:-Write}"
  local input
  if [ "$tool" = "Bash" ]; then
    input=$(jq -nc --arg c "$file_path" '{tool_name:"Bash", tool_input:{command:$c}}')
  else
    input=$(jq -nc --arg fp "$file_path" '{tool_name:"Write", tool_input:{file_path:$fp}}')
  fi
  (
    cd "$sb" || exit 99
    # Head hook lives in the sandbox; dev hook is an absolute path that still
    # resolves libs next to $0 — for the DEV hook we must run from a sandbox
    # that also has a copy of the DEV hook script itself.
    bash "$hook" <<<"$input" >/dev/null 2>&1
  )
  return $?
}

# Install a named hook script into the sandbox (head or a mutated copy).
install_hook() {
  local sb="$1" src="$2" name="$3"
  cp "$src" "$sb/.claude/hooks/$name"
  chmod +x "$sb/.claude/hooks/$name"
}

# --- AC1: worktree source write without ticket must BLOCK on head ----------
SB=$(make_ops_with_worktrees)
install_hook "$SB" "$HOOK_ACTIVE" "require-active-ticket.sh"
WT_SRC="$SB/.claude/worktrees/feat-x/src/a.ts"
: > "$WT_SRC"
rc=0
run_active "$SB/.claude/hooks/require-active-ticket.sh" "$SB" "$WT_SRC" || rc=$?
if [ "$rc" = "2" ]; then
  record_pass "AC1 head: worktree src write without ticket → exit 2"
else
  record_fail "AC1 head: worktree src write without ticket → exit 2" "got rc=$rc"
fi

rm -rf "$SB"

# --- AC2: path table (≥15) — head must not newly block anything dev blocks --
# Compare exit codes. Rule: if dev_rc==2 then head_rc must be 2.
# Also record the worktree-src row as the fix target (dev 0 → head 2).
SB=$(make_ops_with_worktrees)
EXT_WT=$(cat "$SB/.test-ext-wt")
OUTSIDE=$(mktemp -d)
OUTSIDE=$(cd "$OUTSIDE" && pwd -P)
mkdir -p "$OUTSIDE/.claude" "$OUTSIDE/docs"
printf 'x\n' > "$OUTSIDE/.claude/settings.json"
printf 'x\n' > "$OUTSIDE/docs/note.md"
printf 'x\n' > "$OUTSIDE/readme.md"
printf 'x\n' > "$OUTSIDE/plain.txt"

# Path table: label|path|expected rc (pre-fix rc is the same except wt-src,
# which the pre-fix gate allowed with rc=0 — the #1531 bug).
# shellcheck disable=SC2034
PATH_TABLE=$(cat <<EOF
main-src|$SB/src/main.ts|2
main-claude|$SB/.claude/settings.json|0
main-docs|$SB/docs/ops.md|0
main-proj-docs|$SB/projects/demo/docs/note.md|0
main-md|$SB/README.md|0
main-mig|$SB/migrations/001_init.sql|2
wt-src|$SB/.claude/worktrees/feat-x/src/a.ts|2
wt-claude|$SB/.claude/worktrees/feat-x/.claude/settings.json|0
wt-docs|$SB/.claude/worktrees/feat-x/docs/x.md|0
wt-md|$SB/.claude/worktrees/feat-x/README.md|0
ext-src|$EXT_WT/src/a.ts|2
ext-claude|$EXT_WT/.claude/settings.json|0
ext-docs|$EXT_WT/docs/x.md|0
out-claude|$OUTSIDE/.claude/settings.json|0
out-docs|$OUTSIDE/docs/note.md|0
out-md|$OUTSIDE/readme.md|0
out-plain|$OUTSIDE/plain.txt|0
EOF
)

# Prepare files that may not exist yet
: > "$SB/.claude/worktrees/feat-x/src/a.ts"
: > "$SB/.claude/worktrees/feat-x/.claude/settings.json"
: > "$SB/.claude/worktrees/feat-x/docs/x.md"
: > "$SB/.claude/worktrees/feat-x/README.md"
: > "$EXT_WT/src/a.ts"
: > "$EXT_WT/.claude/settings.json"
: > "$EXT_WT/docs/x.md"
: > "$SB/README.md"

# Run table against head
install_hook "$SB" "$HOOK_ACTIVE" "require-active-ticket.sh"
HEAD_RESULTS=$(mktemp)
while IFS='|' read -r label path _expected; do
  [ -n "$label" ] || continue
  rc=0
  run_active "$SB/.claude/hooks/require-active-ticket.sh" "$SB" "$path" || rc=$?
  printf '%s|%s\n' "$label" "$rc" >> "$HEAD_RESULTS"
done <<EOF
$PATH_TABLE
EOF

ROW_COUNT=$(wc -l < "$HEAD_RESULTS" | tr -d ' ')
if [ "$ROW_COUNT" -ge 15 ]; then
  record_pass "AC2 table has ≥15 paths (got $ROW_COUNT)"
else
  record_fail "AC2 table has ≥15 paths" "got $ROW_COUNT"
fi

echo "--- AC2 path table (label | expected | head) ---"
while IFS='|' read -r label path expected; do
  [ -n "$label" ] || continue
  h=$(awk -F'|' -v l="$label" '$1==l{print $2; exit}' "$HEAD_RESULTS")
  echo "  $label | expected=$expected | head=$h"
  if [ "$h" = "$expected" ]; then
    record_pass "AC2 $label → rc=$expected"
  else
    record_fail "AC2 $label → rc=$expected" "got rc=$h path=$path"
  fi
done <<EOF
$PATH_TABLE
EOF

rm -f "$HEAD_RESULTS"
rm -rf "$SB" "$OUTSIDE"

# --- AC3: stay exempt with no ticket --------------------------------------
SB=$(make_ops_with_worktrees)
install_hook "$SB" "$HOOK_ACTIVE" "require-active-ticket.sh"
: > "$SB/.claude/worktrees/feat-x/.claude/settings.json"
: > "$SB/.claude/worktrees/feat-x/docs/x.md"
: > "$SB/projects/demo/docs/note.md"
: > "$SB/some-note.md"

for label_path in \
  "wt-claude|$SB/.claude/worktrees/feat-x/.claude/settings.json" \
  "wt-docs|$SB/.claude/worktrees/feat-x/docs/x.md" \
  "ops-claude|$SB/.claude/settings.json" \
  "proj-docs|$SB/projects/demo/docs/note.md" \
  "any-md|$SB/some-note.md"
do
  label="${label_path%%|*}"
  path="${label_path#*|}"
  rc=0
  run_active "$SB/.claude/hooks/require-active-ticket.sh" "$SB" "$path" || rc=$?
  if [ "$rc" = "0" ]; then
    record_pass "AC3 exempt: $label"
  else
    record_fail "AC3 exempt: $label" "got rc=$rc path=$path"
  fi
done
rm -rf "$SB"

# --- Ticketed worktree writes still ALLOWED --------------------------------
SB=$(make_ops_with_worktrees)
install_hook "$SB" "$HOOK_ACTIVE" "require-active-ticket.sh"
: > "$SB/.claude/worktrees/feat-x/src/a.ts"
mkdir -p "$SB/.claude/session"
printf 'repo=test-org/test-repo\nnumber=42\n' > "$SB/.claude/session/current-ticket"
rc=0
run_active "$SB/.claude/hooks/require-active-ticket.sh" "$SB" \
  "$SB/.claude/worktrees/feat-x/src/a.ts" || rc=$?
if [ "$rc" = "0" ]; then
  record_pass "ticketed: ops fallback allows worktree src write"
else
  record_fail "ticketed: ops fallback allows worktree src write" "got rc=$rc"
fi
rm -f "$SB/.claude/session/current-ticket"

# Tier-0 per-worktree marker: need a workspace/<project> layout for project
# detection. Simulate via workspace/example linked to the same worktree path
# by writing under workspace/example which is a linked worktree of the ops
# fork — or set CLAUDE_WORKTREE_BRANCH with a workspace project path.
mkdir -p "$SB/workspace/example/src" "$SB/.claude/session/tickets/example"
# Make workspace/example a real linked worktree so git detects the branch.
(
  cd "$SB" || exit 1
  git worktree add -q -b wt-tier0 workspace/example >/dev/null 2>&1 || true
)
mkdir -p "$SB/workspace/example/src"
: > "$SB/workspace/example/src/a.ts"
printf 'repo=test-org/test-repo\nnumber=99\n' \
  > "$SB/.claude/session/tickets/example/wt-tier0"
export CLAUDE_WORKTREE_BRANCH=wt-tier0
rc=0
run_active "$SB/.claude/hooks/require-active-ticket.sh" "$SB" \
  "$SB/workspace/example/src/a.ts" || rc=$?
unset CLAUDE_WORKTREE_BRANCH
if [ "$rc" = "0" ]; then
  record_pass "ticketed: tier-0 per-worktree marker allows workspace write"
else
  record_fail "ticketed: tier-0 per-worktree marker allows workspace write" "got rc=$rc"
fi
rm -rf "$SB"

# --- Bash redirect into worktree source (same exemption logic) -------------
SB=$(make_ops_with_worktrees)
install_hook "$SB" "$HOOK_ACTIVE" "require-active-ticket.sh"
mkdir -p "$SB/.claude/worktrees/feat-x/src"
rc=0
run_active "$SB/.claude/hooks/require-active-ticket.sh" "$SB" \
  "echo x > $SB/.claude/worktrees/feat-x/src/a.ts" Bash || rc=$?
if [ "$rc" = "2" ]; then
  record_pass "Bash: redirect into worktree src without ticket → exit 2"
else
  record_fail "Bash: redirect into worktree src without ticket → exit 2" "got rc=$rc"
fi
rm -rf "$SB"

# --- Relative path into linked worktree must also block (#1531 hole) -------
# Absolute AC1 covers Edit/Write with full paths. Bash and some harnesses
# still pass a repo-relative target from the main-clone CWD.
SB=$(make_ops_with_worktrees)
install_hook "$SB" "$HOOK_ACTIVE" "require-active-ticket.sh"
mkdir -p "$SB/.claude/worktrees/feat-x/src"
: > "$SB/.claude/worktrees/feat-x/src/a.ts"
rc=0
run_active "$SB/.claude/hooks/require-active-ticket.sh" "$SB" \
  ".claude/worktrees/feat-x/src/a.ts" || rc=$?
if [ "$rc" = "2" ]; then
  record_pass "relative Write: worktree src without ticket → exit 2"
else
  record_fail "relative Write: worktree src without ticket → exit 2" "got rc=$rc"
fi
rc=0
run_active "$SB/.claude/hooks/require-active-ticket.sh" "$SB" \
  "echo x > .claude/worktrees/feat-x/src/a.ts" Bash || rc=$?
if [ "$rc" = "2" ]; then
  record_pass "relative Bash: worktree redirect without ticket → exit 2"
else
  record_fail "relative Bash: worktree redirect without ticket → exit 2" "got rc=$rc"
fi
rm -rf "$SB"

# --- Pre-review hardening (A1-A3) -------------------------------------------
# A1: with _lib-path-resolve.sh missing, the exemptions must still work, so
# /start-ticket can write its own marker.
SB=$(make_ops_with_worktrees)
install_hook "$SB" "$HOOK_ACTIVE" "require-active-ticket.sh"
rm -f "$SB/.claude/hooks/_lib-path-resolve.sh"
for label_path in \
  "no-resolve session marker|$SB/.claude/session/current-ticket" \
  "no-resolve ops docs|$SB/docs/x.svg" \
  "no-resolve worktree .claude|$SB/.claude/worktrees/feat-x/.claude/settings.json"
do
  label="${label_path%%|*}"
  path="${label_path#*|}"
  rc=0
  run_active "$SB/.claude/hooks/require-active-ticket.sh" "$SB" "$path" || rc=$?
  if [ "$rc" = "0" ]; then
    record_pass "A1 exempt: $label"
  else
    record_fail "A1 exempt: $label" "got rc=$rc"
  fi
done
rc=0
run_active "$SB/.claude/hooks/require-active-ticket.sh" "$SB" \
  "$SB/.claude/worktrees/feat-x/src/a.ts" || rc=$?
if [ "$rc" = "2" ]; then
  record_pass "A1 no-resolve: worktree src still gated"
else
  record_fail "A1 no-resolve: worktree src still gated" "got rc=$rc"
fi
rm -rf "$SB"

# A2: a worktree whose name has a space. Target extraction cuts the path at
# the space, which used to leave an exempt .claude/worktrees/... prefix.
SB=$(make_ops_with_worktrees)
install_hook "$SB" "$HOOK_ACTIVE" "require-active-ticket.sh"
(
  cd "$SB" || exit 1
  git worktree add -q -b feat-sp ".claude/worktrees/feat sp" >/dev/null 2>&1
)
mkdir -p "$SB/.claude/worktrees/feat sp/src"
rc=0
run_active "$SB/.claude/hooks/require-active-ticket.sh" "$SB" \
  "echo x > \"$SB/.claude/worktrees/feat sp/src/a.ts\"" Bash || rc=$?
if [ "$rc" = "2" ]; then
  record_pass "A2 Bash: worktree path with a space → exit 2"
else
  record_fail "A2 Bash: worktree path with a space → exit 2" "got rc=$rc"
fi
rm -rf "$SB"

# A3: a worktree that does not exist yet (created in the same command).
SB=$(make_ops_with_worktrees)
install_hook "$SB" "$HOOK_ACTIVE" "require-active-ticket.sh"
rc=0
run_active "$SB/.claude/hooks/require-active-ticket.sh" "$SB" \
  "$SB/.claude/worktrees/not-yet/src/a.ts" || rc=$?
if [ "$rc" = "2" ]; then
  record_pass "A3 Write: not-yet-created worktree src → exit 2"
else
  record_fail "A3 Write: not-yet-created worktree src → exit 2" "got rc=$rc"
fi
rc=0
run_active "$SB/.claude/hooks/require-active-ticket.sh" "$SB" \
  "$SB/.claude/worktrees/not-yet/NOTES.md" || rc=$?
if [ "$rc" = "0" ]; then
  record_pass "A3 Write: *.md under a not-yet-created worktree stays exempt"
else
  record_fail "A3 Write: *.md under a not-yet-created worktree stays exempt" "got rc=$rc"
fi
rm -rf "$SB"

# --- AC4: migration hook same exemption verdicts ---------------------------
# Meta paths → allow (0). Migration-shaped worktree path without ticket → 2.
SB=$(make_ops_with_worktrees)
install_hook "$SB" "$HOOK_MIG" "require-migration-ticket.sh"
install_libs "$SB/.claude/hooks"
mkdir -p "$SB/.claude/worktrees/feat-x/migrations"
: > "$SB/.claude/worktrees/feat-x/migrations/002.sql"
: > "$SB/.claude/worktrees/feat-x/.claude/settings.json"
: > "$SB/.claude/worktrees/feat-x/docs/x.md"

run_mig() {
  local hook="$1" sb="$2" file_path="$3"
  local input
  input=$(jq -nc --arg fp "$file_path" '{tool_name:"Write", tool_input:{file_path:$fp}}')
  (
    cd "$sb" || exit 99
    bash "$hook" <<<"$input" >/dev/null 2>&1
  )
  return $?
}

rc=0
run_mig "$SB/.claude/hooks/require-migration-ticket.sh" "$SB" \
  "$SB/.claude/worktrees/feat-x/.claude/settings.json" || rc=$?
[ "$rc" = "0" ] && record_pass "AC4 mig: worktree .claude exempt" \
  || record_fail "AC4 mig: worktree .claude exempt" "got rc=$rc"

rc=0
run_mig "$SB/.claude/hooks/require-migration-ticket.sh" "$SB" \
  "$SB/.claude/worktrees/feat-x/docs/x.md" || rc=$?
[ "$rc" = "0" ] && record_pass "AC4 mig: worktree docs exempt" \
  || record_fail "AC4 mig: worktree docs exempt" "got rc=$rc"

rc=0
run_mig "$SB/.claude/hooks/require-migration-ticket.sh" "$SB" \
  "$SB/projects/demo/docs/note.md" || rc=$?
[ "$rc" = "0" ] && record_pass "AC4 mig: projects/*/docs exempt" \
  || record_fail "AC4 mig: projects/*/docs exempt" "got rc=$rc"

rc=0
run_mig "$SB/.claude/hooks/require-migration-ticket.sh" "$SB" \
  "$SB/.claude/worktrees/feat-x/migrations/002.sql" || rc=$?
if [ "$rc" = "2" ]; then
  record_pass "AC4 mig head: worktree migration without ticket → exit 2"
else
  record_fail "AC4 mig head: worktree migration without ticket → exit 2" "got rc=$rc"
fi

rm -rf "$SB"

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases: $FAILED_CASES" >&2
  exit 1
fi
exit 0
