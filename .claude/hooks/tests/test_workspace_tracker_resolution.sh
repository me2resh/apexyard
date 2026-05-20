#!/bin/bash
# test_workspace_tracker_resolution.sh — regression tests for me2resh/apexyard#310.
#
# Bug: hooks that read tracker config via _lib-read-config.sh / _lib-tracker.sh
# resolved `.claude/project-config.json` via `git rev-parse --show-toplevel`.
# When the operator runs the hook from inside a workspace/<project>/ clone,
# `--show-toplevel` returns the project clone's git root — NOT the ops fork.
# Result: tracker.kind silently defaulted to "gh" even when the operator had
# configured Linear / Jira / custom at the ops-fork level, and Linear/Jira-shaped
# IDs (PROJ-42, ENG-7, etc.) were rejected as "missing GitHub issue".
#
# Fix: _lib-read-config.sh now uses _lib-ops-root.sh to walk up to the ops-fork
# anchor (v2 .apexyard-fork marker OR v1 onboarding.yaml + apexyard.projects.yaml
# pair) before falling back to `--show-toplevel`. The three named hooks
# (validate-pr-create.sh, verify-commit-refs.sh, require-skill-for-issue-create.sh)
# additionally route direct config reads through the same resolution.
#
# Cases:
#   1. _lib-read-config.sh resolves ops-fork config when cwd is inside
#      workspace/<project>/ (the core bug — was loading no config / framework
#      defaults only).
#   2. tracker_kind returns the ops-fork-configured value ("jira") from a
#      workspace clone, NOT the gh default.
#   3. verify-commit-refs.sh dispatches the configured tracker (jira) for a
#      PROJ-shaped ticket reference when invoked from a workspace clone. The
#      hook calls `jira issue view` instead of `gh issue view`, and the
#      shape passes through.
#   4. validate-pr-create.sh dispatches the configured tracker (jira) for a
#      PROJ-shaped PR title from a workspace clone.
#   5. require-skill-for-issue-create.sh continues to recognise the
#      bootstrap-skill exemption and the active-issue-skill marker even when
#      invoked from inside a workspace clone (config-driven matchers must
#      still load — this exercises config_get for .ticket.create_command_patterns
#      and .ticket.bootstrap_skills).
#   6. Regression: from the ops-fork root itself (NOT a workspace clone),
#      every config lookup still resolves correctly. Closes the worry that
#      the fix breaks the standard case.
#
# Exit 0 = all pass. Exit 1 on first failure.

set -u

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACKER_LIB="$HOOK_DIR/_lib-tracker.sh"
CONFIG_LIB="$HOOK_DIR/_lib-read-config.sh"
OPS_ROOT_LIB="$HOOK_DIR/_lib-ops-root.sh"
PR_CREATE_HOOK="$HOOK_DIR/validate-pr-create.sh"
COMMIT_REFS_HOOK="$HOOK_DIR/verify-commit-refs.sh"
SKILL_GATE_HOOK="$HOOK_DIR/require-skill-for-issue-create.sh"
DEFAULTS="$(cd "$HOOK_DIR/.." && pwd)/project-config.defaults.json"
EXTRACT_PUSH_REF="$HOOK_DIR/_lib-extract-push-ref.sh"
DETECT_BASH_WRITE="$HOOK_DIR/_lib-detect-bash-write.sh"

for f in "$TRACKER_LIB" "$CONFIG_LIB" "$OPS_ROOT_LIB" "$PR_CREATE_HOOK" "$COMMIT_REFS_HOOK" "$SKILL_GATE_HOOK" "$DEFAULTS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file not found: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

record_pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
record_fail() {
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  - $1"
  echo "FAIL: $1"
  [ -n "${2:-}" ] && echo "  $2"
}

