#!/bin/bash
# #1810 (AgDR-0263): the commit-format check treats the body of a quoted
# heredoc that only feeds a file write as data. Prose in that body that
# names a commit, with Markdown backticks, must not start the commit checks.
# A real commit is still checked: a command substitution in -m blocks, and a
# message file is still read and validated.
#
# Each case runs validate-commit-format.sh, or dispatch-bash.sh, from this
# source tree with the working directory in a temp fixture repo.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
HOOKS="$ROOT/.claude/hooks"

PASS=0
FAIL=0
FAILED_CASES=""

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FX="$TMP/fx"
mkdir -p "$FX" "$TMP/out" "$TMP/home/.notes"
git -C "$FX" init -q
git -C "$FX" checkout -q -b feature/GH-1810-fixture
printf 'a\n' > "$FX/a.txt"
git -C "$FX" add a.txt
git -C "$FX" -c user.email=test@example.com -c user.name=test commit -q -m "chore: init"
printf 'fix(#1810): valid subject from a file\n' > "$TMP/good-msg.txt"
printf 'not a valid subject\n' > "$TMP/bad-msg.txt"

BT=$(printf '\140')
TAB=$(printf '\t')
V=commit
OUT="$TMP/out/review.md"
# Review prose: a commit mention in inline code, an apostrophe, a hash.
MENTION="Run ${BT}git ${V} -m x${BT} after ${BT}abc123${BT}. Don't skip it."

# run_case <label> <hook> <command> <want rc> <want stderr regex or "">
run_case() {
  local label="$1" hook="$2" cmd="$3" want_rc="$4" want_re="$5"
  local input got got_rc
  input=$(jq -nc --arg c "$cmd" --arg d "$FX" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$d}')
  got=$(cd "$FX" && printf '%s' "$input" | HOME="${CASE_HOME:-$HOME}" \
    /bin/bash "$HOOKS/$hook" 2>&1 >/dev/null)
  got_rc=$?
  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc" >&2
    echo "    stderr: ${got:0:300}" >&2
    FAIL=$((FAIL + 1)); FAILED_CASES="${FAILED_CASES}[${label}] "
    return
  fi
  if [ -n "$want_re" ] && ! printf '%s\n' "$got" | grep -qE "$want_re"; then
    echo "FAIL [$label]: stderr did not match /$want_re/" >&2
    echo "    stderr: ${got:0:300}" >&2
    FAIL=$((FAIL + 1)); FAILED_CASES="${FAILED_CASES}[${label}] "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS + 1))
}

H=validate-commit-format.sh
D=dispatch-bash.sh

# --- AC1: a quoted heredoc that only writes a file is not blocked ---------
run_case "cat > file, quoted heredoc with backticks: allow" "$H" \
  "cat > $OUT <<'EOF'
$MENTION
EOF" 0 ""
run_case "cat <<'EOF' > file: allow" "$H" \
  "cat <<'EOF' > $OUT
$MENTION
EOF" 0 ""
run_case "cat >> file, double-quoted delimiter: allow" "$H" \
  "cat >> $OUT <<\"EOF\"
$MENTION
EOF" 0 ""
run_case "tee -a file: allow" "$H" \
  "tee -a $OUT <<'EOF'
$MENTION
EOF" 0 ""
run_case "<<- with a tab-indented delimiter: allow" "$H" \
  "cat > $OUT <<-'EOF'
${TAB}$MENTION
${TAB}EOF" 0 ""
run_case "mkdir && cat > file: allow" "$H" \
  "mkdir -p $TMP/out && cat > $OUT <<'EOF'
$MENTION
EOF" 0 ""
run_case "file write, then a command that does not read the file: allow" "$H" \
  "cat > $OUT <<'EOF'
$MENTION
EOF
echo done" 0 ""
run_case "two file writes in one command: allow" "$H" \
  "cat > $OUT <<'EOF'
$MENTION
EOF
cat > $TMP/out/second.md <<'EOF'
$MENTION
EOF
echo done" 0 ""

