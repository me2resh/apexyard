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

# --- #744 + #745: REPO_ROOT anchored to FILE_PATH not CWD (#744, #745) ------
#
# These tests exercise the fix for me2resh/apexyard#744 / #745.  The core
# failure: `git rev-parse --show-toplevel` ran from the HOOK'S CWD, not from
# the edited file's directory.  When the harness fires with CWD=/tmp (or any
# dir that isn't the file's git repo), REPO_ROOT resolves to "" or the wrong
# tree, the OPS_ROOT walk-up never finds the ops fork, MARKER_HOME becomes "."
# (relative), and the per-project marker is missed → gate fails closed even
# though /start-ticket set a valid marker.

LIB_OPS_SRC="$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"
LIB_PORT_SRC="$SRC_ROOT/.claude/hooks/_lib-portfolio-paths.sh"

# Helper: run hook from an arbitrary CWD, using the hook's absolute path.
# Args: label want_rc want_stderr_regex input sandbox_dir run_cwd
# Deletes sandbox_dir on completion (same lifecycle as run_case).
run_case_cwd() {
  local label="$1" want_rc="$2" want_stderr_regex="$3" input="$4" sb="$5" run_cwd="$6"
  local got_stderr got_rc
  got_stderr=$(cd "$run_cwd" && echo "$input" | bash "$sb/.claude/hooks/require-active-ticket.sh" 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:300})" >&2
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

