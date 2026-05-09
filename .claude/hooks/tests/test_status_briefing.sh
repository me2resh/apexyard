#!/bin/bash
# Tests for .claude/skills/status/briefing.sh — the helper that backs
# /status --briefing and `apexyard status` (me2resh/apexyard#182).
#
# Each case:
#   - builds an isolated sandbox apexyard fork containing onboarding.yaml,
#     a minimal registry, the briefing helper itself, an optional
#     workspace/<name>/, and an optional ticket marker
#   - invokes briefing.sh with APEXYARD_OPS_ROOT, APEXYARD_CWD,
#     APEXYARD_GH overrides so the test never touches the real fork or
#     the real `gh` binary
#   - asserts each output line matches an expected substring
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HELPER_SRC="$SRC_ROOT/.claude/skills/status/briefing.sh"

if [ ! -f "$HELPER_SRC" ]; then
  echo "FAIL: briefing helper not found at $HELPER_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

# ---------------------------------------------------------------------------
# make_fork: build an isolated apexyard fork sandbox.
#   $1 (optional) — name of a workspace directory to create
# Returns the sandbox absolute path on stdout.
# ---------------------------------------------------------------------------
make_fork() {
  local sb workspace_name
  workspace_name="${1:-}"
  sb=$(mktemp -d)
  # Canonicalize so paths match what `pwd -P` / dirname produce on macOS.
  sb=$(cd "$sb" && pwd -P)

  # Marker files for "this is an apexyard fork".
  : > "$sb/onboarding.yaml"
  cat > "$sb/apexyard.projects.yaml" <<YAML
version: 1
projects:
  - name: example
    repo: example/example
YAML

  # Copy the helper into the same relative path the real fork uses, so
  # the shim's "find helper at \$ops_root/.claude/skills/status/briefing.sh"
  # resolution works.
  mkdir -p "$sb/.claude/skills/status" "$sb/.claude/session/tickets"
  cp "$HELPER_SRC" "$sb/.claude/skills/status/briefing.sh"
  chmod +x "$sb/.claude/skills/status/briefing.sh"

  if [ -n "$workspace_name" ]; then
    mkdir -p "$sb/workspace/$workspace_name"
    (
      cd "$sb/workspace/$workspace_name" || exit 1
      git init -q -b "feature/test-branch"
      git config user.email "test@example.com"
      git config user.name "test"
      : > .keep
      git add .keep
      git commit -q -m "init"
    )
  fi

  printf '%s' "$sb"
}

# ---------------------------------------------------------------------------
# write_marker: drop a key=value ticket marker.
#   $1 — sandbox root
#   $2 — marker filename relative to .claude/session/ (e.g.
#        "current-ticket" or "tickets/<workspace>")
#   $3 — repo (e.g. "owner/repo")
#   $4 — number
#   $5 — title
# ---------------------------------------------------------------------------
write_marker() {
  local sb="$1" rel="$2" repo="$3" number="$4" title="$5"
  local path="$sb/.claude/session/$rel"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
repo=$repo
number=$number
title=$title
url=https://github.com/$repo/issues/$number
suggested_branch=feature/test
started_at=2026-05-03T00:00:00Z
EOF
}

