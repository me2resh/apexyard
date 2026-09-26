#!/bin/bash
# Smoke tests for .claude/hooks/pre-push-gate.sh
#
# Each case:
#   - sets up an isolated sandbox repo under $TMPDIR
#   - seeds a project-config.json with a specific `.pre_push.commands` array
#   - pipes a synthetic PreToolUse JSON blob into the hook
#   - asserts exit code + stderr contents
#
# Exit 0 if all cases pass; exit 1 on first failure with a clear message.

set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/pre-push-gate.sh"
if [ ! -x "$HOOK_SRC" ]; then
  echo "FAIL: hook not found or not executable at $HOOK_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

# -- sandbox builder -----------------------------------------------------
make_sandbox() {
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    touch onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session"
  cp "$HOOK_SRC" "$sb/.claude/hooks/pre-push-gate.sh"
  chmod +x "$sb/.claude/hooks/pre-push-gate.sh"

  # Copy the shared reader + shipped defaults so config lookups resolve
  # the same way they do in a real fork (same pattern as #115 test harness).
  # Also copy _lib-ops-root.sh + _lib-resolution-cache.sh — both optional
  # (config_get works without them, the plain pre-#381 way) but their
  # presence is what lets case14 below exercise the real
  # pin-vs-cwd resolution path #1366's fix runs through in production.
  local src_root
  src_root=$(cd "$(dirname "$0")/../../.." && pwd)
  if [ -f "$src_root/.claude/hooks/_lib-read-config.sh" ]; then
    cp "$src_root/.claude/hooks/_lib-read-config.sh" "$sb/.claude/hooks/_lib-read-config.sh"
  fi
  if [ -f "$src_root/.claude/hooks/_lib-ops-root.sh" ]; then
    cp "$src_root/.claude/hooks/_lib-ops-root.sh" "$sb/.claude/hooks/_lib-ops-root.sh"
  fi
  if [ -f "$src_root/.claude/hooks/_lib-resolution-cache.sh" ]; then
    cp "$src_root/.claude/hooks/_lib-resolution-cache.sh" "$sb/.claude/hooks/_lib-resolution-cache.sh"
  fi
  if [ -f "$src_root/.claude/project-config.defaults.json" ]; then
    cp "$src_root/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  fi
  echo "$sb"
}

# push_json_for <target-dir> <shape>: a push command that targets a
# DIFFERENT directory than the session cwd — the shape #1366 reports.
# shape: "cd" for `cd <dir> && git push origin HEAD`, "-C" for
# `git -C <dir> push origin HEAD`.
push_json_for() {
  local target="$1"
  local shape="$2"
  if [ "$shape" = "-C" ]; then
    printf '{"tool_input":{"command":"git -C %s push origin HEAD"}}' "$target"
  else
    printf '{"tool_input":{"command":"cd %s && git push origin HEAD"}}' "$target"
  fi
}

push_json() {
  cat <<EOF
{"tool_input":{"command":"git push origin HEAD"}}
EOF
}

run_hook() {
  local sb="$1"
  local stdin_payload="$2"
  local want_rc="$3"
  local want_stderr_regex="$4"
  local label="$5"
  (
    cd "$sb" || exit 1
    echo "$stdin_payload" | bash .claude/hooks/pre-push-gate.sh 2>/tmp/pre-push-gate-stderr.$$
  )
  local got_rc=$?
  local got_stderr
  got_stderr=$(cat /tmp/pre-push-gate-stderr.$$ 2>/dev/null)
  rm -f /tmp/pre-push-gate-stderr.$$

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:200})" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# -------------------- CASE 1: non-git-push command --------------------
case1() {
  local sb; sb=$(make_sandbox)
  echo '{"tool_input":{"command":"ls -la"}}' | (cd "$sb" && bash .claude/hooks/pre-push-gate.sh 2>/dev/null)
  local rc=$?
  if [ "$rc" = "0" ]; then
    echo "PASS [non-git-push-silent]"
    PASS=$((PASS+1))
  else
    echo "FAIL [non-git-push-silent]: want rc=0, got $rc" >&2
    FAIL=$((FAIL+1))
  fi
  rm -rf "$sb"
}

# -------------------- CASE 2: empty commands → no-op --------------------
case2() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": []}}
EOF
  run_hook "$sb" "$(push_json)" 0 "" "empty-commands-noop"
  rm -rf "$sb"
}

# -------------------- CASE 3: passing command --------------------
case3() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "echo-ok", "run": "true"}]}}
EOF
  run_hook "$sb" "$(push_json)" 0 "" "passing-command"
  rm -rf "$sb"
}

