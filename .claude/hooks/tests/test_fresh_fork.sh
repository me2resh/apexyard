#!/bin/bash
# Smoke tests for .claude/hooks/_lib-fresh-fork.sh
#
# Covers the three fresh_fork_state() outcomes (fresh / configured /
# not-a-fork) plus split-portfolio v2 path resolution, per
# docs/technical-designs/onboarding-increment-1.md § D2 and AgDR-0098.
#
# Each case builds an isolated sandbox apexyard fork under a tmp dir,
# sources the lib, and asserts fresh_fork_state()'s stdout.
#
# Exit 0 means all cases passed. Exit 1 on first failure.

set -u

LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-fresh-fork.sh"
PORTFOLIO_LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-portfolio-paths.sh"
CONFIG_LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-read-config.sh"
DEFAULTS_SRC="$(cd "$(dirname "$0")/../.." && pwd)/project-config.defaults.json"
HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/onboarding-check.sh"

for f in "$LIB_SRC" "$PORTFOLIO_LIB_SRC" "$CONFIG_LIB_SRC" "$DEFAULTS_SRC" "$HOOK_SRC"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file not found at $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

# ---------------------------------------------------------------------------
# make_fork: build an isolated apexyard fork sandbox with the fresh-fork lib
# + its dependencies. Returns the sandbox path on stdout. By default the
# sandbox has NEITHER onboarding.yaml NOR onboarding.example.yaml — callers
# add whichever fixture files their case needs.
# ---------------------------------------------------------------------------
make_fork() {
  local sb
  sb=$(mktemp -d)
  # Canonicalize for macOS (mktemp returns /var/..., real path is /private/var/...).
  sb=$(cd "$sb" && pwd -P)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"

    mkdir -p .claude/hooks
    cp "$LIB_SRC" .claude/hooks/_lib-fresh-fork.sh
    cp "$PORTFOLIO_LIB_SRC" .claude/hooks/_lib-portfolio-paths.sh
    cp "$CONFIG_LIB_SRC" .claude/hooks/_lib-read-config.sh
    cp "$DEFAULTS_SRC" .claude/project-config.defaults.json
    cp "$HOOK_SRC" .claude/hooks/onboarding-check.sh
    chmod +x .claude/hooks/onboarding-check.sh

    git add -A
    git commit -q -m "test fixture" >/dev/null
  )
  echo "$sb"
}

