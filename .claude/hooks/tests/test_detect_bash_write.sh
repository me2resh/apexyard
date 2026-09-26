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

# #1372 — the mode must be read from the SECOND argument, not from anywhere
# inside the parentheses. The "python read" case above passes on `dev` only
# because `/tmp/x` happens to contain no w, a or +; a realistic path does. A
# single-argument open() is always mode 'r' in Python.
assert_read  "python read, path contains 'a'" 'python3 -c "print(open(\"data.txt\").read())"'
assert_read  "python read, dotted path"       'python3 -c "print(open(\".claude/x.json\").read())"'
assert_read  "python read, explicit r mode"   'python3 -c "print(open(\"data.txt\", \"r\").read())"'
assert_read  "python read, binary mode"       'python3 -c "print(open(\"data.txt\", \"rb\").read())"'

# Write modes. None of these call .write(), so the open() mode alone decides —
# otherwise the neighbouring `\.write\b` clause carries the verdict and the mode
# is never actually tested. The path contains no w, a or + for the same reason:
# with a path like "data.txt" the old form matched the filename instead.
#
# Only the 'x' case discriminates old from new — 'x' was absent from the old
# mode class entirely. The 'r+' and keyword-mode cases pass either way (via the
# literal '+' and 'w'); they are regression guards, not bug pins.
assert_write "python open x mode"             'python3 -c "open(\"file.txt\", \"x\")"'
assert_write "python open r+ mode"            'python3 -c "open(\"file.txt\", \"r+\")"'
assert_write "python open keyword mode"       'python3 -c "open(\"file.txt\", mode=\"w\")"'

# Nested parentheses in the path argument — the most common real write idiom.
# A `[^)]*` form cannot cross the inner `)`, so it would miss all three. `dev`
# catches the Path() and os.path.join() forms only by accident, via the `a` in
# "Path" and "path"; it misses str(p) outright.
assert_write "python open, nested Path()"     'python3 -c "open(pathlib.Path(d) / \"f\", \"w\")"'
assert_write "python open, nested str()"      'python3 -c "open(str(p), \"w\")"'
assert_write "python open, os.path.join"      'python3 -c "open(os.path.join(d, \"f\"), \"w\")"'

# pathlib.Path.open() takes the MODE as its FIRST positional argument, unlike
# the builtin open(file, mode). So there is no comma, and a clause written for
# the builtin misses it — while `Path("f").open("w")` truncates a real file on
# open, before any .write() call. Needs its own clause.
assert_write "pathlib Path.open w"            'python3 -c "import pathlib; pathlib.Path(\"f.txt\").open(\"w\").close()"'
assert_write "pathlib Path.open a"            'python3 -c "import pathlib; pathlib.Path(\"f.txt\").open(\"a\")"'
assert_write "pathlib Path.open x"            'python3 -c "import pathlib; pathlib.Path(\"f.txt\").open(\"x\")"'
assert_read  "pathlib Path.open r"            'python3 -c "import pathlib; print(pathlib.Path(\"f.txt\").open(\"r\").read())"'
assert_read  "pathlib Path.open default"      'python3 -c "import pathlib; print(pathlib.Path(\"f.txt\").open().read())"'

# Keyword-argument mode on Path.open(). There is no comma before the mode
# token, so a clause anchoring the mode immediately after `.open(` misses it —
# and `Path(p).open(mode="w", encoding=...)` is the more idiomatic form once
# an encoding is also passed.
assert_write "pathlib Path.open mode kwarg"   'python3 -c "from pathlib import Path; Path(\"f\").open(mode=\"w\")"'
assert_write "pathlib Path.open kwarg+enc"    'python3 -c "from pathlib import Path; Path(\"f\").open(mode=\"w\", encoding=\"utf-8\")"'
assert_read  "pathlib Path.open r kwarg"      'python3 -c "from pathlib import Path; print(Path(\"f\").open(mode=\"r\").read())"'

# The mode is unknowable at the call site, so this is treated as a write.
assert_write "python open star-args"          'python3 -c "open(*args)"'

