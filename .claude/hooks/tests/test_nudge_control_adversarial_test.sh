#!/bin/bash
# Test fixtures for nudge-control-adversarial-test.sh (AgDR-0117).
#
# The hook is a plain ADVISORY nudge (per AgDR-0117's rejection of #1057's
# proposed blocking CI meta-gate): on `gh pr create`, if the PR's diff touches
# a `.claude/hooks/*.sh` file whose OWN header carries `# CLASS: CONTROL`
# (the AgDR-0104 typology), print a one-line reminder to pair the change with
# an adversarial test. It must NEVER block — every assertion below checks
# exit code 0, including the case where the nudge fires.
#
# Cases covered:
#   1. PR touches a CONTROL hook               → nudge fires, exit 0
#   2. PR touches a non-CONTROL hook            → silent, exit 0
#   3. PR touches an unrelated file              → silent, exit 0
#   4. Command is not `gh pr create`             → silent, exit 0
#   5. PR touches TWO CONTROL hooks              → nudge names both, exit 0
#   6. Unresolvable base branch                   → silent, exit 0 (no crash)
#
# To run:  ./.claude/hooks/tests/test_nudge_control_adversarial_test.sh
# Exit 0 = all pass, 1 = at least one failure.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
HOOK="$REPO_ROOT/.claude/hooks/nudge-control-adversarial-test.sh"

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook not found or not executable at $HOOK" >&2
  exit 1
fi

PASS=0
FAIL=0

make_payload() {
  local cmd="$1"
  jq -n --arg c "$cmd" '{tool_input: {command: $c}}'
}

# setup_repo <base-setup-fn> <feature-setup-fn>
#   base-setup-fn    : runs on main, commits the starting state
#   feature-setup-fn : runs on a feature branch, commits the PR's changes
setup_repo() {
  local base_fn="$1"
  local feat_fn="$2"
  local dir
  dir=$(mktemp -d -t nudge-control.XXXXXX)
  (
    cd "$dir" || exit 1
    git init -q -b main
    git config user.email t@t.test
    git config user.name test
    echo "company: test" > onboarding.yaml
    mkdir -p .claude/hooks
    git add onboarding.yaml
    git commit -q -m init
    "$base_fn"
    git checkout -q -b feature
    "$feat_fn"
  )
  echo "$dir"
}

# run_case <name> <dir> <expected_exit> <expected_stderr_substr|""> <command>
run_case() {
  local name="$1" dir="$2" expected_exit="$3" expected_substr="$4" cmd="$5"
  local stderr_file
  stderr_file=$(mktemp)

  ( cd "$dir" && echo "$(make_payload "$cmd")" | "$HOOK" ) 2> "$stderr_file"
  local actual_exit=$?
  local stderr_content
  stderr_content=$(cat "$stderr_file")
  rm -f "$stderr_file"

  local ok=1
  if [ "$actual_exit" != "$expected_exit" ]; then ok=0; fi
  if [ -n "$expected_substr" ]; then
    echo "$stderr_content" | grep -qF -- "$expected_substr" || ok=0
  else
    [ -n "$stderr_content" ] && ok=0
  fi

  if [ "$ok" = 1 ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "   expected exit=$expected_exit, got $actual_exit"
    [ -n "$expected_substr" ] && echo "   expected stderr to contain: $expected_substr"
    echo "   stderr was: $stderr_content"
    FAIL=$((FAIL + 1))
  fi

  rm -rf "$dir"
}

write_control_hook() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/bin/bash
# CLASS: CONTROL (AgDR-0104 labelling). Test fixture placeholder.
echo hi
EOF
}

write_plain_hook() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/bin/bash
# A plain advisory hook, no CLASS header.
echo hi
EOF
}

# ---------------------------------------------------------------------------
# Case 1: PR touches a CONTROL hook → nudge fires, exit 0.
# ---------------------------------------------------------------------------
c1_base() {
  write_control_hook .claude/hooks/block-unreviewed-merge.sh
  git add .claude/hooks/block-unreviewed-merge.sh
  git commit -q -m "base: add control hook"
}
c1_feat() {
  echo "# tweak" >> .claude/hooks/block-unreviewed-merge.sh
  git add .claude/hooks/block-unreviewed-merge.sh
  git commit -q -m "feat: tweak control hook"
}
dir=$(setup_repo c1_base c1_feat)
run_case "PR touching a CONTROL hook fires the nudge (exit 0)" "$dir" 0 \
  "ADVISORY: this PR touches trust-chain CONTROL hook(s) [block-unreviewed-merge.sh]" \
  "gh pr create --base main --title t --body b"

