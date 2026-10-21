#!/bin/bash
# Collect the existing runtime corpus, then compare both public functions.
# Each distinct command compares stdout bytes and status against the full walk.
set -eu
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
unset APEXYARD_OPS_ROOT APEXYARD_PORTFOLIO_ROOT CLAUDE_PROJECT_DIR
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bdw-prefilter.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export BDW_EQ_CORPUS="$TMP/corpus"
: > "$BDW_EQ_CORPUS"
# Work on a disposable copy of the hooks. No source or repository state is modified.
mkdir -p "$TMP/repo/.claude"
cp -R "$ROOT/.claude/hooks" "$TMP/repo/.claude/hooks"
cp "$ROOT/.claude/"*.json "$TMP/repo/.claude/"
LIB="$TMP/repo/.claude/hooks/_lib-detect-bash-write.sh"
printf '\n_BDW_EQ_CORPUS=%q\n' "$BDW_EQ_CORPUS" >> "$LIB"
cat >> "$LIB" <<'ORACLE'

# Test-only collectors preserve the original function's output and status.
_bdw_collect_definition=$(declare -f bash_extract_write_targets)
eval "${_bdw_collect_definition/bash_extract_write_targets/_bdw_collect_targets}"
_bdw_collect_definition=$(declare -f bash_command_has_unextractable_write)
eval "${_bdw_collect_definition/bash_command_has_unextractable_write/_bdw_collect_unextractable}"
unset _bdw_collect_definition
bash_extract_write_targets() {
  { printf '%s\0' "$1" >> "$_BDW_EQ_CORPUS"; } 2>/dev/null || :
  _bdw_collect_targets "$@"
}
bash_command_has_unextractable_write() {
  { printf '%s\0' "$1" >> "$_BDW_EQ_CORPUS"; } 2>/dev/null || :
  _bdw_collect_unextractable "$@"
}
ORACLE
# Run the fast suites that call the library directly, in parallel. The 120 s
# test cap of bin/run-hook-tests.sh rules out the slower gate suites. A suite
# failure is reported, but only an equivalence mismatch fails this test.
names="test_detect_bash_write.sh test_detect_bash_write_1502.sh test_mask_quoted.sh test_command_scrub_regressions.sh test_hook_substitutions_bash32.sh test_awk_fallback.sh"
suites=0
for name in $names; do
  ( /bin/bash "$TMP/repo/.claude/hooks/tests/$name" > "$TMP/$name.log" 2>&1; echo $? > "$TMP/$name.rc" ) &
  suites=$((suites + 1))
done
wait
suite_failures=0
for name in $names; do
  if [ "$(cat "$TMP/$name.rc")" = 0 ]; then
    printf 'PASS: corpus suite %s\n' "$name"
  else
    printf 'NOTE: corpus suite returned nonzero: %s\n' "$name"
    suite_failures=$((suite_failures + 1))
  fi
