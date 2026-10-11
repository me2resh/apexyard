#!/bin/bash
# test_record_check_change_only.sh — a reconciliation is kept only when a
# criterion status changes. Otherwise one dated line goes to the Checks
# section of the plan notes (AgDR-0225, ac8-3). No network.

set -u
fail=0
real_root="$(cd "$(dirname "$0")/../../../.." && pwd)"
script="$real_root/.claude/skills/orbit/lib/record-check.sh"
sb=$(mktemp -d "${TMPDIR:-/tmp}/orbit-check-test.XXXXXX")

mk() { # file status-of-ac1-1
  printf '{"criterionAssessments":[{"criterionId":"ac1-1","status":"%s"},{"criterionId":"ac1-2","status":"not-verified"}]}\n' "$2" > "$1"
}
notes="$sb/notes.md"
printf '# Notes\n\n## Checks\n\nEach check that changes no status adds one line here.\n\n## After\n\ntext\n' > "$notes"

mk "$sb/prev.json" not-verified
mk "$sb/cand.json" not-verified
out=$("$script" --previous "$sb/prev.json" --candidate "$sb/cand.json" --notes "$notes" --commit abc1234 --date 2026-10-12)
[ "$out" = "unchanged" ] || { echo "FAIL: expected unchanged, got $out"; fail=1; }
[ ! -e "$sb/cand.json" ] || { echo "FAIL: unchanged candidate was kept"; fail=1; }
grep -qxF -- "- 2026-10-12, abc1234: checked, no change." "$notes" || { echo "FAIL: no dated line in the notes"; fail=1; }
# The line sits inside Checks, before the next heading.
line_no=$(grep -n 'checked, no change' "$notes" | cut -d: -f1)
after_no=$(grep -n '^## After' "$notes" | cut -d: -f1)
[ "$line_no" -lt "$after_no" ] || { echo "FAIL: line is not inside the Checks section"; fail=1; }

# Same check again adds no second line.
mk "$sb/cand.json" not-verified
"$script" --previous "$sb/prev.json" --candidate "$sb/cand.json" --notes "$notes" --commit abc1234 --date 2026-10-12 >/dev/null
[ "$(grep -c 'checked, no change' "$notes")" -eq 1 ] || { echo "FAIL: duplicate line"; fail=1; }

# A new commit adds a second line.
mk "$sb/cand.json" not-verified
"$script" --previous "$sb/prev.json" --candidate "$sb/cand.json" --notes "$notes" --commit def5678 --date 2026-10-13 >/dev/null
[ "$(grep -c 'checked, no change' "$notes")" -eq 2 ] || { echo "FAIL: second dated line missing"; fail=1; }

# A status change keeps the candidate and adds no line.
before=$(cat "$notes")
mk "$sb/cand.json" achieved
out=$("$script" --previous "$sb/prev.json" --candidate "$sb/cand.json" --notes "$notes" --commit fff9999 --date 2026-10-14)
[ "$out" = "changed: ac1-1" ] || { echo "FAIL: expected 'changed: ac1-1', got $out"; fail=1; }
[ -e "$sb/cand.json" ] || { echo "FAIL: changed candidate was deleted"; fail=1; }
[ "$(cat "$notes")" = "$before" ] || { echo "FAIL: notes changed on a status change"; fail=1; }

# A removed criterion counts as a change.
printf '{"criterionAssessments":[{"criterionId":"ac1-1","status":"not-verified"}]}\n' > "$sb/cand.json"
out=$("$script" --previous "$sb/prev.json" --candidate "$sb/cand.json" --notes "$notes" --commit 1111111 --date 2026-10-15)
[ "$out" = "changed: ac1-2" ] || { echo "FAIL: removed criterion not reported: $out"; fail=1; }

# The same file as previous and candidate is refused and nothing is deleted.
mk "$sb/same.json" not-verified
ln -s same.json "$sb/link.json"
before=$(cat "$notes")
for pair in "$sb/same.json $sb/same.json" "$sb/same.json $sb/link.json"; do
  set -- $pair
  out=$("$script" --previous "$1" --candidate "$2" --notes "$notes" --commit 2222222 --date 2026-10-16 2>&1); rc=$?
  [ "$rc" -eq 21 ] || { echo "FAIL: same-file case exit $rc, expected 21 ($out)"; fail=1; }
  case "$out" in *"same file"*) ;; *) echo "FAIL: no clear message: $out"; fail=1 ;; esac
  [ -e "$sb/same.json" ] || { echo "FAIL: same-file case deleted the record"; fail=1; }
  [ "$(cat "$notes")" = "$before" ] || { echo "FAIL: same-file case changed the notes"; fail=1; }
done

rm -rf "$sb"
[ "$fail" -eq 0 ] && echo "PASS: a reconciliation is written only on a status change"
exit "$fail"
