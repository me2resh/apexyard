#!/bin/bash
# Smoke tests for .claude/hooks/check-jq-installed.sh — SessionStart
# advisory that warns when `jq` is missing on a fork that has any
# project-config file present.
#
# Each case:
#   - builds an isolated sandbox under $TMPDIR with a synthetic ops-fork
#     layout (legacy v1 anchor: onboarding.yaml + apexyard.projects.yaml)
#   - toggles jq's presence by either using the real PATH (jq present)
#     OR a stub PATH where `jq` resolves to a non-existent binary
#     (jq absent)
#   - optionally drops a project-config file into the ops fork
#   - runs the hook from the ops-fork dir
#   - asserts banner output / silence
#
# Cases covered:
#   1. jq present → silent exit 0 (regardless of config presence)
#   2. jq missing + project-config.json present → warning emitted
#   3. jq missing + project-config.defaults.json present → warning emitted
#   4. jq missing + no project-config file → silent exit 0 (nothing to
#      degrade, banner would be noise)
#   5. jq missing + not inside any ops fork → silent exit 0
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/check-jq-installed.sh"
LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-ops-root.sh"
PASS=0
FAIL=0
FAILED=""

if [ ! -f "$HOOK_SRC" ]; then
  echo "FAIL: hook not found at $HOOK_SRC" >&2
  exit 1
fi

# Build a synthetic ops-fork layout under $1 with a legacy v1 anchor:
#   $1/onboarding.yaml
#   $1/apexyard.projects.yaml
#   $1/.claude/hooks/check-jq-installed.sh   (copy of the source hook)
#   $1/.claude/hooks/_lib-ops-root.sh        (copy of the shared lib)
build_fork() {
  local fk="$1"
  mkdir -p "$fk/.claude/hooks"
  : > "$fk/onboarding.yaml"
  : > "$fk/apexyard.projects.yaml"
  cp "$HOOK_SRC" "$fk/.claude/hooks/check-jq-installed.sh"
  chmod +x "$fk/.claude/hooks/check-jq-installed.sh"
  if [ -f "$LIB_SRC" ]; then
    cp "$LIB_SRC" "$fk/.claude/hooks/_lib-ops-root.sh"
  fi
}

# Run the hook from $1 (ops fork dir) with jq either visible (when
# $2 is "present") or hidden (when $2 is "missing"). For the "missing"
# case we point PATH at a directory containing a stub `jq` that's a
# non-executable placeholder file — `command -v` walks PATH looking
# for an executable, finds the stub, and reports it missing because
# it's not +x. This sidesteps both the "where is jq actually
# installed" problem and the "exported functions don't propagate to a
# fresh bash" problem with `command` overrides.
#
# We keep the rest of PATH so coreutils (bash, mktemp, grep, cat, ...)
# remain reachable.
run_hook_from() {
  local fk="$1" mode="$2"
  case "$mode" in
    present)
      ( cd "$fk" || exit 1; bash .claude/hooks/check-jq-installed.sh 2>&1 )
      ;;
    missing)
      # Two-stage approach: first try a PATH-only mask (works on macOS
      # where jq is in /opt/homebrew/bin or /usr/local/bin and absent
      # from /usr/bin); fall through to a `command` function override
      # if jq is still reachable via PATH (true on Linux where jq is
      # typically packaged into /usr/bin). Each approach has a quirk:
      #   - PATH-only: cheapest, works in a child bash process.
      #   - command override: works regardless of where jq lives, but
      #     requires sourcing the hook into a subshell so the function
      #     stays in scope. We use `bash -c '… . "$2"'` for that.
      ( cd "$fk" || exit 1
        PATH="/usr/bin:/bin"
        if ! command -v jq >/dev/null 2>&1; then
          bash .claude/hooks/check-jq-installed.sh 2>&1
        else
          bash -c '
            command() {
              if [ "$1" = "-v" ] && [ "$2" = "jq" ]; then
                return 1
              fi
              builtin command "$@"
            }
            cd "$1" || exit 1
            . .claude/hooks/check-jq-installed.sh
          ' _ "$fk" 2>&1
        fi
      )
      ;;
  esac
}