# Archive extraction writes files. `dev` caught the tarfile form only because
# every ".tar" path contains an `a`, and never caught the zipfile form at all.
assert_write "python tarfile extractall"      'python3 -c "import tarfile; tarfile.open(\"b.tar\").extractall(\".\")"'
assert_write "python zipfile extractall"      'python3 -c "import zipfile; zipfile.ZipFile(\"b.zip\").extractall(\".\")"'

# tarfile write modes carry a compression suffix after ":" or "|". Those
# characters would otherwise end the mode token early and read as a read.
assert_write "python tarfile w:gz"            'python3 -c "import tarfile; tarfile.open(\"out.tgz\", \"w:gz\")"'
assert_write "python tarfile w|gz stream"     'python3 -c "import tarfile; tarfile.open(\"out.tgz\", \"w|gz\")"'
assert_write "python tarfile x:bz2"           'python3 -c "import tarfile; tarfile.open(\"out.tbz\", \"x:bz2\")"'
assert_read  "python tarfile r:gz"            'python3 -c "import tarfile; tarfile.open(\"in.tgz\", \"r:gz\")"'

# A mode held in a variable could be any mode. dev caught these only because a
# realistic identifier like "path" contains an "a" — rename it and the accident
# disappears, so match the shape instead.
assert_write "python open, variable mode"     'python3 -c "open(path, mode)"'
assert_write "python open, other var names"   'python3 -c "open(filename, filemode)"'
assert_read  "python open, kwarg not a mode"  'python3 -c "print(open(p, encoding=\"utf-8\").read())"'

# os.open takes integer flags rather than a mode string.
assert_write "python os.open O_WRONLY"        'python3 -c "import os; os.open(path, os.O_WRONLY|os.O_CREAT)"'
assert_write "python os.open O_APPEND"        'python3 -c "import os; os.open(path, os.O_APPEND)"'
assert_read  "python os.open O_RDONLY"        'python3 -c "import os; os.open(path, os.O_RDONLY)"'

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

# --- bash_command_is_deletion_only (#569) — positive class (rm-only) ---

assert_deletion_only() {
  local label="$1" cmd="$2"
  if bash_command_is_deletion_only "$cmd"; then
    echo "PASS [deletion-only/$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [should-be-deletion-only/$label]: $cmd" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}deletion-only/${label} "
  fi
}

assert_not_deletion_only() {
  local label="$1" cmd="$2"
  if bash_command_is_deletion_only "$cmd"; then
    echo "FAIL [should-NOT-be-deletion-only/$label]: $cmd" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}not-deletion-only/${label} "
  else
    echo "PASS [not-deletion-only/$label]"
    PASS=$((PASS+1))
  fi
}

# Positive class: rm-only → deletion_only returns 0
assert_deletion_only "rm file"          "rm file.ts"
assert_deletion_only "rm -f file"       "rm -f .claude/session/current-ticket"
assert_deletion_only "rm -rf dir"       "rm -rf /tmp/workdir"

# Negative class: content-writing alongside or instead of rm → deletion_only returns 1
assert_not_deletion_only "cp (not rm)"              "cp src.txt dst.txt"
assert_not_deletion_only "mv (not rm)"              "mv old.txt new.txt"
assert_not_deletion_only "dd (not rm)"              "dd if=/dev/zero of=x bs=1M count=1"
assert_not_deletion_only "install (not rm)"         "install -m 0644 src dst"
assert_not_deletion_only "rm + redirect"            "rm old.ts && echo x > src/app.ts"
assert_not_deletion_only "rm + tee"                 "rm a | tee b"
assert_not_deletion_only "redirect only (no rm)"    "echo x > file.ts"
assert_not_deletion_only "cp only"                  "cp a b"

# --- bash_extract_write_targets (#886) — ALL targets, not just the first ---

assert_targets() {
  local label="$1" cmd="$2" want="$3"
  local got
  got=$(bash_extract_write_targets "$cmd" | sort | tr '\n' ',' )
  local want_sorted
  want_sorted=$(printf '%s' "$want" | tr ',' '\n' | sort | tr '\n' ',')
  if [ "$got" = "$want_sorted" ]; then
    echo "PASS [targets/$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [targets/$label]: cmd=$cmd  want=[$want_sorted]  got=[$got]" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}targets/${label} "
  fi
}

