#!/bin/bash
# Smoke tests for /handover's clone-first deep-dive prompt
# (me2resh/apexyard#188 — LSP spike Option 3).
#
# /handover is a markdown skill spec the model executes; this test
# exercises two things:
#
#   1. SPEC SHAPE — the SKILL.md file contains the prompt text at the
#      right location (after step 7 "Append to the portfolio registry",
#      before what becomes the final summary), and surfaces the five
#      cost-transparency facts the ticket's AC requires.
#
#   2. RUNTIME SHAPE — a small bash simulator that mirrors the clone
#      branch the spec documents, exercised against an isolated sandbox
#      with a mocked `git` binary so no network call ever fires. Verifies:
#
#        - operator response `n`     → no `git clone` invocation, exit clean
#        - operator response `later` → no `git clone` invocation, exit clean
#        - operator response `y`     → exactly one `git clone <url> workspace/<name>`
#                                       invocation with the documented argument shape
#        - workspace already exists  → no `git clone` invocation (skip-if-exists)
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
# spec_assert <label> <expected literal substring> [grep-extended-regex flag]
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
# Spec-shape tests — verify the SKILL.md contains the documented prompt
# at the documented location.
# ---------------------------------------------------------------------------

# 1. The new step exists, with a heading that names the clone-first option.
spec_assert "spec-step-heading" \
  "### 8. Offer the clone-first deep-dive option (recommended)"

# 2. Insertion point — step 7 (registry append) still precedes step 8, and
#    step 9 (validation) follows step 8. Catches accidental reordering.
spec_assert "spec-step-7-still-registry"  \
  "### 7. Append to the portfolio registry"
spec_assert "spec-step-9-still-validation" \
  "### 9. Offer validation (conditional, default-no)"
spec_assert "spec-step-10-summary" \
  "### 10. Return a summary"

# 3. Five cost-transparency facts (AC #3 of the ticket).
spec_assert "spec-cost-1-enable-lsp-tool"   "ENABLE_LSP_TOOL=1"
spec_assert "spec-cost-2-plugin-install"    "plugin install is your problem"
spec_assert "spec-cost-3-disk-and-gitignore" "gitignored"
spec_assert "spec-cost-4-cross-project-grep" "Cross-project semantic queries still need grep"
spec_assert "spec-cost-5-cold-start"         "Cold-start on large monorepos can be 30+ seconds"

# 4. Three-option prompt response shape.
spec_assert "spec-prompt-response-options" "[y / n / later]"

# 5. Follow-up skill suggestion on success (AC #4 of the ticket).
spec_assert "spec-followup-threat-model" \
  "Want to run /threat-model against the new clone now?"

# 6. Skip-if-exists branch is documented. After framework #242 the skill
# resolves the workspace dir via portfolio_workspace_dir (split-portfolio
# v2 may point it at a sibling private repo), so the literal becomes
# `$WORKSPACE_DIR/<name>` rather than `workspace/<name>`. The shape of
# the skip branch (an `if [ -d ... ]; then` guard around `git clone`)
# is what the spec test pins.
spec_assert "spec-skip-if-exists" \
  'if [ -d "$WORKSPACE_DIR/<name>" ]; then'

# 7. Decline path documented as silent (no side effects).
spec_assert "spec-decline-silent" \
  "Skip silently — no side effects"

# ---------------------------------------------------------------------------
# Runtime-shape simulator. Mirrors the bash logic the spec documents in
# the "On `y`" branch. The simulator never touches the real `git`; we
# point PATH at a mock that records its argv and exits 0.
#
# simulate <answer> <workspace-pre-exists?> <name> <repo-url>
#   → echoes the recorded `git clone` argv to stdout (empty if no call)
#   → returns simulator exit code
# ---------------------------------------------------------------------------
simulate() {
  local answer="$1" pre_exists="$2" name="$3" repo_url="$4"
  local sb log
  sb=$(mktemp -d)
  sb=$(cd "$sb" && pwd -P)
  log="$sb/.git-clone-calls.log"
  : > "$log"

  # Mock `git` — only handles `git clone <url> <dest>`; for anything else,
  # the simulator never calls it, so we just record + exit 0.
  cat > "$sb/git" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = "clone" ]; then
  printf '%s\n' "\$*" >> "$log"
  # Pretend the clone succeeded — make the destination dir so any
  # subsequent skip-if-exists logic in a re-run sees a real workspace.
  if [ -n "\$3" ]; then
    mkdir -p "\$3"
  fi
  exit 0
