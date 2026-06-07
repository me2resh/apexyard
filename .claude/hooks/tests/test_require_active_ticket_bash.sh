#!/bin/bash
# Tests for require-active-ticket.sh — Bash-write coverage (#151) and
# bootstrap-skill exemption (#150).
#
# Each case:
#   - builds an isolated sandbox containing onboarding.yaml, an empty
#     registry, the hook script, the two libs it sources, and the shipped
#     project-config defaults
#   - optionally writes a current-ticket marker and/or active-bootstrap
#     marker to flip the gate
#   - pipes a synthetic PreToolUse JSON (Edit or Bash tool) to the hook
#   - asserts exit code (0=pass-through, 2=blocked) and stderr regex
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/require-active-ticket.sh"
LIB_BASH="$SRC_ROOT/.claude/hooks/_lib-detect-bash-write.sh"
LIB_CFG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"

for f in "$HOOK_SRC" "$LIB_BASH" "$LIB_CFG" "$DEFAULTS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

make_sandbox() {
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    : > onboarding.yaml
    : > apexyard.projects.yaml
    git add onboarding.yaml apexyard.projects.yaml
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session"
  cp "$HOOK_SRC" "$sb/.claude/hooks/require-active-ticket.sh"
  cp "$LIB_BASH" "$sb/.claude/hooks/_lib-detect-bash-write.sh"
  cp "$LIB_CFG"  "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$DEFAULTS" "$sb/.claude/project-config.defaults.json"
  chmod +x "$sb/.claude/hooks/require-active-ticket.sh"
  echo "$sb"
}

run_case() {
  local label="$1" want_rc="$2" want_stderr_regex="$3" input="$4" sb="$5"
  local got_stderr got_rc
  got_stderr=$(cd "$sb" && echo "$input" | bash .claude/hooks/require-active-ticket.sh 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:200})" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# --- Bash-write coverage (#151) -----------------------------------------

