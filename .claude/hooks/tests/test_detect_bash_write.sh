#!/bin/bash
# Tests for the bash-write-detection helper (#151, extended in #153).
#
# Covers:
#   - bash_command_appears_to_write: each pattern in the matcher table
#     (positive-class) and a representative read-only set (negative-class)
#   - bash_extract_write_target: the simple cases where extraction works
#     (>, >>, tee, cp/mv last arg, curl -o, wget -O), and the documented
#     misses (python -c, script runners) returning empty
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

# First-version coverage (#152).
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

# #153 — file-moving builtins.
assert_write "cp file"              "cp src.txt /tmp/dst.txt"
assert_write "mv file"              "mv old.txt /tmp/new.txt"
assert_write "rm file"              "rm /tmp/x"
assert_write "rm -rf"               "rm -rf /tmp/dir"
assert_write "dd of"                "dd if=/dev/zero of=/tmp/x bs=1M count=1"
assert_write "install"              "install -m 0644 src /tmp/dst"

# #153 — archive / network writes.
assert_write "tar -xf"              "tar -xf archive.tar"
assert_write "tar xzf"              "tar xzf archive.tar.gz"
assert_write "tar --extract"        "tar --extract --file=archive.tar"
assert_write "curl -o"              "curl -o /tmp/x https://example.com/f"
assert_write "curl --output"        "curl --output /tmp/x https://example.com/f"
assert_write "wget -O"              "wget -O /tmp/x https://example.com/f"
assert_write "wget --output-doc"    "wget --output-document=/tmp/x https://example.com/f"

# #153 — additional interpreters.
assert_write "perl -e print FH"     'perl -e "open(my $fh, \">\", \"/tmp/x\"); print $fh \"hi\";"'
assert_write "perl -e unlink"       'perl -e "unlink \"/tmp/x\""'
assert_write "php -r file_put"      'php -r "file_put_contents(\"/tmp/x\", \"hi\");"'
assert_write "php -r fwrite"        'php -r "$f = fopen(\"/tmp/x\", \"w\"); fwrite($f, \"hi\");"'
assert_write "go run"               "go run main.go"
assert_write "deno run"             "deno run --allow-write script.ts"
assert_write "deno script.ts"       "deno script.ts"
assert_write "bun run"              "bun run script.ts"
assert_write "bun script.ts"        "bun script.ts"

# #153 — python helpers.
assert_write "pathlib touch"        'python3 -c "import pathlib; pathlib.Path(\"/tmp/x\").touch()"'
assert_write "shutil.copy"          'python3 -c "import shutil; shutil.copy(\"a\", \"b\")"'
assert_write "shutil.move"          'python3 -c "import shutil; shutil.move(\"a\", \"b\")"'
assert_write "os.rename"            'python3 -c "import os; os.rename(\"a\", \"b\")"'

# #153 — ruby/node heredocs.
ruby_heredoc=$'ruby <<\'RB\'\nFile.write("/tmp/x", "hi")\nRB'
assert_write "ruby heredoc"         "$ruby_heredoc"
node_heredoc=$'node <<\'JS\'\nrequire("fs").writeFileSync("/tmp/x", "hi")\nJS'
assert_write "node heredoc"         "$node_heredoc"

# --- READ patterns (negative class — must NOT trigger) -----------------

# First-version coverage (#152).
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

# #153 — counterexamples for the new matcher families.
assert_read  "cp --help"      "cp --help"
assert_read  "cp --version"   "cp --version"
assert_read  "rm --help"      "rm --help"
assert_read  "mv --version"   "mv --version"
assert_read  "git rm"         "git rm src.txt"
assert_read  "git mv"         "git mv old.txt new.txt"
assert_read  "tar -t"         "tar -t archive.tar"
assert_read  "tar --list"     "tar --list -f archive.tar"
assert_read  "tar -tzf"       "tar -tzf archive.tar.gz"
assert_read  "curl -s url"    "curl -s https://example.com/f"
assert_read  "curl bare"      "curl https://example.com/f"
assert_read  "wget --help"    "wget --help"
assert_read  "wget bare"      "wget https://example.com/f"
assert_read  "deno fmt"       "deno fmt"
assert_read  "deno test"      "deno test --no-check"
assert_read  "go build"       "go build ./..."
assert_read  "go version"     "go version"
assert_read  "perl -v"        "perl -v"
assert_read  "php --version"  "php --version"

# --- target extraction (positive class — should produce target) --------

# First-version coverage (#152).
assert_target "redirect path"      "echo hi > /tmp/x"           "/tmp/x"
assert_target "append path"        "echo hi >> /tmp/x"          "/tmp/x"
assert_target "tee path"           "echo x | tee /tmp/x"        "/tmp/x"
assert_target "tee with flag"      "echo x | tee -a /tmp/x"     "/tmp/x"

# #153 — new extractors.
assert_target "cp last arg"        "cp src.txt /tmp/dst.txt"    "/tmp/dst.txt"
assert_target "mv last arg"        "mv a.txt /tmp/b.txt"        "/tmp/b.txt"
assert_target "curl -o path"       "curl -o /tmp/f https://example.com/f"        "/tmp/f"
assert_target "curl --output"      "curl --output /tmp/f https://example.com/f"  "/tmp/f"
assert_target "wget -O path"       "wget -O /tmp/f https://example.com/f"        "/tmp/f"

# --- target extraction (documented misses — empty result) --------------

assert_target "python -c (miss)"   'python3 -c "open(\"/tmp/x\",\"w\").write(\"hi\")"' ""
assert_target "node -e (miss)"     'node -e "fs.writeFileSync(\"/tmp/x\",\"hi\")"' ""
assert_target "go run (miss)"      "go run main.go" ""
assert_target "deno run (miss)"    "deno run script.ts" ""

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
