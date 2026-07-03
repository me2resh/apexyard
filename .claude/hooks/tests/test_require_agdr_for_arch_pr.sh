#!/bin/bash
# Test fixtures for require-agdr-for-arch-pr.sh.
#
# Each case builds a JSON tool_input payload, primes a throwaway git repo
# with base/HEAD state, and pipes the payload to the hook. We assert on the
# exit code and (optionally) a substring of stderr.
#
# To run:  ./.claude/hooks/tests/test_require_agdr_for_arch_pr.sh
# Exit 0 = all pass, 1 = at least one failure.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
HOOK="$REPO_ROOT/.claude/hooks/require-agdr-for-arch-pr.sh"

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

# Create a minimal fake fork: an isolated git repo with a main branch plus a
# feature branch carrying the changes we want to test.
# Usage: setup_repo <base-setup-fn> <feature-setup-fn>
#   base-setup-fn      : runs on main, commits the starting state
#   feature-setup-fn   : runs on the feature branch, commits the PR changes
setup_repo() {
  local base_fn="$1"
  local feat_fn="$2"
  local dir
  dir=$(mktemp -d -t agdr-pr.XXXXXX)
  (
    cd "$dir" || exit 1
    git init -q -b main
    git config user.email t@t.test
    git config user.name test
    # Fork marker so the hook's (future) root-walk finds a plausible ops root.
    echo "company: test" > onboarding.yaml
    git add onboarding.yaml
    git commit -q -m init
    "$base_fn"
    git checkout -q -b feature
    "$feat_fn"
  )
  echo "$dir"
}