# 1. echo > .gitignore with no ticket → BLOCKED
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo x > .gitignore" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash echo redirect blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 2. python -c '...write_text...' on .gitignore w/o ticket → BLOCKED
#    (the exact bypass attempt from #151)
sb=$(make_sandbox)
in=$(jq -nc --arg c 'python3 -c "import pathlib; pathlib.Path(\".gitignore\").write_text(\"x\")"' \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash python write_text bypass blocked" 2 "BLOCKED" "$in" "$sb"

# 3. cat /file → allowed (read-only)
sb=$(make_sandbox)
in=$(jq -nc --arg c "cat /etc/hostname" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash read passes through" 0 "" "$in" "$sb"

# 4. echo > .claude/foo.json → allowed (path exemption catches it)
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo x > .claude/foo.json" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash write to .claude/ exempt" 0 "" "$in" "$sb"

# 5. tee /docs/note.md → allowed (path + .md exemption)
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo x | tee docs/note.md" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash write to .md exempt" 0 "" "$in" "$sb"

# --- Bootstrap-skill exemption (#150) -----------------------------------

# 6. Edit src/foo.ts, no ticket, NO bootstrap marker → BLOCKED
sb=$(make_sandbox)
in=$(jq -nc --arg p "$sb/src/foo.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "edit blocked w/o ticket no bootstrap" 2 "BLOCKED" "$in" "$sb"

# 7. Edit .gitignore, no ticket, BOOTSTRAP marker (setup) → allowed
sb=$(make_sandbox)
echo "setup" > "$sb/.claude/session/active-bootstrap"
in=$(jq -nc --arg p "$sb/.gitignore" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "edit allowed with setup bootstrap marker" 0 "" "$in" "$sb"

# 8. Edit src/foo.ts, no ticket, BOOTSTRAP marker (handover) → allowed
sb=$(make_sandbox)
echo "handover" > "$sb/.claude/session/active-bootstrap"
in=$(jq -nc --arg p "$sb/src/foo.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "edit allowed with handover bootstrap marker" 0 "" "$in" "$sb"

# 9. Edit src/foo.ts, no ticket, BOOTSTRAP marker (UNKNOWN skill) → BLOCKED
#    (only skills on the configured bootstrap_skills list are exempt)
sb=$(make_sandbox)
echo "some-random-skill" > "$sb/.claude/session/active-bootstrap"
in=$(jq -nc --arg p "$sb/src/foo.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "edit blocked when bootstrap marker is for non-listed skill" 2 "BLOCKED" "$in" "$sb"

# 10. Bash python write to .gitignore, BOOTSTRAP marker (setup) → allowed
#     (this is the exact /setup-runs-into-#151-bypass scenario from #150)
sb=$(make_sandbox)
echo "setup" > "$sb/.claude/session/active-bootstrap"
in=$(jq -nc --arg c 'python3 -c "import pathlib; pathlib.Path(\".gitignore\").write_text(\"x\")"' \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash write allowed with setup bootstrap" 0 "" "$in" "$sb"

# 11. Empty bootstrap marker → no exemption (treated as no marker)
sb=$(make_sandbox)
: > "$sb/.claude/session/active-bootstrap"
in=$(jq -nc --arg p "$sb/src/foo.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "edit blocked when bootstrap marker is empty" 2 "BLOCKED" "$in" "$sb"

# --- Active-ticket marker still works (regression for the legacy path) -

# 12. Edit src/foo.ts with a current-ticket marker → allowed
sb=$(make_sandbox)
cat > "$sb/.claude/session/current-ticket" <<EOF
repo=me2resh/apexyard
number=999
title=test
url=https://example.com
EOF
in=$(jq -nc --arg p "$sb/src/foo.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "edit allowed with active ticket marker" 0 "" "$in" "$sb"

# --- Per-worktree marker tier (#513) -----------------------------------

# NOTE: PROJECT resolution compares FILE_PATH against the hook's resolved
# OPS_ROOT (from `git rev-parse`, which canonicalises symlinks). On macOS
# mktemp returns a /var/... path that git reports as /private/var/..., so the
# file_path must use the realpath of the sandbox or the workspace prefix won't
# match. rsb = canonical sandbox path.

# 13. per-worktree marker present + matching branch → allowed
sb=$(make_sandbox)
rsb=$(cd "$sb" && pwd -P)
mkdir -p "$sb/.claude/session/tickets/myproj"
cat > "$sb/.claude/session/tickets/myproj/feature__x" <<EOF
repo=me2resh/apexyard
number=513
title=worktree A
EOF
in=$(jq -nc --arg p "$rsb/workspace/myproj/src/foo.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
export CLAUDE_WORKTREE_BRANCH="feature/x"
run_case "per-worktree marker honored on matching branch" 0 "" "$in" "$sb"
unset CLAUDE_WORKTREE_BRANCH

# 14. per-worktree isolation: marker exists for branch A, agent on branch B,
#     no per-project file, no current-ticket → BLOCKED (proves no collision)
sb=$(make_sandbox)
rsb=$(cd "$sb" && pwd -P)
mkdir -p "$sb/.claude/session/tickets/myproj"
cat > "$sb/.claude/session/tickets/myproj/feature__a" <<EOF
repo=me2resh/apexyard
number=513
title=worktree A
EOF
in=$(jq -nc --arg p "$rsb/workspace/myproj/src/foo.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
export CLAUDE_WORKTREE_BRANCH="feature/b"
run_case "per-worktree isolation: branch B not satisfied by branch A marker" 2 "BLOCKED" "$in" "$sb"
unset CLAUDE_WORKTREE_BRANCH

# 15. per-project FILE marker still works under a workspace path with no
#     worktree branch detected (single-agent regression)
sb=$(make_sandbox)
rsb=$(cd "$sb" && pwd -P)
mkdir -p "$sb/.claude/session/tickets"
cat > "$sb/.claude/session/tickets/myproj" <<EOF
repo=me2resh/apexyard
number=513
title=single agent
EOF
in=$(jq -nc --arg p "$rsb/workspace/myproj/src/foo.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "per-project file marker still works (no worktree)" 0 "" "$in" "$sb"

# 16. git linked-worktree detection (NO env var): a real linked worktree at
#     workspace/myproj on branch wt-x is detected via absolute git-dir vs
#     common-dir, tier-0 marker honored. Exercises the write/read-symmetric
#     detection path, not just the CLAUDE_WORKTREE_BRANCH shortcut.
sb=$(make_sandbox)
rsb=$(cd "$sb" && pwd -P)
( cd "$sb" && git worktree add -q workspace/myproj -b wt-x >/dev/null 2>&1 )
mkdir -p "$sb/.claude/session/tickets/myproj"
cat > "$sb/.claude/session/tickets/myproj/wt-x" <<EOF
repo=me2resh/apexyard
number=513
title=worktree via git detection
EOF
in=$(jq -nc --arg p "$rsb/workspace/myproj/foo.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "per-worktree via git linked-worktree detection (no env var)" 0 "" "$in" "$sb"

# --- #569: bash-write path-exemption fixes ------------------------------
# These cases prove the over-blocking described in #569 is gone, while
# preserving the gate for writes into tracked source paths.

# 17. cat > /tmp/x with no ticket → allowed (absolute path outside repo)
sb=$(make_sandbox)
in=$(jq -nc --arg c "cat > /tmp/commit-msg.txt" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash redirect to /tmp exempt (no ticket needed)" 0 "" "$in" "$sb"

# 18. echo > /var/tmp/scratch with no ticket → allowed (non-repo absolute path)
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo hello > /var/tmp/scratch.txt" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash redirect to /var/tmp exempt" 0 "" "$in" "$sb"

# 19. echo > .claude/session/foo with no ticket → allowed (exempt .claude/ path)
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo x > .claude/session/foo" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash redirect to .claude/ exempt" 0 "" "$in" "$sb"

# 20. cp src dst where dst is a .claude/ path → allowed (exempt destination)
sb=$(make_sandbox)
in=$(jq -nc --arg c "cp .claude/session/tickets/myproj .claude/session/current-ticket" \
      '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash cp to .claude/ destination exempt" 0 "" "$in" "$sb"

# 21. rm -f file.txt with no ticket → allowed (deletion-only, no content written)
sb=$(make_sandbox)
in=$(jq -nc --arg c "rm -f workspace/proj/.git/tmpfile" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash rm-only exempt (no ticket needed)" 0 "" "$in" "$sb"

# 22. rm -rf dir/ with no ticket → allowed (deletion-only)
sb=$(make_sandbox)
in=$(jq -nc --arg c "rm -rf /tmp/workdir" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash rm -rf exempt" 0 "" "$in" "$sb"

# 23. cat > \$VAR with no ticket → allowed (unresolvable variable target)
sb=$(make_sandbox)
in=$(jq -nc --arg c 'cat > "$CEO"' '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash redirect to shell variable exempt (unresolvable target)" 0 "" "$in" "$sb"

# 24. echo > src/app.ts with no ticket → STILL BLOCKED (tracked source path)
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo x > src/app.ts" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash redirect to tracked source still blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 25. rm followed by redirect into tracked source → STILL BLOCKED (not deletion-only)
sb=$(make_sandbox)
in=$(jq -nc --arg c "rm old.ts && echo x > src/app.ts" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash rm+redirect to tracked source still blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 25b. var WITH a path tail into tracked source → STILL BLOCKED (#582 review:
#      the blanket $* exemption was fail-open; var+tail must not bypass the gate).
sb=$(make_sandbox)
in=$(jq -nc --arg c 'echo x > $PWD/src/app.ts' '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash redirect to \$PWD/src tracked path still blocked" 2 "BLOCKED" "$in" "$sb"

# 25c. var-prefixed relative path tail → STILL BLOCKED (not a bare variable).
sb=$(make_sandbox)
in=$(jq -nc --arg c 'echo x > $D/app.ts' '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash redirect to \$D/app.ts (var+tail) still blocked" 2 "BLOCKED" "$in" "$sb"

# 25d. bare braced variable target → allowed (unresolvable scratch path).
sb=$(make_sandbox)
in=$(jq -nc --arg c 'cat > "${marker}"' '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash redirect to bare \${marker} exempt" 0 "" "$in" "$sb"

# 26. All #569 cases pass through when a current-ticket marker IS present (regression)
sb=$(make_sandbox)
cat > "$sb/.claude/session/current-ticket" <<EOF
repo=me2resh/apexyard
number=569
title=test
url=https://example.com
EOF
in=$(jq -nc --arg c "echo x > src/app.ts" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "bash redirect to tracked source allowed WITH active ticket" 0 "" "$in" "$sb"

# --- Summary -----------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
