#!/bin/bash
# Smoke tests for .claude/hooks/warn-stale-review-markers.sh
#
# Each case:
#   - sets up an isolated sandbox repo under $TMPDIR
#   - stages marker files (or not) under .claude/session/reviews/
#   - stubs `gh` on PATH to return deterministic values
#   - pipes a synthetic PostToolUse JSON blob into the hook
#   - asserts the hook's stderr / exit code / marker-file state
#
# Exit 0 means all cases passed. Exit 1 on first failure with a clear message.

set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/warn-stale-review-markers.sh"
if [ ! -x "$HOOK_SRC" ]; then
  echo "FAIL: hook not found or not executable at $HOOK_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

# Build a fresh sandbox for each case: a tiny git repo with an onboarding.yaml
# (so the settings.json resolver would find it), the hook copied in, and a
# PATH-shim dir where we drop a fake `gh` script per-case.
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
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session/reviews" "$sb/bin"
  cp "$HOOK_SRC" "$sb/.claude/hooks/warn-stale-review-markers.sh"
  chmod +x "$sb/.claude/hooks/warn-stale-review-markers.sh"
  # The hook sources the shared config reader landed in apexyard#109. The
  # sandbox therefore needs both the reader and the shipped defaults so
  # config lookups resolve the same way they do in a real fork.
  local src_root
  src_root=$(cd "$(dirname "$0")/../../.." && pwd)
  if [ -f "$src_root/.claude/hooks/_lib-read-config.sh" ]; then
    cp "$src_root/.claude/hooks/_lib-read-config.sh" "$sb/.claude/hooks/_lib-read-config.sh"
  fi
  if [ -f "$src_root/.claude/project-config.defaults.json" ]; then
    cp "$src_root/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  fi
  echo "$sb"
}

# Write a gh stub. Arguments: sandbox dir, behaviour keyword.
#   no-pr        → all `gh pr view` calls exit 1 (no PR for branch)
#   pr:<n>:<sha> → `gh pr view --json number` returns <n>;
#                  `gh pr view <n> --json headRefOid` returns <sha>
#   offline      → every gh call exits 1 with network error
write_gh_stub() {
  local sb="$1"
  local mode="$2"
  cat > "$sb/bin/gh" <<'STUB_HEAD'
#!/bin/bash
# Test stub for gh — behaviour controlled by $GH_STUB_MODE.
args="$*"
STUB_HEAD
  cat >> "$sb/bin/gh" <<STUB_BODY
mode="$mode"
STUB_BODY
  cat >> "$sb/bin/gh" <<'STUB_TAIL'
case "$mode" in
  no-pr)
    # Simulates the "no PR for current branch" path.
    exit 1
    ;;
  offline)
    echo "error connecting to api.github.com" >&2
    exit 1
    ;;
  pr:*)
    # pr:<num>:<sha>
    num="${mode#pr:}"
    num="${num%%:*}"
    sha="${mode##*:}"
    # Route by args.
    if [[ "$args" == *"--json number"* && "$args" != *"headRefOid"* ]]; then
      echo "$num"
      exit 0
    fi
    if [[ "$args" == *"headRefOid"* ]]; then
      echo "$sha"
      exit 0
    fi
    # Fallback: pretend success but empty.
    exit 0
    ;;
esac
exit 1
STUB_TAIL
  chmod +x "$sb/bin/gh"
}

