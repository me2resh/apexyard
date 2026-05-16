#!/bin/bash
# Smoke tests for .claude/hooks/_lib-portfolio-paths.sh
#
# Each case:
#   - builds an isolated sandbox apexyard fork under $TMPDIR
#   - drops project-config + registry + projects_dir + ideas_backlog
#   - sources the helper + validates resolution / validate behavior
#
# Exit 0 means all cases passed. Exit 1 on first failure.

set -u

LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-portfolio-paths.sh"
CONFIG_LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-read-config.sh"
DEFAULTS_SRC="$(cd "$(dirname "$0")/../.." && pwd)/project-config.defaults.json"

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

PASS=0
FAIL=0
FAILED_CASES=""

# ---------------------------------------------------------------------------
# make_fork: build an isolated apexyard fork sandbox with the hook lib +
# shared config lib + defaults file + minimal registry / projects_dir.
# Returns the sandbox path on stdout.
# ---------------------------------------------------------------------------
make_fork() {
  local sb
  sb=$(mktemp -d)
  # Canonicalize for macOS (mktemp returns /var/..., real path is /private/var/...).
  # `pwd -P` (POSIX physical pwd) follows symlinks; bare `pwd` outputs the logical
  # name, which doesn't match what git/realpath/dirname will produce.
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
# run_case <name> <bash-snippet>: source the libs in a fresh subshell rooted
# at <sandbox> and run the snippet. The snippet asserts behavior + exits
# 0 on pass, non-zero on fail.
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
# Case 1: defaults resolve to absolute paths inside the fork
# ---------------------------------------------------------------------------
SB=$(make_fork)
run_case "defaults: registry resolves to fork-rooted absolute path" "$SB" '
r=$(portfolio_registry)
expected="'"$SB"'/apexyard.projects.yaml"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
run_case "defaults: projects_dir resolves to fork-rooted absolute path" "$SB" '
r=$(portfolio_projects_dir)
expected="'"$SB"'/projects"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
run_case "defaults: ideas_backlog resolves to fork-rooted absolute path" "$SB" '
r=$(portfolio_ideas_backlog)
expected="'"$SB"'/projects/ideas-backlog.md"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
run_case "defaults: validate is OK" "$SB" '
if portfolio_validate >/dev/null 2>&1; then exit 0; else echo "validate failed"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 2: override in project-config.json wins
# ---------------------------------------------------------------------------
SB=$(make_fork)
# Set up sibling portfolio dir
mkdir -p "$SB/../portfolio_test_$$"
cat > "$SB/../portfolio_test_$$/apex.yaml" <<'YAML'
version: 1
projects: []
YAML
mkdir -p "$SB/../portfolio_test_$$/proj"
touch "$SB/../portfolio_test_$$/proj/ideas.md"

# Resolve the actual sibling path (mktemp may use a different real path on macOS).
SIB=$(cd "$SB/../portfolio_test_$$" && pwd)

cat > "$SB/.claude/project-config.json" <<JSON
{
  "portfolio": {
    "registry": "$SIB/apex.yaml",
    "projects_dir": "$SIB/proj",
    "ideas_backlog": "$SIB/proj/ideas.md"
  }
}
JSON

run_case "override: absolute registry path wins" "$SB" '
r=$(portfolio_registry)
expected="'"$SIB"'/apex.yaml"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
run_case "override: validate is OK against sibling-dir paths" "$SB" '
if portfolio_validate >/dev/null 2>&1; then exit 0; else echo "validate failed: $(portfolio_validate)"; exit 1; fi
'
rm -rf "$SB" "$SIB"

# ---------------------------------------------------------------------------
# Case 3: relative override resolves against fork root
# ---------------------------------------------------------------------------
SB=$(make_fork)
mkdir -p "$SB/custom"
cat > "$SB/custom/registry.yaml" <<'YAML'
version: 1
projects: []
YAML
mkdir -p "$SB/custom/projects"
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "portfolio": {
    "registry": "./custom/registry.yaml",
    "projects_dir": "./custom/projects"
  }
}
JSON
run_case "relative-override: registry resolves against fork root" "$SB" '
r=$(portfolio_registry)
expected="'"$SB"'/custom/registry.yaml"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 4: validate detects a missing registry
# ---------------------------------------------------------------------------
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "portfolio": {
    "registry": "./does-not-exist.yaml"
  }
}
JSON
run_case "validate: missing registry → broken with clear message" "$SB" '
out=$(portfolio_validate 2>&1)
rc=$?
case "$out" in
  *"file does not exist"*) [ "$rc" -ne 0 ] && exit 0 ;;
esac
echo "got rc=$rc out=$out"
exit 1
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 5: validate detects a registry without a projects: key
# ---------------------------------------------------------------------------
SB=$(make_fork)
cat > "$SB/apexyard.projects.yaml" <<'YAML'
not_projects:
  - foo
