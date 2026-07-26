#!/bin/bash
# Regression test for me2resh/apexyard#1018 — portfolio_validate() false-positives
# on Windows/Git Bash for a plain single-fork setup, because of a
# drive-letter (D:/Projs/fork) vs MSYS-mount-point (/d/Projs/fork) path
# spelling mismatch inside `_portfolio_canonicalize`.
#
# Why this test drives the comparison directly instead of a filesystem
# fixture: the bug is a Windows/MSYS-runtime-specific behavior — git.exe
# (a native Windows binary) emits drive-letter paths, while `cd ... &&
# pwd -P` (run by bash, an MSYS binary) emits the MSYS mount-point form
# FOR THE SAME LOCATION. That translation only exists inside the MSYS
# runtime. On macOS/Linux, "D:/Projs/fork" and "/d/Projs/fork" are just
# two unrelated path strings (colon has no special meaning) — there is
# no way to make `cd` treat them as the same directory here, so a
# filesystem-based fixture would not exercise the real bug at all; it
# would only test colon-containing directory names, an unrelated
# concern. Driving `_portfolio_canonicalize` directly with both
# spellings as string inputs is the correct, honest reproduction on a
# non-Windows CI runner — matching the bug report's own repro shape.
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

run_case() {
  local name="$1"
  local snippet="$2"
  local out rc

  out=$(
    # shellcheck source=/dev/null
    . "$LIB_SRC"
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
# Case 1: a Windows drive-letter absolute path normalizes to the MSYS
# mount-point form instead of being returned raw/unchanged.
# ---------------------------------------------------------------------------
run_case "#1018: drive-letter path normalizes to MSYS mount-point form" '
r=$(_portfolio_canonicalize "D:/Projs/fork/apexyard.projects.yaml")
expected="/d/Projs/fork/apexyard.projects.yaml"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'

# ---------------------------------------------------------------------------
# Case 2: lowercase drive letter also normalizes (case-insensitive drive).
# ---------------------------------------------------------------------------
run_case "#1018: lowercase drive letter also normalizes" '
r=$(_portfolio_canonicalize "d:/projs/fork/projects")
expected="/d/projs/fork/projects"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'

# ---------------------------------------------------------------------------
# Case 3: backslash-separated drive-letter form (native Windows spelling)
# also normalizes, with backslashes converted to forward slashes.
# ---------------------------------------------------------------------------
run_case "#1018: backslash drive-letter form normalizes" '
r=$(_portfolio_canonicalize "C:\Users\x\apexyard")
expected="/c/Users/x/apexyard"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'

# ---------------------------------------------------------------------------
# Case 4 (the core acceptance criterion): the drive-letter spelling and the
# already-MSYS-form spelling of the IDENTICAL location now canonicalize to
# the same string — this is what makes the string-prefix comparison inside
# portfolio_validate() succeed instead of false-positiving.
# ---------------------------------------------------------------------------
run_case "#1018: drive-letter and MSYS spellings of the same path compare EQUAL" '
a=$(_portfolio_canonicalize "D:/Projs/fork/apexyard.projects.yaml")
b=$(_portfolio_canonicalize "/d/Projs/fork/apexyard.projects.yaml")
if [ "$a" = "$b" ]; then exit 0; else echo "a=$a b=$b (should match)"; exit 1; fi
'

# ---------------------------------------------------------------------------
# Case 5: reproduces the exact false-positive mechanism from
# portfolio_validate()'s partial-split-portfolio-v2 detector (introduced in
# #373). root_real/wd_real are what a direct `cd "$root" && pwd -P` call
# yields on real MSYS (already normalized); registry/projects_dir are what
# portfolio_registry()/portfolio_projects_dir() return for a plain
# single-fork setup with NO .portfolio overrides (all defaults, so the
# raw value is $root/apexyard.projects.yaml with $root in drive-letter
# form, exactly as git.exe would emit it).
#
# BEFORE the fix: registry/projects_dir were returned raw (drive-letter
# form) by _portfolio_canonicalize, so this exact prefix match failed —
# the false positive this issue reports.
# AFTER the fix: both sides normalize to the same MSYS form, so the
# comparison now correctly judges "inside the fork".
# ---------------------------------------------------------------------------
run_case "#1018: portfolio_validate prefix comparison no longer false-positives" '
root_real="/d/Projs/fork"
registry=$(_portfolio_canonicalize "D:/Projs/fork/apexyard.projects.yaml")
projects_dir=$(_portfolio_canonicalize "D:/Projs/fork/projects")

_outside_fork() {
  case "$1" in
    "$root_real"|"$root_real"/*) return 1 ;;
  esac
  return 0
}

if _outside_fork "$registry"; then
  echo "registry judged OUTSIDE fork (false positive!): $registry vs root_real=$root_real"
  exit 1
fi
if _outside_fork "$projects_dir"; then
  echo "projects_dir judged OUTSIDE fork (false positive!): $projects_dir vs root_real=$root_real"
  exit 1
fi
exit 0
'

# ---------------------------------------------------------------------------
# Case 6: proves the bug mechanism (not just the fix) — feeding the RAW,
# un-normalized drive-letter string (what the code returned before this
# fix) into the identical comparison DOES false-positive. This is the
# "would have failed before the fix" pin, expressed without needing a
# second copy of the pre-fix library.
# ---------------------------------------------------------------------------
run_case "#1018: sanity — the raw (un-normalized) drive-letter form DOES mismatch (proves the bug was real)" '
root_real="/d/Projs/fork"
registry_raw="D:/Projs/fork/apexyard.projects.yaml"   # what the OLD code returned, unnormalized

_outside_fork() {
  case "$1" in
    "$root_real"|"$root_real"/*) return 1 ;;
  esac
  return 0
}

if _outside_fork "$registry_raw"; then
  exit 0   # correctly demonstrates the old bug: raw form mismatches root_real
else
  echo "expected the raw/unnormalized form to mismatch (that IS the bug) but it matched"
  exit 1
fi
'

# ---------------------------------------------------------------------------
# Case 7: a GENUINE misconfiguration — registry/projects_dir resolving to a
# real, different sibling directory (not just a spelling difference of the
# SAME path) — must still be detected as outside the fork. The fix must not
# make the outside-fork check toothless.
# ---------------------------------------------------------------------------
run_case "#1018: genuine misconfig (different sibling dir) is still detected as OUTSIDE the fork" '
root_real="/d/Projs/fork"
sibling_registry=$(_portfolio_canonicalize "D:/Projs/portfolio-sibling/apexyard.projects.yaml")

_outside_fork() {
  case "$1" in
    "$root_real"|"$root_real"/*) return 1 ;;
  esac
  return 0
}

if _outside_fork "$sibling_registry"; then
  exit 0   # correctly detected as outside — genuine misconfig still caught
else
  echo "sibling path ($sibling_registry) was wrongly judged INSIDE root_real ($root_real) — detection broken"
  exit 1
fi
'

# ---------------------------------------------------------------------------
# Case 8: POSIX no-op — every ordinary absolute POSIX path canonicalizes
# exactly the way it did before this fix (the drive-letter branch is never
# entered because none of these start with "<letter>:"). Pinned against the
# same `cd ... && pwd -P` logic the function itself uses, so this fails if
# the new preprocessing step ever mutates a real POSIX path.
# ---------------------------------------------------------------------------
run_case "#1018: POSIX absolute path is an exact no-op (real dir, symlinks resolved)" '
r=$(_portfolio_canonicalize "/tmp")
expected=$(cd /tmp && pwd -P)
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'

run_case "#1018: POSIX absolute path to a nonexistent leaf is an exact no-op (tail preserved verbatim)" '
r=$(_portfolio_canonicalize "/nonexistent-for-test-1018/foo/bar.yaml")
expected="/nonexistent-for-test-1018/foo/bar.yaml"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'

run_case "#1018: relative path is an exact no-op (unchanged, not absolute)" '
r=$(_portfolio_canonicalize "./relative/path.yaml")
expected="./relative/path.yaml"
if [ "$r" = "$expected" ]; then exit 0; else echo "got=$r expected=$expected"; exit 1; fi
'

# ---------------------------------------------------------------------------
# Case 9: end-to-end POSIX regression via the real public resolvers + a
# real single-fork sandbox (same fixture shape as test_portfolio_paths.sh
# case 1) — proves portfolio_validate() still passes clean on an ordinary
# macOS/Linux single-fork setup after this fix, i.e. the fix is genuinely
# a no-op for the framework's default, most common path.
# ---------------------------------------------------------------------------
SB=$(mktemp -d)
SB=$(cd "$SB" && pwd -P)
(
  cd "$SB" || exit 1
  git init -q
  git config user.email "test@example.com"
  git config user.name "test"
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
  git commit -q -m "test fixture (#1018 regression)"
)
run_case "#1018: real POSIX single-fork sandbox — portfolio_validate still OK" "
out=\$(
  cd '$SB' || exit 99
  . .claude/hooks/_lib-read-config.sh
  . .claude/hooks/_lib-portfolio-paths.sh
  portfolio_clear_cache
  if portfolio_validate; then echo OK; else portfolio_validate; fi
)
rc=\$?
if [ \"\$out\" = \"OK\" ] && [ \"\$rc\" -eq 0 ]; then exit 0; else echo \"got out=[\$out] rc=\$rc\"; exit 1; fi
"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "===== test_portfolio_paths_windows_drive_letter.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0
