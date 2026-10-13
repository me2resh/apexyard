#!/bin/bash
# Tests for the Agent Gate Contract pilot (me2resh/apexyard#1698, AgDR-0237):
# block-ambient-tracker-repo.sh in its normal, repair and preview modes, and
# the dispatch-bash.sh repair pass in Claude Code, Codex and OpenCode shapes.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOKS="${HOOKS_OVERRIDE:-$SRC_ROOT/.claude/hooks}"
HOOK="$HOOKS/block-ambient-tracker-repo.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export APEXYARD_OPS_DISABLE_PIN=1
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR APEXYARD_CODEX_HOOK_TOOL APEXYARD_AGC_MODE || true
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; FAIL=$((FAIL + 1)); }

make_repo() {
  local root="$1" origin="$2"
  mkdir -p "$root"
  : > "$root/.apexyard-fork"
  git init -q --template= "$root"
  git -C "$root" remote add origin "$origin"
}

add_project() {
  local root="$1" name="$2" repo="$3"
  [ -f "$root/apexyard.projects.yaml" ] || printf 'projects:\n' > "$root/apexyard.projects.yaml"
  printf '  - name: %s\n    repo: %s\n' "$name" "$repo" >> "$root/apexyard.projects.yaml"
  mkdir -p "$root/workspace"
  git init -q --template= "$root/workspace/$name"
  printf '%s\n' "repo=$repo" > "$root/workspace/$name/.git/apexyard-ticket"
}

payload() {
  jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c, description: "test call"}}'
}

# claude_payload adds the fields Claude Code sends with every hook call.
claude_payload() {
  jq -nc --arg c "$1" '{session_id: "s", transcript_path: "/tmp/t.jsonl", cwd: "/tmp", permission_mode: "default",
    hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c, description: "test call"}}'
}

# hook_run <mode> <command> <root>: runs the hook, stdout to $TMP/out,
# stderr to $TMP/err, and sets RC.
hook_run() {
  local mode="$1" command="$2" root="$3"
  RC=0
  (cd "$root" && payload "$command" | APEXYARD_AGC_MODE="$mode" "$HOOK" >"$TMP/out" 2>"$TMP/err") || RC=$?
}

single="$TMP/single"
make_repo "$single" "git@github.com:owner/framework.git"
add_project "$single" demo owner/project

multiple="$TMP/multiple"
make_repo "$multiple" "git@github.com:owner/framework.git"
add_project "$multiple" a owner/project-a
add_project "$multiple" b owner/project-b

matching="$TMP/matching"
make_repo "$matching" "git@github.com:owner/project.git"
add_project "$matching" demo owner/project

# --- The hook in preview mode -------------------------------------------------

hook_run preview 'gh issue view 42' "$single"
if [ "$RC" -eq 0 ] && jq -e '.agc == "0.1" and .verdict == "repaired"
    and .findings[0].remedy == {kind: "rewrite", applied: true, input: {command: "gh issue view --repo owner/project 42"}}
    and .findings[0].check.kind == "preview" and .attempt == {n: 1, budget: 3}
    and (.subject.fingerprint | startswith("sha256:"))' "$TMP/out" >/dev/null; then
  pass 'preview: a single-target call is repaired with --repo after the subcommand'
else
  fail 'preview: a single-target call is repaired with --repo after the subcommand' "$TMP/out"
fi

hook_run preview 'gh pr list' "$multiple"
if [ "$RC" -eq 0 ] && jq -e '.verdict == "block" and .findings[0].remedy.kind == "delegate"
    and (.findings[0].what | contains("owner/project-a, owner/project-b"))' "$TMP/out" >/dev/null; then
  pass 'preview: two active targets give a block with a delegate remedy, and exit 0'
else
  fail 'preview: two active targets give a block with a delegate remedy, and exit 0' "$TMP/out"
fi

hook_run preview 'gh issue view 42' "$matching"
if [ "$RC" -eq 0 ] && jq -e '.verdict == "allow" and .findings == []' "$TMP/out" >/dev/null; then
  pass 'preview: a matching checkout gives allow'
