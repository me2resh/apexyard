#!/bin/bash
# Tests for .claude/hooks/maintain-docs-index.sh (me2resh/apexyard#753).
#
# The hook is a PostToolUse advisory hook (Write/Edit/MultiEdit): when enabled,
# it (re)generates a per-project docs/INDEX.md and nudges when a doc lands
# outside docs/. It must NEVER block (exit 0 always) and must be a silent no-op
# when disabled (the default).
#
# Sandbox style mirrors test_tracker_create.sh: a temp fork root (.apexyard-fork
# + onboarding.yaml + registry), the libs + the hook copied in, a project-config
# defaults file, git initialised so date lookups have history. The hook is run
# from its sandbox copy with cwd = sandbox so config + portfolio paths resolve
# inside the sandbox.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/maintain-docs-index.sh"
CONFIG_LIB="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
PORTFOLIO_LIB="$SRC_ROOT/.claude/hooks/_lib-portfolio-paths.sh"
OPSROOT_LIB="$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"

if [ ! -f "$HOOK_SRC" ]; then
  echo "FAIL: hook not found: $HOOK_SRC" >&2
  exit 1
fi

PASS=0; FAIL=0; FAILED=""

assert_eq() { # <label> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1));
  else echo "FAIL [$1]: want [$2] got [$3]" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}$1 "; fi
}
assert_contains() { # <label> <haystack> <needle>
  if printf '%s' "$2" | grep -qF -- "$3"; then PASS=$((PASS+1));
  else echo "FAIL [$1]: [$2] does not contain [$3]" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}$1 "; fi
}
assert_not_exists() { # <label> <path>
  if [ ! -e "$2" ]; then PASS=$((PASS+1));
  else echo "FAIL [$1]: expected NOT to exist: $2" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}$1 "; fi
}
assert_exists() { # <label> <path>
  if [ -e "$2" ]; then PASS=$((PASS+1));
  else echo "FAIL [$1]: expected to exist: $2" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}$1 "; fi
}

# make_sandbox <enabled:true|false>  → echoes the sandbox path
make_sandbox() {
  local enabled="${1:-false}" sb
  sb=$(mktemp -d); sb=$(cd "$sb" && pwd -P)
  mkdir -p "$sb/.claude/hooks"
  touch "$sb/.apexyard-fork" "$sb/onboarding.yaml"
  printf 'version: 1\nprojects: []\n' > "$sb/apexyard.projects.yaml"
  cp "$HOOK_SRC"      "$sb/.claude/hooks/maintain-docs-index.sh"
  cp "$CONFIG_LIB"    "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$PORTFOLIO_LIB" "$sb/.claude/hooks/_lib-portfolio-paths.sh"
  [ -f "$OPSROOT_LIB" ] && cp "$OPSROOT_LIB" "$sb/.claude/hooks/_lib-ops-root.sh"
  cat > "$sb/.claude/project-config.defaults.json" <<JSON
{ "docs_index": { "enabled": ${enabled}, "index_filename": "INDEX.md" } }
JSON
  ( cd "$sb" && git init -q && git config user.email t@t.t && git config user.name t \
      && git commit -q --allow-empty -m init ) 2>/dev/null
  echo "$sb"
}

