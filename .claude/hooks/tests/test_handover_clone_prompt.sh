#!/bin/bash
# Smoke tests for /handover's clone behaviour.
#
# History: the original design (me2resh/apexyard#188) offered a clone-first
# deep-dive prompt at step 8 with a `[y / n / later]` choice. That was
# REDESIGNED — the repo is now cloned by DEFAULT at step 1.5-clone (no prompt;
# `--no-clone` opts out), and step 8 became a follow-up-skills offer against the
# already-cloned repo. This test was rewritten (#528) to pin the current spec
# instead of the removed prompt.
#
# /handover is a markdown skill spec the model executes; this test exercises:
#
#   1. SPEC SHAPE — SKILL.md documents clone-by-default at step 1.5-clone
#      (skip-if-`.git`-exists, `--no-clone` to decline), the step-8 follow-up
#      offer, the LSP cost-transparency facts, and the surrounding step order.
#
#   2. RUNTIME SHAPE — a small bash simulator mirroring the spec's clone branch,
#      run against an isolated sandbox with a mocked `git` (no network). Verifies:
#        - default (no --no-clone), workspace absent → exactly one
#          `git clone <url> <workspace>/<name>`
#        - `--no-clone`                              → no git clone (declined)
#        - workspace/<name>/.git already exists      → no git clone (skip)
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SKILL_FILE="$SRC_ROOT/.claude/skills/handover/SKILL.md"

if [ ! -f "$SKILL_FILE" ]; then
  echo "FAIL: handover SKILL.md not found at $SKILL_FILE" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

# ---------------------------------------------------------------------------
# spec_assert <label> <expected literal substring>
# ---------------------------------------------------------------------------
spec_assert() {
  local label="$1" needle="$2"
  if grep -qF -- "$needle" "$SKILL_FILE"; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label]: missing literal substring in SKILL.md: '$needle'" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
  fi
}

# ---------------------------------------------------------------------------
# Spec-shape tests — the current clone-by-default design.
# ---------------------------------------------------------------------------

# 1. Clone happens at step 1.5-clone, by default, on the URL path.
spec_assert "spec-step-1.5-clone-heading" \
  "### 1.5-clone. Clone the repo (URL path only — default yes)"
spec_assert "spec-clone-default-yes" \
  'Default is **yes** — no confirmation needed unless the operator explicitly passes `--no-clone`'

# 2. Clone mechanics: workspace resolved via the portfolio helper, skip when a
#    .git already exists, otherwise clone.
spec_assert "spec-workspace-dir-helper" "WORKSPACE_DIR=\$(portfolio_workspace_dir)"
spec_assert "spec-skip-if-git-exists"   'if [ -d "$WORKSPACE_DIR/<name>/.git" ]; then'
spec_assert "spec-clone-command"        'git clone <repo-url> "$WORKSPACE_DIR/<name>"'

# 3. Clone-status marker drives the downstream read path.
spec_assert "spec-clone-status-marker"  'CLONE_STATUS="cloned"'
spec_assert "spec-no-clone-declined"    '$CLONE_STATUS="declined"'

# 4. Step 8 is now a follow-up-skills offer against the already-cloned repo.
spec_assert "spec-step-8-heading" \
  "### 8. Offer follow-up deep-dive skills (against the already-cloned repo)"
spec_assert "spec-step-8-threat-model"   "1. /threat-model"
spec_assert "spec-step-8-options"        "[1/2/3/all/none — default none]"

# 5. Cost-transparency facts the step-8 offer still surfaces.
spec_assert "spec-cost-enable-lsp-tool"  "ENABLE_LSP_TOOL=1"
spec_assert "spec-cost-cold-start"       "Cold-start on large monorepos can be 30+ seconds"

# 6. Surrounding step order (catches accidental reordering).
spec_assert "spec-step-7-registry"    "### 7. Append to the portfolio registry"
spec_assert "spec-step-9-validation"  "### 9. Offer validation (conditional, default-no)"
spec_assert "spec-step-10-summary"    "### 10. Return a summary"

# ---------------------------------------------------------------------------
# Runtime-shape simulator. Mirrors the clone branch the spec documents in
# step 1.5-clone. Never touches the real `git`; PATH points at a mock that
# records its argv and exits 0.
#
# simulate <no_clone_flag> <workspace-git-pre-exists?> <name> <repo-url>
#   → echoes the recorded `git clone` argv to stdout (empty if no call)
# ---------------------------------------------------------------------------
simulate() {
  local no_clone="$1" pre_exists="$2" name="$3" repo_url="$4"
  local sb log
  sb=$(mktemp -d)
  sb=$(cd "$sb" && pwd -P)
  log="$sb/.git-clone-calls.log"
  : > "$log"

  cat > "$sb/git" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = "clone" ]; then
  printf '%s\n' "\$*" >> "$log"
  [ -n "\$3" ] && mkdir -p "\$3"
  exit 0
fi
exit 0
MOCK
  chmod +x "$sb/git"

  # WORKSPACE_DIR resolves to workspace/ in single-fork mode (what the sandbox
  # models). Optionally pre-create workspace/<name>/.git to exercise the skip.
  if [ "$pre_exists" = "1" ]; then
    mkdir -p "$sb/workspace/$name/.git"
  fi

  # Faithful translation of the spec's step-1.5-clone branch. Status → stderr;
  # only the captured git-clone argv lands on stdout.
  (
    cd "$sb" || exit 1
    PATH="$sb:$PATH"
    WORKSPACE_DIR="workspace"
    if [ "$no_clone" = "1" ]; then
      echo "declined (--no-clone)" >&2
    elif [ -d "$WORKSPACE_DIR/$name/.git" ]; then
      echo "preserved (already exists)" >&2
    else
      git clone "$repo_url" "$WORKSPACE_DIR/$name" >/dev/null 2>&1
      echo "cloned" >&2
    fi
  )

  [ -s "$log" ] && cat "$log"
  rm -rf "$sb"
}

URL="https://github.com/example/example-app.git"

# Case A: default (no --no-clone), workspace absent → exactly one clone.
out=$(simulate "0" 0 "example-app" "$URL" 2>/dev/null)
expected="clone $URL workspace/example-app"
if [ "$out" = "$expected" ]; then
  echo "PASS [runtime-default-clones]"
  PASS=$((PASS+1))
else
  echo "FAIL [runtime-default-clones]: argv mismatch" >&2
  echo "    expected: $expected" >&2
  echo "    got:      $out" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}runtime-default-clones "
fi

# Case B: --no-clone → no git clone.
out=$(simulate "1" 0 "example-app" "$URL" 2>/dev/null)
if [ -z "$out" ]; then
  echo "PASS [runtime-no-clone-declines]"
  PASS=$((PASS+1))
else
  echo "FAIL [runtime-no-clone-declines]: expected no git invocation, got: $out" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}runtime-no-clone-declines "
fi

# Case C: workspace/<name>/.git pre-exists → skip the clone.
out=$(simulate "0" 1 "example-app" "$URL" 2>/dev/null)
if [ -z "$out" ]; then
  echo "PASS [runtime-skip-if-exists]"
  PASS=$((PASS+1))
else
  echo "FAIL [runtime-skip-if-exists]: expected no git invocation when clone exists, got: $out" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}runtime-skip-if-exists "
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Total: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases: $FAILED_CASES" >&2
  exit 1
fi
exit 0