else
  fail 'preview: a matching checkout gives allow' "$TMP/out"
fi

hook_run preview 'cd x && gh pr list' "$single"
if [ "$RC" -eq 0 ] && jq -e '.verdict == "block" and .findings[0].remedy.kind == "delegate"' "$TMP/out" >/dev/null; then
  pass 'preview: a compound command is not repaired'
else
  fail 'preview: a compound command is not repaired' "$TMP/out"
fi

# --- The hook in normal and repair mode ----------------------------------------

hook_run '' 'gh issue view 42' "$single"
agc_line=$(sed -n '/^```agc$/{n;p;}' "$TMP/err")
if [ "$RC" -eq 2 ] && grep -q '^BLOCKED: tracker command has no explicit repository' "$TMP/err" \
  && jq -e '.verdict == "block" and .findings[0].remedy == {kind: "command", run: "gh issue view --repo owner/project 42"}' <<<"$agc_line" >/dev/null \
  && [ ! -s "$TMP/out" ]; then
  pass 'normal mode still blocks, and adds the AGC object with the exact command on stderr'
else
  fail 'normal mode still blocks, and adds the AGC object with the exact command on stderr' "$TMP/err"
fi

hook_run repair 'gh pr create --title "a b" --body x' "$single"
if [ "$RC" -eq 0 ] && jq -e '.findings[0].remedy.input.command == "gh pr create --repo owner/project --title \"a b\" --body x"' "$TMP/out" >/dev/null; then
  pass 'repair mode: quoted arguments after the subcommand stay unchanged'
else
  fail 'repair mode: quoted arguments after the subcommand stay unchanged' "$TMP/out"
fi

for shape in 'gh pr list; rm -rf x' 'gh pr list | cat' 'gh pr list $(echo x)' 'FOO=1 gh pr list' 'gh pr list # note'; do
  hook_run repair "$shape" "$single"
  if [ "$RC" -eq 2 ] && [ ! -s "$TMP/out" ]; then
    pass "repair mode: no repair for: $shape"
  else
    fail "repair mode: no repair for: $shape" "$TMP/out"
  fi
done

hook_run repair 'gh pr list' "$multiple"
if [ "$RC" -eq 2 ] && [ ! -s "$TMP/out" ]; then
  pass 'repair mode: two targets still block'
else
  fail 'repair mode: two targets still block' "$TMP/out"
fi

unsafe="$TMP/unsafe"
make_repo "$unsafe" "git@github.com:owner/framework.git"
add_project "$unsafe" demo 'owner/project;touch-pwned'
hook_run repair 'gh pr list' "$unsafe"
if [ "$RC" -eq 2 ] && [ ! -s "$TMP/out" ]; then
  pass 'repair mode: a target that is not a plain owner/repo is never written into a command'
else
  fail 'repair mode: a target that is not a plain owner/repo is never written into a command' "$TMP/out"
fi

# --- The dispatcher repair pass ------------------------------------------------
# Real dispatcher, real tracker hook and real libraries. Every other gate is a
# stub that passes, except block-privileged-escalation.sh, which blocks the
# rewritten command when RECHECK_BLOCK is set. That proves the gates judge the
# rewritten call, not the original one.

D="$TMP/dispatch"
mkdir -p "$D"
cp "$HOOKS"/_lib-*.sh "$HOOKS/dispatch-bash.sh" "$HOOKS/block-ambient-tracker-repo.sh" "$D/"
for script in block-privileged-escalation.sh require-skill-for-issue-create.sh require-orbit-slice-for-ticket.sh \
  require-migration-ticket.sh require-active-ticket.sh warn-review-marker-write.sh warn-isolated-build-risk.sh \
  block-reviewer-repo-mutation.sh block-reviewer-ci-wait.sh block-forged-menu-approval.sh block-git-add-all.sh \
  block-main-push.sh validate-branch-name.sh pre-push-gate.sh block-agent-routing-drift.sh check-secrets.sh \
  block-onboarding-in-git.sh verify-commit-refs.sh validate-commit-format.sh require-agdr-for-arch-changes.sh \
  warn-bootstrap-scope.sh suggest-ticket-template.sh validate-issue-structure.sh block-private-refs-in-public-repos.sh \
  validate-pr-create.sh require-agdr-for-arch-pr.sh nudge-control-adversarial-test.sh block-unreviewed-merge.sh \
  require-design-review-for-ui.sh block-merge-on-red-ci.sh require-architecture-review.sh detect-role-trigger.sh; do
  cat > "$D/$script" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
