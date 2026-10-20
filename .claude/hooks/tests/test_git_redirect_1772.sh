#!/bin/bash
# #1772 / #1805 step 1: redirections before the git verb still route.
# Fail-before uses the hooks tree at a pinned dev commit (build rule 10a).
set -eu
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
HOOKS="$ROOT/.claude/hooks"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

has_in() {
  local lib="$1" cmd="$2" sub="$3"
  /bin/bash -c '
    . "$1" || exit 1
    if command_has_git_subcommand "$2" "$3"; then exit 0; else exit 1; fi
  ' _ "$lib" "$cmd" "$sub"
}

# Load verbs from this file only (never put them on the parent Shell line).
PUSH_CMD='git push origin feature/GH-1805-x'
COMMIT_CMD='git commit -m x'

cases_push=(
  "git >/dev/null push origin feature/GH-1805-x"
  "git 2>&1 push origin feature/GH-1805-x"
  "git>/tmp/x push origin feature/GH-1805-x"
  "git < /dev/null push origin feature/GH-1805-x"
  "git</dev/null push origin feature/GH-1805-x"
  "git -C /tmp >/dev/null push origin feature/GH-1805-x"
  "git >/dev/null -C /tmp push origin feature/GH-1805-x"
  # #1805 B2: a quoted target with a space, or a substitution target.
  'git >"a b" push origin feature/GH-1805-x'
  "git 2>'my log' push origin feature/GH-1805-x"
  'git >"$OUT/a b" push origin feature/GH-1805-x'
  'git >$(mktemp -d)/x push origin feature/GH-1805-x'
  'git -C /tmp 2>"e r" push origin feature/GH-1805-x'
  # A backquote target, an escaped space and an ANSI-C quoted target.
  'git >`echo a b` push origin feature/GH-1805-x'
  'git >a\ b push origin feature/GH-1805-x'
  "git >\$'a b' push origin feature/GH-1805-x"
)
cases_commit=(
  "git >/dev/null commit -m x"
  "git 2>/dev/null commit -m x"
  'git >"a b" commit -m x'
  'git 2>$(mktemp) commit -m x'
  'git >"a\" b" commit -m x'
)
# #1805 B2: a target that the shared grammar cannot match (nested
# substitution, escaped quote) must still reach the gates, which block it.
cases_uncertain=(
  'git >$(a $(b c)) push origin feature/GH-1805-x'
  'git >"$(echo "a b")" push origin feature/GH-1805-x'
  'git >"$(printf ")")" commit -m x'
  # A parameter expansion with a space, and a target that is not closed.
  'git >${X:-a b} push origin feature/GH-1805-x'
  'git >"a b push origin feature/GH-1805-x'
  'git 2>`a b commit -m x'
)

# Fail-before: archive the hooks tree at a pinned dev commit. The pin is the
# dev commit before #1805 (the #1804 squash). A squash merge keeps it on dev.
# REDIRECT_1772_BASE_HOOKS or REDIRECT_1772_BASE_REF overrides the pin.
FAIL_BEFORE_PIN=5eb65c0f9cba2456c1a7fd41b56edc0a65f2c784
BASE_HOOKS="${REDIRECT_1772_BASE_HOOKS:-}"
fb_note=""
scratch=""
trap 'rm -rf "${scratch:-}"' EXIT
if [ -z "$BASE_HOOKS" ]; then
  BASE_REF="${REDIRECT_1772_BASE_REF:-$FAIL_BEFORE_PIN}"
  if git -C "$ROOT" rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null 2>&1; then
    scratch=$(mktemp -d)
    git -C "$ROOT" archive "$BASE_REF" .claude/hooks | tar -x -C "$scratch"
    BASE_HOOKS="$scratch/.claude/hooks"
  else
    # Shallow CI clones can miss the pinned commit.
    fb_note="pinned base ${BASE_REF} is not in this clone"
  fi
fi