YAML
run_case "validate: registry without 'projects:' key → broken" "$SB" '
out=$(portfolio_validate 2>&1)
rc=$?
case "$out" in
  *"projects:"*) [ "$rc" -ne 0 ] && exit 0 ;;
esac
echo "got rc=$rc out=$out"
exit 1
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 6: validate detects a missing projects_dir
# ---------------------------------------------------------------------------
SB=$(make_fork)
rm -rf "$SB/projects"
run_case "validate: missing projects_dir → broken" "$SB" '
out=$(portfolio_validate 2>&1)
rc=$?
case "$out" in
  *"projects_dir"*"directory does not exist"*) [ "$rc" -ne 0 ] && exit 0 ;;
esac
echo "got rc=$rc out=$out"
exit 1
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 7: ideas_backlog file missing but parent exists → still OK (creatable)
# ---------------------------------------------------------------------------
SB=$(make_fork)
rm -f "$SB/projects/ideas-backlog.md"
run_case "validate: ideas_backlog missing-but-creatable → OK" "$SB" '
if portfolio_validate >/dev/null 2>&1; then exit 0; else echo "validate failed: $(portfolio_validate)"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 8: ideas_backlog parent missing → broken
# ---------------------------------------------------------------------------
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "portfolio": {
    "ideas_backlog": "./nowhere/ideas.md"
  }
}
JSON
run_case "validate: ideas_backlog with missing parent → broken" "$SB" '
out=$(portfolio_validate 2>&1)
rc=$?
case "$out" in
  *"ideas_backlog"*"parent dir"*) [ "$rc" -ne 0 ] && exit 0 ;;
esac
echo "got rc=$rc out=$out"
exit 1
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 9: portfolio_clear_cache resets the cached value
# (Note: cross-`$(...)` caching is impossible in POSIX shell — same caveat
# as _CONFIG_CACHE in _lib-read-config.sh. The cache only helps within a
# single function-body that makes multiple resolver calls without using
# command substitution between them. We verify clear_cache works as a
# spec contract.)
# ---------------------------------------------------------------------------
SB=$(make_fork)
run_case "cache: clear_cache resets resolver state" "$SB" '
# Populate cache, mutate config, clear cache, verify second call sees the new value.
inner=$(
  source .claude/hooks/_lib-read-config.sh
  source .claude/hooks/_lib-portfolio-paths.sh
  portfolio_clear_cache
  portfolio_registry >/dev/null    # populates cache
  cat > .claude/project-config.json <<JSON
{"portfolio": {"registry": "/elsewhere/apex.yaml"}}
JSON
  portfolio_clear_cache
  # Clear _CONFIG_CACHE too, since the underlying jq output is cached there.
  _CONFIG_CACHE=""
  portfolio_registry
)
case "$inner" in
  "/elsewhere/apex.yaml") exit 0 ;;
esac
echo "expected /elsewhere/apex.yaml after clear_cache; got: $inner"
exit 1
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 10 (v2): portfolio_onboarding_path resolves to in-fork default
# ---------------------------------------------------------------------------
SB=$(make_fork)
run_case "v2: portfolio_onboarding_path defaults to in-fork onboarding.yaml" "$SB" '
r=$(portfolio_onboarding_path)
expected="'"$SB"'/onboarding.yaml"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 11 (v2): portfolio_workspace_dir resolves to in-fork default
# ---------------------------------------------------------------------------
SB=$(make_fork)
run_case "v2: portfolio_workspace_dir defaults to in-fork workspace" "$SB" '
r=$(portfolio_workspace_dir)
expected="'"$SB"'/workspace"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 12 (v2): explicit override for onboarding + workspace_dir wins
# (split-portfolio v2 mode — both keys point at sibling private repo)
# ---------------------------------------------------------------------------
SB=$(make_fork)
SIB=$(mktemp -d)
SIB=$(cd "$SIB" && pwd -P)
mkdir -p "$SIB/workspace"
cat > "$SIB/onboarding.yaml" <<'YAML'
company:
  name: "Test Co"
YAML
cat > "$SB/.claude/project-config.json" <<JSON
{
  "portfolio": {
    "onboarding": "$SIB/onboarding.yaml",
    "workspace_dir": "$SIB/workspace"
  }
}
JSON
run_case "v2: portfolio_onboarding_path override → sibling repo path" "$SB" '
r=$(portfolio_onboarding_path)
expected="'"$SIB"'/onboarding.yaml"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
run_case "v2: portfolio_workspace_dir override → sibling repo path" "$SB" '
r=$(portfolio_workspace_dir)
expected="'"$SIB"'/workspace"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
run_case "v2: validate is OK against sibling-dir onboarding + workspace" "$SB" '
if portfolio_validate >/dev/null 2>&1; then exit 0; else echo "validate failed: $(portfolio_validate)"; exit 1; fi
'
rm -rf "$SB" "$SIB"

