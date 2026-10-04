#!/bin/bash
# Regression pins for me2resh/apexyard#1502 write-detector gaps.
#
# Acceptance criteria (one assert group each):
#   1. Versioned pythonX.Y -c with a write is detected.
#   2. Option arguments that contain the letter c before -c still reach -c.
#   3. When a segment here-doc cannot be materialised, detection fails closed
#      (reports a write) rather than "no write".
#
# LIB_SRC may point at an alternate detector copy for fail-before proofs run
# outside this file. The shipped run always uses the in-tree library.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB_SRC="${LIB_SRC:-$ROOT/.claude/hooks/_lib-detect-bash-write.sh}"

if [ ! -f "$LIB_SRC" ]; then
  echo "FAIL: lib not found at $LIB_SRC" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$LIB_SRC"

PASS=0
FAIL=0
FAILED_CASES=""

assert_write() {
  local label="$1" cmd="$2"
  if bash_command_appears_to_write "$cmd"; then
    echo "PASS [write/$label]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [should-detect-write/$label]: $cmd" >&2
    FAIL=$((FAIL + 1))
    FAILED_CASES="${FAILED_CASES}write/${label} "
  fi
}

assert_read() {
  local label="$1" cmd="$2"
  if bash_command_appears_to_write "$cmd"; then
    echo "FAIL [should-be-read/$label]: $cmd" >&2
    FAIL=$((FAIL + 1))
    FAILED_CASES="${FAILED_CASES}read/${label} "
  else
    echo "PASS [read/$label]"
    PASS=$((PASS + 1))
  fi
}

# --- AC1: versioned pythonX.Y ------------------------------------------------
assert_write "#1502 AC1 python3.12 -c open w" \
  "python3.12 -c \"open('src/app.ts','w').write('x')\""
assert_write "#1502 AC1 python3.12.1 -c open w" \
  "python3.12.1 -c \"open('src/app.ts','w').write('x')\""
assert_write "#1502 AC1 python2.7 -c open w" \
  "python2.7 -c \"open('src/app.ts','w').write('x')\""
# Neighbour: versioned binary with a read stays a read.
assert_read "#1502 AC1 python3.12 -c read stays read" \
  "python3.12 -c \"print(open('src/app.ts').read())\""

# --- AC2: option argument containing c before -c -----------------------------
assert_write "#1502 AC2 -W error::ResourceWarning -c" \
  "python3 -W error::ResourceWarning -c \"open('src/app.ts','w').write('x')\""
assert_write "#1502 AC2 -X pycache_prefix=/x -c" \
  "python3 -X pycache_prefix=/x -c \"open('src/app.ts','w').write('x')\""
assert_write "#1502 AC2 versioned + -W ResourceWarning -c" \
  "python3.12 -W error::ResourceWarning -c \"open('src/app.ts','w').write('x')\""
# #1480 neighbours must stay detected (never match less than before).
assert_write "#1502 AC2 neighbour -W ignore -c" \
  "python3 -W ignore -c \"open('src/app.ts','w').write('x')\""
assert_write "#1502 AC2 neighbour -Bc" \
  "python3 -Bc \"open('src/app.ts','w').write('x')\""

# --- AC3: here-doc segment read failure fails closed -------------------------
# Bash 3.2 writes here-doc bodies to a temp file. ulimit -f 0 makes that write
# fail. trap '' XFSZ keeps the shell alive so the detector can return. The
# command must be a real redirect write that needs the segment loop
# (`false ||> file` is the #886 shape). Run inside a disposable directory so
# any empty sh-thd-* leftovers from the failed here-doc stay out of the
# caller's tree.
ac3_dir=$(mktemp -d) || {
  echo "FAIL [write/#1502 AC3 here-doc fail closed]: mktemp failed" >&2
  FAIL=$((FAIL + 1))
  FAILED_CASES="${FAILED_CASES}write/AC3-mktemp "
  ac3_dir=""
}
if [ -n "$ac3_dir" ]; then
  ac3_out=$(
    cd "$ac3_dir" || exit 1
    trap '' XFSZ
    ulimit -f 0 2>/dev/null || {
      echo "SKIP_ULIMIT"
      exit 0
    }
    # Re-source under the restricted limit so the here-doc inside the matcher
    # is the one that fails.
    # shellcheck source=/dev/null
    . "$LIB_SRC"
    if bash_command_appears_to_write 'false ||> src/app.ts'; then
      echo WRITE
    else
      echo READ
    fi
  ) 2>/dev/null

  case "$ac3_out" in
    WRITE)
      echo "PASS [write/#1502 AC3 here-doc fail closed]"
      PASS=$((PASS + 1))
      ;;
    SKIP_ULIMIT)
      echo "FAIL [write/#1502 AC3 here-doc fail closed]: ulimit -f unavailable" >&2
      FAIL=$((FAIL + 1))
      FAILED_CASES="${FAILED_CASES}write/AC3-ulimit "
      ;;
    *)
      echo "FAIL [should-detect-write/#1502 AC3 here-doc fail closed]: got=[$ac3_out]" >&2
      FAIL=$((FAIL + 1))
      FAILED_CASES="${FAILED_CASES}write/AC3-heredoc "
      ;;
  esac
  rm -rf "$ac3_dir"
fi

# Sanity: under a normal limit the same command still detects.
assert_write "#1502 AC3 neighbour false ||> still a write" \
  'false ||> src/app.ts'

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