# Run the hook inside a sandbox with a given stdin JSON and assert conditions.
# Args: sandbox, json, expected_stderr_grep (empty for "must be silent"),
#       expected_exit (always 0 per spec).
run_hook() {
  local sb="$1"
  local json="$2"
  local expect_grep="$3"
  local case_name="$4"

  local stderr_file
  stderr_file=$(mktemp)
  (
    cd "$sb" || exit 1
    # PATH must be exported so the piped hook subshell sees the stub.
    # A var-prefix on `printf` alone scopes only to printf.
    export PATH="$sb/bin:$PATH"
    printf '%s' "$json" \
      | "$sb/.claude/hooks/warn-stale-review-markers.sh" 2>"$stderr_file"
  )
  local rc=$?

  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$case_name]: hook exited $rc (expected 0)" >&2
    sed 's/^/    stderr: /' "$stderr_file" >&2
    rm -f "$stderr_file"
    FAIL=$((FAIL+1))
    FAILED_CASES="$FAILED_CASES $case_name"
    return 1
  fi

  if [ -z "$expect_grep" ]; then
    # Silent expected — but tolerate the "falling back to local HEAD" WARN
    # line because that's emitted by design when gh is unavailable.
    local noise
    noise=$(grep -v 'falling back to local HEAD' "$stderr_file" | tr -d '[:space:]')
    if [ -n "$noise" ]; then
      echo "FAIL [$case_name]: expected silent, got:" >&2
      sed 's/^/    stderr: /' "$stderr_file" >&2
      rm -f "$stderr_file"
      FAIL=$((FAIL+1))
      FAILED_CASES="$FAILED_CASES $case_name"
      return 1
    fi
  else
    if ! grep -qE "$expect_grep" "$stderr_file"; then
      echo "FAIL [$case_name]: stderr did not match /$expect_grep/" >&2
      sed 's/^/    stderr: /' "$stderr_file" >&2
      rm -f "$stderr_file"
      FAIL=$((FAIL+1))
      FAILED_CASES="$FAILED_CASES $case_name"
      return 1
    fi
  fi

  rm -f "$stderr_file"
  PASS=$((PASS+1))
  echo "PASS [$case_name]"
  return 0
}

push_json_success() {
  # Simulates a successful `git push` tool_response.
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git push -u origin HEAD"},"tool_response":{"stdout":"","stderr":"To https://github.com/acme/repo.git\\n   abc1234..def5678  feature -> feature"}}'
}

push_json_failure() {
  # Simulates a failed `git push` — "rejected" marker in stderr.
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git push origin HEAD"},"tool_response":{"stdout":"","stderr":"To https://github.com/acme/repo.git\\n ! [rejected] feature -> feature (non-fast-forward)\\nerror: failed to push some refs"}}'
}

# -------------------- CASE 1: no PR --------------------
case1() {
  local sb
  sb=$(make_sandbox)
  write_gh_stub "$sb" "no-pr"
  run_hook "$sb" "$(push_json_success)" "" "no-pr-silent"
  rm -rf "$sb"
}

# -------------------- CASE 2: no markers --------------------
case2() {
  local sb
  sb=$(make_sandbox)
  write_gh_stub "$sb" "pr:42:$(printf 'a%.0s' {1..40})"
  # No markers written. Should be silent.
  run_hook "$sb" "$(push_json_success)" "" "no-markers-silent"
  rm -rf "$sb"
}

# -------------------- CASE 3: fresh markers --------------------
case3() {
  local sb
  sb=$(make_sandbox)
  local sha
  sha=$(printf 'b%.0s' {1..40})
  write_gh_stub "$sb" "pr:42:$sha"
  # Markers record the current PR HEAD — not stale.
  echo "$sha" > "$sb/.claude/session/reviews/42-rex.approved"
  echo "$sha" > "$sb/.claude/session/reviews/42-ceo.approved"
  run_hook "$sb" "$(push_json_success)" "" "fresh-markers-silent"
  rm -rf "$sb"
}