# -------------------- CASE 4: failing command --------------------
case4() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "deliberate-fail", "run": "echo oops; exit 1"}]}}
EOF
  run_hook "$sb" "$(push_json)" 2 "deliberate-fail: FAILED" "failing-command-blocks"
  rm -rf "$sb"
}

# -------------------- CASE 5: skip marker in HEAD commit --------------------
case5() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "should-skip", "run": "exit 1"}]}}
EOF
  # Amend the HEAD commit message to include the skip marker.
  (cd "$sb" && git commit --amend -q -m "init

<!-- pre-push: skip -->")
  run_hook "$sb" "$(push_json)" 0 "pre-push gate bypassed by skip marker" "skip-marker-bypasses"
  rm -rf "$sb"
}

# -------------------- CASE 6: multiple commands, first fails --------------------
case6() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [
  {"name": "lint", "run": "exit 1"},
  {"name": "test", "run": "true"}
]}}
EOF
  run_hook "$sb" "$(push_json)" 2 "lint: FAILED" "fail-fast-on-first-red"
  rm -rf "$sb"
}

# -------------------- CASE 7: no config at all → no-op --------------------
case7() {
  local sb; sb=$(make_sandbox)
  # No project-config.json at all; defaults ship with empty commands.
  run_hook "$sb" "$(push_json)" 0 "" "no-config-noop"
  rm -rf "$sb"
}


# -------------------- CASE 8: untracked bad markdown → no failure --------------------
# Regression guard for #548: a markdownlint command driven by git ls-files must
# NOT lint untracked files, so a lint-dirty untracked .md must not block the push.
# The command string avoids \0 / null-delimiter JSON escapes (jq rejects \0);
# filenames in sandboxes are space-free so plain xargs (newline-split) is safe here.
case8() {
  local sb; sb=$(make_sandbox)
  # Configure markdownlint using git ls-files (the fixed command shape).
  # shellcheck disable=SC2016
  printf '%s\n' \
    '{"pre_push": {"commands": [{"name": "markdownlint", "run": "command -v npx >/dev/null 2>&1 || { echo INFO; exit 0; }; md_files=$(git ls-files '"'"'*.md'"'"' 2>/dev/null); [ -z \"$md_files\" ] && { echo INFO_SKIP; exit 0; }; echo \"$md_files\" | xargs npx --yes markdownlint-cli2 2>&1"}]}}' \
    > "$sb/.claude/project-config.json"
  # Drop a lint-dirty untracked markdown file.
  # Critically, this file is NOT `git add`-ed, so git ls-files will not see it.
  mkdir -p "$sb/.claude/skills/external-skill"
  printf '# Bad heading  \n- item without blank line\n' \
    > "$sb/.claude/skills/external-skill/DOCS.md"
  # Push must succeed: the untracked file must be invisible to markdownlint.
  run_hook "$sb" "$(push_json)" 0 "" "untracked-bad-md-ignored"
  rm -rf "$sb"
}

# -------------------- CASE 9: tracked bad markdown → failure --------------------
# Regression guard for #548: a lint error in a TRACKED markdown file must still
# block the push, so the fix does not weaken the gate for real content.
# Same command shape as case8 (space-safe xargs without -0, valid JSON).
case9() {
  local sb; sb=$(make_sandbox)
  # shellcheck disable=SC2016
  printf '%s\n' \
    '{"pre_push": {"commands": [{"name": "markdownlint", "run": "command -v npx >/dev/null 2>&1 || { echo INFO; exit 0; }; md_files=$(git ls-files '"'"'*.md'"'"' 2>/dev/null); [ -z \"$md_files\" ] && { echo INFO_SKIP; exit 0; }; echo \"$md_files\" | xargs npx --yes markdownlint-cli2 2>&1"}]}}' \
    > "$sb/.claude/project-config.json"
  # Create a lint-dirty markdown file and COMMIT it so git ls-files sees it.
  # MD047 (files-end-with-single-newline) is reliably detectable without a
  # markdownlint config: just omit the trailing newline.
  printf '# README\nno-trailing-newline' > "$sb/README.md"
  (cd "$sb" && git add README.md && git commit -q -m "chore: add bad README")
  # Use a local npx stub so this gate test never depends on registry access or
  # a package download. The test is about propagating a tracked lint failure,
  # not about testing markdownlint-cli2 itself.
  mkdir -p "$sb/bin"
  cat > "$sb/bin/npx" <<'EOF'
#!/bin/bash
echo "MD047: Files should end with a single newline" >&2
exit 1
EOF
  chmod +x "$sb/bin/npx"
  PATH="$sb/bin:$PATH"
  run_hook "$sb" "$(push_json)" 2 "markdownlint: FAILED" "tracked-bad-md-fails"
  rm -rf "$sb"
}