# Single-target commands still return exactly one target (no regression
# vs. the singular bash_extract_write_target).
assert_targets "single redirect"          "echo hi > /tmp/x"                          "/tmp/x"
assert_targets "single in-repo redirect"  "echo hi > src/app.ts"                      "src/app.ts"
assert_targets "single tee"               "echo x | tee /tmp/x"                       "/tmp/x"
assert_targets "single cp"                "cp src.txt /tmp/dst.txt"                   "/tmp/dst.txt"

# THE #886 bypass shape: an out-of-repo (or otherwise exempt) target FIRST,
# an in-repo target SECOND — both must be present in the extracted set so a
# consumer can gate on the second even though the first would exempt alone.
assert_targets "semicolon-chained: out-of-repo then in-repo" \
  "echo a > /tmp/x; echo b > src/app.ts"                                              "/tmp/x,src/app.ts"
assert_targets "&&-chained: out-of-repo then in-repo" \
  "cp a.txt /tmp/b.txt && echo y > src/app.ts"                                        "/tmp/b.txt,src/app.ts"
assert_targets "tee with multiple file operands" \
  "echo x | tee /tmp/a src/b.ts"                                                      "/tmp/a,src/b.ts"
assert_targets "tee -a with multiple file operands" \
  "echo x | tee -a /tmp/a src/b.ts"                                                   "/tmp/a,src/b.ts"
assert_targets "three semicolon-chained redirects" \
  "echo a > /tmp/x; echo b > /tmp/y; echo c > src/app.ts"                             "/tmp/x,/tmp/y,src/app.ts"

# #886/#926 (Hakim security-review finding): NO-SPACE separator+redirection.
# Splitting on the separator can leave a segment that BEGINS with `>` —
# e.g. `;> .gitignore` splits into a second segment of `> .gitignore`. The
# original leading-context regex `[^|<&]>...` required a character before
# `>` to exist at all, so it silently dropped the target at position 0.
# These are Hakim's exact repro strings from the PR #926 review.
assert_targets "no-space semicolon then redirect" \
  "echo a > /tmp/ok;> .gitignore"                                                     "/tmp/ok,.gitignore"
assert_targets "no-space semicolon+redirect with trailing command" \
  "echo a > /tmp/ok;> .gitignore cat /etc/hostname"                                   "/tmp/ok,.gitignore"
assert_targets "no-space && then redirect" \
  "echo a > /tmp/ok&&> .gitignore"                                                    "/tmp/ok,.gitignore"
assert_targets "no-space | then redirect" \
  "echo a > /tmp/ok|> .gitignore"                                                     "/tmp/ok,.gitignore"
assert_targets "no-space || then redirect" \
  "echo a > /tmp/ok||> .gitignore"                                                    "/tmp/ok,.gitignore"

# Sanity: the anchored fix must not turn 2>&1 (fd-dup) or a heredoc into a
# false-positive redirection target.
if bash_command_appears_to_write "make build 2>&1"; then
  echo "FAIL [targets/2>&1 must not be treated as a write]" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}targets/fd-dup-false-positive "
else
  echo "PASS [targets/2>&1 correctly not a write]"
  PASS=$((PASS+1))
fi
assert_targets "heredoc still extracts correctly (no regression)" \
  "$(printf 'cat > /tmp/x <<EOF\nhi\nEOF')"                                           "/tmp/x"

# #886/#926 round 3 (Hakim adversarial re-hunt): the operator alternation
# only modelled >, >>, and n> — it missed &>/&>> (redirect BOTH streams to
# a file) and >|/>>| (force-clobber, noclobber override). Both are real,
# destructive truncating writes. Hakim's exact repros:
assert_targets "&> redirects both streams to a file (Hakim repro)" \
  "echo hi &> .gitignore"                                                            ".gitignore"