# -------------------- CASE 4: stale rex marker --------------------
case4() {
  local sb
  sb=$(make_sandbox)
  local new_sha old_sha
  new_sha=$(printf 'c%.0s' {1..40})
  old_sha=$(printf 'd%.0s' {1..40})
  write_gh_stub "$sb" "pr:42:$new_sha"
  echo "$old_sha" > "$sb/.claude/session/reviews/42-rex.approved"
  run_hook "$sb" "$(push_json_success)" \
    "Stale review marker: 42-rex\.approved.*was ddddddd.*now ccccccc" \
    "stale-rex-warn"
  # Marker file should still exist (warn mode, not delete).
  if [ ! -f "$sb/.claude/session/reviews/42-rex.approved" ]; then
    echo "FAIL [stale-rex-warn]: marker was deleted in warn mode" >&2
    FAIL=$((FAIL+1))
    PASS=$((PASS-1))
  fi
  rm -rf "$sb"
}

# -------------------- CASE 5: stale ceo marker --------------------
case5() {
  local sb
  sb=$(make_sandbox)
  local new_sha old_sha
  new_sha=$(printf 'e%.0s' {1..40})
  old_sha=$(printf 'f%.0s' {1..40})
  write_gh_stub "$sb" "pr:42:$new_sha"
  echo "$old_sha" > "$sb/.claude/session/reviews/42-ceo.approved"
  run_hook "$sb" "$(push_json_success)" \
    "Stale review marker: 42-ceo\.approved" \
    "stale-ceo-warn"
  rm -rf "$sb"
}

# -------------------- CASE 6: stale design marker --------------------
case6() {
  local sb
  sb=$(make_sandbox)
  local new_sha old_sha
  new_sha=$(printf '1%.0s' {1..40})
  old_sha=$(printf '2%.0s' {1..40})
  write_gh_stub "$sb" "pr:42:$new_sha"
  echo "$old_sha" > "$sb/.claude/session/reviews/42-design.approved"
  run_hook "$sb" "$(push_json_success)" \
    "Stale review marker: 42-design\.approved" \
    "stale-design-warn"
  rm -rf "$sb"
}

# -------------------- CASE 7: delete mode --------------------
case7() {
  local sb
  sb=$(make_sandbox)
  local new_sha old_sha
  new_sha=$(printf '3%.0s' {1..40})
  old_sha=$(printf '4%.0s' {1..40})
  write_gh_stub "$sb" "pr:42:$new_sha"
  echo "$old_sha" > "$sb/.claude/session/reviews/42-rex.approved"
  # Opt in to delete mode.
  cat > "$sb/.claude/project-config.json" <<EOF
{"review_markers": {"on_stale": "delete"}}
EOF
  run_hook "$sb" "$(push_json_success)" \
    "Stale review marker deleted: 42-rex\.approved" \
    "stale-rex-delete"
  if [ -f "$sb/.claude/session/reviews/42-rex.approved" ]; then
    echo "FAIL [stale-rex-delete]: marker was NOT deleted in delete mode" >&2
    FAIL=$((FAIL+1))
    PASS=$((PASS-1))
  fi
  rm -rf "$sb"
}

# -------------------- CASE 8: push failure --------------------
case8() {
  local sb
  sb=$(make_sandbox)
  local new_sha old_sha
  new_sha=$(printf '5%.0s' {1..40})
  old_sha=$(printf '6%.0s' {1..40})
  write_gh_stub "$sb" "pr:42:$new_sha"
  # Stale marker present — but push failed, so the hook should stay silent
  # (the remote didn't move, so prior markers are still valid against the
  # remote's actual HEAD).
  echo "$old_sha" > "$sb/.claude/session/reviews/42-rex.approved"
  run_hook "$sb" "$(push_json_failure)" "" "push-failed-silent"
  # Marker must NOT have been deleted.
  if [ ! -f "$sb/.claude/session/reviews/42-rex.approved" ]; then
    echo "FAIL [push-failed-silent]: marker was touched on failed push" >&2
    FAIL=$((FAIL+1))
    PASS=$((PASS-1))
  fi
  rm -rf "$sb"
}

# Run all cases.
case1
case2
case3
case4
case5
case6
case7
case8

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED_CASES" >&2
  exit 1
fi
exit 0