# --- AC2: a real commit with a command substitution in -m still blocks ----
run_case "commit -m with \$(...): block" "$H" \
  "git ${V} -m \"fix(#1810): subject \$(date)\"" 2 "does not accept command substitutions"
run_case "commit -m with a backtick substitution: block" "$H" \
  "git ${V} -m \"fix(#1810): subject ${BT}date${BT}\"" 2 "backtick command substitutions"

# --- Paired: the body is data only for a file write -----------------------
run_case "file write, then a real commit: block" "$H" \
  "cat > $OUT <<'EOF'
$MENTION
EOF
git ${V} -m \"bad subject\"" 2 "newline compound commit commands"
run_case "real commit before a file write: block" "$H" \
  "git ${V} -m \"fix(#1810): subject\" && cat > $OUT <<'EOF'
$MENTION
EOF" 2 "does not accept compound commit commands"
run_case "unquoted heredoc file write: block" "$H" \
  "cat > $OUT <<EOF
$MENTION
EOF" 2 "backtick command substitutions"
run_case "heredoc fed to a shell: block" "$H" \
  "bash <<'EOF'
git ${V} -m \"bad subject\"
EOF" 2 "newline compound commit commands"
run_case "file write, then the file runs: block" "$H" \
  "cat > $TMP/out/run.sh <<'EOF'
git ${V} -m \"bad subject\"
EOF
bash $TMP/out/run.sh" 2 "newline compound commit commands"
run_case "unterminated heredoc: block" "$H" \
  "cat > $OUT <<'EOF'
$MENTION" 2 "backtick command substitutions"
run_case "text after the delimiter word: block" "$H" \
  "cat > $OUT <<'EOF' && git ${V} -m \"bad subject\"
$MENTION
EOF" 2 ""
run_case "quoted file write inside an unquoted heredoc: block" "$H" \
  "cat > $TMP/out/outer.md <<EOF
cat > $OUT <<'IN'
$MENTION
IN
EOF" 2 "backtick command substitutions"
run_case "start line after a line continuation: block" "$H" \
  "sh \\
cat > $OUT <<'EOF'
git ${V} -m \"bad subject\"
EOF" 2 "newline compound commit commands"

# --- AC3: a message read from a file is still checked ----------------------
run_case "commit -F valid file: allow" "$H" \
  "git ${V} -F $TMP/good-msg.txt" 0 ""
run_case "commit -F invalid file: block" "$H" \
  "git ${V} -F $TMP/bad-msg.txt" 2 "BLOCKED: Commit subject"
run_case "commit --file= invalid file: block" "$H" \
  "git ${V} --file=$TMP/bad-msg.txt" 2 "BLOCKED: Commit subject"

# --- Through the dispatcher ------------------------------------------------
# A target in a home-directory dot folder is not a routing data sink
# (AgDR-0262), so the dispatcher runs the commit gates on this write.
CASE_HOME="$TMP/home"
run_case "dispatcher: write into a home dot folder: allow" "$D" \
  "cat > $TMP/home/.notes/review.md <<'EOF'
$MENTION
EOF" 0 ""
unset CASE_HOME
run_case "dispatcher: mkdir && cat > file: allow" "$D" \
  "mkdir -p $TMP/out && cat > $OUT <<'EOF'
$MENTION
EOF" 0 ""
run_case "dispatcher: file write, then a real commit: block" "$D" \
  "mkdir -p $TMP/out && cat > $OUT <<'EOF'
$MENTION
EOF
git ${V} -m \"bad subject\"" 2 "commit-format hook does not accept newline compound"
run_case "dispatcher: commit -m with \$(...): block" "$D" \
  "git ${V} -m \"fix(#1810): subject \$(date)\"" 2 "does not accept command substitutions"
run_case "dispatcher: commit -F invalid file: block" "$D" \
  "git ${V} -F $TMP/bad-msg.txt" 2 "BLOCKED: Commit subject"

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