# Run the hook from inside $1 with payload built from $2 (command string).
# $3 = expected exit code, $4 = optional stderr substring.
run_case() {
  local name="$1"
  local dir="$2"
  local expected_exit="$3"
  local expected_stderr_substr="$4"
  local cmd="$5"

  local stderr_file
  stderr_file=$(mktemp)

  ( cd "$dir" && echo "$(make_payload "$cmd")" | "$HOOK" ) 2> "$stderr_file"
  local actual_exit=$?
  local stderr_content
  stderr_content=$(cat "$stderr_file")
  rm -f "$stderr_file"

  local ok=1
  if [ "$actual_exit" != "$expected_exit" ]; then ok=0; fi
  if [ -n "$expected_stderr_substr" ]; then
    if ! echo "$stderr_content" | grep -qF -- "$expected_stderr_substr"; then
      ok=0
    fi
  fi

  if [ "$ok" = 1 ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "   expected exit=$expected_exit, got $actual_exit"
    if [ -n "$expected_stderr_substr" ]; then
      echo "   expected stderr to contain: $expected_stderr_substr"
    fi
    echo "   stderr was:"
    echo "$stderr_content" | sed 's/^/     /'
    FAIL=$((FAIL + 1))
  fi

  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Fixture setup helpers
# ---------------------------------------------------------------------------

# 1. Arch path change (domain/) on feature branch, no AgDR in body → BLOCK.
c1_base() {
  mkdir -p src/domain
  echo "export const x = 1" > src/domain/widget.ts
  git add src/domain/widget.ts
  git commit -q -m "base: add domain"
}
c1_feat() {
  echo "export const x = 2" > src/domain/widget.ts
  git add src/domain/widget.ts
  git commit -q -m "feat: tweak domain"
}

# 2. Same as above but PR body links an AgDR → PASS.
#    (Reuses c1_*)

# 3. Dep added to package.json (no version bump) → BLOCK.
c3_base() {
  cat > package.json <<'JSON'
{
  "name": "t",
  "version": "0.0.1",
  "dependencies": {
    "lodash": "^4.0.0"
  }
}
JSON
  git add package.json
  git commit -q -m "base: pkg"
}
c3_feat() {
  cat > package.json <<'JSON'
{
  "name": "t",
  "version": "0.0.1",
  "dependencies": {
    "lodash": "^4.0.0",
    "zod": "^3.0.0"
  }
}
JSON
  git add package.json
  git commit -q -m "feat: add zod"
}

# 4. Version-only bump — same keys, different version → NO FIRE → PASS.
c4_base() {
  cat > package.json <<'JSON'
{
  "name": "t",
  "dependencies": {
    "lodash": "^4.0.0"
  }
}
JSON
  git add package.json
  git commit -q -m "base: pkg"
}
c4_feat() {
  cat > package.json <<'JSON'
{
  "name": "t",
  "dependencies": {
    "lodash": "^4.17.0"
  }
}
JSON
  git add package.json
  git commit -q -m "feat: bump lodash"
}

# 5. Skip marker with arch change → PASS with warning on stderr.
#    (Reuses c1_*)

# 6. Non-triggering diff — a plain README change → PASS.
c6_base() {
  echo "# hello" > README.md
  git add README.md
  git commit -q -m "base: readme"
}
c6_feat() {
  echo "# hello world" > README.md
  git add README.md
  git commit -q -m "feat: tweak readme"
}

# ---------------------------------------------------------------------------
# Run cases
# ---------------------------------------------------------------------------

DIR=$(setup_repo c1_base c1_feat)
run_case "arch path changed, no AgDR → BLOCK" \
  "$DIR" 2 "no AgDR reference" \
  "gh pr create --base main --title 'feat(#1): tweak domain' --body 'just a change'"

DIR=$(setup_repo c1_base c1_feat)
run_case "arch path changed, AgDR referenced → PASS" \
  "$DIR" 0 "" \
  "gh pr create --base main --title 'feat(#1): tweak domain' --body 'See AgDR-0007-tweak-domain for rationale.'"

DIR=$(setup_repo c3_base c3_feat)
run_case "new dep added, no AgDR → BLOCK" \
  "$DIR" 2 "Triggering dep-file additions" \
  "gh pr create --base main --title 'feat(#2): add zod' --body 'needed it'"

DIR=$(setup_repo c4_base c4_feat)
run_case "version-only bump → PASS (no fire)" \
  "$DIR" 0 "" \
  "gh pr create --base main --title 'chore(#3): bump lodash' --body 'no decision here'"

DIR=$(setup_repo c1_base c1_feat)
run_case "skip marker bypasses → PASS with warning" \
  "$DIR" 0 "agdr: not-applicable marker present" \
  "gh pr create --base main --title 'refactor(#4): move domain' --body 'pure rename <!-- agdr: not-applicable -->'"

DIR=$(setup_repo c6_base c6_feat)
run_case "non-matching diff → PASS" \
  "$DIR" 0 "" \
  "gh pr create --base main --title 'docs(#5): readme' --body 'no arch change'"

DIR=$(setup_repo c1_base c1_feat)
run_case "non-gh command → no-op" \
  "$DIR" 0 "" \
  "git status"

# ---------------------------------------------------------------------------
# Spike exemption (apexyard#180) — three signals; any one wins.
# ---------------------------------------------------------------------------

# Spike signal (a): PR title type = `spike(...)`. Arch path changed, no AgDR
# in body — production rule would BLOCK; spike exemption flips to PASS.
DIR=$(setup_repo c1_base c1_feat)
run_case "spike PR title (arch change, no AgDR) → PASS via spike exemption" \
  "$DIR" 0 "spike/prototype PR detected" \
  "gh pr create --base main --title 'spike(#180): explore X' --body 'just a spike'"

# Spike signal (c): branch name starts with `spike/`. Set the feature branch
# name accordingly before running the case. Same arch-change fixture.
spike_branch_setup() {
  local dir
  dir=$(setup_repo c1_base c1_feat)
  ( cd "$dir" && git branch -m spike/GH-180-explore ) >/dev/null 2>&1
  echo "$dir"
}

DIR=$(spike_branch_setup)
run_case "spike branch name (arch change, no AgDR, non-spike PR title) → PASS via branch signal" \
  "$DIR" 0 "spike/prototype PR detected" \
  "gh pr create --base main --title 'feat(#180): tweak domain' --body 'just exploring'"

# Spike signal (b): active-ticket marker references a [Spike] ticket.
# Build a fixture where the repo IS its own ops root (has onboarding.yaml +
# apexyard.projects.yaml + the marker). c1_base/c1_feat already provides
# arch-path changes; we just have to seed the marker and the registry.
spike_marker_setup() {
  local dir
  dir=$(setup_repo c1_base c1_feat)
  (
    cd "$dir" || exit 1
    echo "version: 1
projects: []" > apexyard.projects.yaml
    mkdir -p .claude/session
    cat > .claude/session/current-ticket <<'EOF'
repo=test/repo
number=180
title=[Spike] active-marker exemption test
url=https://example.test
suggested_branch=spike/GH-180-test
started_at=2026-05-03T00:00:00Z
EOF
    git add apexyard.projects.yaml
    git commit -q -m "test: add registry"
  )
  echo "$dir"
}

DIR=$(spike_marker_setup)
run_case "spike active-ticket marker (arch change, non-spike branch + title) → PASS via marker signal" \
  "$DIR" 0 "spike/prototype PR detected" \
  "gh pr create --base main --title 'feat(#180): tweak domain' --body 'no AgDR'"

# ---------------------------------------------------------------------------
# Prototype exemption (apexyard#673) — same three signals as spike; any one
# wins. Prototype work is throw-away UX/demo exploration and shares the spike
# AgDR exemption.
# ---------------------------------------------------------------------------

# Prototype signal (a): PR title type = `prototype(...)`.
DIR=$(setup_repo c1_base c1_feat)
run_case "prototype PR title (arch change, no AgDR) → PASS via prototype exemption" \
  "$DIR" 0 "spike/prototype PR detected" \
  "gh pr create --base main --title 'prototype(#673): explore look-and-feel' --body 'just a prototype'"

# Prototype signal (c): branch name starts with `prototype/`.
prototype_branch_setup() {
  local dir
  dir=$(setup_repo c1_base c1_feat)
  ( cd "$dir" && git branch -m prototype/GH-673-explore ) >/dev/null 2>&1
  echo "$dir"
}

DIR=$(prototype_branch_setup)
run_case "prototype branch name (arch change, no AgDR, non-prototype PR title) → PASS via branch signal" \
  "$DIR" 0 "spike/prototype PR detected" \
  "gh pr create --base main --title 'feat(#673): tweak domain' --body 'just exploring UX'"

# Prototype signal (b): active-ticket marker referencing a [Prototype] ticket
# is supported by the hook (see require-agdr-for-arch-pr.sh — the marker grep
# matches `^title=\[(Spike|Prototype)\]`). It is NOT asserted here because it
# shares the same in-sandbox ops-root resolution limitation as the pre-existing
# "spike active-ticket marker" case above (the marker fixture's ops root isn't
# resolved inside the test sandbox). Signals (a) PR-title-type and (c)
# branch-name — both exercised above — give the prototype exemption equivalent
# coverage to the spike exemption's reliably-green signals.

# ---------------------------------------------------------------------------
# Regression: embedded-quote truncation bug (apexyard#461).
#
# The original sed extractor used `[^"]*` which stopped at the first embedded
# double-quote inside --body, false-blocking PRs where quoted text appeared
# before the AgDR reference or the skip marker.
#
# These cases exercise the three required sub-scenarios from the ticket ACs:
#   (A) AgDR reference follows an embedded quote → hook PASSES.
#   (B) Skip marker follows an embedded quote     → hook PASSES with warn.
#   (C) Embedded quote, but NO AgDR reference     → hook still BLOCKS
#       (true-negative: verifying we haven't over-corrected the gate).
#
# All three use the c1_base/c1_feat arch-change fixture so the hook's
# arch-detection fires and the body-check is actually reached.
# ---------------------------------------------------------------------------

# (A) AgDR reference comes after embedded quote text → PASS.
DIR=$(setup_repo c1_base c1_feat)
run_case "embedded quote before AgDR ref → PASS (no false-block) [#461-A]" \
  "$DIR" 0 "" \
  "gh pr create --base main --title 'feat(#1): tweak domain' --body 'Summary: uses \"greedy\" matching. See AgDR-0007-tweak-domain for rationale.'"

# (B) Skip marker follows an embedded quote → PASS with skip-marker warning.
DIR=$(setup_repo c1_base c1_feat)
run_case "embedded quote before skip marker → PASS with skip warning [#461-B]" \
  "$DIR" 0 "agdr: not-applicable marker present" \
  "gh pr create --base main --title 'refactor(#2): move domain' --body 'Uses \"pure\" rename. <!-- agdr: not-applicable -->'"

# (C) Embedded quote, but genuinely NO AgDR reference and NO skip marker → still BLOCK.
DIR=$(setup_repo c1_base c1_feat)
run_case "embedded quote, no AgDR ref at all → still BLOCKS (true-negative) [#461-C]" \
  "$DIR" 2 "no AgDR reference" \
  "gh pr create --base main --title 'feat(#3): tweak domain' --body 'Uses \"greedy\" matching but forgot to add the decision record.'"

# ---------------------------------------------------------------------------
# Two-repo `cd <target> && gh pr create` (no --repo) — me2resh/apexyard#669.
#
# The hook fires from the cwd tree (the ops fork, which carries arch changes
# on HEAD) BEFORE the in-command `cd` executes. Without re-rooting the diff to
# the cd-target, the hook diffs the cwd tree and false-blocks a docs-only PR
# that is actually being created in a *different* repo (the split-portfolio
# private repo, or a `workspace/<project>/` clone in single-fork mode).
#
# The fix: when the command begins with `cd <path> && …`, evaluate the PR diff
# against <path>'s git tree, not the cwd's.
# ---------------------------------------------------------------------------

# Build a sibling target repo with a docs-only feature branch (no arch paths).
make_target_repo_docs() {
  local pdir
  pdir=$(mktemp -d -t agdr-tgt.XXXXXX)
  (
    cd "$pdir" || exit 1
    git init -q -b main
    git config user.email t@t.test
    git config user.name test
    git remote add origin git@github.com:test-org/portfolio.git
    mkdir -p docs
    echo "# registry" > docs/readme.md
    git add docs/readme.md
    git commit -q -m "base: docs"
    git checkout -q -b feature
    echo "# registry update" >> docs/readme.md
    git add docs/readme.md
    git commit -q -m "docs: update registry"
  )
  echo "$pdir"
}

# Build a sibling target repo whose feature branch DOES touch an arch path.
make_target_repo_arch() {
  local pdir
  pdir=$(mktemp -d -t agdr-tgt.XXXXXX)
  (
    cd "$pdir" || exit 1
    git init -q -b main
    git config user.email t@t.test
    git config user.name test
    git remote add origin git@github.com:test-org/portfolio.git
    mkdir -p src/domain
    echo "export const x = 1" > src/domain/widget.ts
    git add src/domain/widget.ts
    git commit -q -m "base: domain"
    git checkout -q -b feature
    echo "export const x = 2" > src/domain/widget.ts
    git add src/domain/widget.ts
    git commit -q -m "feat: tweak domain"
  )
  echo "$pdir"
}

# (D) cwd tree has arch changes; cd-target is docs-only → PASS (no false-block).
#     Pre-fix this BLOCKS because the hook diffs the cwd (fork) tree. [#669]
FORK_DIR=$(setup_repo c1_base c1_feat)
TGT_DOCS=$(make_target_repo_docs)
run_case "cd-target docs-only PR (cwd has arch changes), no --repo → PASS [#669]" \
  "$FORK_DIR" 0 "" \
  "cd $TGT_DOCS && gh pr create --base main --title 'chore(#5): update registry docs' --body 'Docs only. No decisions made.'"
rm -rf "$TGT_DOCS"

# (E) cd-target itself touches an arch path, no AgDR → still BLOCKS.
#     Proves the re-root targets the right tree rather than just skipping. [#669]
FORK_DIR2=$(setup_repo c6_base c6_feat)
TGT_ARCH=$(make_target_repo_arch)
run_case "cd-target arch PR, no AgDR → still BLOCKS (true-negative) [#669]" \
  "$FORK_DIR2" 2 "no AgDR reference" \
  "cd $TGT_ARCH && gh pr create --base main --title 'feat(#6): portfolio domain' --body 'Forgot the decision record.'"
rm -rf "$TGT_ARCH"

# (F) cd-target arch PR WITH an AgDR reference → PASS. [#669]
FORK_DIR3=$(setup_repo c1_base c1_feat)
TGT_ARCH2=$(make_target_repo_arch)
run_case "cd-target arch PR with AgDR ref → PASS [#669]" \
  "$FORK_DIR3" 0 "" \
  "cd $TGT_ARCH2 && gh pr create --base main --title 'feat(#7): portfolio domain' --body 'See AgDR-0009-portfolio-domain for rationale.'"
rm -rf "$TGT_ARCH2"

# ---------------------------------------------------------------------------
# #769 bug 1 — diff-base resolves origin/<base> before upstream/<base>.
# On a fork DIVERGED-behind upstream (its own baseline arch customisations that
# upstream lacks), diffing against upstream/<base>'s merge-base attributes the
# fork's OWN baseline files to the PR → false arch-block on a docs-only PR.
# ---------------------------------------------------------------------------
setup_diverged_fork() {
  local dir; dir=$(mktemp -d -t agdr-b1.XXXXXX)
  (
    cd "$dir" || exit 1
    git init -q -b main
    git config user.email t@t.test; git config user.name test
    echo "company: test" > onboarding.yaml
    git add onboarding.yaml; git commit -q -m init
    local p; p=$(git rev-parse HEAD)
    # Fork baseline: a CI workflow the fork carries but upstream does not.
    mkdir -p .github/workflows; echo "on: push" > .github/workflows/fork-custom.yml
    git add .github/workflows/fork-custom.yml; git commit -q -m "fork: baseline ci"
    git update-ref refs/remotes/origin/main HEAD       # origin/main = fork main
    # upstream/main diverged from p — does NOT have the fork's workflow.
    git checkout -q "$p"
    echo "# upstream" > UPSTREAM.md; git add UPSTREAM.md; git commit -q -m "upstream: unrelated"
    git update-ref refs/remotes/upstream/main HEAD
    # Feature branch off the fork's main: docs only.
    git checkout -q main; git checkout -q -b feature
    mkdir -p docs; echo "# new" > docs/new.md
    git add docs/new.md; git commit -q -m "docs: add"
  )
  echo "$dir"
}

B1_DIR=$(setup_diverged_fork)
run_case "docs-only PR on a fork diverged-behind upstream → PASS (diffs origin/main, not upstream/main) [#769 bug1]" \
  "$B1_DIR" 0 "" \
  "gh pr create --base main --title 'docs(#9): update guide' --body 'Docs only. No decisions.'"

# ---------------------------------------------------------------------------
# #769 bug 2 — the skip marker (and any AgDR ref) inside a heredoc --body with
# a trailing pipe is honoured. The --body extractor cannot recover a value that
# spans newlines or is followed by a shell operator; the raw command is now part
# of the haystack, so the marker is seen regardless of --body quoting shape.
# ---------------------------------------------------------------------------
B2_DIR=$(setup_repo c1_base c1_feat)   # feature touches src/domain/ (arch), no AgDR
B2_CMD=$'gh pr create --base main --title "feat(#10): domain" --body "$(cat <<\'EOF\'\nSome body text.\n<!-- agdr: not-applicable -->\nEOF\n)" 2>&1 | tail -3'
run_case "arch PR, skip-marker in a heredoc --body with trailing pipe → PASS (bypassed) [#769 bug2]" \
  "$B2_DIR" 0 "not-applicable marker present" \
  "$B2_CMD"

# And the AgDR-reference path through the same heredoc+pipe shape → PASS.
B2b_DIR=$(setup_repo c1_base c1_feat)
B2b_CMD=$'gh pr create --base main --title "feat(#11): domain" --body "$(cat <<\'EOF\'\nSee AgDR-0009-portfolio-domain for the rationale.\nEOF\n)" 2>&1 | tail -3'
run_case "arch PR, AgDR ref in a heredoc --body with trailing pipe → PASS [#769 bug2]" \
  "$B2b_DIR" 0 "" \
  "$B2b_CMD"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
