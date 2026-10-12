#!/bin/bash
# Exact parser parity and process-launch budgets for #1613.
# Test inputs and reference regexes keep literal variables and backticks.
# shellcheck disable=SC2016
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=/dev/null
. "$ROOT/.claude/hooks/_lib-extract-pr.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() {
  if "$@"; then
    PASS=$((PASS+1))
  else
    printf 'FAIL: %s\n' "$*" >&2
    FAIL=$((FAIL+1))
  fi
}

# These reference bodies are verbatim from HEAD before the fast paths.
ref__has_argv_merge() {
  # Use tr, not ${1//$'\n'/ }: under macOS /bin/bash 3.2 that substitution
  # slows sharply with input size (about 2,000 lines took over a minute), and
  # a gate that times out does not block. tr is linear.
  local flat
  flat=$(printf '%s' "$1" | tr '\n' ' ')
  # Match each quote style separately so one kind cannot close another.
  # A backtick inside '…' or "…" (e.g. commit_message with inline code) must
  # stay inside that element. Optional JSON-style backslash before each
  # opener and closer (covers \"gh\" as well as "gh").
  local elem='([\\]?"[^"]*[\\]?"|[\\]?'\''[^'\'']*[\\]?'\''|[\\]?`[^`]*[\\]?`)'
  local comma='[[:space:]]*,[[:space:]]*'
  local argv_start='\[?[[:space:]]*'
  # Quoted flag/option elements between major tokens (e.g. '-R', 'o/r').
  local argv_flags="(${elem}${comma})*"
  # ≤20 chars of list-join / star-unpack glue, and at least one of ] [ + * ,
  # (#1552 shape 7). Space-only gaps between quoted tokens stay non-matches
  # so prose like '`gh` `pr` `merge`' does not look like an argv list.
  local glue='([][:space:]"`'"'"']){0,10}[][+*,]([][+*,[:space:]"`'"'"']){0,9}'
  # Binary element: optional path prefix and/or leading pad inside the quotes.
  local gh_elem='([\]?["'"'"'`]([^/"'"'"'`[:space:]]*/)*[[:space:]]*gh[\]?["'"'"'`])'
  local glab_elem='([\]?["'"'"'`]([^/"'"'"'`[:space:]]*/)*[[:space:]]*glab[\]?["'"'"'`])'
  local pr_elem='([\]?["'"'"'`]pr[\]?["'"'"'`])'
  local mr_elem='([\]?["'"'"'`]mr[\]?["'"'"'`])'
  local merge_elem='([\]?["'"'"'`]merge[\]?["'"'"'`])'
  local api_tok='([\]?["'"'"'`]api[\]?["'"'"'`])'
  local open_q='([\\]?"|[\\]?'\''|[\\]?`)'

  # Classic comma-separated argv, with optional global flags between tokens.
  if printf '%s\n' "$flat" | grep -qE "${gh_elem}${comma}${argv_start}${argv_flags}${pr_elem}${comma}${merge_elem}"; then
    return 0
  fi
  # Joined lists / star-unpacking with a bounded glue gap (#1552 shape 7).
  if printf '%s\n' "$flat" | grep -qE "${gh_elem}${glue}${pr_elem}${glue}${merge_elem}"; then
    return 0
  fi
  # One element holds the remainder: 'gh' then a quoted "pr merge …" (#1552 shape 5).
  if printf '%s\n' "$flat" | grep -qE "${gh_elem}${glue}${open_q}pr[[:space:]]+merge\b"; then
    return 0
  fi
  # glab mr merge argv (with optional flags or glue).
  if printf '%s\n' "$flat" | grep -qE "${glab_elem}${comma}${argv_start}${argv_flags}${mr_elem}${comma}${merge_elem}"; then
    return 0
  fi
  if printf '%s\n' "$flat" | grep -qE "${glab_elem}${glue}${mr_elem}${glue}${merge_elem}"; then
    return 0
  fi

  # The same argv shape can call the GitHub API merge endpoint directly.
  # Intermediate quoted args may contain commas (e.g. '-f', 'm=a,b') and
  # backticks (e.g. commit_message with inline code).
  local api_elem='([\\]?"[^"[:space:],]*/pulls/[0-9]+/merge([?][^"[:space:],]*)?[\\]?"|[\\]?'\''[^'\''[:space:],]*/pulls/[0-9]+/merge([?][^'\''[:space:],]*)?[\\]?'\''|[\\]?`[^`[:space:],]*/pulls/[0-9]+/merge([?][^`[:space:],]*)?[\\]?`)'
  local argv_any="(${elem}${comma})*"
  printf '%s\n' "$flat" | grep -qE "${gh_elem}${comma}${argv_start}${api_tok}${comma}${argv_any}${api_elem}"
}

ref__join_shell_continuations() {
  join_shell_continuations "$1"
}

ref__forge_from_command() {
  if echo "${1:-}" | grep -qE '\bglab\s+(mr|api)\b'; then echo glab; else echo gh; fi
}

inputs=(
  ''
  'gh pr merge 5 --repo a/b'
  'gh pr merge 300 --repo me2resh/apexyard --squash'
  'glab mr merge 7 -R a/b'
  'gh api repos/a/b/pulls/42/merge -X PUT'
  'glab api projects/a%2Fb/merge_requests/7/merge'
  'echo hello'
  'plain text'
  "single ' quote"
  'backtick ` only'
  'double " quote'
  '# gh pr merge 5'
  '# glab mr merge 7'
  'python3 -c "subprocess.run(['"'"'gh'"'"','"'"'pr'"'"','"'"'merge'"'"','"'"'5'"'"'])"'
  'node -e "spawnSync(['"'"'gh'"'"','"'"'pr'"'"','"'"'merge'"'"','"'"'5'"'"'])"'
  '["gh", "pr", "merge", "5"]'
  "['gh','pr','merge','5']"
  '[`gh`,`pr`,`merge`,`5`]'
  '["glab", "mr", "merge", "7"]'
  "['glab','mr','merge','7']"
  '["gh", "api", "repos/a/b/pulls/42/merge"]'
  '["gh", "-R", "a/b", "pr", "merge", "5"]'
  '["/usr/bin/gh", "pr", "merge", "5"]'
  '["gh"] + ["pr"] + ["merge", "5"]'
  'glab nonsense'
  'notglab mr merge'
  'tracker_pr_merge "$REPO" 8 squash'
  'gh pr merge "$PR"'
  $'gh pr \\\nmerge 5'
  $'gh p\\\nr merge 5'
  $'# comment \\\ngh pr merge 5'
  $'echo "quoted \\\ntext"'
  $'echo \'single \\\ntext\''
  $'gh pr merge 5\nglab mr merge 7'
  $'plain text\n'
  $'\n\n'
  $'["gh",\n"pr",\n"merge", "5"]'
  $'glab\nmr merge 7'
  'literal\backslash'
)
for input in "${inputs[@]}"; do
  for fn in _has_argv_merge _join_shell_continuations _forge_from_command; do
    "$fn" "$input" > "$TMP/new"
    actual_rc=$?
    "ref_$fn" "$input" > "$TMP/ref"
    reference_rc=$?
    check test "$actual_rc" -eq "$reference_rc"
    check cmp "$TMP/new" "$TMP/ref"
  done