# ---------------------------------------------------------------------------
# Case 13 (v2): override pointing at non-existent onboarding → broken
# ---------------------------------------------------------------------------
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "portfolio": {
    "onboarding": "/nowhere/onboarding.yaml"
  }
}
JSON
run_case "v2: validate catches missing onboarding override" "$SB" '
out=$(portfolio_validate 2>&1)
rc=$?
case "$out" in
  *"onboarding"*"file does not exist"*) [ "$rc" -ne 0 ] && exit 0 ;;
esac
echo "got rc=$rc out=$out"
exit 1
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 14 (v2): override pointing at non-existent workspace_dir → broken
# ---------------------------------------------------------------------------
SB=$(make_fork)
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "portfolio": {
    "workspace_dir": "/nowhere/workspace"
  }
}
JSON
run_case "v2: validate catches missing workspace_dir override" "$SB" '
out=$(portfolio_validate 2>&1)
rc=$?
case "$out" in
  *"workspace_dir"*"directory does not exist"*) [ "$rc" -ne 0 ] && exit 0 ;;
esac
echo "got rc=$rc out=$out"
exit 1
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 15 (v2): missing in-fork workspace dir is OK (no managed projects yet)
# ---------------------------------------------------------------------------
SB=$(make_fork)
# Default workspace dir is $SB/workspace; don't create it.
run_case "v2: validate tolerates missing in-fork workspace (creatable)" "$SB" '
if portfolio_validate >/dev/null 2>&1; then exit 0; else echo "validate failed: $(portfolio_validate)"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 16 (v2): portfolio_is_v2 detects the .apexyard-fork marker
# ---------------------------------------------------------------------------
SB=$(make_fork)
# Without marker — should be v1.
run_case "v2: portfolio_is_v2 returns false without .apexyard-fork marker" "$SB" '
if portfolio_is_v2; then echo "expected non-zero exit"; exit 1; else exit 0; fi
'
# Add the marker — now v2.
touch "$SB/.apexyard-fork"
run_case "v2: portfolio_is_v2 returns true when .apexyard-fork present" "$SB" '
if portfolio_is_v2; then exit 0; else echo "expected zero exit"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 17 (custom-templates): seed templates/ in the sandbox so the
# framework-default branch has something to find. Then test override
# semantics.
# ---------------------------------------------------------------------------
SB=$(make_fork)
mkdir -p "$SB/templates/architecture"
cat > "$SB/templates/prd.md" <<'MD'
# Framework PRD
MD
cat > "$SB/templates/agdr.md" <<'MD'
# Framework AgDR
MD
cat > "$SB/templates/architecture/c4-context.md" <<'MD'
# Framework C4 Context
MD
run_case "custom-templates: framework default returned when no override" "$SB" '
r=$(portfolio_resolve_template prd.md)
expected="'"$SB"'/templates/prd.md"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
run_case "custom-templates: framework default returned for nested path" "$SB" '
r=$(portfolio_resolve_template architecture/c4-context.md)
expected="'"$SB"'/templates/architecture/c4-context.md"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
run_case "custom-templates: missing both → empty + nonzero exit" "$SB" '
r=$(portfolio_resolve_template does-not-exist.md)
rc=$?
if [ -z "$r" ] && [ "$rc" -ne 0 ]; then exit 0; else echo "got=$r rc=$rc"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 18 (custom-templates): single-fork adopter with custom-templates
# next to the registry — override wins over framework default.
# ---------------------------------------------------------------------------
SB=$(make_fork)
mkdir -p "$SB/templates/architecture"
cat > "$SB/templates/prd.md" <<'MD'
# Framework PRD
MD
cat > "$SB/templates/architecture/c4-context.md" <<'MD'
# Framework C4 Context
MD
mkdir -p "$SB/custom-templates/architecture"
cat > "$SB/custom-templates/prd.md" <<'MD'
# Custom PRD
MD
cat > "$SB/custom-templates/architecture/c4-context.md" <<'MD'
# Custom C4 Context
MD
run_case "custom-templates: custom prd.md wins over framework default" "$SB" '
r=$(portfolio_resolve_template prd.md)
expected="'"$SB"'/custom-templates/prd.md"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
run_case "custom-templates: nested custom override wins over framework default" "$SB" '
r=$(portfolio_resolve_template architecture/c4-context.md)
expected="'"$SB"'/custom-templates/architecture/c4-context.md"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 19 (custom-templates): split-portfolio v2 — custom-templates
# lives in the sibling private repo (next to the registry override).
# ---------------------------------------------------------------------------
SB=$(make_fork)
mkdir -p "$SB/templates"
cat > "$SB/templates/prd.md" <<'MD'
# Framework PRD
MD
SIB=$(mktemp -d)
SIB=$(cd "$SIB" && pwd -P)
cat > "$SIB/apex.yaml" <<'YAML'
version: 1
projects: []
YAML
mkdir -p "$SIB/proj"
mkdir -p "$SIB/custom-templates/architecture"
cat > "$SIB/custom-templates/prd.md" <<'MD'
# Sibling Custom PRD
MD
cat > "$SIB/custom-templates/architecture/c4-context.md" <<'MD'
# Sibling Custom C4 Context
MD
cat > "$SB/.claude/project-config.json" <<JSON
{
  "portfolio": {
    "registry": "$SIB/apex.yaml",
    "projects_dir": "$SIB/proj"
  }
}
JSON
run_case "custom-templates: split-portfolio sibling override wins" "$SB" '
r=$(portfolio_resolve_template prd.md)
expected="'"$SIB"'/custom-templates/prd.md"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
run_case "custom-templates: split-portfolio sibling nested override wins" "$SB" '
r=$(portfolio_resolve_template architecture/c4-context.md)
expected="'"$SIB"'/custom-templates/architecture/c4-context.md"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
run_case "custom-templates: split-portfolio falls through to framework when no override" "$SB" '
# Remove the sibling override for prd.md, leave c4-context.md custom.
rm -f "'"$SIB"'/custom-templates/prd.md"
r=$(portfolio_resolve_template prd.md)
expected="'"$SB"'/templates/prd.md"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
rm -rf "$SB" "$SIB"