echo "stub $(basename "$0") ran"
if [ -n "${RECHECK_BLOCK:-}" ] && [ "$(basename "$0")" = block-privileged-escalation.sh ] \
  && grep -q -- '--repo owner/project' <<<"$input"; then
  echo "BLOCKED: stub re-check saw the rewritten command" >&2
  exit 2
fi
EOF
done
chmod +x "$D"/*.sh

# dispatch <runtime> <command>: runtime is claude, codex or opencode.
dispatch() {
  local runtime="$1" command="$2" body
  RC=0
  case "$runtime" in
    claude) body=$(claude_payload "$command") ;;
    *) body=$(payload "$command") ;;
  esac
  (
    cd "$single" || exit 99
    case "$runtime" in
      claude) export CLAUDE_PROJECT_DIR="$single" ;;
      codex) export APEXYARD_CODEX_HOOK_TOOL=Bash ;;
    esac
    printf '%s' "$body" | "$D/dispatch-bash.sh" >"$TMP/out" 2>"$TMP/err"
  ) || RC=$?
}

dispatch claude 'gh issue view 42'
if [ "$RC" -eq 0 ] && jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
    and .hookSpecificOutput.updatedInput == {command: "gh issue view --repo owner/project 42", description: "test call"}
    and (.hookSpecificOutput | has("permissionDecision") | not)
    and (.hookSpecificOutput.additionalContext | contains("```agc"))' "$TMP/out" >/dev/null; then
  pass 'Claude Code: repaired, full tool input kept, no permissionDecision'
else
  fail 'Claude Code: repaired, full tool input kept, no permissionDecision' "$TMP/out"
fi
if grep -q 'stub block-privileged-escalation.sh ran' "$TMP/err" && [ "$(wc -l < "$TMP/out" | tr -d ' ')" -eq 1 ]; then
  pass 'Claude Code: gate output goes to stderr, stdout holds only the PreToolUse JSON'
else
  fail 'Claude Code: gate output goes to stderr, stdout holds only the PreToolUse JSON' "$TMP/out"
fi

dispatch codex 'gh issue view 42'
if [ "$RC" -eq 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "allow"
    and .hookSpecificOutput.updatedInput.command == "gh issue view --repo owner/project 42"' "$TMP/out" >/dev/null; then
  pass 'Codex: repaired with permissionDecision allow'
else
  fail 'Codex: repaired with permissionDecision allow' "$TMP/out"
fi

dispatch opencode 'gh issue view 42'
if [ "$RC" -eq 2 ] && ! grep -q 'updatedInput' "$TMP/out"; then
  pass 'OpenCode-shaped call: no repair, the block stands'
else
  fail 'OpenCode-shaped call: no repair, the block stands' "$TMP/out"
fi

RECHECK_BLOCK=1 dispatch claude 'gh issue view 42'
if [ "$RC" -eq 2 ] && ! grep -q 'updatedInput' "$TMP/out" && grep -q 'stub re-check saw the rewritten command' "$TMP/err"; then
  pass 'a later gate that blocks the rewritten call wins over the repair'
else
  fail 'a later gate that blocks the rewritten call wins over the repair' "$TMP/err"
fi

# Without a repair the dispatcher keeps its old output behaviour: gate stdout
# passes through, and no PreToolUse JSON is added.
dispatch claude 'gh issue view 42 --repo owner/project'
if [ "$RC" -eq 0 ] && ! grep -q 'hookSpecificOutput' "$TMP/out"; then
  pass 'an explicit repository needs no repair and adds no PreToolUse JSON'
else
  fail 'an explicit repository needs no repair and adds no PreToolUse JSON' "$TMP/out"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