fi
exit 0
MOCK
  chmod +x "$sb/git"

  # Optionally pre-create workspace/<name>/ to exercise the skip branch.
  if [ "$pre_exists" = "1" ]; then
    mkdir -p "$sb/workspace/$name"
  fi

  # The simulator: a faithful translation of the spec's "On y" + skip
  # branches. Lives inside this test on purpose — the spec is the source
  # of truth, and any divergence between this and the spec is a test
  # failure to triage. All status output goes to stderr; only the
  # captured git-clone argv from $log lands on stdout.
  (
    cd "$sb" || exit 1
    PATH="$sb:$PATH"
    case "$answer" in
      y|Y|yes)
        if [ -d "workspace/$name" ]; then
          echo "skip-existing" >&2
        else
          git clone "$repo_url" "workspace/$name" >/dev/null 2>&1
          echo "cloned" >&2
        fi
        ;;
      n|N|no|later|"")
        echo "skipped" >&2
        ;;
      *)
        # Unknown input → treat as `n` per the spec.
        echo "skipped" >&2
        ;;
    esac
  )
  local rc=$?

  # Echo whatever git invocations were captured.
  if [ -s "$log" ]; then
    cat "$log"
  fi

  rm -rf "$sb"
  return $rc
}

# Case A: answer `n` → no clone, exit 0
out=$(simulate "n" 0 "example-app" "https://github.com/example/example-app.git" 2>/dev/null)
if [ -z "$out" ]; then
  echo "PASS [runtime-decline-no]"
  PASS=$((PASS+1))
else
  echo "FAIL [runtime-decline-no]: expected no git invocation, got: $out" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}runtime-decline-no "
fi

# Case B: answer `later` → no clone, exit 0
out=$(simulate "later" 0 "example-app" "https://github.com/example/example-app.git" 2>/dev/null)
if [ -z "$out" ]; then
  echo "PASS [runtime-decline-later]"
  PASS=$((PASS+1))
else
  echo "FAIL [runtime-decline-later]: expected no git invocation, got: $out" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}runtime-decline-later "
fi

# Case C: answer `y` → exactly one `git clone <url> workspace/<name>`
out=$(simulate "y" 0 "example-app" "https://github.com/example/example-app.git" 2>/dev/null)
expected="clone https://github.com/example/example-app.git workspace/example-app"
if [ "$out" = "$expected" ]; then
  echo "PASS [runtime-accept-y]"
  PASS=$((PASS+1))
else
  echo "FAIL [runtime-accept-y]: argv mismatch" >&2
  echo "    expected: $expected" >&2
  echo "    got:      $out" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}runtime-accept-y "
fi

# Case D: workspace pre-exists → answer `y` skips the clone
out=$(simulate "y" 1 "example-app" "https://github.com/example/example-app.git" 2>/dev/null)
if [ -z "$out" ]; then
  echo "PASS [runtime-skip-if-exists]"
  PASS=$((PASS+1))
else
  echo "FAIL [runtime-skip-if-exists]: expected no git invocation when workspace exists, got: $out" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}runtime-skip-if-exists "
fi

# Case E: unknown input → treated as `n` (no clone)
out=$(simulate "maybe" 0 "example-app" "https://github.com/example/example-app.git" 2>/dev/null)
if [ -z "$out" ]; then
  echo "PASS [runtime-unknown-input-no-clone]"
  PASS=$((PASS+1))
else
  echo "FAIL [runtime-unknown-input-no-clone]: expected no git invocation, got: $out" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}runtime-unknown-input-no-clone "
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
