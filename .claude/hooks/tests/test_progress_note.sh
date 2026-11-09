#!/bin/bash
# Offline progress-note lifecycle and SessionStart fixtures. Bash 3.2.
set -euo pipefail
# The assertions are bare commands. Name the failing line, so a CI failure is readable.
trap 'printf "FAIL line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=/dev/null
. "$ROOT/.claude/hooks/_lib-progress-note.sh"
mkdir "$TMP/tree"
git -C "$TMP/tree" init -q
printf 'repo=owner/repo\nnumber=42\n' > "$TMP/tree/.git/apexyard-ticket"
progress_note_create "$TMP/tree"
note="$TMP/tree/.git/apexyard-progress.md"
[ "$(wc -l < "$note" | tr -d ' ')" = 6 ]
for field in Task Outputs Completed Decisions 'Open issues' 'Next action'; do
  grep -q "^$field: " "$note"
done
for stage in 'PR opened' 'CI result' 'Review verdict' 'Fix pushed' Merge; do
  progress_note_update "$TMP/tree" Completed "$stage: evidence at SHA abc"
done
for stage in 'PR opened' 'CI result' 'Review verdict' 'Fix pushed' Merge; do
  grep -q "$stage: evidence at SHA abc" "$note"
done
progress_note_update "$TMP/tree" 'Next action' $'Check CI\nthen review'
grep -qx 'Next action: Check CI then review' "$note"
cp "$note" "$TMP/saved"
progress_note_create "$TMP/tree"
cmp "$note" "$TMP/saved"
if progress_note_update "$TMP/tree" invalid value; then exit 1; fi
cmp "$note" "$TMP/saved"
mkdir "$note.lock"
if progress_note_update "$TMP/tree" Decisions lost 2> "$TMP/lock-error"; then exit 1; fi
cmp "$note" "$TMP/saved"
rmdir "$note.lock"
# A failed rename preserves the old note and removes its temporary file.
# The library invokes this fixture override indirectly.
# shellcheck disable=SC2329
if (mv() { return 1; }; progress_note_update "$TMP/tree" Decisions lost); then exit 1; fi
cmp "$note" "$TMP/saved"
[ ! -d "$note.lock" ]
for leftover in "$note".tmp.*; do [ ! -e "$leftover" ]; done
# Concurrent attempts either append their evidence or report a lock conflict.
for i in 1 2 3 4 5 6; do
  (
    if progress_note_update "$TMP/tree" Completed "writer-$i" 2> "$TMP/error-$i"; then
      touch "$TMP/success-$i"
    fi
  ) &
done
wait
for i in 1 2 3 4 5 6; do
  if [ -f "$TMP/success-$i" ]; then grep -q "writer-$i" "$note"; fi
done
for source in startup compact; do
  jq -cn --arg cwd "$TMP/tree" --arg source "$source" '{cwd:$cwd,source:$source}' |
    bash "$ROOT/.claude/hooks/print-progress-note.sh" > "$TMP/out"
  grep -q 'age: 0 hours' "$TMP/out"
  grep -q 'Task: owner/repo#42' "$TMP/out"
  if grep -q WARN "$TMP/out"; then exit 1; fi
done
touch -t 202001010000 "$note"
jq -cn --arg cwd "$TMP/tree" '{cwd:$cwd,source:"compact"}' |
  bash "$ROOT/.claude/hooks/print-progress-note.sh" > "$TMP/out"
grep -q 'older than 24 hours' "$TMP/out"
# Ignore arbitrary appended prose and bound a very long field.
printf '\nUnrelated prose\n' >> "$note"
progress_note_update "$TMP/tree" Decisions "$(printf '%3000s' x)"
progress_note_print "$TMP/tree" > "$TMP/out"
[ "$(wc -l < "$TMP/out")" -le 8 ]
if grep -q 'Unrelated prose' "$TMP/out"; then exit 1; fi
awk 'length>2100 {exit 1}' "$TMP/out"
# A switched marker must not display the preceding ticket's state.
printf 'repo=owner/repo\nnumber=43\n' > "$TMP/tree/.git/apexyard-ticket"
[ -z "$(progress_note_print "$TMP/tree")" ]
progress_note_create "$TMP/tree"
grep -qx 'Task: owner/repo#43' "$note"
if grep -q 'PR opened' "$note"; then exit 1; fi
rm "$TMP/tree/.git/apexyard-ticket"
[ -z "$(progress_note_print "$TMP/tree")" ]
if progress_note_create "$TMP/tree"; then exit 1; fi
# Linked worktrees have independent notes in their own git directories.
git -C "$TMP/tree" -c user.name=Test -c user.email=test@example.test commit --allow-empty -qm fixture
git -C "$TMP/tree" worktree add -qb ticket "$TMP/linked"
dir=$(git -C "$TMP/linked" rev-parse --absolute-git-dir)
printf 'repo=owner/repo\nnumber=44\n' > "$dir/apexyard-ticket"
progress_note_create "$TMP/linked"
grep -qx 'Task: owner/repo#44' "$dir/apexyard-progress.md"
grep -qx 'Task: owner/repo#43' "$note"
# Skill and brief wiring must retain the shared evidence condition.
for file in docs/progress-notes.md .claude/skills/fan-out/SKILL.md .claude/rules/reconcile-before-build.md; do
  grep -q 'acceptance criteria' "$ROOT/$file"
  grep -q 'CI green on the current head SHA, Rex APPROVED at that head, progress note current' "$ROOT/$file"
  grep -q '20 turns' "$ROOT/$file"
  grep -q 'report the blocker with evidence' "$ROOT/$file"
done
for file in docs/progress-notes.md .claude/rules/pr-workflow.md; do
  grep -q 'PR opened, CI result, review verdict, fix pushed, and merge' "$ROOT/$file"
  grep -q 'progress_note_update' "$ROOT/$file"
done
for skill in start-ticket code-review approve-merge; do
  grep -q 'Details: docs/progress-notes.md.' "$ROOT/.claude/skills/$skill/SKILL.md"
done
printf 'PASS: progress note lifecycle, SessionStart, and workflow wiring\n'