done
# Expected outputs and statuses were measured with the original library.
commands=(
  'gh pr merge 5 --repo a/b'
  'gh api repos/a/b/pulls/42/merge -X PUT'
  'glab api projects/a%2Fb/merge_requests/7/merge'
  'gh pr merge "$PR" --repo a/b'
  'gh pr merge 5 --repo "$REPO"'
  ' tracker_pr_merge "$REPO" 8 squash'
  ' tracker_pr_merge a/b "$PR" squash'
  ' tracker_pr_merge a/b 8 squash'
  'echo hello'
  'glab mr merge 9 -R a/b'
  'gh api repos/a/b/pulls/42/notes'
  'glab api projects/a%2Fb/merge_requests/7/notes'
  'gh pr merge --squash'
  'gh pr merge 300 --repo me2resh/apexyard --squash'
)
expected_pr=(5 42 7 '' 5 8 '' 8 '' 9 '' '' '' 300)
expected_variable=(1 1 1 0 0 0 0 1 1 1 1 1 1 1)
for ((i=0; i<${#commands[@]}; i++)); do
  out=$(extract_pr_number "${commands[$i]}")
  rc=$?
  check test "$rc" -eq 0
  check test "$out" = "${expected_pr[$i]}"
  merge_command_uses_variable "${commands[$i]}"
  rc=$?
  check test "$rc" -eq "${expected_variable[$i]}"
done
# Shims count launches without changing tool output or status.
mkdir "$TMP/tools" "$TMP/no-awk"
LOG="$TMP/launches"
export LOG
for tool in awk grep tr sed head; do
  real=$(command -v "$tool")
  printf '#!/bin/bash\nprintf "%%s\\n" "%s" >> "$LOG"\nexec "%s" "$@"\n' "$tool" "$real" > "$TMP/tools/$tool"
  chmod +x "$TMP/tools/$tool"
  [ "$tool" = awk ] || cp "$TMP/tools/$tool" "$TMP/no-awk/$tool"
done
old_path=$PATH
PATH="$TMP/tools:$PATH"
: > "$LOG"
_has_argv_merge 'gh pr merge 5 --repo a/b'
check test "$?" -eq 1
_join_shell_continuations 'gh pr merge 5 --repo a/b' > "$TMP/joined"
check test "$?" -eq 0
check test "$(< "$TMP/joined")" = 'gh pr merge 5 --repo a/b'
_forge_from_command 'gh pr merge 5' > "$TMP/forge"
check test "$?" -eq 0
check test "$(< "$TMP/forge")" = gh
check test ! -s "$LOG"
: > "$LOG"
_join_shell_continuations $'gh pr \\\nmerge 5' > "$TMP/joined"
check test "$?" -eq 0
check test "$(< "$TMP/joined")" = 'gh pr merge 5'
check grep -q '^awk$' "$LOG"
_has_argv_merge 'python3 -c "subprocess.run(['"'"'gh'"'"','"'"'pr'"'"','"'"'merge'"'"','"'"'5'"'"'])"'
check test "$?" -eq 0
# Original missing-awk output is raw input plus its broad-space copy.
# Keep core tools available while exercising the missing-awk path.
# shellcheck disable=SC2123
PATH="$TMP/no-awk"
: > "$LOG"
_join_shell_continuations 'plain text' > "$TMP/fallback"
check test "$?" -eq 0
check test "$(< "$TMP/fallback")" = $'plain text\nplain text'
check grep -q '^tr$' "$LOG"
ref__join_shell_continuations 'plain text' > "$TMP/reference-fallback"
check test "$?" -eq 0
PATH=$old_path
check cmp "$TMP/fallback" "$TMP/reference-fallback"
printf 'extract PR fast paths: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