# 27. #744 core: file under <ops_root>/workspace/myproj/src/x.ts, valid
#     per-project marker, hook runs with CWD=/tmp.  Before the fix the gate
#     fails closed (REPO_ROOT="" → MARKER_HOME="." → marker not found).
#     After the fix REPO_ROOT is derived from FILE_PATH, OPS_ROOT is found
#     by walking up from the workspace dir, and the marker is found → exit 0.
sb=$(make_sandbox)
rsb=$(cd "$sb" && pwd -P)
mkdir -p "$sb/workspace/myproj/src"
mkdir -p "$sb/.claude/session/tickets"
cat > "$sb/.claude/session/tickets/myproj" <<EOF
repo=me2resh/myproj
number=744
title=anchor fix test
EOF
in=$(jq -nc --arg p "$rsb/workspace/myproj/src/x.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case_cwd "#744 core: file in workspace, valid marker, CWD=/tmp → exempt" 0 "" "$in" "$sb" "/tmp"

# 28. #744 regression: same layout, NO marker, CWD=/tmp → gate still BLOCKS.
sb=$(make_sandbox)
rsb=$(cd "$sb" && pwd -P)
mkdir -p "$sb/workspace/myproj/src"
in=$(jq -nc --arg p "$rsb/workspace/myproj/src/x.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case_cwd "#744 regression: no marker, CWD=/tmp → still blocked" 2 "BLOCKED" "$in" "$sb" "/tmp"

# 29. #744 .claude/ path still exempt with CWD=/tmp (path-exemption regression).
sb=$(make_sandbox)
rsb=$(cd "$sb" && pwd -P)
in=$(jq -nc --arg p "$rsb/.claude/hooks/my-hook.sh" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case_cwd "#744 .claude/ path still exempt even with wrong CWD" 0 "" "$in" "$sb" "/tmp"

# 30. #745 split-portfolio: ops fork and workspace are SIBLING directories;
#     workspace_dir is configured (absolute path) in the ops fork's project-config;
#     per-project marker lives in the ops fork; ops root is resolved via the
#     session pin (CLAUDE_CODE_SESSION_ID + pin file at $HOME/.claude/apexyard/).
#     CWD=/tmp.  Expected: exempt (exit 0).
#
#     This mirrors the production split-portfolio v2 scenario where:
#       <ops_fork>/            ← apexyard framework fork
#         .apexyard-fork
#         .claude/project-config.json   (portfolio.workspace_dir = absolute sibling path)
#         .claude/session/tickets/myproj
#       <sibling_ws>/          ← private portfolio workspace (sibling, NOT under ops fork)
#         myproj/src/x.ts      ← file being edited
#     The session-start pin-ops-root.sh hook records ops_fork in
#     ~/.claude/apexyard/ops-root-<SESSION_ID> so resolve_ops_root finds it
#     even when the hook fires with CWD=/tmp.
_t30_ops=$(mktemp -d)
_t30_ws=$(mktemp -d)
_t30_ops_real=$(cd "$_t30_ops" && pwd -P)
_t30_ws_real=$(cd "$_t30_ws" && pwd -P)

# Bootstrap the ops fork
(
  cd "$_t30_ops" || exit 1
  git init -q
  git config user.email "test@example.com"
  git config user.name "test"
  : > .apexyard-fork
  : > onboarding.yaml
  : > apexyard.projects.yaml
  git add .apexyard-fork onboarding.yaml apexyard.projects.yaml
  git commit -q -m "init"
)

# Install hook + libs into ops fork
mkdir -p "$_t30_ops/.claude/hooks"
cp "$HOOK_SRC"  "$_t30_ops/.claude/hooks/require-active-ticket.sh"
cp "$LIB_BASH"  "$_t30_ops/.claude/hooks/_lib-detect-bash-write.sh"
cp "$LIB_CFG"   "$_t30_ops/.claude/hooks/_lib-read-config.sh"
cp "$DEFAULTS"  "$_t30_ops/.claude/project-config.defaults.json"
[ -f "$LIB_OPS_SRC" ]  && cp "$LIB_OPS_SRC"  "$_t30_ops/.claude/hooks/_lib-ops-root.sh"
[ -f "$LIB_PORT_SRC" ] && cp "$LIB_PORT_SRC" "$_t30_ops/.claude/hooks/_lib-portfolio-paths.sh"
chmod +x "$_t30_ops/.claude/hooks/require-active-ticket.sh"

# Configure workspace_dir to the sibling path (absolute in config so
# _portfolio_resolve returns it directly without needing _portfolio_root).
cat > "$_t30_ops/.claude/project-config.json" <<EOF
{
  "portfolio": {
    "workspace_dir": "$_t30_ws_real"
  }
}
EOF

# Per-project marker in ops fork
mkdir -p "$_t30_ops/.claude/session/tickets"
cat > "$_t30_ops/.claude/session/tickets/myproj" <<EOF
repo=me2resh/myproj
number=745
title=split-portfolio anchor fix
EOF

# Project dir in sibling workspace
mkdir -p "$_t30_ws/myproj/src"

# Write a session pin so resolve_ops_root finds ops_fork from CWD=/tmp.
# Use a HERMETIC temp pin dir (not the real $HOME/.claude/apexyard) so the test
# is deterministic in CI and never reads/pollutes the operator's real pin store.
_t30_sid="apexyard-test745-$$"
_t30_pin_dir=$(mktemp -d)
printf '%s\n' "$_t30_ops_real" > "$_t30_pin_dir/ops-root-${_t30_sid}"

_t30_in=$(jq -nc --arg p "$_t30_ws_real/myproj/src/x.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')

# Re-enable the pin for THIS invocation: bin/run-hook-tests.sh exports
# APEXYARD_OPS_DISABLE_PIN=1 suite-wide (so the suite never reads the operator's
# real pin), but this case deliberately exercises pin-based split-portfolio
# resolution, so we override it back to empty for the hook call only.
_t30_stderr=$(cd /tmp && echo "$_t30_in" | \
  CLAUDE_CODE_SESSION_ID="$_t30_sid" \
  APEXYARD_OPS_PIN_DIR="$_t30_pin_dir" \
  APEXYARD_OPS_DISABLE_PIN='' \
  bash "$_t30_ops/.claude/hooks/require-active-ticket.sh" 2>&1 >/dev/null)
_t30_rc=$?

# Cleanup
rm -rf "$_t30_ops" "$_t30_ws"
rm -f "$_t30_pin_dir/ops-root-${_t30_sid}"

_t30_label="#745 split-portfolio: sibling workspace, session pin → exempt"
if [ "$_t30_rc" != "0" ]; then
  echo "FAIL [$_t30_label]: want rc=0, got $_t30_rc (stderr: ${_t30_stderr:0:300})" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${_t30_label} "
else
  echo "PASS [$_t30_label]"
  PASS=$((PASS+1))
fi

# --- Out-of-governance exemption (#883): the ~/.zshrc-style bug repro --
#
# Prior to #883, the "outside the repo" exemption (#569) only fired for
# the Bash-write path — an Edit-tool write to a home dotfile like
# ~/.zshrc was gated with no legitimate way to satisfy the gate on a fork
# with GitHub Issues disabled (no tracker to file a chore ticket in).
# These cases prove the fix (Edit/MultiEdit AND Bash, symlinks resolved,
# governed-tree boundaries unchanged).

# 31. Edit tool absolute write to a home-dotfile-style path OUTSIDE any
#     git repo and OUTSIDE the ops fork, no ticket → EXEMPT. The core
#     #883 repro.
sb=$(make_sandbox)
home_sim=$(mktemp -d)
in=$(jq -nc --arg p "$home_sim/.zshrc" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "#883 Edit-tool write to out-of-repo dotfile exempt (no ticket)" 0 "" "$in" "$sb"
rm -rf "$home_sim"

# 32. Same but MultiEdit tool shape (file_path key) → EXEMPT.
sb=$(make_sandbox)
home_sim=$(mktemp -d)
in=$(jq -nc --arg p "$home_sim/.bashrc" '{tool_name:"MultiEdit", tool_input:{file_path:$p}}')
run_case "#883 MultiEdit-tool write to out-of-repo dotfile exempt" 0 "" "$in" "$sb"
rm -rf "$home_sim"

# 33. Bash relative write from a CWD entirely outside any git repo /
#     governed tree (simulates `cd ~ && echo 'export X=1' >> .zshrc`)
#     → EXEMPT. Uses run_case_cwd so the hook actually executes with
#     CWD=home_sim (not the sandbox) and has no session pin to fall back
#     on — proving the exemption doesn't depend on the ops root being
#     resolvable.
sb=$(make_sandbox)
home_sim=$(mktemp -d)
in=$(jq -nc --arg c "echo 'export X=1' >> .zshrc" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case_cwd "#883 bash relative write from out-of-repo CWD exempt" 0 "" "$in" "$sb" "$home_sim"
rm -rf "$home_sim"

# 34. In-repo source Edit write is UNCHANGED — still blocked without a
#     ticket (regression guard: the new exemption must not widen scope
#     for governed content).
sb=$(make_sandbox)
mkdir -p "$sb/src"
rsb=$(cd "$sb" && pwd -P)
in=$(jq -nc --arg p "$rsb/src/app.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "#883 regression: in-repo Edit write still blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 35. Symlink from OUTSIDE the repo INTO the governed sandbox tree must
#     NOT bypass the gate: resolving the write target's real path (not
#     its literal path) is what fail-closed requires.
sb=$(make_sandbox)
rsb=$(cd "$sb" && pwd -P)
mkdir -p "$sb/src"
home_sim=$(mktemp -d)
ln -s "$rsb" "$home_sim/link-into-repo"
in=$(jq -nc --arg p "$home_sim/link-into-repo/src/app.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "#883 symlink into governed repo does NOT bypass gate" 2 "BLOCKED" "$in" "$sb"
rm -rf "$home_sim"

# 36. Symlink case WITH an active ticket → allowed (proves the symlink IS
#     correctly resolved to governed content, and the normal ticket-gate
#     logic — not the out-of-governance exemption — is what applies).
sb=$(make_sandbox)
rsb=$(cd "$sb" && pwd -P)
mkdir -p "$sb/src"
cat > "$sb/.claude/session/current-ticket" <<EOF
repo=me2resh/apexyard
number=883
title=symlink test
EOF
home_sim=$(mktemp -d)
ln -s "$rsb" "$home_sim/link-into-repo"
in=$(jq -nc --arg p "$home_sim/link-into-repo/src/app.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "#883 symlink into governed repo allowed WITH active ticket" 0 "" "$in" "$sb"
rm -rf "$home_sim"

# 37. Workspace-project write (governed, even without its own .git) still
#     blocks without a ticket — proves the explicit WORKSPACE_DIR check
#     (not merely "is this a git repo") governs the boundary. Mirrors the
#     #745 split-portfolio layout, where a workspace project clone may
#     have no .git of its own.
sb=$(make_sandbox)
rsb=$(cd "$sb" && pwd -P)
mkdir -p "$sb/workspace/myproj/src"
in=$(jq -nc --arg p "$rsb/workspace/myproj/src/x.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "#883 workspace-project write (no .git) still blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 38. Unresolvable Bash write target (embedded interpreter, no
#     extractable path) remains categorically gated — fail-closed,
#     unchanged. The out-of-governance check must never fire on an empty
#     FILE_PATH.
sb=$(make_sandbox)
in=$(jq -nc --arg c "python3 -c \"import pathlib,os; pathlib.Path(os.environ.get('HOME','/tmp')+'/.railsrc').write_text('x')\"" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#883 unresolvable bash target stays gated (fail-closed)" 2 "BLOCKED" "$in" "$sb"

# --- Security review finding on PR #885 (Hakim): symlinked-out non-git --
# --- workspace project must NOT be exempted -----------------------------
#
# A registered workspace/<proj> that is ITSELF a symlink whose real
# target lives OUTSIDE workspace/ in a directory that is not itself a git
# repo used to be wrongly exempted: resolving the symlink made the
# containment checks read "outside ops, outside workspace, not a git
# repo" even though the RAW path plainly names a governed
# workspace/<project> location. The fix evaluates ops/workspace
# containment against BOTH the raw and the resolved target.

# 39. workspace/proj -> <external non-git dir>; write through the raw
#     workspace/proj path, no ticket → BLOCKED (was wrongly EXEMPT
#     before the raw-AND-resolved fix).
sb=$(make_sandbox)
rsb=$(cd "$sb" && pwd -P)
mkdir -p "$sb/workspace"
external=$(mktemp -d)
mkdir -p "$external/src"
ln -s "$external" "$sb/workspace/proj"
in=$(jq -nc --arg p "$rsb/workspace/proj/src/x.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "#885 symlinked-out non-git workspace project still blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"
rm -rf "$external"

# 40. Same symlinked-out workspace project, WITH an active ticket marker
#     → ALLOWED. Keeps the existing "symlink governed content works with
#     a ticket" behaviour coherent: the raw-containment check correctly
#     routes this through the normal ticket-gate logic (not the
#     out-of-governance exemption), and the ticket marker satisfies it.
sb=$(make_sandbox)
rsb=$(cd "$sb" && pwd -P)
mkdir -p "$sb/workspace"
external=$(mktemp -d)
mkdir -p "$external/src"
ln -s "$external" "$sb/workspace/proj"
cat > "$sb/.claude/session/current-ticket" <<EOF
repo=me2resh/apexyard
number=885
title=symlinked-out workspace project test
EOF
in=$(jq -nc --arg p "$rsb/workspace/proj/src/x.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
run_case "#885 symlinked-out non-git workspace project allowed WITH active ticket" 0 "" "$in" "$sb"
rm -rf "$external"

# --- #886: judge ALL bash write targets, not just the first ------------
#
# The bypass shape: a command names an out-of-repo (or otherwise exempt)
# target FIRST and an in-repo target SECOND. Before #886, the hook judged
# only the first extracted target — an exempt first target let the whole
# command through even though it also wrote somewhere gated.

# 41. Multi-target: /tmp (exempt) THEN src/app.ts (gated), no ticket →
#     BLOCKED. This is the exact bypass the #885 review surfaced.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo a > /tmp/x; echo b > src/app.ts" \
      '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 multi-target (out-of-repo then in-repo) blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 42. Same multi-target command, WITH an active ticket → ALLOWED (every
#     target independently clears the gate).
sb=$(make_sandbox)
cat > "$sb/.claude/session/current-ticket" <<EOF
repo=me2resh/apexyard
number=886
title=multi-target bash write test
EOF
in=$(jq -nc --arg c "echo a > /tmp/x; echo b > src/app.ts" \
      '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 multi-target (out-of-repo then in-repo) allowed WITH ticket" 0 "" "$in" "$sb"

# 43. Regression: a SINGLE out-of-repo target (no second target) remains
#     exempt — the per-target loop must not become stricter than before
#     for the plain single-target case.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo a > /tmp/x" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 regression: single out-of-repo target still exempt" 0 "" "$in" "$sb"

# 44. Regression: a SINGLE in-repo target (no other target) remains gated
#     w/o a ticket — same as before #886.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo a > src/app.ts" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 regression: single in-repo target still blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 45. tee naming BOTH an out-of-repo and an in-repo file in one invocation
#     (`tee /tmp/a src/b.ts`) — both are targets of the SAME command, no
#     ticket → BLOCKED on the in-repo one.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo x | tee /tmp/a src/b.ts" \
      '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 tee with out-of-repo + in-repo operands blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# --- #886/#926: NO-SPACE separator+redirection (Hakim security-review) --
#
# `echo a > /tmp/ok;> .gitignore` — after splitting on `;`, the second
# segment is `> .gitignore`, which BEGINS with `>`. The pre-fix regex
# `[^|<&]>...` required a character before `>` to exist, so this second,
# in-repo target was silently dropped and the whole command exempted on
# the first (out-of-repo) target alone. These are Hakim's exact repro
# strings, now expected to BLOCK.

# 46. No-space `;` then redirect, no ticket → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo a > /tmp/ok;> .gitignore" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 no-space ';' then redirect blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 47. Same command, WITH an active ticket → ALLOWED (both targets clear).
sb=$(make_sandbox)
cat > "$sb/.claude/session/current-ticket" <<EOF
repo=me2resh/apexyard
number=886
title=no-space redirection bypass test
EOF
in=$(jq -nc --arg c "echo a > /tmp/ok;> .gitignore" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 no-space ';' then redirect allowed WITH ticket" 0 "" "$in" "$sb"

# 48. No-space `;` + redirect with a trailing command appended, no ticket
#     → BLOCKED (the trailing `cat /etc/hostname` must not swallow the
#     dropped target or change the verdict).
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo a > /tmp/ok;> .gitignore cat /etc/hostname" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 no-space ';' + redirect with trailing command blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 49. No-space `&&` then redirect, no ticket → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo a > /tmp/ok&&> .gitignore" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 no-space '&&' then redirect blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 50. No-space `|` then redirect, no ticket → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo a > /tmp/ok|> .gitignore" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 no-space '|' then redirect blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 51. No-space `||` then redirect, no ticket → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo a > /tmp/ok||> .gitignore" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 no-space '||' then redirect blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# --- #886/#926 round 3: &>, &>>, >|, >>| (Hakim adversarial re-hunt) ----
#
# The operator alternation only modelled `>`/`>>`/`n>` — it missed
# `&>`/`&>>` (redirect BOTH streams to a file) and `>|`/`>>|`
# (force-clobber, noclobber override). Both are real, destructive
# truncating writes that were passing (exit 0) with no active ticket.

# 52. `&>` (redirect-both-streams) into an in-repo file, no ticket → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo hi &> .gitignore" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 '&>' redirect-both-streams blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 53. Same command, WITH an active ticket → ALLOWED.
sb=$(make_sandbox)
cat > "$sb/.claude/session/current-ticket" <<EOF
repo=me2resh/apexyard
number=886
title=redirect-both-streams operator test
EOF
in=$(jq -nc --arg c "echo hi &> .gitignore" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 '&>' redirect-both-streams allowed WITH ticket" 0 "" "$in" "$sb"

# 54. `&>>` (append-both-streams) into an in-repo file, no ticket → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo hi &>> .gitignore" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 '&>>' append-both-streams blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 55. `>|` (force-clobber) after a no-space `;`, out-of-repo THEN in-repo,
#     no ticket → BLOCKED on the in-repo (migration-shaped) target. This is
#     Hakim's exact second repro.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo a > /tmp/ok;>| db/migrations/006.sql" \
      '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 '>|' force-clobber blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 56. Same command, WITH an active ticket → ALLOWED (both targets clear).
sb=$(make_sandbox)
cat > "$sb/.claude/session/current-ticket" <<EOF
repo=me2resh/apexyard
number=886
title=force-clobber operator test
EOF
in=$(jq -nc --arg c "echo a > /tmp/ok;>| db/migrations/006.sql" \
      '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 '>|' force-clobber allowed WITH ticket" 0 "" "$in" "$sb"

# 57. `>>|` (force-clobber-append) variant, no ticket → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo a > /tmp/ok;>>| db/migrations/006.sql" \
      '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 '>>|' force-clobber-append blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# --- Sanity: fd-dup / read forms must NOT be newly gated ---------------
#
# `>&2` / `2>&1` / `1>&2` are fd-duplication (redirecting one fd to
# ANOTHER fd), never a file write — the broadened operator set must not
# start treating them as write targets. `< file` is a plain read.

# 58. `echo err >&2` (fd-dup only, no in-repo write) — no ticket, still
#     ALLOWED (nothing here is a write target at all).
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo err >&2" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 sanity: '>&2' fd-dup alone is not gated" 0 "" "$in" "$sb"

# 59. `make build 2>&1` — no ticket, still ALLOWED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "make build 2>&1" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 sanity: '2>&1' fd-dup alone is not gated" 0 "" "$in" "$sb"

# 60. `cat < src/app.ts` — a plain READ of a tracked file, no ticket →
#     still ALLOWED (reading is not gated; only writes are).
sb=$(make_sandbox)
in=$(jq -nc --arg c "cat < src/app.ts" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 sanity: plain '<' read is not gated" 0 "" "$in" "$sb"

# --- #886/#926 round 4: ZERO whitespace between operator and target -----
#
# Hakim's fourth adversarial re-hunt: the mandatory `[[:space:]]+` after
# the operator was itself a bypass — bash accepts ZERO whitespace between
# a redirect operator and its target. All five of these are real,
# destructive truncating writes that were passing (exit 0) with no ticket.

# 61. `>` with no space at all, no ticket → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo hi>src/migrations/001.sql" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 no-space '>' (Hakim repro) blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 62. Same command, WITH an active ticket → ALLOWED.
sb=$(make_sandbox)
cat > "$sb/.claude/session/current-ticket" <<EOF
repo=me2resh/apexyard
number=886
title=no-whitespace redirect operator test
EOF
in=$(jq -nc --arg c "echo hi>src/migrations/001.sql" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 no-space '>' allowed WITH ticket" 0 "" "$in" "$sb"

# 63. `2>` (fd-numbered) with no space, no ticket → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo a > /tmp/ok; echo b 2>src/migrations/001.sql" \
      '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 no-space 'n>' fd-numbered blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 64. `>>` with no space, no ticket → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo a > /tmp/ok; echo b>>src/migrations/001.sql" \
      '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 no-space '>>' blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 65. `>|` (force-clobber) with no space, no ticket → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo a > /tmp/ok; echo b>|src/migrations/001.sql" \
      '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 no-space '>|' blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 66. `&>` (redirect-both-streams) with no space, no ticket → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo a > /tmp/ok; echo b&>src/migrations/001.sql" \
      '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 no-space '&>' blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# --- Sanity: no-space fd-dup / read forms must NOT be newly gated ------

# 67. `echo err>&2` (fd-dup, NO space either) — no ticket, still ALLOWED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo err>&2" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 sanity: no-space '>&2' fd-dup is not gated" 0 "" "$in" "$sb"

# 68. `make build 2>&1;true` (fd-dup, no space) — no ticket, still ALLOWED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "make build 2>&1;true" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 sanity: no-space '2>&1' fd-dup is not gated" 0 "" "$in" "$sb"

# --- #886/#926 round 5: STRUCTURAL fix — |/||-adjacent redirects --------
#
# Hakim's fifth adversarial re-hunt found the actual root cause: DETECTION
# (bash_command_appears_to_write) ran the redirection matcher on the
# WHOLE, unsplit command, where a `|`-preceded `>` is excluded by the
# leading-context class (needed for `2>&1`/`>&2`) and isn't at `^` either.
# EXTRACTION already split first and found the target correctly —
# detection and extraction disagreed. `;>` and `&&>` survived earlier
# rounds by coincidence (`;` isn't excluded; `&&>` contains the substring
# `&>`); `|`/`||` had no such rescue. These are real, truncating writes.

# 69. `false ||> src/app.ts` (Hakim repro), no ticket → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "false ||> src/app.ts" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 '||>' after false blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 70. Same command, WITH an active ticket → ALLOWED.
sb=$(make_sandbox)
cat > "$sb/.claude/session/current-ticket" <<EOF
repo=me2resh/apexyard
number=886
title=pipe-adjacent redirect operator test
EOF
in=$(jq -nc --arg c "false ||> src/app.ts" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 '||>' after false allowed WITH ticket" 0 "" "$in" "$sb"

# 71. `false ||>| src/app.ts` (force-clobber variant, Hakim repro), no
#     ticket → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "false ||>| src/app.ts" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 '||>|' force-clobber after false blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 72. `echo x |> src/app.ts` (single-pipe variant, Hakim repro), no ticket
#     → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo x |> src/app.ts" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 '|>' after echo blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# 73. The deletion-only bypass: `rm old.ts; false ||> src/app.ts` — a real
#     write hiding behind a pipe-adjacent redirect alongside an rm. Must
#     NOT be classified as deletion-only; no ticket → BLOCKED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "rm old.ts; false ||> src/app.ts" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 rm + '||>' hides a real write, blocked w/o ticket" 2 "BLOCKED" "$in" "$sb"

# --- Sanity: pipe-adjacent fd-dup / reads must NOT be newly gated -------

# 74. `echo x | cat 2>&1` — pipe THEN fd-dup, no in-repo write at all →
#     still ALLOWED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "echo x | cat 2>&1" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 sanity: pipe then '2>&1' fd-dup is not gated" 0 "" "$in" "$sb"

# 75. `false || echo err >&2` — or-chain THEN fd-dup, no in-repo write →
#     still ALLOWED.
sb=$(make_sandbox)
in=$(jq -nc --arg c "false || echo err >&2" '{tool_name:"Bash", tool_input:{command:$c}}')
run_case "#886 sanity: '||' then '>&2' fd-dup is not gated" 0 "" "$in" "$sb"

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