if [ -z "$fb_note" ] && { [ -z "${BASE_HOOKS:-}" ] || [ ! -f "$BASE_HOOKS/_lib-git-global.sh" ]; }; then
  fb_note="no base _lib-git-global.sh"
fi
if [ -z "$fb_note" ] && grep -q '_git_take_redir' "$BASE_HOOKS/_lib-git-global.sh"; then
  # The base already has the fix, so it cannot show the old miss.
  fb_note="base ${BASE_REF:-override} already skips redirections"
fi

if [ -z "$fb_note" ]; then
  fb_miss=0
  for cmd in "${cases_push[@]}"; do
    if has_in "$BASE_HOOKS/_lib-git-global.sh" "$cmd" push; then
      fail "fail-before still routes: $cmd"
    else
      fb_miss=$((fb_miss + 1))
    fi
  done
  for cmd in "${cases_commit[@]}"; do
    if has_in "$BASE_HOOKS/_lib-git-global.sh" "$cmd" commit; then
      fail "fail-before still routes: $cmd"
    else
      fb_miss=$((fb_miss + 1))
    fi
  done
  if [ "$fb_miss" -eq $((${#cases_push[@]} + ${#cases_commit[@]})) ]; then
    pass "fail-before: ${fb_miss} redirect cases miss routing on base"
  fi
else
  echo "NOTE: skip fail-before: ${fb_note}"
fi

# After-fix: current library routes every redirect case.
if has_in "$HOOKS/_lib-git-global.sh" "$PUSH_CMD" push; then
  pass "plain push still routes"
else
  fail "plain push still routes"
fi
if has_in "$HOOKS/_lib-git-global.sh" "$COMMIT_CMD" commit; then
  pass "plain commit still routes"
else
  fail "plain commit still routes"
fi

for cmd in "${cases_push[@]}"; do
  if has_in "$HOOKS/_lib-git-global.sh" "$cmd" push; then
    pass "routes push: $cmd"
  else
    fail "routes push: $cmd"
  fi
done
for cmd in "${cases_commit[@]}"; do
  if has_in "$HOOKS/_lib-git-global.sh" "$cmd" commit; then
    pass "routes commit: $cmd"
  else
    fail "routes commit: $cmd"
  fi
done

for cmd in "${cases_uncertain[@]}"; do
  if /bin/bash -c '. "$1" || exit 1; git_uncertain_protected_shape "$2"' _ "$HOOKS/_lib-git-global.sh" "$cmd"; then
    pass "unparsed target fails closed: $cmd"
  else
    fail "unparsed target fails closed: $cmd"
  fi
done
# Allow twin: a consumable target with a later prose word is not uncertain.
twin='git log > "$OUT/a b.txt" && grep commit "$OUT/a b.txt"'
if /bin/bash -c '. "$1" || exit 1; git_uncertain_protected_shape "$2"' _ "$HOOKS/_lib-git-global.sh" "$twin"; then
  fail "consumable target is not uncertain: $twin"
else
  pass "consumable target is not uncertain: $twin"
fi

# `git > push` writes to a file named push; it is not a push verb.
if has_in "$HOOKS/_lib-git-global.sh" "git > push" push; then
  fail "file-named push is not a verb"
else
  pass "file-named push is not a verb"
fi

# prepare_invocation skips the redirection and finds the verb.
if /bin/bash -c '
  . "$1" || exit 1
  git_prepare_invocation "git >/dev/null log" log "$PWD"
' _ "$HOOKS/_lib-git-global.sh"; then
  pass "prepare skips redirect before log"
else
  fail "prepare skips redirect before log"
fi

# #1772 B1: a redirect target that starts with a digit and runs on is one
# shell word. The replay arguments must hold no --git-dir or --work-tree.
b1_replay() {
  /bin/bash -c '
    . "$1" || exit 1
    git_prepare_invocation "$2" "$3" "$4" || exit 3
    printf "%s\n" "${GIT_REPLAY_ARGS[@]}"
  ' _ "$HOOKS/_lib-git-global.sh" "$1" "$2" "$3"
}
GD_VAL="/gd-placeholder"
WT_VAL="/wt-placeholder"
GITW="gi""t"
for sub in push commit; do
  if [ "$sub" = push ]; then rest='origin feature/GH-1772-x'; else rest='-m x'; fi
  for opt in "--git-dir=$GD_VAL" "--work-tree=$WT_VAL"; do
    for op in '>' '2>' '&>' '<'; do
      cmd="$GITW ${op}1${opt} $sub $rest"
      out=$(b1_replay "$cmd" "$sub" "$PWD") || true
      if printf '%s\n' "$out" | grep -qE -- '^--(git-dir|work-tree)'; then
        fail "digit-led redirect target is one word (no replay option): $cmd"
      else
        pass "digit-led redirect target is one word (no replay option): $cmd"
      fi
    done
  done
  # Allow twin: a real fd target still ends at its boundary, and a following
  # real option is still read.
  for fdform in '2>&1' '>&2' '1>/dev/null' '2>&-'; do
    cmd="$GITW $fdform --git-dir=$GD_VAL $sub $rest"
    out=$(b1_replay "$cmd" "$sub" "$PWD") || true
    if printf '%s\n' "$out" | grep -qxF -- "--git-dir=$GD_VAL"; then
      pass "fd target still ends at its boundary: $cmd"
    else
      fail "fd target still ends at its boundary: $cmd"
    fi
  done
done

# Dispatcher routes push gates for a redirect-shaped push (stub gates).
TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "${scratch:-}"' EXIT
mkdir -p "$TMP/hooks" "$TMP/bin"
ln -s /bin/bash "$TMP/bin/bash"
PATH="$TMP/bin:$PATH"
cp "$HOOKS/dispatch-bash.sh" "$HOOKS/_lib-awk-fallback.sh" "$HOOKS/_lib-extract-pr.sh" \
  "$HOOKS/_lib-command-scrub.sh" "$HOOKS/_lib-git-global.sh" \
  "$TMP/hooks/" 2>/dev/null || true
chmod +x "$TMP/hooks/dispatch-bash.sh"
scripts='block-ambient-tracker-repo.sh block-privileged-escalation.sh require-skill-for-issue-create.sh require-orbit-slice-for-ticket.sh require-migration-ticket.sh require-active-ticket.sh warn-review-marker-write.sh warn-isolated-build-risk.sh block-reviewer-repo-mutation.sh block-reviewer-ci-wait.sh block-forged-menu-approval.sh block-git-add-all.sh block-main-push.sh validate-branch-name.sh pre-push-gate.sh block-agent-routing-drift.sh check-secrets.sh block-onboarding-in-git.sh verify-commit-refs.sh validate-commit-format.sh require-agdr-for-arch-changes.sh warn-bootstrap-scope.sh suggest-ticket-template.sh validate-issue-structure.sh block-private-refs-in-public-repos.sh validate-pr-create.sh require-agdr-for-arch-pr.sh nudge-control-adversarial-test.sh block-unreviewed-merge.sh require-design-review-for-ui.sh block-merge-on-red-ci.sh require-architecture-review.sh detect-role-trigger.sh'
for script in $scripts; do
  cat > "$TMP/hooks/$script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
name=$(basename "$0")
printf '%s\n' "$name" >> "${DISPATCH_LOG:?}"
EOF
  chmod +x "$TMP/hooks/$script"
done

payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
  'git >/dev/null push origin feature/GH-1805-x')
: > "$TMP/log"
printf '%s' "$payload" | DISPATCH_LOG="$TMP/log" "$TMP/hooks/dispatch-bash.sh" >/dev/null
if grep -qx 'block-main-push.sh' "$TMP/log" && grep -qx 'validate-branch-name.sh' "$TMP/log"; then
  pass "dispatcher routes push gates for redirect push"
else
  fail "dispatcher routes push gates for redirect push"
  cat "$TMP/log" >&2 || true
fi

payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
  'git >/dev/null commit -m x')
: > "$TMP/log"
printf '%s' "$payload" | DISPATCH_LOG="$TMP/log" "$TMP/hooks/dispatch-bash.sh" >/dev/null
if grep -qx 'check-secrets.sh' "$TMP/log" && grep -qx 'validate-commit-format.sh' "$TMP/log"; then
  pass "dispatcher routes commit gates for redirect commit"
else
  fail "dispatcher routes commit gates for redirect commit"
  cat "$TMP/log" >&2 || true
fi

# #1805 B2 through the dispatcher: a quoted target with a space and an
# unparsed nested target both reach the push gates.
for cmd in 'git >"a b" push origin feature/GH-1805-x' 'git >$(a $(b c)) push origin feature/GH-1805-x'; do
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd")
  : > "$TMP/log"
  printf '%s' "$payload" | DISPATCH_LOG="$TMP/log" "$TMP/hooks/dispatch-bash.sh" >/dev/null
  if grep -qx 'block-main-push.sh' "$TMP/log" && grep -qx 'validate-branch-name.sh' "$TMP/log"; then
    pass "dispatcher routes push gates: $cmd"
  else
    fail "dispatcher routes push gates: $cmd"
    cat "$TMP/log" >&2 || true
  fi
done

# The visitor blocks the unparsed target (real block-main-push gate).
cp "$HOOKS/block-main-push.sh" "$TMP/real-bmp.sh"
for lib in "$HOOKS"/_lib-*.sh; do cp "$lib" "$TMP/"; done
for cmd in 'git >$(a $(b c)) push origin feature/GH-1805-x' 'git >${X:-a b} push origin feature/GH-1805-x'; do
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$cmd" "$TMP")
  rc=0
  out=$(printf '%s' "$payload" | /bin/bash "$TMP/real-bmp.sh" 2>&1) || rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'redirection hides'; then
    pass "push gate blocks an unparsed redirection target: $cmd"
  else
    fail "push gate blocks an unparsed redirection target (rc=$rc): $cmd: $(printf '%s' "$out" | head -2)"
  fi
done

# No jq: the dispatcher cannot read the command, so a redirect-shaped push or
# commit in the raw payload blocks. Keep every executable except jq.
cp "$HOOKS/_lib-fail-closed-json.sh" "$TMP/hooks/"
mkdir -p "$TMP/nojq"
old_ifs=$IFS
IFS=:
for dir in $PATH; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*; do
    name=${f##*/}
    if [ "$name" != jq ] && [ -f "$f" ] && [ -x "$f" ] && [ ! -e "$TMP/nojq/$name" ]; then
      ln -s "$f" "$TMP/nojq/$name"
    fi
  done
done
IFS=$old_ifs
nojq_run() {
  local cmd="$1" payload rc=0
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd")
  : > "$TMP/log"
  printf '%s' "$payload" | PATH="$TMP/nojq" DISPATCH_LOG="$TMP/log" /bin/bash "$TMP/hooks/dispatch-bash.sh" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
for cmd in 'git >"a b" push origin feature/GH-1805-x' 'git >$(a $(b c)) push origin feature/GH-1805-x' \
  "git 2>'e r' commit -m x" 'git >${X:-a b} push origin feature/GH-1805-x'; do
  rc=$(nojq_run "$cmd")
  if [ "$rc" = 2 ]; then
    pass "no jq blocks redirect shape: $cmd"
  else
    fail "no jq blocks redirect shape (rc=$rc): $cmd"
  fi
done
# Allow twin: a redirect with no push or commit word is not blocked.
rc=$(nojq_run 'git log > "a b.txt"')
if [ "$rc" = 0 ]; then
  pass "no jq allows a redirect with no push or commit"
else
  fail "no jq allows a redirect with no push or commit (rc=$rc)"
fi

echo "TOTAL $PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