# run_hook <sandbox> <abs_file_path>  → runs the hook, sets RC + STDERR globals
#
# The ops-root resolver used by the config lib is pin-aware: it consults the
# session pin ($HOME/.claude/apexyard/ops-root-<session>) BEFORE walking up. When
# these tests run inside a live Claude Code session, CLAUDE_CODE_SESSION_ID is set
# and the pin points at the REAL fork — so config would resolve there, not the
# sandbox. Unset the session id and disable the pin so resolution falls back to
# walk-up and finds the sandbox's .apexyard-fork anchor.
run_hook() {
  local sb="$1" fp="$2" payload
  payload=$(printf '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$fp")
  STDERR=$(cd "$sb" && printf '%s' "$payload" | \
    env -u CLAUDE_CODE_SESSION_ID APEXYARD_OPS_DISABLE_PIN=1 \
    bash "$sb/.claude/hooks/maintain-docs-index.sh" 2>&1 >/dev/null)
  RC=$?
}

# ---------------------------------------------------------------------------
# Case 1 — disabled (default): silent no-op, no INDEX written.
# ---------------------------------------------------------------------------
SB=$(make_sandbox false)
mkdir -p "$SB/projects/alpha/docs"
printf '# Alpha Overview\n' > "$SB/projects/alpha/docs/overview.md"
run_hook "$SB" "$SB/projects/alpha/docs/overview.md"
assert_eq        "disabled → exit 0"            "0" "$RC"
assert_eq        "disabled → silent"            ""  "$STDERR"
assert_not_exists "disabled → no INDEX.md"      "$SB/projects/alpha/docs/INDEX.md"

# ---------------------------------------------------------------------------
# Case 2 — enabled + doc under docs/: INDEX.md generated with header + row.
# ---------------------------------------------------------------------------
SB=$(make_sandbox true)
mkdir -p "$SB/projects/alpha/docs"
printf '# Alpha Overview\n\nbody\n' > "$SB/projects/alpha/docs/overview.md"
( cd "$SB" && git add -A && git commit -q -m "add overview" ) 2>/dev/null
run_hook "$SB" "$SB/projects/alpha/docs/overview.md"
assert_eq       "enabled/docs → exit 0"                 "0" "$RC"
assert_exists   "enabled/docs → INDEX.md created"       "$SB/projects/alpha/docs/INDEX.md"
IDX=$(cat "$SB/projects/alpha/docs/INDEX.md" 2>/dev/null)
assert_contains "INDEX → has header row"                "$IDX" "| Doc | Title | Created | Modified |"
assert_contains "INDEX → lists the doc"                 "$IDX" "overview.md"
assert_contains "INDEX → title from heading"            "$IDX" "Alpha Overview"
assert_contains "INDEX → git created date (YYYY-)"      "$IDX" "$(date +%Y)-"

# ---------------------------------------------------------------------------
# Case 3 — enabled + doc OUTSIDE docs/: nudge on stderr, still exit 0.
# ---------------------------------------------------------------------------
SB=$(make_sandbox true)
mkdir -p "$SB/projects/alpha/gtm"
printf '# GTM Plan\n' > "$SB/projects/alpha/gtm/plan.md"
run_hook "$SB" "$SB/projects/alpha/gtm/plan.md"
assert_eq       "outside-docs → exit 0"        "0" "$RC"
assert_contains "outside-docs → nudge"         "$STDERR" "OUTSIDE docs/"
assert_contains "outside-docs → names project" "$STDERR" "projects/alpha/gtm/plan.md"

# ---------------------------------------------------------------------------
# Case 4 — enabled + file OUTSIDE projects/: silent no-op.
# ---------------------------------------------------------------------------
SB=$(make_sandbox true)
mkdir -p "$SB/docs"
printf '# Framework Doc\n' > "$SB/docs/thing.md"
run_hook "$SB" "$SB/docs/thing.md"
assert_eq        "non-project → exit 0"   "0" "$RC"
assert_eq        "non-project → silent"   ""  "$STDERR"
assert_not_exists "non-project → no INDEX" "$SB/docs/INDEX.md"

# ---------------------------------------------------------------------------
# Case 5 — enabled + non-md/html write under docs/: skipped, no INDEX.
# ---------------------------------------------------------------------------
SB=$(make_sandbox true)
mkdir -p "$SB/projects/alpha/docs"
printf 'data\n' > "$SB/projects/alpha/docs/notes.txt"
run_hook "$SB" "$SB/projects/alpha/docs/notes.txt"
assert_eq         "txt write → exit 0"     "0" "$RC"
assert_not_exists "txt write → no INDEX"   "$SB/projects/alpha/docs/INDEX.md"

# ---------------------------------------------------------------------------
# Case 6 — enabled + grouping: subdir docs grouped separately from root docs.
# ---------------------------------------------------------------------------
SB=$(make_sandbox true)
mkdir -p "$SB/projects/alpha/docs/adr"
printf '# Root Doc\n'  > "$SB/projects/alpha/docs/root.md"
printf '# ADR One\n'   > "$SB/projects/alpha/docs/adr/one.md"
run_hook "$SB" "$SB/projects/alpha/docs/root.md"
IDX=$(cat "$SB/projects/alpha/docs/INDEX.md" 2>/dev/null)
assert_contains "grouping → General group"  "$IDX" "## General"
assert_contains "grouping → adr subgroup"   "$IDX" "## adr"
assert_contains "grouping → nested path"    "$IDX" "adr/one.md"

# ---------------------------------------------------------------------------
# Case 7 — enabled + write IS the index file: no recursion / no crash.
# ---------------------------------------------------------------------------
SB=$(make_sandbox true)
mkdir -p "$SB/projects/alpha/docs"
printf '# existing index\n' > "$SB/projects/alpha/docs/INDEX.md"
run_hook "$SB" "$SB/projects/alpha/docs/INDEX.md"
assert_eq       "index write → exit 0"     "0" "$RC"
# the hook must NOT rewrite/overwrite when the triggering file IS the index
assert_contains "index write → left as-is" "$(cat "$SB/projects/alpha/docs/INDEX.md")" "existing index"

# ---------------------------------------------------------------------------
# Case 8 — path traversal on the write target (me2resh/apexyard#768 review).
# A file_path with `../` immediately after projects/ must NOT let the hook
# write an INDEX.md outside projects/<name>/docs/. Here the traversal target
# is $SB/docs/INDEX.md (one level up, into the framework's own docs/), which
# already exists so the [ -d "$DOCS_DIR" ] guard would otherwise pass.
# ---------------------------------------------------------------------------
SB=$(make_sandbox true)
mkdir -p "$SB/docs" "$SB/projects/alpha/docs"          # $SB/docs = the escape target
printf '# Framework Doc\n' > "$SB/docs/thing.md"
run_hook "$SB" "$SB/projects/../docs/x.md"
assert_eq         "traversal → exit 0"                 "0" "$RC"
assert_not_exists "traversal → no escaped INDEX write" "$SB/docs/INDEX.md"

# ---------------------------------------------------------------------------
# Case 9 — content injection: a hostile doc title (HTML) and a filename with
# markdown-link breakout chars must be escaped in INDEX.md, not emitted raw
# (me2resh/apexyard#768 security review, LOW).
# ---------------------------------------------------------------------------
SB=$(make_sandbox true)
mkdir -p "$SB/projects/alpha/docs"
printf '# <img src=x onerror=alert(1)>\n' > "$SB/projects/alpha/docs/evil].md"
( cd "$SB" && git add -A && git commit -q -m "add evil doc" ) 2>/dev/null
run_hook "$SB" "$SB/projects/alpha/docs/evil].md"
IDX=$(cat "$SB/projects/alpha/docs/INDEX.md" 2>/dev/null)
assert_eq       "injection → exit 0"                 "0" "$RC"
assert_contains "injection → title HTML-escaped"     "$IDX" "&lt;img src=x onerror=alert(1)&gt;"
assert_not_exists_str() { # inline: assert the raw payload is NOT present
  if printf '%s' "$IDX" | grep -qF -- "$1"; then
    echo "FAIL [$2]: raw payload present: $1" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}$2 "
  else PASS=$((PASS+1)); fi
}
assert_not_exists_str "<img src=x onerror=alert(1)>" "injection → no raw <img> in INDEX"
assert_not_exists_str "evil]"                        "injection → filename ] neutralised"
assert_contains "injection → filename ] percent-encoded" "$IDX" "evil%5D.md"