# -------------------- CASE 10: marker MENTIONED in prose → does NOT bypass --------------------
# Regression guard for #1097: the skip marker used to be grep-matched
# unanchored, so a commit message that merely *discusses* the marker
# (documentation, a review comment quoted verbatim, a revert body) matched
# too and silently disabled every check. The match must be whole-line
# (grep -x): a sentence that contains the marker string inline is NOT a
# deliberate bypass, so the check must still run (and still block on a
# failing command).
case10() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "should-not-skip", "run": "echo oops; exit 1"}]}}
EOF
  # The marker appears INSIDE a sentence, not as its own line — this must
  # NOT be treated as a deliberate bypass.
  (cd "$sb" && git commit --amend -q -m "docs: explain the escape hatch

This documents the <!-- pre-push: skip --> marker so contributors know
it exists. It should not itself act as a bypass.")
  run_hook "$sb" "$(push_json)" 2 "should-not-skip: FAILED" "marker-mentioned-in-prose-does-not-bypass"
  rm -rf "$sb"
}

# -------------------- CASE 11: marker on its OWN LINE → still bypasses --------------------
# The other direction of #1097's fix: a deliberate bypass — the marker as
# a line by itself, exactly the shape the documented amend snippet emits —
# must keep working after anchoring the match to -x.
case11() {
  local sb; sb=$(make_sandbox)
  cat > "$sb/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "should-skip", "run": "exit 1"}]}}
EOF
  (cd "$sb" && git commit --amend -q -m "fix: emergency hotfix

<!-- pre-push: skip -->")
  run_hook "$sb" "$(push_json)" 0 "pre-push gate bypassed by skip marker" "marker-own-line-still-bypasses"
  rm -rf "$sb"
}

# -------------------- CASE 12: `cd <B> && git push` runs B's checks, not A's --------------------
# Regression guard for me2resh/apexyard#1366: the session cwd (sandbox A)
# carries a FAILING check; the push actually targets sandbox B (a `cd`
# prefix), which carries a PASSING one. Before the fix, REPO_ROOT was
# derived from `git rev-parse --show-toplevel` with no `-C`/`cd` awareness,
# so A's failing check ran (and blocked) regardless of what was pushed.
case12() {
  local a b
  a=$(make_sandbox)
  b=$(make_sandbox)
  cat > "$a/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "A-should-not-run", "run": "touch A_RAN; exit 1"}]}}
EOF
  cat > "$b/.claude/project-config.json" <<EOF
{"pre_push": {"commands": [{"name": "B-should-run", "run": "touch $b/B_RAN"}]}}
EOF
  local payload; payload=$(push_json_for "$b" "cd")
  run_hook "$a" "$payload" 0 "" "cd-prefix-targets-B-not-A"
  if [ -f "$a/A_RAN" ]; then
    echo "FAIL [cd-prefix-targets-B-not-A]: A's command ran; it should not have" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}cd-prefix-A-ran "
  fi
  if [ ! -f "$b/B_RAN" ]; then
    echo "FAIL [cd-prefix-targets-B-not-A]: B's command did NOT run; it should have" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}cd-prefix-B-did-not-run "
  fi
  rm -rf "$a" "$b"
}

# -------------------- CASE 13: `git -C <B> push` runs B's checks, not A's --------------------
# Same as case12, the OTHER shape #1366 names: `git -C <dir> push`. This
# shape did not even match the hook's own `\bgit\s+push\b` push-detection
# gate before the fix — the hook exited 0 silently, running NEITHER
# repo's checks. B_RAN must exist to prove B's check genuinely ran, not
# that the hook skipped both.
case13() {
  local a b
  a=$(make_sandbox)
  b=$(make_sandbox)
  cat > "$a/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "A-should-not-run", "run": "touch A_RAN; exit 1"}]}}
EOF
  cat > "$b/.claude/project-config.json" <<EOF
{"pre_push": {"commands": [{"name": "B-should-run", "run": "touch $b/B_RAN"}]}}
EOF
  local payload; payload=$(push_json_for "$b" "-C")
  run_hook "$a" "$payload" 0 "" "dash-C-targets-B-not-A"
  if [ -f "$a/A_RAN" ]; then
    echo "FAIL [dash-C-targets-B-not-A]: A's command ran; it should not have" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}dash-C-A-ran "
  fi
  if [ ! -f "$b/B_RAN" ]; then
    echo "FAIL [dash-C-targets-B-not-A]: B's command did NOT run — the -C form was never even detected as a push" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}dash-C-B-did-not-run "
  fi
  rm -rf "$a" "$b"
}