# ---------------------------------------------------------------------------
# Case 2: PR touches a non-CONTROL hook → silent, exit 0.
# ---------------------------------------------------------------------------
c2_base() {
  write_plain_hook .claude/hooks/suggest-ticket-template.sh
  git add .claude/hooks/suggest-ticket-template.sh
  git commit -q -m "base: add plain hook"
}
c2_feat() {
  echo "# tweak" >> .claude/hooks/suggest-ticket-template.sh
  git add .claude/hooks/suggest-ticket-template.sh
  git commit -q -m "feat: tweak plain hook"
}
dir=$(setup_repo c2_base c2_feat)
run_case "PR touching a non-CONTROL hook is silent (exit 0)" "$dir" 0 "" \
  "gh pr create --base main --title t --body b"

# ---------------------------------------------------------------------------
# Case 3: PR touches an unrelated file (not under .claude/hooks/) → silent.
# ---------------------------------------------------------------------------
c3_base() {
  write_control_hook .claude/hooks/block-unreviewed-merge.sh
  mkdir -p src
  echo "export const x = 1" > src/widget.ts
  git add .claude/hooks/block-unreviewed-merge.sh src/widget.ts
  git commit -q -m "base: add control hook + widget"
}
c3_feat() {
  echo "export const x = 2" > src/widget.ts
  git add src/widget.ts
  git commit -q -m "feat: tweak widget only"
}
dir=$(setup_repo c3_base c3_feat)
run_case "PR touching an unrelated file is silent (exit 0)" "$dir" 0 "" \
  "gh pr create --base main --title t --body b"

# ---------------------------------------------------------------------------
# Case 4: command is not `gh pr create` → silent, exit 0, regardless of diff.
# ---------------------------------------------------------------------------
dir=$(setup_repo c1_base c1_feat)
run_case "non-'gh pr create' command is silent (exit 0)" "$dir" 0 "" \
  "gh pr list --state open"

# ---------------------------------------------------------------------------
# Case 5: PR touches TWO CONTROL hooks → nudge names both, exit 0.
# ---------------------------------------------------------------------------
c5_base() {
  write_control_hook .claude/hooks/block-unreviewed-merge.sh
  write_control_hook .claude/hooks/block-merge-on-red-ci.sh
  git add .claude/hooks/block-unreviewed-merge.sh .claude/hooks/block-merge-on-red-ci.sh
  git commit -q -m "base: add two control hooks"
}
c5_feat() {
  echo "# tweak" >> .claude/hooks/block-unreviewed-merge.sh
  echo "# tweak" >> .claude/hooks/block-merge-on-red-ci.sh
  git add .claude/hooks/block-unreviewed-merge.sh .claude/hooks/block-merge-on-red-ci.sh
  git commit -q -m "feat: tweak both control hooks"
}
dir=$(setup_repo c5_base c5_feat)
stderr_file=$(mktemp)
( cd "$dir" && echo "$(make_payload "gh pr create --base main --title t --body b")" | "$HOOK" ) 2> "$stderr_file"
rc=$?
content=$(cat "$stderr_file")
rm -f "$stderr_file"
if [ "$rc" = 0 ] && echo "$content" | grep -qF "block-unreviewed-merge.sh" && echo "$content" | grep -qF "block-merge-on-red-ci.sh"; then
  echo "PASS: PR touching two CONTROL hooks names both in the nudge (exit 0)"
  PASS=$((PASS + 1))
else
  echo "FAIL: PR touching two CONTROL hooks names both in the nudge (exit 0)"
  echo "   rc=$rc stderr=$content"
  FAIL=$((FAIL + 1))
fi
rm -rf "$dir"

# ---------------------------------------------------------------------------
# Case 6: unresolvable base branch (AND no fallback candidate resolves
# either — the repo's default branch is deliberately named "trunk", not
# "main"/"master", so origin/dev, upstream/dev, origin/main, upstream/main,
# main, and master all miss too) → silent, exit 0 (no crash).
# ---------------------------------------------------------------------------
dir=$(mktemp -d -t nudge-control.XXXXXX)
(
  cd "$dir" || exit 1
  git init -q -b trunk
  git config user.email t@t.test
  git config user.name test
  echo "company: test" > onboarding.yaml
  mkdir -p .claude/hooks
  git add onboarding.yaml
  git commit -q -m init
  c1_base
  git checkout -q -b feature
  c1_feat
)
run_case "unresolvable --base branch (no fallback ref either) is silent (exit 0)" "$dir" 0 "" \
  "gh pr create --base nonexistent-branch-xyz --title t --body b"

# ---------------------------------------------------------------------------
# Case 7: the hook NEVER exits non-zero, even when it fires. This is the
# load-bearing property (advisory, not a gate) — assert it explicitly beyond
# case 1's exit-code check, scanning across every case run above implicitly
# already covers this, but pin it once more with an unambiguous name so a
# future edit that flips the hook to `exit 2` fails loudly here too.
# ---------------------------------------------------------------------------
dir=$(setup_repo c1_base c1_feat)
run_case "hook is non-blocking: exit 0 even when the nudge fires" "$dir" 0 \
  "Non-blocking — this is a reminder, not a gate." \
  "gh pr create --base main --title t --body b"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