# ---------------------------------------------------------------------------
# Case 10 — content injection via DIRECTORY-derived sinks (me2resh/apexyard#768
# re-review): the group heading (## <subdir>) and the project-name header
# (# Docs Index — <project>) must be HTML-escaped too, not just the table cells.
# An attacker who can name a leaf file can equally name a directory/project.
# ---------------------------------------------------------------------------
SB=$(make_sandbox true)
PROJ='<svg onload=alert(1)>'
SUB='<img src=x onerror=alert(1)>'
mkdir -p "$SB/projects/$PROJ/docs/$SUB"
printf '# Note\n' > "$SB/projects/$PROJ/docs/$SUB/note.md"
( cd "$SB" && git add -A && git commit -q -m "add hostile dirs" ) 2>/dev/null
run_hook "$SB" "$SB/projects/$PROJ/docs/$SUB/note.md"
IDX=$(cat "$SB/projects/$PROJ/docs/INDEX.md" 2>/dev/null)
assert_eq       "dir-injection → exit 0"                  "0" "$RC"
assert_contains "dir-injection → group heading escaped"   "$IDX" "## &lt;img src=x onerror=alert(1)&gt;"
assert_contains "dir-injection → project header escaped"  "$IDX" "# Docs Index — &lt;svg onload=alert(1)&gt;"
if printf '%s' "$IDX" | grep -qF -- "## <img src=x onerror=alert(1)>"; then
  echo "FAIL [dir-injection → no raw group heading]: raw heading present" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}dir-injection-raw-heading "
else PASS=$((PASS+1)); fi

# ---------------------------------------------------------------------------
echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS  FAIL: 0"
  exit 0
else
  echo "PASS: $PASS  FAIL: $FAIL  (failed: $FAILED)"
  exit 1
fi
