#!/bin/bash
# ERE interval lock for every hook library (#1757, #1067, #1071).
#
# `{n,m}` is not portable in awk. mawk 1.3.4 aborts on it. A fallback that
# fails closed then blocks every direct merge. POSIX grep accepts the same
# form, so this lock scans awk program literals only.
#
# Shell comments and awk comments are ignored. A `${1}` outside an awk
# program is not an awk interval. An interval in awk code fails the lock.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOKS="$ROOT/.claude/hooks"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/extract.awk" <<'AWK'
function word_char(c) { return c ~ /[A-Za-z0-9_]/ }
function ch(s, i) { return substr(s, i, 1) }
function blank_awk_comment(line,    k) {
  k = index(line, "#")
  if (k == 0) return line
  return substr(line, 1, k - 1)
}
function emit_program(path, text, start_line,    n, i, line, ln, c) {
  n = length(text)
  line = ""
  ln = start_line
  for (i = 1; i <= n; i++) {
    c = substr(text, i, 1)
    if (c == "\n") {
      printf "%s:%d:%s\n", path, ln, blank_awk_comment(line)
      line = ""
      ln++
    } else line = line c
  }
  if (line != "" || n == 0) printf "%s:%d:%s\n", path, ln, blank_awk_comment(line)
}
function read_word(s, i, n, want_lit,    c) {
  LIT = ""
  if (i > n) { END_AT = i; return 0 }
  while (i <= n) {
    c = ch(s, i)
    if (c == " " || c == "\t" || c == "\n" || c == "\r") break
    if (c == "\\" && i < n && ch(s, i + 1) == "\n") break
    if (c == "'") {
      i++
      while (i <= n && ch(s, i) != "'") {
        if (want_lit) LIT = LIT ch(s, i)
        i++
      }
      if (i <= n) i++
      continue
    }
    if (c == "\"") {
      i++
      while (i <= n) {
        c = ch(s, i)
        if (c == "\\") {
          if (want_lit && i < n) LIT = LIT ch(s, i + 1)
          i += 2
          continue
        }
        if (c == "\"") { i++; break }
        if (want_lit) LIT = LIT c
        i++
      }
      continue
    }
    if (c == "\\") {
      if (want_lit && i < n) LIT = LIT ch(s, i + 1)
      i += 2
      continue
    }
    if (want_lit) LIT = LIT c
    i++
  }
  END_AT = i
  return 1
}
function skip_ws(s, i, n,    c) {
  while (i <= n) {
    c = ch(s, i)
    if (c == "\\" && i < n && ch(s, i + 1) == "\n") { i += 2; continue }
    if (c != " " && c != "\t" && c != "\n" && c != "\r") break
    i++
  }
  return i
}
function line_of(s, i,    k, ln) {
  ln = 1
  for (k = 1; k < i && k <= length(s); k++) if (substr(s, k, 1) == "\n") ln++
  return ln
}
function take_program(path, s, i, n,    start) {
  i = skip_ws(s, i, n)
  if (i > n) return i
  if (ch(s, i) != "'" && ch(s, i) != "\"") return i
  start = line_of(s, i)
  read_word(s, i, n, 1)
  emit_program(path, LIT, start)
  return END_AT
}
function after_awk(path, s, i, n,    j, flag) {
  j = skip_ws(s, i, n)
  while (j <= n && ch(s, j) == "-") {
    read_word(s, j, n, 1)
    flag = LIT
    j = END_AT
    if (flag == "-v" || flag == "-F" || flag == "-f") {
      j = skip_ws(s, j, n)
      if (j <= n) { read_word(s, j, n, 0); j = END_AT }
    }
    j = skip_ws(s, j, n)
  }
  return take_program(path, s, j, n)
}
function after_fallback(path, s, i, n,    j, a) {
  j = i
  for (a = 0; a < 2; a++) {
    j = skip_ws(s, j, n)
    if (j > n) return j
    read_word(s, j, n, 0)
    j = END_AT
  }
  j = skip_ws(s, j, n)
  return take_program(path, s, j, n)
}
BEGIN { RS = "\034" }
{
  s = $0
  n = length(s)
  i = 1
  insq = 0
  indq = 0
  while (i <= n) {
    c = ch(s, i)
    if (insq) {
      if (c == "'") insq = 0
      i++
      continue
    }
    if (indq) {
      if (c == "\\") { i += 2; continue }
      if (c == "\"") indq = 0
      i++
      continue
    }
    if (c == "\\" && i < n && ch(s, i + 1) == "\n") { i += 2; continue }
    if (c == "'") { insq = 1; i++; continue }
    if (c == "\"") { indq = 1; i++; continue }
    if (c == "#" && (i == 1 || ch(s, i - 1) ~ /[ \t\n;&|()<>]/)) {
      while (i <= n && ch(s, i) != "\n") i++
      continue
    }
    if ((i == 1 || !word_char(ch(s, i - 1))) && substr(s, i, 3) == "awk" && (i + 3 > n || !word_char(ch(s, i + 3)))) {
      i = after_awk(FILENAME, s, i + 3, n)
      continue
    }
    name = "_run_awk_or_fallback"
    namelen = length(name)
    if ((i == 1 || !word_char(ch(s, i - 1))) && substr(s, i, namelen) == name && (i + namelen > n || !word_char(ch(s, i + namelen)))) {
      i = after_fallback(FILENAME, s, i + namelen, n)
      continue
    }
    i++
  }
}
AWK

INTERVAL_RE='\{[0-9]+(,[0-9]*)?\}'

scan_files() {
  LC_ALL=C awk -f "$TMP/extract.awk" "$@"
}

hits_of() {
  scan_files "$@" | grep -nE "$INTERVAL_RE" || true
}

shopt -s nullglob
libs=("$HOOKS"/_lib-*.sh)
shopt -u nullglob
if [ "${#libs[@]}" -eq 0 ]; then
  fail "found hook libraries to scan"
else
  pass "found ${#libs[@]} hook libraries to scan"
fi

LIB_HITS=$(hits_of "${libs[@]}")
if [ -n "$LIB_HITS" ]; then
  fail "no ERE interval in an awk program under .claude/hooks/_lib-*.sh"
  printf '%s\n' "$LIB_HITS" | head -5 >&2
else
  pass "no ERE interval in an awk program under .claude/hooks/_lib-*.sh"
fi

# The lock must see an interval in code and ignore one in a comment.
cat > "$TMP/real.sh" <<'EOF'
awk '
  # The old {1,2} form is described here.
  re = ".{0,3}"
'
EOF
REAL_HITS=$(hits_of "$TMP/real.sh")
if printf '%s\n' "$REAL_HITS" | grep -q ':3:'; then
  pass "interval lock reports the awk source line"
else
  fail "interval lock reports the awk source line"
  printf '%s\n' "${REAL_HITS:-<none>}" >&2
fi
if printf '%s\n' "$REAL_HITS" | grep -q '{1,2}'; then
  fail "interval lock ignores an awk comment"
else
  pass "interval lock ignores an awk comment"
fi

# A POSIX grep interval is not compiled by awk. The lock must leave it.
cat > "$TMP/grep.sh" <<'EOF'
printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$' || return 1
EOF
if [ -z "$(hits_of "$TMP/grep.sh")" ]; then
  pass "interval lock ignores a grep interval outside awk"
else
  fail "interval lock ignores a grep interval outside awk"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