# ---------------------------------------------------------------------------
# run_case: execute the helper and assert each expected line is present.
#   $1 — label
#   $2 — sandbox path
#   $3 — APEXYARD_CWD value (relative to sandbox, or absolute)
#   $4 — APEXYARD_GH value (full path; empty disables gh)
#   $5..$N — expected literal substrings (line-fragment match)
# ---------------------------------------------------------------------------
run_case() {
  local label="$1" sb="$2" cwd="$3" gh_bin="$4"
  shift 4

  # Resolve relative cwd against the sandbox. Empty string → sandbox root
  # itself (no trailing slash, so the equality check against ops_root passes).
  if [ -z "$cwd" ]; then
    cwd="$sb"
  else
    case "$cwd" in
      /*) ;;
      *)  cwd="$sb/$cwd" ;;
    esac
  fi

  local out
  out=$(APEXYARD_OPS_ROOT="$sb" APEXYARD_CWD="$cwd" APEXYARD_GH="$gh_bin" \
        bash "$sb/.claude/skills/status/briefing.sh" 2>&1)
  local rc=$?

  rm -rf "$sb"

  if [ "$rc" != "0" ]; then
    echo "FAIL [$label]: helper exited rc=$rc" >&2
    echo "    output: $out" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi

  local expected
  for expected in "$@"; do
    if ! printf '%s' "$out" | grep -qF -- "$expected"; then
      echo "FAIL [$label]: missing expected substring: '$expected'" >&2
      echo "    output:" >&2
      echo "$out" | sed 's/^/      /' >&2
      FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
      return
    fi
  done

  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# ---------------------------------------------------------------------------
# 1. cwd at ops root → workspace = "(ops)", branch from no git → (no branch)
# ---------------------------------------------------------------------------
sb=$(make_fork)
run_case "ops-root-workspace" "$sb" "" "" \
  "Active workspace:" \
  "(ops)" \
  "(none)" \
  "<none — inferred per task>"

# ---------------------------------------------------------------------------
# 2. cwd inside workspace/<name>/ → workspace = "<name>", branch from git
# ---------------------------------------------------------------------------
sb=$(make_fork "example-app")
run_case "workspace-name" "$sb" "workspace/example-app" "" \
  "Active workspace:  example-app" \
  "Branch:" \
  "feature/test-branch"

# ---------------------------------------------------------------------------
# 3. cwd outside ops_root → workspace = "(unknown)"
# ---------------------------------------------------------------------------
sb=$(make_fork)
unrelated_dir=$(mktemp -d)
unrelated_dir=$(cd "$unrelated_dir" && pwd -P)
run_case "unknown-cwd" "$sb" "$unrelated_dir" "" \
  "(unknown)"
rm -rf "$unrelated_dir"

# ---------------------------------------------------------------------------
# 4. ops-fallback ticket marker — read from .claude/session/current-ticket
# ---------------------------------------------------------------------------
sb=$(make_fork)
write_marker "$sb" "current-ticket" "me2resh/apexyard" "182" "[Feature] briefing slide"
run_case "ops-ticket-fallback" "$sb" "" "" \
  "Active ticket:" \
  "#182 — [Feature] briefing slide"

# ---------------------------------------------------------------------------
# 5. per-project marker takes priority over ops fallback
# ---------------------------------------------------------------------------
sb=$(make_fork "demo-app")
write_marker "$sb" "current-ticket"          "me2resh/apexyard"   "100" "ops-level title"
write_marker "$sb" "tickets/demo-app"        "owner/demo-app"     "42"  "per-project title"
run_case "per-project-priority" "$sb" "workspace/demo-app" "" \
  "Active workspace:  demo-app" \
  "#42 — per-project title"

# ---------------------------------------------------------------------------
# 6. role inference — ticket has `backend` label → role = backend
#
# Mock `gh` by writing a tiny shim script that prints a fixed JSON
# blob whenever invoked with `issue view ... --json labels`.
# ---------------------------------------------------------------------------
sb=$(make_fork)
write_marker "$sb" "current-ticket" "me2resh/apexyard" "200" "backend ticket"
gh_shim="$sb/.gh-shim"
cat > "$gh_shim" <<'SHIM'
#!/usr/bin/env bash
# Minimal mock: only handles `gh issue view N --repo R --json labels`.
case "$1 $2" in
  "issue view")
    # Print labels JSON as gh would. Field set is what briefing.sh reads.
    cat <<'JSON'
{"labels":[{"name":"backend"},{"name":"P1"}]}
JSON
    ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$gh_shim"
run_case "role-from-label-backend" "$sb" "" "$gh_shim" \
  "Role set:" \
  "backend"

# ---------------------------------------------------------------------------
# 7. role inference with no matching label → emit the explicit fallback
# ---------------------------------------------------------------------------
sb=$(make_fork)
write_marker "$sb" "current-ticket" "me2resh/apexyard" "300" "label-less"
gh_shim="$sb/.gh-shim"
cat > "$gh_shim" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "issue view") echo '{"labels":[{"name":"P2"},{"name":"enhancement"}]}' ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$gh_shim"
run_case "role-no-matching-label" "$sb" "" "$gh_shim" \
  "Role set:" \
  "<none — inferred per task>"

# ---------------------------------------------------------------------------
# 8. exactly four lines of output (every briefing has the same shape)
# ---------------------------------------------------------------------------
sb=$(make_fork)
out=$(APEXYARD_OPS_ROOT="$sb" APEXYARD_CWD="$sb" APEXYARD_GH="" \
      bash "$sb/.claude/skills/status/briefing.sh" 2>&1)
rc=$?
line_count=$(printf '%s' "$out" | grep -c '^')
rm -rf "$sb"
if [ "$rc" = "0" ] && [ "$line_count" = "4" ]; then
  echo "PASS [four-line-shape]"
  PASS=$((PASS+1))
else
  echo "FAIL [four-line-shape]: rc=$rc lines=$line_count" >&2
  echo "$out" | sed 's/^/    /' >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}four-line-shape "
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
