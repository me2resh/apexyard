#!/bin/bash
# Tests for the bash-write-detection helper (#151).
#
# Covers:
#   - bash_command_appears_to_write: each pattern in the matcher table
#     (positive-class) and a representative read-only set (negative-class)
#   - bash_extract_write_target: the simple cases where extraction works
#     (>, >>, tee), and the documented misses (python -c) returning empty
#
# Exit 0 if all cases pass; exit 1 on first failure.

set -u

LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-detect-bash-write.sh"
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
    PASS=$((PASS+1))
  else
    echo "FAIL [should-detect-write/$label]: $cmd" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}write/${label} "
  fi
}

assert_read() {
  local label="$1" cmd="$2"
  if bash_command_appears_to_write "$cmd"; then
    echo "FAIL [should-be-read/$label]: $cmd" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}read/${label} "
  else
    echo "PASS [read/$label]"
    PASS=$((PASS+1))
  fi
}

assert_target() {
  local label="$1" cmd="$2" want="$3"
  local got
  got=$(bash_extract_write_target "$cmd")
  if [ "$got" = "$want" ]; then
    echo "PASS [target/$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [target/$label]: cmd=$cmd  want=[$want]  got=[$got]" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}target/${label} "
  fi
}

# --- WRITE patterns (positive class) -----------------------------------

assert_write "echo redirect"        "echo hi > /tmp/x"
assert_write "echo append"          "echo hi >> /tmp/x"
assert_write "cat heredoc"          $'cat > /tmp/x <<EOF\nhi\nEOF'
assert_write "tee"                  "echo x | tee /tmp/x"
assert_write "tee -a"               "echo x | tee -a /tmp/x"
assert_write "printf redirect"      "printf '%s' hello > /tmp/x"
assert_write "sed -i GNU"           "sed -i s/foo/bar/ /tmp/x"
assert_write "sed -i BSD"           "sed -i '' s/foo/bar/ /tmp/x"
assert_write "awk inplace"          "awk -i inplace 1 /tmp/x"
assert_write "python -c write_text" 'python3 -c "import pathlib; pathlib.Path(\"/tmp/x\").write_text(\"hi\")"'
assert_write "python -c open w"     'python3 -c "open(\"/tmp/x\", \"w\").write(\"hi\")"'
assert_write "python heredoc -"     $'python3 - <<\'PY\'\nimport pathlib\npathlib.Path("/tmp/x").write_text("hi")\nPY'
assert_write "node -e writeFile"    'node -e "require(\"fs\").writeFileSync(\"/tmp/x\", \"hi\")"'
assert_write "node -e appendFile"   'node -e "require(\"fs\").appendFileSync(\"/tmp/x\", \"hi\")"'
assert_write "ruby -e File.write"   'ruby -e "File.write(\"/tmp/x\", \"hi\")"'

# --- READ patterns (negative class — must NOT trigger) -----------------

assert_read  "cat"            "cat /tmp/x"
assert_read  "grep file"      "grep foo /tmp/x"
assert_read  "ls"             "ls -la /tmp"
assert_read  "find"           "find . -name foo"
assert_read  "git status"     "git status"
assert_read  "git diff"       "git diff HEAD"
assert_read  "pipe to grep"   "cat /tmp/x | grep foo"
assert_read  "stderr merge"   "make build 2>&1"
assert_read  "python read"    'python3 -c "print(open(\"/tmp/x\").read())"'
assert_read  "node read"      'node -e "console.log(require(\"fs\").readFileSync(\"/tmp/x\", \"utf8\"))"'

# --- target extraction (positive class — should produce target) --------

assert_target "redirect path"      "echo hi > /tmp/x"           "/tmp/x"
assert_target "append path"        "echo hi >> /tmp/x"          "/tmp/x"
assert_target "tee path"           "echo x | tee /tmp/x"        "/tmp/x"
assert_target "tee with flag"      "echo x | tee -a /tmp/x"     "/tmp/x"

# --- target extraction (documented misses — empty result) --------------

assert_target "python -c (miss)"   'python3 -c "open(\"/tmp/x\",\"w\").write(\"hi\")"' ""
assert_target "node -e (miss)"     'node -e "fs.writeFileSync(\"/tmp/x\",\"hi\")"' ""

# --- Regression: the exact bypass attempt that surfaced #151 ----------

bypass_cmd=$'python3 - <<\'PY\'\nimport pathlib\np = pathlib.Path(".gitignore")\np.write_text("...")\nPY'
assert_write "issue-151 bypass attempt" "$bypass_cmd"

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