# NOTE: unlike the other rows in this block, `&>>` happens to extract
# correctly even under the PRE-round-3 regex — not via the dedicated `&>>?`
# alternative this fix adds, but by coincidence: the pattern's leading-context
# class `[^|<&]` doesn't exclude `>` itself, so the SECOND `>` in `&>>` reads
# the FIRST `>` as valid (non-excluded) leading context and matches anyway.
# Kept here as a correctness/coverage check (it must still pass post-fix),
# not a fail-pre/pass-post discriminator like the bare `&>` row above it.
assert_targets "&>> append-both-streams to a file" \
  "echo hi &>> .gitignore"                                                           ".gitignore"
assert_targets ">| force-clobber after no-space semicolon (Hakim repro)" \
  "echo a > /tmp/ok;>| db/migrations/006.sql"                                         "/tmp/ok,db/migrations/006.sql"
assert_targets ">>| force-clobber-append variant" \
  "echo a > /tmp/ok;>>| db/migrations/006.sql"                                        "/tmp/ok,db/migrations/006.sql"
assert_targets ">| with a space after the separator (not just no-space)" \
  "echo a > /tmp/ok; >| db/migrations/006.sql"                                        "/tmp/ok,db/migrations/006.sql"

# #886/#926 round 4 (Hakim's fourth adversarial re-hunt): ZERO whitespace
# between the operator and its target. Bash accepts this for every
# operator — the mandatory `[[:space:]]+` this pattern used through round 3
# silently dropped all five of these real, destructive writes. Hakim's
# exact repros:
assert_targets "no-space '>' (Hakim repro)" \
  "echo hi>src/migrations/001.sql"                                                    "src/migrations/001.sql"
assert_targets "no-space 'n>' fd-numbered (Hakim repro)" \
  "echo a > /tmp/ok; echo b 2>src/migrations/001.sql"                                 "/tmp/ok,src/migrations/001.sql"
assert_targets "no-space '>>' (Hakim repro)" \
  "echo a > /tmp/ok; echo b>>src/migrations/001.sql"                                  "/tmp/ok,src/migrations/001.sql"
assert_targets "no-space '>|' (Hakim repro)" \
  "echo a > /tmp/ok; echo b>|src/migrations/001.sql"                                  "/tmp/ok,src/migrations/001.sql"
assert_targets "no-space '&>' (Hakim repro)" \
  "echo a > /tmp/ok; echo b&>src/migrations/001.sql"                                  "/tmp/ok,src/migrations/001.sql"

# Sanity: relaxing whitespace to optional must NOT open a new false-positive
# surface on fd-dup forms written with NO space either — the target
# character class (not the whitespace requirement) is what excludes them.
assert_targets "no-space '>&2' fd-dup — still not a write target" \
  "echo err>&2"                                                                       ""
assert_targets "no-space '2>&1' fd-dup — still not a write target" \
  "make build 2>&1;true"                                                              ""

# #886/#926 round 5 (Hakim's fifth adversarial re-hunt — the STRUCTURAL
# root of the whole series): `|`/`||`-adjacent redirects. Detection
# (bash_command_appears_to_write) used to run the redirection matcher on
# the WHOLE, unsplit command, where a `|`-preceded `>` is excluded by the
# leading-context class and isn't at `^` either — so `|>`/`||>`/`||>|`
# were never even recognised as writes, let alone extracted. Extraction
# already split first, so it found the target correctly — detection and
# extraction DISAGREED. This block proves EXTRACTION already returns the
# right target for these (it did before round 5 too); the real fix is in
# the DETECTION-level test block further down, which is where the
# structural bug actually lived.
assert_targets "'||>' after a false command (Hakim repro)" \
  "false ||> src/app.ts"                                                             "src/app.ts"
assert_targets "'||>|' force-clobber after a false command (Hakim repro)" \
  "false ||>| src/app.ts"                                                            "src/app.ts"
assert_targets "'|>' after echo (Hakim repro)" \
  "echo x |> src/app.ts"                                                             "src/app.ts"

