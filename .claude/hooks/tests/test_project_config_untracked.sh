#!/bin/bash
# Regression test for me2resh/apexyard#1031 — `.claude/project-config.json` is
# listed in `.gitignore` but is also tracked in the index, and git ignores
# `.gitignore` entirely for already-tracked files. The ignore rule is therefore
# inert for every adopter fork.
#
# WHY THIS IS NOT MERELY COSMETIC
# -------------------------------
# The issue was originally filed as "permanent drift in git status". The real
# consequence is silent, unrecoverable loss of fork-local config:
#
#   - The file holds an adopter's private `portfolio` block. That block is
#     load-bearing — path resolution is config-only, there is no
#     convention-based sibling discovery, and `.apexyard-fork` is
#     presence-only.
#   - Because the file is TRACKED, a plain `git checkout <branch>` (or a
#     reset) writes the indexed version straight over the working copy.
#     Git does not warn: it is checking out a tracked file as instructed.
#   - The destroyed content was never in git — correctly, it is private — so
#     there is nothing to restore from.
#
# WHAT IS ASSERTED, AND WHICH CASES ARE DISCRIMINATING
# ----------------------------------------------------
# Cases 1 and 3 FAIL against the unfixed tree and pass after — they are the
# discriminating pair that proves the fix does something.
#
# Case 2 (the ignore rule matches) and case 4 (framework-specific pre_push
# must not leak into the shipped defaults) both pass before AND after. They
# are stated honestly as REGRESSION GUARDS, not as proof of the fix. Case 4
# in particular guards the trap found while fixing this: `_lib-read-config.sh`
# merges with `jq -s '.[0] * .[1]'`, so an adopter who defines no `pre_push`
# of their own inherits whatever is in the defaults file. Moving the
# framework's own dog-fooding commands there would silently make every
# adopter run apexyard's `test_subpack_extraction.sh` on push. The framework's
# copy belongs in `project-config.example.json`, mirroring the
# `onboarding.example.yaml` precedent this issue identifies as correct.
#
# Exit 0 if all cases pass; exit 1 on first failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

PASS=0
FAIL=0
FAILED_CASES=""

ok()   { PASS=$((PASS+1)); echo "PASS [$1]"; }
bad()  { FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}\n  - $1: $2"; echo "FAIL [$1] $2"; }

cd "$REPO_ROOT" || { echo "cannot cd to repo root"; exit 1; }

# Only meaningful inside a git work tree. Skip cleanly elsewhere (e.g. a
# tarball export) rather than reporting a false failure.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "SKIP: not inside a git work tree — repo-hygiene assertions do not apply."
  exit 0
fi

# --- Case 1 (DISCRIMINATING): the real config file must NOT be tracked ------
if git ls-files --error-unmatch .claude/project-config.json >/dev/null 2>&1; then
  bad "config-untracked" \
    ".claude/project-config.json is still in the git index; its .gitignore entry is inert and a branch switch will overwrite adopter-local config"
else
  ok "config-untracked"
fi

# --- Case 2 (REGRESSION GUARD): .gitignore must still list it ---------------
# Passes before and after the fix; it exists so a future cleanup does not
# remove the ignore entry once the file is untracked and the drift disappears.
if grep -qxF '.claude/project-config.json' .gitignore 2>/dev/null; then
  ok "gitignore-entry-present"
else
  bad "gitignore-entry-present" \
    ".gitignore no longer lists .claude/project-config.json — untracking alone will not stop it being re-added"
fi

# --- Case 3 (DISCRIMINATING): a tracked example template must exist ---------
EXAMPLE=".claude/project-config.example.json"
if ! git ls-files --error-unmatch "$EXAMPLE" >/dev/null 2>&1; then
  bad "example-tracked" \
    "$EXAMPLE is not tracked — adopters and framework contributors have no template to copy, mirroring onboarding.example.yaml"
elif ! command -v jq >/dev/null 2>&1; then
  echo "SKIP [example-valid-json]: jq not installed"
  ok "example-tracked"
elif ! jq -e . "$EXAMPLE" >/dev/null 2>&1; then
  bad "example-tracked" "$EXAMPLE is tracked but is not valid JSON"
else
  ok "example-tracked"
fi

# --- Case 4 (REGRESSION GUARD): defaults must not carry framework commands --
# See the header. This protects adopters from inheriting apexyard's own
# repo-specific pre-push commands through the defaults merge.
DEFAULTS=".claude/project-config.defaults.json"
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP [defaults-pre-push-empty]: jq not installed"
elif [ ! -f "$DEFAULTS" ]; then
  bad "defaults-pre-push-empty" "$DEFAULTS is missing"
else
  n=$(jq -r '(.pre_push.commands // []) | length' "$DEFAULTS" 2>/dev/null)
  if [ "$n" = "0" ]; then
    ok "defaults-pre-push-empty"
  else
    bad "defaults-pre-push-empty" \
      "$DEFAULTS ships $n pre_push command(s); adopters without their own pre_push would inherit them via the 'jq -s .[0] * .[1]' merge"
  fi
fi

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  # shellcheck disable=SC2059
  printf "failed cases:$FAILED_CASES\n"
  exit 1
fi
exit 0
