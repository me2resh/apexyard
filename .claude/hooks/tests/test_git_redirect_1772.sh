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
  # #1772 N2: the zsh clobber forms and a named descriptor (the Bash tool
  # can run zsh).
  "git >! f push origin feature/GH-1805-x"
  "git >!f push origin feature/GH-1805-x"
  "git >>| f push origin feature/GH-1805-x"
  "git >>|f push origin feature/GH-1805-x"
  "git >>! f push origin feature/GH-1805-x"
  "git &>! f push origin feature/GH-1805-x"
  "git &>| f push origin feature/GH-1805-x"
  "git &>>| f push origin feature/GH-1805-x"
  "git >&| f push origin feature/GH-1805-x"
  "git >>& f push origin feature/GH-1805-x"
  "git 2>! f push origin feature/GH-1805-x"
  "git -C /tmp >! f push origin feature/GH-1805-x"
  "git {fd}>/dev/null push origin feature/GH-1805-x"
  "git {fd}</dev/null push origin feature/GH-1805-x"
  "git {log_fd}>>f push origin feature/GH-1805-x"
)
cases_commit=(
  "git >/dev/null commit -m x"
  "git 2>/dev/null commit -m x"
  'git >"a b" commit -m x'
  'git 2>$(mktemp) commit -m x'
  'git >"a\" b" commit -m x'
  # #1772 N2.
  "git >! f commit -m x"
  "git >>| f commit -m x"
  "git {fd}>/dev/null commit -m x"
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
  # #1772 N1: a quoted target or a substitution target that goes on to the
  # next line. The verb is on the later line.
  $'git >"a\nb" push origin feature/GH-1805-x'
  $'git >\'a\nb\' push origin feature/GH-1805-x'
  $'git >$(echo\nx) push origin feature/GH-1805-x'
  $'git 2>"a\nb" commit -m x'
  $'git >"a\nb\nc" push origin feature/GH-1805-x'
  $'git -C /tmp >"a\nb"\tcommit -m x'
  # #1772 N2: a zsh form with a target that the grammar cannot match.
  'git >! $(a $(b)) push origin feature/GH-1805-x'
  'git {fd}>"a b push origin feature/GH-1805-x'
  # #1772 R2-1: `&>` and `&>>` are operators, not a separator. A target
  # that the grammar cannot match, or that goes on to the next line, fails
  # closed after them too.
  'git &>$(a $(b c)) push origin feature/GH-1805-x'
  'git &>>$(a $(b c)) commit -m x'
  $'git &>"a\nb" push origin feature/GH-1805-x'
  $'git &>>\'a\nb\' commit -m x'
  'git &>! $(a $(b)) push origin feature/GH-1805-x'
)
# #1772 N1 allow twins: a target that goes on to the next line, with no push
# or commit word after it, is not uncertain.
cases_not_uncertain=(
  $'git log > "a\nb"'
  $'git log > "a\nb"\necho done'
  $'echo push\ngit log > "a\nb"'
  # #1772 N2 allow twins: a zsh form with a target that the grammar reads.
  'git log >! "a b.txt" && grep push "a b.txt"'
  'git log {fd}>"a b" && grep commit "a b"'
  'git log >>| out.txt; echo commit'
  # #1772 R2-1 allow twin: an `&>` target that the grammar reads.
  'git log &> "a b.txt" && grep push "a b.txt"'
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

for cmd in "${cases_not_uncertain[@]}"; do
  if /bin/bash -c '. "$1" || exit 1; git_uncertain_protected_shape "$2"' _ "$HOOKS/_lib-git-global.sh" "$cmd"; then
    fail "readable or later-free target is not uncertain: $cmd"
  else
    pass "readable or later-free target is not uncertain: $cmd"
  fi
done

# #1772 N2 allow twins: a zsh form before a verb that is not push or commit
# does not route.
for cmd in 'git >! out.txt log' 'git {fd}>/dev/null log' 'git log >>| push.txt' 'git &>! push.txt status'; do
  if has_in "$HOOKS/_lib-git-global.sh" "$cmd" push || has_in "$HOOKS/_lib-git-global.sh" "$cmd" commit; then
    fail "zsh form with another verb does not route: $cmd"
  else
    pass "zsh form with another verb does not route: $cmd"
  fi
done

# #1772 N2: the gate scanner skips a zsh form and a named descriptor.
for cmd in 'git >!f log' 'git >>|f log' 'git >>| f log' 'git &>!f log' 'git {fd}>/dev/null log' 'git 2>!f -C . log'; do
  if /bin/bash -c '
    . "$1" || exit 1
    git_prepare_invocation "$2" log "$PWD"
  ' _ "$HOOKS/_lib-git-global.sh" "$cmd"; then
    pass "prepare skips zsh redirect: $cmd"
  else
    fail "prepare skips zsh redirect: $cmd"
  fi
done
# #1772 R2-2: an operator that ends in `!` and then a blank has a bash
# reading and a zsh reading. The gate scanner cannot know the shell, so it
# fails closed.
for cmd in 'git >! f log' 'git >>! f log' 'git &>! f log' 'git &>>! f log' 'git >&! f log' \
  'git 2>! f -C . log' 'git {fd}>! f log'; do
  if /bin/bash -c '
    . "$1" || exit 1
    git_prepare_invocation "$2" log "$PWD"
  ' _ "$HOOKS/_lib-git-global.sh" "$cmd"; then
    fail "prepare fails closed on a ! operator and a blank: $cmd"
  else
    pass "prepare fails closed on a ! operator and a blank: $cmd"
  fi
done

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
scripts='block-protected-target-writes.sh block-ambient-tracker-repo.sh block-privileged-escalation.sh require-skill-for-issue-create.sh require-orbit-slice-for-ticket.sh require-migration-ticket.sh require-active-ticket.sh warn-review-marker-write.sh warn-isolated-build-risk.sh block-reviewer-repo-mutation.sh block-reviewer-ci-wait.sh block-forged-menu-approval.sh block-git-add-all.sh block-main-push.sh validate-branch-name.sh pre-push-gate.sh block-agent-routing-drift.sh check-secrets.sh block-onboarding-in-git.sh verify-commit-refs.sh validate-commit-format.sh require-agdr-for-arch-changes.sh warn-bootstrap-scope.sh suggest-ticket-template.sh validate-issue-structure.sh block-private-refs-in-public-repos.sh validate-pr-create.sh require-agdr-for-arch-pr.sh nudge-control-adversarial-test.sh block-unreviewed-merge.sh require-design-review-for-ui.sh block-merge-on-red-ci.sh require-architecture-review.sh detect-role-trigger.sh'
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
for cmd in 'git >"a b" push origin feature/GH-1805-x' 'git >$(a $(b c)) push origin feature/GH-1805-x' \
  $'git >"a\nb" push origin feature/GH-1805-x' 'git >! f push origin feature/GH-1805-x' \
  'git {fd}>/dev/null push origin feature/GH-1805-x' \
  'git &>$(a $(b c)) push origin feature/GH-1805-x' $'git &>"a\nb" push origin feature/GH-1805-x' \
  'git &>! $(a $(b)) push origin feature/GH-1805-x' 'git&>$(a $(b)) push origin feature/GH-1805-x'; do
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
# #1772 R2-1: an unreadable `&>>` target before a commit routes the commit
# gates.
for cmd in 'git &>>$(a $(b)) commit -m x' 'git &>| $(a $(b)) commit -m x'; do
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd")
  : > "$TMP/log"
  printf '%s' "$payload" | DISPATCH_LOG="$TMP/log" "$TMP/hooks/dispatch-bash.sh" >/dev/null
  if grep -qx 'check-secrets.sh' "$TMP/log" && grep -qx 'validate-commit-format.sh' "$TMP/log"; then
    pass "dispatcher routes commit gates: $cmd"
  else
    fail "dispatcher routes commit gates: $cmd"
    cat "$TMP/log" >&2 || true
  fi
done

# The visitor blocks the unparsed target (real block-main-push gate).
cp "$HOOKS/block-main-push.sh" "$TMP/real-bmp.sh"
for lib in "$HOOKS"/_lib-*.sh; do cp "$lib" "$TMP/"; done
for cmd in 'git >$(a $(b c)) push origin feature/GH-1805-x' 'git >${X:-a b} push origin feature/GH-1805-x' \
  $'git >"a\nb" push origin feature/GH-1805-x' $'git >\'a\nb\' push origin feature/GH-1805-x' \
  'git &>$(a $(b c)) push origin feature/GH-1805-x' $'git &>"a\nb" push origin feature/GH-1805-x'; do
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
# #1772 N2: `git >! push ...` has two readings. Bash runs `git push` and
# zsh writes to a file named push. The gate scanner cannot know the shell,
# so it blocks (#1772 R2-2: any `!` operator and then a blank).
for cmd in 'git >! push origin feature/GH-1805-x' 'git 2>! push origin feature/GH-1805-x' \
  'git >! f push origin feature/GH-1805-x'; do
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$cmd" "$TMP")
  rc=0
  out=$(printf '%s' "$payload" | /bin/bash "$TMP/real-bmp.sh" 2>&1) || rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'cannot resolve'; then
    pass "push gate blocks a zsh form with two readings: $cmd"
  else
    fail "push gate blocks a zsh form with two readings (rc=$rc): $cmd: $(printf '%s' "$out" | head -2)"
  fi
done
# Allow twins: the same gate allows a plain push and a glued zsh form (one
# reading in each shell) to a feature branch.
for cmd in 'git push origin feature/GH-1805-x' 'git >!f push origin feature/GH-1805-x'; do
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$cmd" "$TMP")
  rc=0
  out=$(printf '%s' "$payload" | /bin/bash "$TMP/real-bmp.sh" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "push gate allows: $cmd"
  else
    fail "push gate allows (rc=$rc): $cmd: $(printf '%s' "$out" | head -2)"
  fi
done

# #1772 R2-2: both readings reach the verb, with different repositories.
# The working directory is a repository on a feature branch that holds a
# file named `!`. A second repository is on main. Bash writes to `!` and
# pushes from the second repository. Zsh writes to the option word and
# pushes from the working directory. The gates must block.
cp "$HOOKS/validate-branch-name.sh" "$TMP/real-vbn.sh"
ZR="$TMP/zr"
mkdir -p "$ZR/cwd" "$ZR/o"
for r in "$ZR/cwd" "$ZR/o"; do
  (
    cd "$r" || exit 1
    git init -q
    git -c user.email=test@example.com -c user.name=Test -c core.hooksPath=/dev/null -c commit.gpgsign=false \
      commit -q --allow-empty -m init
    git checkout -q -B main
  )
done
(cd "$ZR/cwd" && git checkout -q -B feature/GH-1772-x && : > '!')
GW="gi""t"
gate_rc() {
  local gate="$1" cmd="$2" payload rc=0
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$cmd" "$ZR/cwd")
  (cd "$ZR/cwd" && printf '%s' "$payload" | /bin/bash "$gate" >/dev/null 2>&1) || rc=$?
  printf '%s' "$rc"
}
for f in ">! --$GW-dir=$ZR/o/.$GW" ">>! --$GW-dir=$ZR/o/.$GW" "&>! --$GW-dir=$ZR/o/.$GW" \
  "2>! -C $ZR/o" ">&! --$GW-dir=$ZR/o/.$GW --work-tree=$ZR/o" "{fd}>! -C $ZR/o"; do
  cmd="$GW $f push"
  for gate in "$TMP/real-bmp.sh" "$TMP/real-vbn.sh"; do
    rc=$(gate_rc "$gate" "$cmd")
    if [ "$rc" = 2 ]; then
      pass "gate blocks two readings that both reach the verb (${gate##*/}): ${cmd//$ZR/ZR}"
    else
      fail "gate blocks two readings that both reach the verb (${gate##*/}, rc=$rc): ${cmd//$ZR/ZR}"
    fi
  done
done
# Glued forms have one reading. The gate still resolves the option after
# the target (blocks on main) and allows the working directory branch.
rc=$(gate_rc "$TMP/real-bmp.sh" "$GW >!x -C $ZR/o push")
if [ "$rc" = 2 ]; then
  pass "glued ! form still reads the option after it"
else
  fail "glued ! form still reads the option after it (rc=$rc)"
fi
rc=$(gate_rc "$TMP/real-bmp.sh" "$GW >!x push")
if [ "$rc" = 0 ]; then
  pass "glued ! form on a feature branch is allowed"
else
  fail "glued ! form on a feature branch is allowed (rc=$rc)"
fi

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
  "git 2>'e r' commit -m x" 'git >${X:-a b} push origin feature/GH-1805-x' \
  'git >! f push origin feature/GH-1805-x' 'git >>| "a b" commit -m x' \
  'git {fd}>/dev/null push origin feature/GH-1805-x' 'git &>! $(a (b)) push origin feature/GH-1805-x' \
  $'git >"a\nb" push origin feature/GH-1805-x'; do
  rc=$(nojq_run "$cmd")
  if [ "$rc" = 2 ]; then
    pass "no jq blocks redirect shape: $cmd"
  else
    fail "no jq blocks redirect shape (rc=$rc): $cmd"
  fi
done
# Allow twin: a redirect with no push or commit word is not blocked.
for cmd in 'git log > "a b.txt"' 'git log >! "a b.txt"' 'git log {fd}>/dev/null'; do
  rc=$(nojq_run "$cmd")
  if [ "$rc" = 0 ]; then
    pass "no jq allows a redirect with no push or commit: $cmd"
  else
    fail "no jq allows a redirect with no push or commit (rc=$rc): $cmd"
  fi
done

# #1772 N3: the redirect scan stays linear when one line holds many git
# words. Time the dispatcher (stub gates) on the head tree and on the base
# tree. The head run must finish within the larger of 6 times the base time
# and the base time plus 1.5 seconds. A slow CI runner showed 0.80 seconds
# against a 0.16 second base, so the old 0.5 second margin was too tight.
# The old super-linear code took 15 to 33 seconds, far over this limit.
# A host that runs a short command slower than 0.15 seconds gets a larger
# margin in the same ratio. Without a base tree, the limit uses the head
# time for the same text with no redirection. On a very slow host the
# limits are reported in NOTE lines and do not fail the test. Run this
# with the default awk.
stub_tree() {
  local src="$1" dest="$2" script
  mkdir -p "$dest"
  cp "$src"/*.sh "$dest/"
  for script in $scripts; do
    cat > "$dest/$script" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$(basename "$0")" >> "${DISPATCH_LOG:?}"
EOF
    chmod +x "$dest/$script"
  done
  chmod +x "$dest/dispatch-bash.sh"
}
dispatch_secs() {
  local tree="$1" cmd="$2" payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd")
  : > "$TMP/tlog"
  { time (printf '%s' "$payload" | DISPATCH_LOG="$TMP/tlog" /bin/bash "$tree/dispatch-bash.sh" >/dev/null 2>&1 || true); } 2> "$TMP/time"
  tail -n 1 "$TMP/time"
}
# The first run can be slow (cold caches). Use the faster of two runs.
dispatch_min() {
  local a b
  a=$(dispatch_secs "$1" "$2")
  b=$(dispatch_secs "$1" "$2")
  awk -v a="$a" -v b="$b" 'BEGIN { print (b < a) ? b : a }'
}
TIMEFORMAT=%R
stub_tree "$HOOKS" "$TMP/th-head"
have_base=0
if [ -n "${BASE_HOOKS:-}" ] && [ -f "${BASE_HOOKS}/dispatch-bash.sh" ]; then
  stub_tree "$BASE_HOOKS" "$TMP/th-base"
  have_base=1
else
  echo "NOTE: no base tree for the timing check; the limit uses the head time with no redirection"
fi
cal=$(dispatch_min "$TMP/th-head" "echo short")
margin=$(awk -v c="$cal" 'BEGIN { m = 1.5; if (c > 0.15) m = 1.5 * c / 0.15; printf "%.2f", m }')
echo "timing margin ${margin}s (short command ${cal}s)"
GT=git
many=""
for i in $(seq 1 200); do many="$many $GT"; done
c60=""
for i in $(seq 1 60); do c60="$c60 fix $GT"; done
r60=""
for i in $(seq 1 60); do r60="$r60 $GT > a"; done
e200x=""
for i in $(seq 1 200); do e200x="$e200x $GT >x"; done
timing_cases=(
  "echo$many > /dev/null"
  "echo$many > /dev/null && $GT push origin feature/GH-1772-x"
  "echo$e200x push"
  "$GT commit -m \"$c60\" > /dev/null"
  "$GT commit -m \"$r60\""
)
timing_labels=(
  "echo with 200 git words and a redirection"
  "echo with 200 git words, a redirection and a later push"
  "echo with 200 git words, each with a redirection"
  "commit -m with 60 git words and a redirection"
  "commit -m with 60 git words, each with a redirection"
)
for i in 0 1 2 3 4; do
  cmd="${timing_cases[i]}"
  label="${timing_labels[i]}"
  head_s=$(dispatch_min "$TMP/th-head" "$cmd")
  if [ "$have_base" = 1 ]; then
    ref_s=$(dispatch_min "$TMP/th-base" "$cmd")
    ref_kind="base"
  else
    ref_s=$(dispatch_min "$TMP/th-head" "${cmd//>/}")
    ref_kind="head with no redirection"
  fi
  limit=$(awk -v r="$ref_s" -v m="$margin" 'BEGIN { a = r * 6; b = r + m; printf "%.2f", (a > b) ? a : b }')
  slow=$(awk -v r="$ref_s" 'BEGIN { print (r > 5) ? 1 : 0 }')
  if awk -v t="$head_s" -v l="$limit" 'BEGIN { exit !(t <= l) }'; then
    pass "N3 time: $label: ${head_s}s, $ref_kind ${ref_s}s, limit ${limit}s"
  elif [ "$slow" = 1 ]; then
    echo "NOTE: slow host: $label took ${head_s}s; $ref_kind ${ref_s}s; limit ${limit}s"
  else
    fail "N3 time: $label: ${head_s}s is over the limit ${limit}s ($ref_kind ${ref_s}s)"
  fi
done

# #1837 (code review F1 on #1835): the `&>` form with a quoted target that
# holds a blank is in the accepted quadratic class (AgDR-0264 Decision 8).
# Time it at 2000 copies with the same limit. The pinned base above does
# not scan redirections, so the reference is the dev commit that accepted
# the class (the #1835 squash). That reference takes about 10 seconds, so
# each tree runs once, and the slow-host rule above does not apply.
# REDIRECT_1772_AMP_BASE_HOOKS overrides the reference tree.
AMP_PIN=defd0597094d80e72e366de76bf62127410fea98
amp_hooks="${REDIRECT_1772_AMP_BASE_HOOKS:-}"
if [ -z "$amp_hooks" ] && git -C "$ROOT" rev-parse --verify --quiet "${AMP_PIN}^{commit}" >/dev/null 2>&1; then
  mkdir -p "$TMP/amp-src"
  git -C "$ROOT" archive "$AMP_PIN" .claude/hooks | tar -x -C "$TMP/amp-src"
  amp_hooks="$TMP/amp-src/.claude/hooks"
fi
if [ -n "$amp_hooks" ] && [ -f "$amp_hooks/dispatch-bash.sh" ]; then
  stub_tree "$amp_hooks" "$TMP/th-amp"
  amp=""
  for i in $(seq 1 2000); do amp="$amp $GT&>\"a b\""; done
  cmd="echo$amp push"
  head_s=$(dispatch_secs "$TMP/th-head" "$cmd")
  ref_s=$(dispatch_secs "$TMP/th-amp" "$cmd")
  limit=$(awk -v r="$ref_s" -v m="$margin" 'BEGIN { a = r * 6; b = r + m; printf "%.2f", (a > b) ? a : b }')
  label="echo with 2000 git words, each with an &> quoted-blank target"
  if awk -v t="$head_s" -v l="$limit" 'BEGIN { exit !(t <= l) }'; then
    pass "N3 time: $label: ${head_s}s, #1835 reference ${ref_s}s, limit ${limit}s"
  else
    fail "N3 time: $label: ${head_s}s is over the limit ${limit}s (#1835 reference ${ref_s}s)"
  fi
else
  echo "NOTE: skip the &> timing case: reference ${AMP_PIN} is not in this clone"
fi

echo "TOTAL $PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