# Detection-level proof: bash_command_appears_to_write must ALSO recognise
# these — this is the assertion that actually discriminates round 5 from
# rounds 1-4, since it's the DETECTION path (not extraction) that had the
# structural bug.
assert_appears_to_write() {
  local label="$1" cmd="$2"
  if bash_command_appears_to_write "$cmd"; then
    echo "PASS [detect/$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [detect/$label]: bash_command_appears_to_write missed: $cmd" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}detect/${label} "
  fi
}
assert_appears_to_write "'||>' detected as a write (Hakim repro)"    "false ||> src/app.ts"
assert_appears_to_write "'||>|' detected as a write (Hakim repro)"   "false ||>| src/app.ts"
assert_appears_to_write "'|>' detected as a write (Hakim repro)"     "echo x |> src/app.ts"

# Sanity: the deletion-only classifier had the identical structural bug at
# its own direct _bdw_match_redirection call site — `rm x; false ||> y`
# would have been wrongly classified as deletion-only (content-writing
# hiding behind a |-adjacent redirect), exempting it from the ticket gate.
assert_not_deletion_only "rm + '||>' hides a real write (round 5)" \
  "rm old.ts; false ||> src/app.ts"

# Sanity: the round-5 fix must NOT false-positive on fd-dup / read forms
# that also happen to be pipe-adjacent.
assert_targets "'| cmd 2>&1' pipe then fd-dup — not a write" \
  "echo x | cat 2>&1"                                                                 ""
assert_targets "'|| cmd >&2' or-chain then fd-dup — not a write" \
  "false || echo err >&2"                                                             ""

# Sanity: the broadened operator set must NOT false-positive on fd-duplication
# forms, which look superficially similar (`&` and `>` both present) but mean
# something entirely different — redirecting one fd to ANOTHER fd, not to a
# file. Order in "&"/">"" matters: &> is `&` THEN `>` (a write); these forms
# have `>` THEN `&` (a dup) and must stay unmatched.
assert_targets "2>&1 fd-dup — not a write target" \
  "make build 2>&1"                                                                   ""
assert_targets ">&2 fd-dup — not a write target" \
  "echo err >&2"                                                                      ""
assert_targets "1>&2 fd-dup — not a write target" \
  "cmd 1>&2"                                                                          ""
if bash_command_appears_to_write "echo err >&2"; then
  echo "FAIL [targets/>&2 must not be detected as appears_to_write]" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}targets/fd-dup-appears-to-write "
else
  echo "PASS [targets/>&2 correctly not detected as a write]"
  PASS=$((PASS+1))
fi

# Sanity: reads / heredocs / herestrings must still be untouched by the
# broadened operator set.
assert_targets "< plain read redirection — not a write" \
  "cat < /tmp/x"                                                                      ""
assert_targets "<<< herestring — not a write" \
  "cat <<< 'hello'"                                                                   ""

# Duplicate targets across segments collapse to one entry.
got_dup=$(bash_extract_write_targets "echo a > /tmp/x; echo b > /tmp/x" | wc -l | tr -d ' ')
if [ "$got_dup" = "1" ]; then
  echo "PASS [targets/duplicate targets deduped]"
  PASS=$((PASS+1))
else
  echo "FAIL [targets/duplicate targets deduped]: got $got_dup lines, want 1" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}targets/dedupe "
fi

# Documented misses still contribute nothing (no fabricated targets).
assert_targets "python -c (miss) contributes nothing" \
  'python3 -c "open(\"/tmp/x\",\"w\").write(\"hi\")"'                                 ""

# --- #931 residual 1: `<>` read-write open is now DETECTED as a write ---
#
# `[n]<>word` opens `word` for both reading AND writing — a real,
# non-truncating write that every #886/#926 round missed entirely (the
# leading `<` was always excluded by the OTHER operators' own
# leading-context class, so `<>` was structurally invisible, not just an
# uncovered edge case). #931 decided to DETECT rather than
# document-as-accepted: the ticket gate cares about "was tracked content
# touched", not "was it truncated".

assert_write  "<> read-write open, fd-numbered (#931)"  "exec 3<> /tmp/x"
assert_write  "<> read-write open, no fd, no space (#931)" "cmd <>file.txt"
assert_write  "<> read-write open, fd + space (#931)"   "exec 3<> file.txt"