# ---------------------------------------------------------------------------
# Case 20 (custom-templates): empty input → nonzero exit
# ---------------------------------------------------------------------------
SB=$(make_fork)
run_case "custom-templates: empty input → nonzero exit" "$SB" '
r=$(portfolio_resolve_template "")
rc=$?
if [ -z "$r" ] && [ "$rc" -ne 0 ]; then exit 0; else echo "got=$r rc=$rc"; exit 1; fi
'
rm -rf "$SB"


# Case 21 (#243): portfolio_custom_skills_dir defaults to in-fork path
# ---------------------------------------------------------------------------
SB=$(make_fork)
run_case "v2/#243: portfolio_custom_skills_dir defaults to in-fork ./custom-skills" "$SB" '
r=$(portfolio_custom_skills_dir)
expected="'"$SB"'/custom-skills"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 22 (#243): portfolio_custom_handbooks_dir defaults to in-fork path
# ---------------------------------------------------------------------------
SB=$(make_fork)
run_case "v2/#243: portfolio_custom_handbooks_dir defaults to in-fork ./custom-handbooks" "$SB" '
r=$(portfolio_custom_handbooks_dir)
expected="'"$SB"'/custom-handbooks"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 23 (#243): explicit overrides for the new keys win (split-portfolio v2 mode)
# ---------------------------------------------------------------------------
SB=$(make_fork)
SIB=$(mktemp -d)
SIB=$(cd "$SIB" && pwd -P)
mkdir -p "$SIB/custom-skills" "$SIB/custom-handbooks"
cat > "$SB/.claude/project-config.json" <<JSON
{
  "portfolio": {
    "custom_skills_dir": "$SIB/custom-skills",
    "custom_handbooks_dir": "$SIB/custom-handbooks"
  }
}
JSON
run_case "v2/#243: portfolio_custom_skills_dir override → sibling repo path" "$SB" '
r=$(portfolio_custom_skills_dir)
expected="'"$SIB"'/custom-skills"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
run_case "v2/#243: portfolio_custom_handbooks_dir override → sibling repo path" "$SB" '
r=$(portfolio_custom_handbooks_dir)
expected="'"$SIB"'/custom-handbooks"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
rm -rf "$SB" "$SIB"

# ---------------------------------------------------------------------------
# Case 24 (#243): relative override resolves against fork root
# ---------------------------------------------------------------------------
SB=$(make_fork)
mkdir -p "$SB/elsewhere-skills" "$SB/elsewhere-hb"
cat > "$SB/.claude/project-config.json" <<'JSON'
{
  "portfolio": {
    "custom_skills_dir": "./elsewhere-skills",
    "custom_handbooks_dir": "./elsewhere-hb"
  }
}
JSON
run_case "v2/#243: relative-override custom_skills_dir resolves against fork root" "$SB" '
r=$(portfolio_custom_skills_dir)
expected="'"$SB"'/elsewhere-skills"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
run_case "v2/#243: relative-override custom_handbooks_dir resolves against fork root" "$SB" '
r=$(portfolio_custom_handbooks_dir)
expected="'"$SB"'/elsewhere-hb"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'
rm -rf "$SB"


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "===== test_portfolio_paths.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0