# -------------------- CASE 14: reverse direction --------------------
# Same pair, pushed the other way: cwd=B, push targets A via a `cd`
# prefix. A's failing command must now run and block.
case14() {
  local a b
  a=$(make_sandbox)
  b=$(make_sandbox)
  cat > "$a/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "A-should-run", "run": "exit 1"}]}}
EOF
  cat > "$b/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "B-should-not-run", "run": "exit 1"}]}}
EOF
  local payload; payload=$(push_json_for "$a" "cd")
  run_hook "$b" "$payload" 2 "A-should-run: FAILED" "reverse-direction-targets-A"
  rm -rf "$a" "$b"
}

# -------------------- CASE 15: a session pin must NOT override the push target --------------------
# The second half of #1366: the shared config reader prefers a session-
# pinned ops root over `$PWD` (apexyard#381). Simulate a real session
# pinned to sandbox C (a stand-in for "the operator's other, unrelated
# fork") while pushing FROM A TO B via a `cd` prefix. Before the fix, the
# pin made `config_get` read C's `.pre_push.commands` regardless of which
# repo the push actually targeted; B_RAN / C_RAN prove which config was
# actually used.
case15() {
  local a b c
  a=$(make_sandbox)
  b=$(make_sandbox)
  c=$(make_sandbox)
  # C must satisfy _ops_root_pin_valid: an anchor marker + .claude/hooks.
  touch "$c/.apexyard-fork"
  cat > "$a/.claude/project-config.json" <<'EOF'
{"pre_push": {"commands": [{"name": "A-should-not-run", "run": "exit 1"}]}}
EOF
  cat > "$b/.claude/project-config.json" <<EOF
{"pre_push": {"commands": [{"name": "B-should-run", "run": "touch $b/B_RAN"}]}}
EOF
  cat > "$c/.claude/project-config.json" <<EOF
{"pre_push": {"commands": [{"name": "C-should-not-run", "run": "touch $c/C_RAN; exit 1"}]}}
EOF
  local pin_dir; pin_dir=$(mktemp -d)
  printf '%s' "$c" > "$pin_dir/ops-root-test-session-1366"
  local payload; payload=$(push_json_for "$b" "cd")
  (
    cd "$a" || exit 1
    # Force the pin path regardless of the OUTER test runner's own
    # isolation setting (bin/run-hook-tests.sh exports this globally —
    # see its header comment — precisely to avoid a live session pin
    # escaping onto sandbox tests). This case exists to prove the HOOK
    # ITSELF disables the pin for its own config lookup, so unset
    # whatever the outer runner set and let the hook's own behaviour
    # be what's under test.
    unset APEXYARD_OPS_DISABLE_PIN
    export CLAUDE_CODE_SESSION_ID="test-session-1366"
    export APEXYARD_OPS_PIN_DIR="$pin_dir"
    echo "$payload" | bash .claude/hooks/pre-push-gate.sh 2>/tmp/pre-push-gate-stderr.$$
  )
  local rc=$?
  local got_stderr; got_stderr=$(cat /tmp/pre-push-gate-stderr.$$ 2>/dev/null)
  rm -f /tmp/pre-push-gate-stderr.$$
  if [ "$rc" != "0" ]; then
    echo "FAIL [pin-does-not-override-push-target]: want rc=0, got $rc (stderr: ${got_stderr:0:200})" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}pin-override-rc "
  elif [ -f "$c/C_RAN" ]; then
    echo "FAIL [pin-does-not-override-push-target]: the PINNED repo's command ran instead of the pushed repo's" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}pin-override-C-ran "
  elif [ ! -f "$b/B_RAN" ]; then
    echo "FAIL [pin-does-not-override-push-target]: the pushed repo's command did NOT run" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}pin-override-B-did-not-run "
  else
    echo "PASS [pin-does-not-override-push-target]"
    PASS=$((PASS+1))
  fi
  rm -rf "$a" "$b" "$c" "$pin_dir"
}

case1; case2; case3; case4; case5; case6; case7; case8; case9; case10; case11
case12; case13; case14; case15

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