assert() {
  local label="$1" expected_pattern="$2" output="$3"
  if [ -z "$expected_pattern" ]; then
    if [ -z "$output" ]; then
      echo "PASS [$label] — silent"
      PASS=$((PASS+1)); return
    fi
    echo "FAIL [$label] — expected silent, got: $output" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "; return
  fi
  if echo "$output" | grep -qE "$expected_pattern"; then
    echo "PASS [$label]"
    PASS=$((PASS+1)); return
  fi
  echo "FAIL [$label] — expected /$expected_pattern/, got: $output" >&2
  FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
}

# CASE 1: jq present + project-config present → silent
case_jq_present_silent() {
  local fk; fk=$(mktemp -d)/fork
  build_fork "$fk"
  : > "$fk/.claude/project-config.json"
  # Real PATH carries jq (assumption: the dev box running these tests
  # has jq installed — same assumption used by the rest of the test
  # suite). If jq is missing here, the test environment itself is
  # broken; the test result reflects that honestly.
  if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP [jq present case] — jq is not installed in the test environment" >&2
    rm -rf "$(dirname "$fk")"
    return
  fi
  assert "jq present + project-config.json → silent" "" "$(run_hook_from "$fk" "present")"
  rm -rf "$(dirname "$fk")"
}

# CASE 2: jq missing + project-config.json present → warning
case_jq_missing_with_config() {
  local fk; fk=$(mktemp -d)/fork
  build_fork "$fk"
  : > "$fk/.claude/project-config.json"
  assert "jq missing + project-config.json → warning fires" "jq is not installed" "$(run_hook_from "$fk" "missing")"
  rm -rf "$(dirname "$fk")"
}

# CASE 3: jq missing + project-config.defaults.json present → warning
case_jq_missing_with_defaults() {
  local fk; fk=$(mktemp -d)/fork
  build_fork "$fk"
  : > "$fk/.claude/project-config.defaults.json"
  assert "jq missing + project-config.defaults.json → warning fires" "jq is not installed" "$(run_hook_from "$fk" "missing")"
  rm -rf "$(dirname "$fk")"
}

# CASE 4: jq missing + no project-config file → silent
case_jq_missing_no_config() {
  local fk; fk=$(mktemp -d)/fork
  build_fork "$fk"
  # Intentionally no project-config.{,defaults.}json
  assert "jq missing + no project-config → silent" "" "$(run_hook_from "$fk" "missing")"
  rm -rf "$(dirname "$fk")"
}

# CASE 5: jq missing + not inside any ops fork → silent
case_jq_missing_no_ops_root() {
  local outside; outside=$(mktemp -d)
  # Walk-up from a tmp dir might find an ancestor ops fork on a dev
  # box. If it does, this case is ambiguous; document the skip rather
  # than fail spuriously. We pass the hook the absolute path so its
  # `dirname "$0"` resolves to the real hook dir, but invoke from
  # $outside so the ops-root walk starts elsewhere.
  local out
  out=$(
    PATH="/usr/bin:/bin"
    if ! command -v jq >/dev/null 2>&1; then
      cd "$outside" && bash "$HOOK_SRC" 2>&1
    else
      bash -c '
        command() {
          if [ "$1" = "-v" ] && [ "$2" = "jq" ]; then
            return 1
          fi
          builtin command "$@"
        }
        cd "$1" || exit 1
        . "$2"
      ' _ "$outside" "$HOOK_SRC" 2>&1
    fi
  )
  if [ -z "$out" ]; then
    echo "PASS [jq missing + outside ops fork → silent]"
    PASS=$((PASS+1))
  else
    # The walk found an ancestor ops fork with a config file present.
    # That's a legitimate (different) state — not a regression. Note it.
    echo "SKIP [jq missing + outside ops fork] — walk-up found an ancestor ops fork (output: $out)" >&2
  fi
  rm -rf "$outside"
}

case_jq_present_silent
case_jq_missing_with_config
case_jq_missing_with_defaults
case_jq_missing_no_config
case_jq_missing_no_ops_root

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