assert_target "<> extracts the file target (#931)" \
  "exec 3<> /tmp/x"                                                                   "/tmp/x"
assert_targets "<> extracts the file target, multi-target form (#931)" \
  "exec 3<> src/app.ts"                                                               "src/app.ts"

# Sanity: `<>` must not be confused with heredoc (`<<`) or herestring
# (`<<<`) — both contain repeated `<`, never the exact `<` immediately
# followed by `>` this operator requires.
assert_targets "<< heredoc still not a <> false-positive (#931)" \
  "$(printf 'cat > /tmp/x <<EOF\nhi\nEOF')"                                           "/tmp/x"
assert_targets "<<< herestring still not a <> false-positive (#931)" \
  "cat <<< 'hello'"                                                                   ""

# Sanity: a `<>` write hiding behind an `rm` must not be misclassified as
# deletion-only (same shape as the round-5 `||>` sanity check above).
assert_not_deletion_only "rm + '<>' hides a real write (#931)" \
  "rm old.ts; exec 3<> src/app.ts"

# --- #931 residual 2: `>(…)` / `<(…)` process substitution no longer
#     over-blocked ---
#
# `diff a >(sort)` is NOT a file write — `>(sort)` is process substitution
# (a subshell command wired to a fifo/fd path), syntactically adjacent to
# `>` but semantically nothing like a redirect target. Pre-#931 the target
# class allowed a leading `(` and so fabricated `(sort)` as if it were a
# filename — a fail-closed (over-blocking) false positive, not a bypass,
# but worth tightening since it needlessly blocked a common construct
# (`diff a >(sort)`, `tee >(logger)`, etc.) behind the ticket gate.

assert_read "diff with >(...) process substitution is NOT a write (#931)" \
  "diff a >(sort)"
assert_read "<(...) process substitution on the read side (#931, already fine)" \
  "diff <(sort a) <(sort b)"

assert_targets ">(...) process substitution contributes no target (#931)" \
  "diff a >(sort)"                                                                    ""

# The exact shape from #931's own repro: a REAL write earlier in a
# no-space-chained command, a process-substitution tail after it — only
# the real target must surface, and detection must still fire (because of
# the first, real write).
assert_appears_to_write "real write + >(...) tail still detected (#931)" \
  "echo a > /tmp/ok;diff x >(sort)"
assert_targets "real write + >(...) tail: only the real target surfaces (#931)" \
  "echo a > /tmp/ok;diff x >(sort)"                                                    "/tmp/ok"

# Sanity: the leading-`(` exclusion must NOT reject a legitimate filename
# that merely CONTAINS a paren not in the leading position.
assert_targets "filename with non-leading parens still extracts (#931)" \
  'echo hi > "file(1).txt"'                                                           "file(1).txt"

# Sanity: the process-substitution exclusion must not resurrect any
# fd-dup / force-clobber / redirect-both-streams false-negative from
# earlier rounds.
assert_write  ">| force-clobber still a write alongside the new exclusion (#931)" \
  "echo a >| /tmp/x"
assert_write  "&> both-streams still a write alongside the new exclusion (#931)" \
  "echo hi &> .gitignore"
assert_read   "2>&1 fd-dup still excluded alongside the new exclusion (#931)" \
  "make build 2>&1"
assert_read   ">&2 fd-dup still excluded alongside the new exclusion (#931)" \
  "echo err >&2"

# #1145: command substitutions and heredoc bodies are data, not file-write
# targets. Keep the detector from reading ordinary prose as a shell command.
assert_read "printf in command substitution is read-only (#1145)" \
  'result="$(printf "%s" "$result" | jq -r .url)"'
assert_targets "printf substitution has no write target (#1145)" \
  'result="$(printf "%s" "$result" | jq -r .url)"' ""
assert_read "git commit heredoc body is not a file write (#1145)" \
  "git commit -F - <<'MSG'
chore: subject

Body prose ending in portfolio.
MSG"
assert_targets "heredoc prose has no fabricated target (#1145)" \
  "git commit -F - <<'MSG'
chore: subject

Body prose ending in portfolio.
MSG" ""

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