# ---------------------------------------------------------------------------
# run_case <name> <sandbox> <snippet>: source the lib in a fresh subshell
# rooted at <sandbox> and run the snippet. The snippet asserts behavior +
# exits 0 on pass, non-zero on fail.
# ---------------------------------------------------------------------------
run_case() {
  local name="$1"
  local sb="$2"
  local snippet="$3"
  local out rc

  out=$(
    cd "$sb" || exit 99
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-fresh-fork.sh
    eval "$snippet"
  )
  rc=$?

  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "PASS: $name"
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  - $name"
    echo "FAIL: $name"
    if [ -n "$out" ]; then
      echo "  output: $out"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Case 1: no onboarding.yaml, no example → not-a-fork
# ---------------------------------------------------------------------------
SB=$(make_fork)
run_case "not-a-fork: neither onboarding.yaml nor example present" "$SB" '
r=$(fresh_fork_state)
if [ "$r" = "not-a-fork" ]; then exit 0; else echo "got=$r expected=not-a-fork"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 2: no onboarding.yaml, example present → fresh
# ---------------------------------------------------------------------------
SB=$(make_fork)
cat > "$SB/onboarding.example.yaml" <<'YAML'
company:
  name: "Your Company Name"
YAML
run_case "fresh: no onboarding.yaml, example present" "$SB" '
r=$(fresh_fork_state)
if [ "$r" = "fresh" ]; then exit 0; else echo "got=$r expected=fresh"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 3: onboarding.yaml present with placeholder company.name → fresh
# ---------------------------------------------------------------------------
SB=$(make_fork)
cat > "$SB/onboarding.yaml" <<'YAML'
company:
  name: "Your Company Name"
YAML
run_case "fresh: onboarding.yaml present but placeholder company.name" "$SB" '
r=$(fresh_fork_state)
if [ "$r" = "fresh" ]; then exit 0; else echo "got=$r expected=fresh"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 4: onboarding.yaml present with a real company.name → configured
# ---------------------------------------------------------------------------
SB=$(make_fork)
cat > "$SB/onboarding.yaml" <<'YAML'
company:
  name: "Acme Corp"
YAML
run_case "configured: onboarding.yaml present with a real company.name" "$SB" '
r=$(fresh_fork_state)
if [ "$r" = "configured" ]; then exit 0; else echo "got=$r expected=configured"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 5 (split-portfolio v2): onboarding.yaml lives in a sibling repo,
# resolved via the portfolio.onboarding override — configured.
# ---------------------------------------------------------------------------
SB=$(make_fork)
SIB=$(mktemp -d)
SIB=$(cd "$SIB" && pwd -P)
cat > "$SIB/onboarding.yaml" <<'YAML'
company:
  name: "Sibling Co"
YAML
cat > "$SB/.claude/project-config.json" <<JSON
{
  "portfolio": {
    "onboarding": "$SIB/onboarding.yaml"
  }
}
JSON
run_case "v2: sibling-repo onboarding.yaml with real company.name → configured" "$SB" '
r=$(fresh_fork_state)
if [ "$r" = "configured" ]; then exit 0; else echo "got=$r expected=configured"; exit 1; fi
'
rm -rf "$SB" "$SIB"

# ---------------------------------------------------------------------------
# Case 6 (split-portfolio v2): sibling repo onboarding.yaml still carries
# the placeholder → fresh. Confirms the override path, not just the
# in-fork default, participates in the placeholder check.
# ---------------------------------------------------------------------------
SB=$(make_fork)
SIB=$(mktemp -d)
SIB=$(cd "$SIB" && pwd -P)
cat > "$SIB/onboarding.yaml" <<'YAML'
company:
  name: "Your Company Name"
YAML
cat > "$SB/.claude/project-config.json" <<JSON
{
  "portfolio": {
    "onboarding": "$SIB/onboarding.yaml"
  }
}
JSON
run_case "v2: sibling-repo onboarding.yaml with placeholder → fresh" "$SB" '
r=$(fresh_fork_state)
if [ "$r" = "fresh" ]; then exit 0; else echo "got=$r expected=fresh"; exit 1; fi
'
rm -rf "$SB" "$SIB"

# ---------------------------------------------------------------------------
# Case 6b: fresh_fork_config_path() defaults to the in-fork onboarding.yaml
# path (no override configured).
# ---------------------------------------------------------------------------
SB=$(make_fork)
run_case "config-path: defaults to in-fork onboarding.yaml" "$SB" '
r=$(fresh_fork_config_path)
expected="'"$SB"'/onboarding.yaml"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 6c: fresh_fork_config_path() resolves to the sibling repo path when
# split-portfolio v2 overrides portfolio.onboarding. This is the path the
# hook's message-selection logic must check (Rex nit) instead of a
# hardcoded in-fork default.
# ---------------------------------------------------------------------------
SB=$(make_fork)
SIB=$(mktemp -d)
SIB=$(cd "$SIB" && pwd -P)
cat > "$SIB/onboarding.yaml" <<'YAML'
company:
  name: "Your Company Name"
YAML
cat > "$SB/.claude/project-config.json" <<JSON
{
  "portfolio": {
    "onboarding": "$SIB/onboarding.yaml"
  }
}
JSON
run_case "config-path: v2 override resolves to sibling repo path" "$SB" '
r=$(fresh_fork_config_path)
expected="'"$SIB"'/onboarding.yaml"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
rm -rf "$SB" "$SIB"

# ---------------------------------------------------------------------------
# Case 6d (hook-level regression, Rex nit): in split-portfolio v2 with the
# sibling repo's onboarding.yaml still carrying the placeholder,
# onboarding-check.sh must print the "placeholder still present" wording —
# NOT the "no onboarding.yaml" wording. Before the fix, the hook's fresh
# branch checked the hardcoded in-fork path ($REPO_ROOT/onboarding.yaml),
# which doesn't exist in v2 mode, so it always fell into the wrong message.
# ---------------------------------------------------------------------------
SB=$(make_fork)
SIB=$(mktemp -d)
SIB=$(cd "$SIB" && pwd -P)
cat > "$SIB/onboarding.yaml" <<'YAML'
company:
  name: "Your Company Name"
YAML
cat > "$SB/.claude/project-config.json" <<JSON
{
  "portfolio": {
    "onboarding": "$SIB/onboarding.yaml"
  }
}
JSON
run_case "hook (v2): sibling placeholder → \"placeholder still present\" wording" "$SB" '
out=$(bash .claude/hooks/onboarding-check.sh 2>&1)
case "$out" in
  *"placeholder still present"*) exit 0 ;;
