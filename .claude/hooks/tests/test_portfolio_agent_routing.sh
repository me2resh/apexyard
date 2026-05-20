#!/bin/bash
# Smoke tests for portfolio_agent_routing in
# .claude/hooks/_lib-portfolio-paths.sh + the schema validity of the
# shipped agent-routing.yaml.example.
#
# Coverage (per ticket #351, AgDR-0050 Axis 3):
#   1. Default (no config, no file) resolves to ./agent-routing.yaml
#      at the fork root — empty/non-existent file is tolerated by the
#      resolver (unlike the registry, which must exist).
#   2. Single-fork mode: a fork-root agent-routing.yaml resolves to
#      the absolute fork-root path.
#   3. Split-portfolio v2 mode: explicit override pointing at the
#      sibling private repo's agent-routing.yaml resolves correctly.
#   4. Relative override resolves against the fork root.
#   5. portfolio_clear_cache resets the cached value.
#   6. The shipped agent-routing.yaml.example parses as valid YAML
#      (when yq is available; minimal grep check otherwise).
#
# Each case builds an isolated sandbox apexyard fork under $TMPDIR and
# sources the helper + asserts behaviour.
#
# Exit 0 means all cases passed. Exit 1 on first failure.

set -u

LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-portfolio-paths.sh"
CONFIG_LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-read-config.sh"
DEFAULTS_SRC="$(cd "$(dirname "$0")/../.." && pwd)/project-config.defaults.json"
EXAMPLE_SRC="$(cd "$(dirname "$0")/../../.." && pwd)/agent-routing.yaml.example"

if [ ! -f "$LIB_SRC" ]; then
  echo "FAIL: helper not found at $LIB_SRC" >&2
  exit 1
fi
if [ ! -f "$CONFIG_LIB_SRC" ]; then
  echo "FAIL: config lib not found at $CONFIG_LIB_SRC" >&2
  exit 1
fi
if [ ! -f "$DEFAULTS_SRC" ]; then
  echo "FAIL: defaults file not found at $DEFAULTS_SRC" >&2
  exit 1
fi
if [ ! -f "$EXAMPLE_SRC" ]; then
  echo "FAIL: example file not found at $EXAMPLE_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# make_fork: build an isolated apexyard fork sandbox with the hook lib +
# shared config lib + defaults file + minimal registry / projects_dir.
# Returns the sandbox path on stdout.
# ---------------------------------------------------------------------------
make_fork() {
  local sb
  sb=$(mktemp -d)
  # Canonicalize for macOS — same shape as test_portfolio_paths.sh.
  sb=$(cd "$sb" && pwd -P)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"

    # Required marker files for "this is an apexyard fork"
    touch onboarding.yaml
    cat > apexyard.projects.yaml <<'YAML'
version: 1
projects:
  - name: example
    repo: example/example
YAML

    mkdir -p projects
    cat > projects/ideas-backlog.md <<'MD'
# Ideas Backlog
MD

    mkdir -p .claude/hooks
    cp "$LIB_SRC" .claude/hooks/_lib-portfolio-paths.sh
    cp "$CONFIG_LIB_SRC" .claude/hooks/_lib-read-config.sh
    cp "$DEFAULTS_SRC" .claude/project-config.defaults.json

    git add -A
    git commit -q -m "test fixture"
  )
  echo "$sb"
}

# ---------------------------------------------------------------------------
# run_case <name> <sandbox> <bash-snippet>: source the libs in a fresh
# subshell rooted at <sandbox> and run the snippet. The snippet asserts
# behaviour + exits 0 on pass, non-zero on fail.
# ---------------------------------------------------------------------------
run_case() {
  local name="$1"
  local sb="$2"
  local snippet="$3"
  local out rc

  out=$(
    cd "$sb" || exit 99
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-read-config.sh
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-portfolio-paths.sh
    portfolio_clear_cache
    eval "$snippet"
  )
  rc=$?

  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1))
    green "PASS: $name"
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  - $name"
    red "FAIL: $name"
    if [ -n "$out" ]; then
      echo "  output: $out"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Case 1: default — resolver returns ./agent-routing.yaml at the fork
# root even when the file does NOT exist (caller-tolerant of absence).
# ---------------------------------------------------------------------------
SB=$(make_fork)
run_case "default: agent_routing resolves to fork-rooted absolute path (file absent)" "$SB" '
r=$(portfolio_agent_routing)
expected="'"$SB"'/agent-routing.yaml"
if [ "$r" = "$expected" ]; then
  # Absent is OK for this resolver — verify the path does not exist yet.
  if [ ! -f "$r" ]; then
    exit 0
  else
    echo "expected absent file at $r"
    exit 1
  fi
else
  echo "got=$r expected=$expected"
  exit 1
fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 2: single-fork mode — agent-routing.yaml at fork root.
# Resolver returns the absolute path; the file exists.
# ---------------------------------------------------------------------------
SB=$(make_fork)
cat > "$SB/agent-routing.yaml" <<'YAML'
version: 1
agents: {}
YAML
run_case "single-fork: agent-routing.yaml at fork root resolves + exists" "$SB" '
r=$(portfolio_agent_routing)
expected="'"$SB"'/agent-routing.yaml"
if [ "$r" = "$expected" ] && [ -f "$r" ]; then
  exit 0
else
  echo "got=$r expected=$expected exists=$([ -f "$r" ] && echo y || echo n)"
  exit 1
fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 3: split-portfolio v2 — explicit override in project-config.json
# points at the sibling private repo's agent-routing.yaml.
# ---------------------------------------------------------------------------
SB=$(make_fork)
SIB=$(mktemp -d)
SIB=$(cd "$SIB" && pwd -P)
cat > "$SIB/agent-routing.yaml" <<'YAML'
version: 1
agents:
  qa-engineer:
    model: sonnet
YAML
cat > "$SB/.claude/project-config.json" <<JSON
{
  "portfolio": {
    "agent_routing": "$SIB/agent-routing.yaml"
  }
}
JSON
run_case "split-portfolio v2: agent_routing override → sibling repo path" "$SB" '
r=$(portfolio_agent_routing)
expected="'"$SIB"'/agent-routing.yaml"
if [ "$r" = "$expected" ] && [ -f "$r" ]; then
  exit 0
else
  echo "got=$r expected=$expected exists=$([ -f "$r" ] && echo y || echo n)"
  exit 1
fi
'
rm -rf "$SB" "$SIB"

# ---------------------------------------------------------------------------
# Case 4: relative override resolves against fork root (same shape as the
# other portfolio resolvers — see test_portfolio_paths.sh Case 3).
# ---------------------------------------------------------------------------
SB=$(make_fork)
mkdir -p "$SB/config"
cat > "$SB/config/agent-routing.yaml" <<'YAML'
version: 1
agents: {}
YAML
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "portfolio": {
    "agent_routing": "./config/agent-routing.yaml"
  }
}
JSON
run_case "relative-override: agent_routing resolves against fork root" "$SB" '
r=$(portfolio_agent_routing)
expected="'"$SB"'/config/agent-routing.yaml"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 5: portfolio_clear_cache resets the agent_routing cache.
# Same shape as the existing clear_cache case in test_portfolio_paths.sh.
# ---------------------------------------------------------------------------
SB=$(make_fork)
run_case "cache: clear_cache resets agent_routing resolver state" "$SB" '
inner=$(
  source .claude/hooks/_lib-read-config.sh
  source .claude/hooks/_lib-portfolio-paths.sh
  portfolio_clear_cache
  portfolio_agent_routing >/dev/null   # populates cache
  cat > .claude/project-config.json <<JSON
{"portfolio": {"agent_routing": "/elsewhere/agent-routing.yaml"}}
JSON
  portfolio_clear_cache
  _CONFIG_CACHE=""
  portfolio_agent_routing
)
case "$inner" in
  "/elsewhere/agent-routing.yaml") exit 0 ;;
esac
echo "expected /elsewhere/agent-routing.yaml after clear_cache; got: $inner"
exit 1
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 6: the shipped agent-routing.yaml.example parses as valid YAML
# (and is on disk). With yq available we run a full parse; without yq we
# fall back to a minimal grep check for the required top-level keys.
# ---------------------------------------------------------------------------
if command -v yq >/dev/null 2>&1; then
  if yq eval '.' "$EXAMPLE_SRC" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    green "PASS: agent-routing.yaml.example parses as valid YAML (yq)"
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  - agent-routing.yaml.example parses as valid YAML (yq)"
    red "FAIL: agent-routing.yaml.example does not parse as valid YAML"
  fi
  # Confirm the documented top-level keys are present.
  has_version=$(yq eval 'has("version")' "$EXAMPLE_SRC" 2>/dev/null)
  has_agents=$(yq eval 'has("agents")'  "$EXAMPLE_SRC" 2>/dev/null)
  if [ "$has_version" = "true" ] && [ "$has_agents" = "true" ]; then
    PASS=$((PASS + 1))
    green "PASS: agent-routing.yaml.example has 'version' and 'agents' top-level keys"
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  - agent-routing.yaml.example missing top-level keys"
    red "FAIL: agent-routing.yaml.example missing top-level keys (version=$has_version agents=$has_agents)"
  fi
else
  if grep -q '^version:' "$EXAMPLE_SRC" && grep -q '^agents:' "$EXAMPLE_SRC"; then
    PASS=$((PASS + 1))
    green "PASS: agent-routing.yaml.example has 'version:' and 'agents:' (grep fallback; yq not installed)"
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  - agent-routing.yaml.example schema check (grep)"
    red "FAIL: agent-routing.yaml.example missing 'version:' or 'agents:' top-level key"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "===== test_portfolio_agent_routing.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0
