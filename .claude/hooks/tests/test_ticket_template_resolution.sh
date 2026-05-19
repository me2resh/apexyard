#!/bin/bash
# Smoke tests for the uniform ticket-template resolution introduced by #281.
#
# For each of the 7 ticket types (feature, bug, task, migration, idea,
# spike, investigation):
#
#   1. With no adopter override and the framework's templates/tickets/<name>.md
#      in place, the resolver returns the framework default path.
#   2. With an adopter override at <private_repo>/custom-templates/tickets/<name>.md,
#      the resolver picks the override.
#   3. When the framework template is missing AND no override exists, the
#      resolver returns empty + nonzero exit (which the SKILL.md treats as
#      its heredoc-fallback signal). A WARN-on-stderr fallback test verifies
#      a small wrapper that emulates how the consuming skill should react.
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

# All 7 ticket types — every one of these gets the same resolution contract.
TICKET_TYPES="feature bug task migration idea spike investigation"

# ---------------------------------------------------------------------------
# make_fork: build an isolated apexyard fork sandbox with the hook lib +
# shared config lib + defaults file + minimal registry + the 7 framework
# ticket templates seeded under templates/tickets/.
#
# Returns the sandbox path on stdout.
# ---------------------------------------------------------------------------
make_fork() {
  local sb
  sb=$(mktemp -d)
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

    # Seed the 7 framework ticket templates so the default-resolution path
    # has something to find.
    mkdir -p templates/tickets
    for t in feature bug task migration idea spike investigation; do
      cat > "templates/tickets/$t.md" <<MD
# Framework template — $t
MD
    done

    git add -A
    git commit -q -m "test fixture"
  )
  echo "$sb"
}

# ---------------------------------------------------------------------------
# run_case <name> <sandbox> <bash-snippet>: source the libs in a fresh
# subshell rooted at <sandbox> and run the snippet.
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
# Case set 1: defaults resolve to templates/tickets/<name>.md for every
# ticket type (no adopter override).
# ---------------------------------------------------------------------------
SB=$(make_fork)
for t in $TICKET_TYPES; do
  run_case "default: tickets/$t.md resolves to framework template" "$SB" "