done
# shellcheck source=/dev/null
. "$ROOT/.claude/hooks/_lib-detect-bash-write.sh"
# Remove duplicate commands without decoding or changing arbitrary input bytes.
python3 - "$BDW_EQ_CORPUS" "$TMP/unique" <<'PYTHON'
from pathlib import Path
import sys
samples = Path(sys.argv[1]).read_bytes().split(b'\0')[:-1]
Path(sys.argv[2]).write_bytes(b''.join(s + b'\0' for s in dict.fromkeys(samples)))
PYTHON
# check FUNCTION COMMAND [ARG]: the filtered walk and the full walk must give
# the same stdout bytes and the same status. Each worker counts in its own file.
check() {
  local fn="$1" filtered complete
  shift
  filtered=$("$fn" "$@"; printf '\001%s' "$?")
  complete=$(_bdw_candidate_segments() { return 1; }; "$fn" "$@"; printf '\001%s' "$?")
  comparisons=$((comparisons + 1))
  if [ "$filtered" != "$complete" ]; then
    printf 'FAIL: %s %q\n' "$fn" "$1"
    failed=$((failed + 1))
  fi
}
check_command() {
  check bash_extract_write_targets "$1"
  check bash_command_has_unextractable_write "$1"
  [ "${2:-}" = full ] && check bash_extract_write_targets "$1" all
  return 0
}
# The binary-notice doubles match -nE as well as -anE. The encoding-error double
# loses a line only when -a is missing, so it fails on code that lacks -a.
# Prose, shell-fed bodies, all extraction families, and separator edge cases.
samples=(
  '' 'read data' $'echo >file;bad\377byte' $'cat > out <<\047EOF\047\nalpha beta gamma\nEOF'
  $'bash <<\047EOF\047\ncp a b\nsed -i "s/a/b/" c\nEOF'
  $'cat <<EOF\ntee a b\ncurl -o c url\nwget -O d url\nEOF'
  '>a' 'echo x >>a 2>b' 'exec 3<>file' 'echo x >|file' 'echo x &>file'
  'echo x >&file' 'echo x >&2' 'diff a >(sort)' 'false||>file'
  'tee a b 2>err' "sed -i 's/a/b/' f" "sed -n 'p;w out' f"
  'curl --output=f url' 'wget --output-document=f url' 'cp a b >/dev/null'
  'mv a "$target" >/dev/null' 'install a b' 'dd of=f' 'git diff --output=f'
  'sort -o f in' "yq -i '.a=1' f" 'echo "tee cp sed curl git sort yq" >f'
  $'echo >a\n\nplain prose\ncp b c\n' $'echo >a;\tsed -i "s/a/b/" f'
)
# One task per line: "c INDEX" (corpus), "s INDEX" (sample), "g INDEX" (grep
# error), "b INDEX" (binary-input notice). Workers take every Nth task.
corpus=()
while IFS= read -r -d '' cmd; do corpus+=("$cmd"); done < "$TMP/unique"
tasks=()
for ((i=0; i<${#corpus[@]}; i++)); do tasks+=("c $i"); done
for ((i=0; i<${#samples[@]}; i++)); do tasks+=("s $i"); done
for i in 3 4 6 7 8 14 16 17 19 20 22 25 26 28; do tasks+=("g $i" "b $i" "e $i"); done
worker() {
  local id="$1" n="$2" t=0 task kind idx comparisons=0 failed=0
  for task in "${tasks[@]}"; do
    t=$((t + 1))
    [ $((t % n)) -eq "$id" ] || continue
    kind="${task% *}"; idx="${task#* }"
    case "$kind" in
      c) check_command "${corpus[idx]}" ;;
      s) check_command "${samples[idx]}" full ;;
      # A grep failure must select the original complete walk, even with partial output.
      g) grep() { if [ "${1:-}" = -anE ] || [ "${1:-}" = -nE ]; then cat >/dev/null; printf '1:partial\n'; return 2; fi; command grep "$@"; }
         check_command "${samples[idx]}" full; unset -f grep ;;
      # Some grep implementations report binary input without numbered records.
      b) grep() { if [ "${1:-}" = -anE ] || [ "${1:-}" = -nE ]; then cat >/dev/null; printf 'Binary file (standard input) matches\n'; return 0; fi; command grep "$@"; }
         check_command "${samples[idx]}" full; unset -f grep ;;
      # GNU grep 3.5+ in a legacy multibyte locale drops a line that has an
      # encoding error, writes the notice to stderr and exits 0.
      e) grep() {
           # Only a call without -a loses the line; -a prints every selected line.
           if [ "${1:-}" = -nE ]; then
             local hits first l
             hits=$(command grep "$@") || :
             first="${hits%%$'\n'*}"; first="${first#*:}"
             if [ -n "$hits" ]; then
               # Drop every line with the text of the first hit, as grep drops a text with an encoding error in both views.
               while IFS= read -r l; do [ "${l#*:}" = "$first" ] || printf '%s\n' "$l"; done <<DROP_FIRST
$hits
DROP_FIRST
             fi
             echo 'grep: (standard input): binary file matches' >&2
             return 0
           fi
           command grep "$@"
         }
         check_command "${samples[idx]}" full; unset -f grep ;;
    esac
  done
  printf '%s %s\n' "$comparisons" "$failed" > "$TMP/worker.$id"
}
workers=8
for ((w=0; w<workers; w++)); do worker "$w" "$workers" > "$TMP/worker.$w.out" 2>&1 & done
wait
comparisons=0
failed=0
for ((w=0; w<workers; w++)); do
  cat "$TMP/worker.$w.out"
  read -r c f < "$TMP/worker.$w"
  comparisons=$((comparisons + c))
  failed=$((failed + f))
done
[ "$comparisons" -gt 100 ] || failed=$((failed + 1))
printf 'Equivalence: %s byte/status comparisons, %s distinct corpus commands, %s corpus suites, %s mismatches\n' "$comparisons" "${#corpus[@]}" "$suites" "$failed"
printf 'Corpus suite failures: %s (reported separately from equivalence)\n' "$suite_failures"
[ "$failed" -eq 0 ]