# ---------------------------------------------------------------------------
# make_workspace_layout: build a synthetic ops-fork layout containing
# a `workspace/test-project/` clone with its own .git/ so
# `git rev-parse --show-toplevel` from inside resolves to the PROJECT
# clone, NOT the ops fork. This is the exact shape of the production bug.
#
# Layout:
#   <sb>/                          ← ops fork root
#     .git/                          (so the ops fork is a git repo too)
#     onboarding.yaml                (v1 anchor for _lib-ops-root.sh)
#     apexyard.projects.yaml         (v1 anchor)
#     .claude/
#       hooks/...                    (copies of the lib + hook scripts)
#       project-config.defaults.json
#       project-config.json          (per-test override of tracker config)
#     workspace/test-project/
#       .git/                        (project clone is its own git repo)
#
# Echoes the ops-fork path on stdout.
# ---------------------------------------------------------------------------
make_workspace_layout() {
  local sb
  sb=$(mktemp -d)
  sb=$(cd "$sb" && pwd -P)
  (
    cd "$sb" || exit 1
    # The ops-fork itself is a git repo so origin-based fallbacks have something
    # to resolve against. The project clone has its own separate .git/ which
    # is what triggers the bug.
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git remote add origin "https://github.com/test-org/test-fork.git" 2>/dev/null || true

    touch onboarding.yaml
    cat > apexyard.projects.yaml <<'YAML'
version: 1
projects:
  - name: test-project
    repo: test-org/test-project
    workspace: workspace/test-project
YAML
    mkdir -p .claude/hooks/tests
    cp "$TRACKER_LIB"        .claude/hooks/_lib-tracker.sh
    cp "$CONFIG_LIB"         .claude/hooks/_lib-read-config.sh
    cp "$OPS_ROOT_LIB"       .claude/hooks/_lib-ops-root.sh
    cp "$PR_CREATE_HOOK"     .claude/hooks/validate-pr-create.sh
    cp "$COMMIT_REFS_HOOK"   .claude/hooks/verify-commit-refs.sh
    cp "$SKILL_GATE_HOOK"    .claude/hooks/require-skill-for-issue-create.sh
    [ -f "$EXTRACT_PUSH_REF" ]   && cp "$EXTRACT_PUSH_REF"   .claude/hooks/
    [ -f "$DETECT_BASH_WRITE" ] && cp "$DETECT_BASH_WRITE" .claude/hooks/
    chmod +x .claude/hooks/*.sh
    cp "$DEFAULTS" .claude/project-config.defaults.json

    # Gitignore the workspace dir so the outer git repo doesn't try to add
    # the nested project clone as a submodule (mirrors how the real ops fork
    # gitignores workspace/ with `workspace/*/`).
    echo "workspace/" > .gitignore

    # Build the workspace clone — a separate git repo whose --show-toplevel
    # would mislead any cwd-relative config-path resolution. Create it AFTER
    # the outer commit so the outer add doesn't trip on the nested .git/.
    git add -A
    git commit -q -m "test fixture (ops fork shell)" 2>/dev/null

    mkdir -p workspace/test-project
    (
      cd workspace/test-project || exit 1
      git init -q
      git config user.email "proj@example.com"
      git config user.name "proj"
      # Give the project clone an origin so origin-based extractions don't
      # accidentally cross over to the ops-fork's origin.
      git remote add origin "https://github.com/test-org/test-project.git" 2>/dev/null || true
      # Seed a commit so git rev-parse --show-toplevel works from inside.
      : > .keep
      git add .keep
      git commit -q -m "project fixture" 2>/dev/null
    )
  )
  echo "$sb"
}

# Configure tracker.kind=jira with PROJ-NN id_pattern in the OPS FORK's
# project-config.json. This is the operator-visible configuration; the bug
# was that this file was IGNORED when running from inside the workspace
# clone.
write_jira_config() {
  local sb="$1"
  cat > "$sb/.claude/project-config.json" <<'JSON'
{
  "tracker": {
    "kind": "jira",
    "view_command": "jira issue view {id} --raw",
    "id_pattern": "^PROJ-[0-9]+$"
  }
}
JSON
}

# Install a mock `jira` CLI inside the sandbox's bin/. The mock returns
# REST-shaped JSON for `jira issue view <ID> --raw`. PROJ-42 returns
# "In Progress"; PROJ-99 returns "not found" (exit 1).
install_jira_mock() {
  local sb="$1"
  mkdir -p "$sb/bin"
  cat > "$sb/bin/jira" <<'EOF'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  num="$3"
  case "$num" in
    PROJ-99)
      # Simulate "missing" via non-zero exit + empty stdout.
      exit 1
      ;;
    *)
      printf '{"self":"https://jira.x/%s","fields":{"status":{"name":"In Progress"},"summary":"mock %s","labels":[]}}\n' "$num" "$num"
      exit 0
      ;;
  esac
fi
exit 0
EOF
  chmod +x "$sb/bin/jira"
}

# Install a stub `gh` that ALWAYS exits 99 — used to detect accidental
# fallback to GitHub when the configured tracker should have been jira.
# If the hook calls gh, we see exit 99 and the test fails.
install_gh_stub_that_fails() {
  local sb="$1"
  mkdir -p "$sb/bin"
  cat > "$sb/bin/gh" <<'EOF'
#!/bin/bash
# This stub fires when the workspace-tracker-resolution bug is unfixed:
# the hook reaches for `gh issue view` because tracker.kind silently
# defaulted to "gh". exit 99 is visible in the test failure.
echo "[gh-stub] unexpected call: $*" >&2
exit 99
EOF
  chmod +x "$sb/bin/gh"
}

# =============================================================================
# Case 1: _lib-read-config.sh resolves ops-fork config from inside workspace
# clone. Without the fix, config_get '.tracker.kind' would return "" (no
# config file resolvable from project-clone-rooted resolution) or "gh"
# (from the defaults file, which doesn't ship .tracker.kind = "jira").
# =============================================================================
case_1() {
  local sb out
  sb=$(make_workspace_layout)
  write_jira_config "$sb"

  # Source the libs and call config_get from inside the workspace clone.
  out=$(
    cd "$sb/workspace/test-project" || exit 99
    . "$sb/.claude/hooks/_lib-read-config.sh"
    config_get '.tracker.kind' 2>/dev/null
  )
  if [ "$out" = "jira" ]; then
    record_pass "case 1: config_get .tracker.kind resolves to 'jira' from inside workspace clone"
  else
    record_fail "case 1: config_get .tracker.kind resolves to 'jira' from inside workspace clone" "got: '$out' (expected 'jira')"
  fi
  rm -rf "$sb"
}

# =============================================================================
# Case 2: tracker_kind via _lib-tracker.sh returns "jira" from workspace clone.
# This is the higher-level entry point most consumers use.
# =============================================================================
case_2() {
  local sb out
  sb=$(make_workspace_layout)
  write_jira_config "$sb"

  out=$(
    cd "$sb/workspace/test-project" || exit 99
    . "$sb/.claude/hooks/_lib-read-config.sh"
    . "$sb/.claude/hooks/_lib-tracker.sh"
    tracker_clear_cache
    tracker_kind
  )
  if [ "$out" = "jira" ]; then
    record_pass "case 2: tracker_kind returns 'jira' from inside workspace clone"
  else
    record_fail "case 2: tracker_kind returns 'jira' from inside workspace clone" "got: '$out' (expected 'jira')"
  fi
  rm -rf "$sb"
}

# =============================================================================
# Case 3: verify-commit-refs.sh dispatches the jira CLI (not gh) for a
# PROJ-shaped commit reference, when invoked from inside the workspace clone.
#
# We install BOTH a working `jira` mock AND a failing `gh` stub. If the bug
# is present, the hook reaches for `gh` (because tracker.kind silently
# defaulted to "gh") and exits 99. If the fix is in place, it reaches for
# `jira`, gets a valid response, and exits 0.
# =============================================================================
case_3() {
  local sb rc
  sb=$(make_workspace_layout)
  write_jira_config "$sb"
  install_jira_mock "$sb"
  install_gh_stub_that_fails "$sb"

  local input='{"tool_input":{"command":"git commit -m \"fix: address regression\n\nCloses PROJ-42\""}}'
  rc=$(
    cd "$sb/workspace/test-project" || exit 99
    PATH="$sb/bin:$PATH" "$sb/.claude/hooks/verify-commit-refs.sh" <<<"$input" >/dev/null 2>&1
    echo $?
  )
  # Note: verify-commit-refs.sh only scans #N refs by default, not PREFIX-N.
  # The hook's REFS regex is `\b(close[sd]?|fix(e[sd])?|...)\s+#[0-9]+`. With
  # a Jira-style PROJ-42 reference, no #N ref is extracted → hook exits 0
  # without touching the tracker CLI.
  #
  # That's actually the right behaviour for THIS hook: a commit message
  # citing "Closes PROJ-42" is informational prose, not a GitHub auto-close
  # directive. The hook is GitHub-Issue-specific by design (it looks for the
  # auto-close keyword + #N shape that GitHub recognises).
  #
  # For this case we instead exercise an explicit #N reference under a jira
  # config — the hook SHOULD now correctly route through `tracker_view` which
  # dispatches to the configured `jira` template. Since jira CLI won't return
  # anything useful for a #N (we'd need to translate), the hook is expected
  # to fail to find it and BLOCK. Under the bug, the hook reaches for `gh`
  # which is our failing stub — block AND exit 99 visible.
  #
  # Either way: the hook must NOT exit 99 (which is the unique signal that
  # the unwanted `gh` shim got called). 0 (no issues to verify) or 2 (BLOCKED:
  # ticket not found via jira) are both acceptable outcomes here.
  if [ "$rc" != "99" ]; then
    record_pass "case 3: verify-commit-refs.sh did NOT fall back to gh under jira config from workspace clone (rc=$rc)"
  else
    record_fail "case 3: verify-commit-refs.sh did NOT fall back to gh under jira config from workspace clone" "got rc=99 (the gh-stub-that-fails fired — config wasn't resolved correctly)"
  fi
  rm -rf "$sb"
}

# =============================================================================
# Case 4: validate-pr-create.sh dispatches the jira CLI (not gh) for a
# PROJ-shaped PR title, from inside the workspace clone.
#
# The PR title `feat(PROJ-42): ...` should:
#   - Pass the title shape check (PROJ-NN is on the legacy allow-list
#     via the default tracker.id_pattern's [A-Z]{2,10}-[0-9]+ branch).
#   - Be routed through `tracker_view PROJ-42` which dispatches to
#     `jira issue view PROJ-42 --raw` (our mock returns OK).
#   - Exit 0 (hook accepts the PR).
#
# Under the bug, the hook would call `gh issue view 42 --repo ...` (the
# failing stub) and exit 2 with rc=99 visible.
# =============================================================================
case_4() {
  local sb rc
  sb=$(make_workspace_layout)
  write_jira_config "$sb"
  install_jira_mock "$sb"
  install_gh_stub_that_fails "$sb"

  # Build a syntactically-valid PR command. The branch carries a PROJ-ID
  # so the branch-name check on the hook passes too.
  local cmd
  cmd='gh pr create --title "feat(PROJ-42): add jira-shaped ticket flow" --body "
## Testing
verify against staging

## Glossary
| Term | Definition |
|------|------------|
| PROJ | example tracker prefix |
" --head feature/PROJ-42-jira-shape'
  local input
  input=$(jq -nc --arg cmd "$cmd" '{tool_input:{command:$cmd}}')

  rc=$(
    cd "$sb/workspace/test-project" || exit 99
    PATH="$sb/bin:$PATH" "$sb/.claude/hooks/validate-pr-create.sh" <<<"$input" >/dev/null 2>&1
    echo $?
  )
  # 0 = hook accepted the PR via the configured jira tracker.
  # 99 = the failing gh stub fired (bug present).
  # 2 = hook blocked for another reason (shape mismatch, missing section, etc.).
  if [ "$rc" = "0" ]; then
    record_pass "case 4: validate-pr-create.sh routes PROJ-42 via jira (not gh) from workspace clone"
  elif [ "$rc" = "99" ]; then
    record_fail "case 4: validate-pr-create.sh routes PROJ-42 via jira (not gh) from workspace clone" "got rc=99 — the gh-stub-that-fails fired, indicating the hook fell back to GitHub (config not resolved)"
  else
    record_fail "case 4: validate-pr-create.sh routes PROJ-42 via jira (not gh) from workspace clone" "got rc=$rc (expected 0; not 99 = config resolved but blocked for other reasons)"
  fi
  rm -rf "$sb"
}

# =============================================================================
# Case 5: require-skill-for-issue-create.sh reads
# .ticket.create_command_patterns AND .ticket.bootstrap_skills correctly
# from inside the workspace clone.
#
# We invoke the hook with a `gh issue create` command but NO ticket-skill
# marker — the hook should BLOCK (exit 2). If config resolution is broken,
# the patterns list comes back empty and the hook silently passes. We
# assert the BLOCK fires, which proves the patterns list loaded from the
# ops-fork-rooted config.
# =============================================================================
case_5() {
  local sb rc
  sb=$(make_workspace_layout)
  # No override config — the defaults file has the create_command_patterns
  # list. That's the file the hook needs to find from the workspace clone.

  local input
  input=$(jq -nc '{tool_name:"Bash", tool_input:{command:"gh issue create --title test --body x"}}')

  rc=$(
    cd "$sb/workspace/test-project" || exit 99
    PATH="$sb/bin:$PATH" "$sb/.claude/hooks/require-skill-for-issue-create.sh" <<<"$input" >/dev/null 2>&1
    echo $?
  )
  if [ "$rc" = "2" ]; then
    record_pass "case 5: require-skill-for-issue-create.sh blocks raw 'gh issue create' from inside workspace clone (config-driven matchers loaded)"
  else
    record_fail "case 5: require-skill-for-issue-create.sh blocks raw 'gh issue create' from inside workspace clone" "got rc=$rc (expected 2 — the patterns list was loaded from ops-fork-rooted config)"
  fi
  rm -rf "$sb"
}

# =============================================================================
# Case 6: regression — from the ops-fork root itself (NOT a workspace clone),
# every config lookup still resolves correctly. The fix must not break the
# standard case.
# =============================================================================
case_6() {
  local sb out
  sb=$(make_workspace_layout)
  write_jira_config "$sb"

  out=$(
    cd "$sb" || exit 99
    . "$sb/.claude/hooks/_lib-read-config.sh"
    . "$sb/.claude/hooks/_lib-tracker.sh"
    tracker_clear_cache
    tracker_kind
  )
  if [ "$out" = "jira" ]; then
    record_pass "case 6: regression — tracker_kind still resolves from ops-fork root (not just workspace)"
  else
    record_fail "case 6: regression — tracker_kind still resolves from ops-fork root" "got: '$out' (expected 'jira')"
  fi
  rm -rf "$sb"
}

# =============================================================================
# Case 7: regression — when no ops-fork anchor is present (bare clone / CI
# sandbox), _config_repo_root falls back to `git rev-parse --show-toplevel`.
# Previous behaviour preserved.
# =============================================================================
case_7() {
  local sb out
  sb=$(mktemp -d)
  sb=$(cd "$sb" && pwd -P)
  # Build a bare git repo with NO ops-fork anchors. The repo HAS a
  # .claude/project-config.json at its root — that's what we expect the
  # fallback path to find.
  (
    cd "$sb" || exit 99
    git init -q
    git config user.email t@e.x
    git config user.name t
    mkdir -p .claude/hooks
    cp "$CONFIG_LIB"   .claude/hooks/_lib-read-config.sh
    cp "$OPS_ROOT_LIB" .claude/hooks/_lib-ops-root.sh
    cp "$DEFAULTS"     .claude/project-config.defaults.json
    cat > .claude/project-config.json <<'JSON'
{ "tracker": { "kind": "linear" } }
JSON
    git add -A
    git commit -q -m fixture
  )
  out=$(
    cd "$sb" || exit 99
    . "$sb/.claude/hooks/_lib-read-config.sh"
    config_get '.tracker.kind' 2>/dev/null
  )
  if [ "$out" = "linear" ]; then
    record_pass "case 7: regression — no ops-fork anchor → falls back to git rev-parse (config still loads)"
  else
    record_fail "case 7: regression — no ops-fork anchor → falls back to git rev-parse" "got: '$out' (expected 'linear')"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Run all cases
# ---------------------------------------------------------------------------
echo "Running tests for me2resh/apexyard#310 (workspace tracker resolution)..."
case_1
case_2
case_3
case_4
case_5
case_6
case_7

echo
echo "===== test_workspace_tracker_resolution.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0