r=\$(portfolio_resolve_template tickets/$t.md)
expected='$SB/templates/tickets/$t.md'
if [ \"\$r\" = \"\$expected\" ]; then exit 0; else echo \"got=\$r expected=\$expected\"; exit 1; fi
"
done
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case set 2: adopter override under <fork>/custom-templates/tickets/<name>.md
# wins over the framework default (single-fork mode — overrides live in the
# fork because the registry's parent dir IS the fork root).
# ---------------------------------------------------------------------------
SB=$(make_fork)
mkdir -p "$SB/custom-templates/tickets"
for t in $TICKET_TYPES; do
  cat > "$SB/custom-templates/tickets/$t.md" <<MD
# Adopter override — $t
MD
done
for t in $TICKET_TYPES; do
  run_case "override: custom-templates/tickets/$t.md wins over framework default" "$SB" "
r=\$(portfolio_resolve_template tickets/$t.md)
expected='$SB/custom-templates/tickets/$t.md'
if [ \"\$r\" = \"\$expected\" ]; then exit 0; else echo \"got=\$r expected=\$expected\"; exit 1; fi
"
done
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case set 3: split-portfolio v2 — overrides in the sibling private repo
# win over the in-fork framework template.
# ---------------------------------------------------------------------------
SB=$(make_fork)
SIB=$(mktemp -d)
SIB=$(cd "$SIB" && pwd -P)
mkdir -p "$SIB/proj" "$SIB/custom-templates/tickets"
cat > "$SIB/apex.yaml" <<'YAML'
version: 1
projects: []
YAML
for t in $TICKET_TYPES; do
  cat > "$SIB/custom-templates/tickets/$t.md" <<MD
# Sibling-private override — $t
MD
done
cat > "$SB/.claude/project-config.json" <<JSON
{
  "portfolio": {
    "registry": "$SIB/apex.yaml",
    "projects_dir": "$SIB/proj"
  }
}
JSON
for t in $TICKET_TYPES; do
  run_case "split-portfolio: sibling custom-templates/tickets/$t.md wins" "$SB" "
r=\$(portfolio_resolve_template tickets/$t.md)
expected='$SIB/custom-templates/tickets/$t.md'
if [ \"\$r\" = \"\$expected\" ]; then exit 0; else echo \"got=\$r expected=\$expected\"; exit 1; fi
"
done
rm -rf "$SB" "$SIB"

# ---------------------------------------------------------------------------
# Case set 4: missing framework template AND no override → resolver returns
# empty + nonzero exit. The consuming SKILL.md interprets that as the
# "fall back to heredoc + print WARN on stderr" path. A small bash wrapper
# in this test emulates that fallback to confirm the shape works end-to-end.
# ---------------------------------------------------------------------------
SB=$(make_fork)
# Remove the templates/tickets/ dir entirely — neither framework default
# nor adopter override exists for any of the 7 types.
rm -rf "$SB/templates/tickets"

# Wrapper that emulates how a SKILL.md should react to the empty-resolution.
# It prints WARN to stderr and exits 0 with the literal "FALLBACK" on stdout.
WRAPPER='
emit_body_or_fallback() {
  local rel="$1"
  local resolved
  resolved=$(portfolio_resolve_template "$rel")
  if [ -z "$resolved" ]; then
    echo "WARN: $rel template missing — using inline fallback" >&2
    echo "FALLBACK"
    return 0
  fi
  cat "$resolved"
}
'

for t in $TICKET_TYPES; do
  run_case "fallback: tickets/$t.md missing → resolver empty + nonzero" "$SB" "
r=\$(portfolio_resolve_template tickets/$t.md)
rc=\$?
if [ -z \"\$r\" ] && [ \"\$rc\" -ne 0 ]; then exit 0; else echo \"got=\$r rc=\$rc\"; exit 1; fi
"

  run_case "fallback: SKILL.md heredoc path prints WARN on stderr for tickets/$t.md" "$SB" "
$WRAPPER
out=\$(emit_body_or_fallback tickets/$t.md 2>/tmp/ticket_template_test_stderr.\$\$)
stderr=\$(cat /tmp/ticket_template_test_stderr.\$\$)
rm -f /tmp/ticket_template_test_stderr.\$\$
case \"\$out\" in
  FALLBACK)
    case \"\$stderr\" in
      *\"WARN:\"*\"tickets/$t.md\"*\"inline fallback\"*) exit 0 ;;
      *) echo \"missing WARN; stderr=\$stderr\"; exit 1 ;;
    esac
    ;;
  *) echo \"expected FALLBACK; got out=\$out\"; exit 1 ;;
esac
"
done
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case set 5: mixed state — one ticket type has a custom override, the
# others fall through. Ensures the resolution is per-template, not
# all-or-nothing.
# ---------------------------------------------------------------------------
SB=$(make_fork)
mkdir -p "$SB/custom-templates/tickets"
cat > "$SB/custom-templates/tickets/feature.md" <<'MD'
# Adopter override — feature only
MD
run_case "mixed: feature override wins; bug falls through to framework default" "$SB" "
r1=\$(portfolio_resolve_template tickets/feature.md)
expected1='$SB/custom-templates/tickets/feature.md'
r2=\$(portfolio_resolve_template tickets/bug.md)
expected2='$SB/templates/tickets/bug.md'
if [ \"\$r1\" = \"\$expected1\" ] && [ \"\$r2\" = \"\$expected2\" ]; then
  exit 0
else
  echo \"feature got=\$r1 want=\$expected1; bug got=\$r2 want=\$expected2\"
  exit 1
fi
"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "===== test_ticket_template_resolution.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0
