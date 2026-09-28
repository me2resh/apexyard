#!/usr/bin/env bash
# test_generate_mermaid_heredoc.sh
#
# me2resh/apexyard#1410 — generate-mermaid.sh writes its markdown through
# unquoted heredocs (`cat <<EOF`). Bash expands `$` and backticks in such a
# body. One line held bare backticks, so bash ran `/threat-model` as a
# command. The run printed an error on stderr. The generated sentence also
# lost its subject.
#
# This test checks:
#   - a generator run exits 0 and prints nothing on stderr
#   - the generated STRIDE sentence keeps `/threat-model`
#   - every heredoc opener in the generator has a shape the scan knows
#   - the scan finds at least one unquoted heredoc body
#   - no line inside an unquoted heredoc holds a bare backtick
#
# Usage: bash .claude/skills/dfd/tests/test_generate_mermaid_heredoc.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DFD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GENERATOR="$DFD_DIR/generate-mermaid.sh"

if [ ! -f "$GENERATOR" ]; then
  echo "FAIL: expected file missing: $GENERATOR" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
FAILED_CASES=""

ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1 ($2)"; FAIL=$((FAIL + 1)); FAILED_CASES="$FAILED_CASES\n  $1"; }

bash "$GENERATOR" demo /dev/null /dev/null > "$WORK/out.md" 2> "$WORK/err.txt"
rc=$?

echo ""
echo "1) A generator run"

if [ "$rc" -eq 0 ]; then
  ok "the generator exits 0"
else
  bad "the generator exits 0" "exit $rc"
fi

if [ ! -s "$WORK/err.txt" ]; then
  ok "the generator prints nothing on stderr"
else
  bad "the generator prints nothing on stderr" "$(head -c 200 "$WORK/err.txt")"
fi

# Match the literal backticks around the command name.
# shellcheck disable=SC2016
if grep -qF 'entry point — `/threat-model` iterates these crossings' "$WORK/out.md"; then
  ok "the STRIDE sentence keeps /threat-model"
else
  bad "the STRIDE sentence keeps /threat-model" \
      "got: $(grep -F 'STRIDE entry point' "$WORK/out.md" | head -1)"
fi

echo ""
echo "2) Unquoted heredoc bodies hold no bare backtick"

# Print each line of an unquoted heredoc body, with its line number. A quoted
# delimiter, such as <<'EOF' or <<"EOF", stops bash from expanding the body.
# The awk pass does not print that body. It prints UNRECOGNIZED for a `<<`
# line it cannot classify, so a new opener shape fails the test.
bodies=$(awk '
  in_body {
    line = $0
    if (dash) sub(/^\t+/, "", line)
    if (line == delim) { in_body = 0; next }
    print NR ": " $0
    next
  }
  match($0, /(^|[^<])<<-?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*([[:space:];|&<>)]|$)/) {
    d = substr($0, RSTART, RLENGTH)
    dash = (d ~ /<<-/)
    if (substr($0, RSTART + RLENGTH - 1) ~ /(^|[^<])<<[^<]/) print "UNRECOGNIZED " NR ": " $0
    sub(/^[^<]?<<-?[[:space:]]*/, "", d)
    sub(/[^A-Za-z0-9_]$/, "", d)
    delim = d
    in_body = 1
    next
  }
  /(^|[^<])<<[^<]/ && !/<<-?[[:space:]]*(["\047]|\\)/ {
    print "UNRECOGNIZED " NR ": " $0
  }
' "$GENERATOR")

unknown=$(printf '%s\n' "$bodies" | grep '^UNRECOGNIZED' | head -3)
if [ -z "$unknown" ]; then
  ok "every heredoc opener has a known shape"
else
  bad "every heredoc opener has a known shape" "$unknown"
fi

body_lines=$(printf '%s\n' "$bodies" | grep -v '^UNRECOGNIZED')
if [ -z "$body_lines" ]; then
  bad "found at least one unquoted heredoc to check" "none found"
else
  ok "found at least one unquoted heredoc to check"
fi

# A bare backtick follows zero backslashes or an even number of backslashes.
bare=$(printf '%s\n' "$body_lines" | grep -E '(^|[^\\])(\\\\)*`' | head -3)
if [ -z "$bare" ]; then
  ok "no bare backtick in an unquoted heredoc body"
else
  bad "no bare backtick in an unquoted heredoc body" "$bare"
fi

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed:%b\n' "$FAILED_CASES" >&2
  exit 1
fi
exit 0