esac
echo "got: $out"
exit 1
'
run_case "hook (v2): sibling placeholder → does NOT say \"no onboarding.yaml\"" "$SB" '
out=$(bash .claude/hooks/onboarding-check.sh 2>&1)
case "$out" in
  *"no onboarding.yaml"*) echo "got: $out"; exit 1 ;;
esac
exit 0
'
rm -rf "$SB" "$SIB"

# ---------------------------------------------------------------------------
# Case 6e (hook-level regression guard): single-fork mode with no
# onboarding.yaml at all still prints the "no onboarding.yaml" wording
# (confirms the fix didn't flip the single-fork case).
# ---------------------------------------------------------------------------
SB=$(make_fork)
cat > "$SB/onboarding.example.yaml" <<'YAML'
company:
  name: "Your Company Name"
YAML
run_case "hook (v1): no onboarding.yaml → \"no onboarding.yaml\" wording" "$SB" '
out=$(bash .claude/hooks/onboarding-check.sh 2>&1)
case "$out" in
  *"no onboarding.yaml"*) exit 0 ;;
esac
echo "got: $out"
exit 1
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 7: not inside any git repo at all → not-a-fork
# ---------------------------------------------------------------------------
NOGIT=$(mktemp -d)
NOGIT=$(cd "$NOGIT" && pwd -P)
mkdir -p "$NOGIT/.claude/hooks"
cp "$LIB_SRC" "$NOGIT/.claude/hooks/_lib-fresh-fork.sh"
cp "$PORTFOLIO_LIB_SRC" "$NOGIT/.claude/hooks/_lib-portfolio-paths.sh"
cp "$CONFIG_LIB_SRC" "$NOGIT/.claude/hooks/_lib-read-config.sh"
cp "$DEFAULTS_SRC" "$NOGIT/.claude/project-config.defaults.json"
run_case "not-a-fork: outside any git repo" "$NOGIT" '
r=$(fresh_fork_state)
if [ "$r" = "not-a-fork" ]; then exit 0; else echo "got=$r expected=not-a-fork"; exit 1; fi
'
rm -rf "$NOGIT"

# ---------------------------------------------------------------------------
# Case 8: read-only contract — calling fresh_fork_state() never writes
# anything to the sandbox (no new files, no modified files).
# ---------------------------------------------------------------------------
SB=$(make_fork)
cat > "$SB/onboarding.example.yaml" <<'YAML'
company:
  name: "Your Company Name"
YAML
BEFORE=$(cd "$SB" && find . -type f | sort)
(
  cd "$SB" || exit 1
  # shellcheck source=/dev/null
  . .claude/hooks/_lib-fresh-fork.sh
  fresh_fork_state >/dev/null
)
AFTER=$(cd "$SB" && find . -type f | sort)
if [ "$BEFORE" = "$AFTER" ]; then
  PASS=$((PASS + 1))
  echo "PASS: read-only: fresh_fork_state() writes nothing"
else
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  - read-only: fresh_fork_state() writes nothing"
  echo "FAIL: read-only: fresh_fork_state() writes nothing"
  diff <(echo "$BEFORE") <(echo "$AFTER")
fi
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "===== test_fresh_fork.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0
