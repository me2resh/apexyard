#!/bin/bash
# test_record_check_blank_line.sh — a new or empty Checks section has one
# blank line under the heading. A later entry adds no extra blank line.
# No network.

set -u
fail=0
real_root="$(cd "$(dirname "$0")/../../../.." && pwd)"
script="$real_root/.claude/skills/orbit/lib/record-check.sh"
sb=$(mktemp -d "${TMPDIR:-/tmp}/orbit-check-blank-test.XXXXXX")

mk() { # file status-of-ac1-1
  printf '{"criterionAssessments":[{"criterionId":"ac1-1","status":"%s"},{"criterionId":"ac1-2","status":"not-verified"}]}\n' "$2" > "$1"
}

# Run one unchanged check. Both records carry the same status.
unchanged() { # notes commit date
  mk "$sb/prev.json" not-verified
  mk "$sb/cand.json" not-verified
  out=$("$script" --previous "$sb/prev.json" --candidate "$sb/cand.json" --notes "$1" --commit "$2" --date "$3") || {
    echo "FAIL: record-check exited non-zero"
    fail=1
    return
  }
  [ "$out" = "unchanged" ] || { echo "FAIL: expected unchanged, got $out"; fail=1; }
}

expect_file() { # actual expected label
  cmp -s "$1" "$2" || { echo "FAIL: $3 notes differ"; diff -u "$2" "$1" || true; fail=1; }
}

# No consecutive blank lines. Headings and lists have the required blank lines.
lint_notes() { # file label
  msg=$(awk '
    { lines[NR] = $0 }
    END {
      prev_blank = 0
      for (i = 1; i <= NR; i++) {
        blank = (lines[i] ~ /^[[:space:]]*$/)
        if (blank && prev_blank) {
          printf "consecutive blank lines at line %d\n", i
          exit 1
        }
        if (lines[i] ~ /^- / && i > 1 && !prev_blank && lines[i - 1] !~ /^- /) {
          printf "no blank line before list at line %d\n", i
          exit 1
        }
        if (lines[i] ~ /^## /) {
          if (i == 1 || lines[i - 1] !~ /^[[:space:]]*$/) {
            printf "no blank line before heading at line %d\n", i
            exit 1
          }
          if (i == NR || lines[i + 1] !~ /^[[:space:]]*$/) {
            printf "no blank line after heading at line %d\n", i
            exit 1
          }
        }
        prev_blank = blank
      }
    }' "$1") || { echo "FAIL: $2 layout: $msg"; fail=1; }
}

# A. No Checks section yet. The new heading has one blank line, then the entry.
notes="$sb/notes.md"
printf '# Notes\n\ntext\n' > "$notes"
unchanged "$notes" abc1234 2026-10-12
exp="$sb/exp-a.md"
printf '# Notes\n\ntext\n\n## Checks\n\n- 2026-10-12, abc1234: checked, no change.\n' > "$exp"
expect_file "$notes" "$exp" "case A"
cp "$notes" "$sb/case-a.md"

# B. A second entry follows the first with no blank line between them.
unchanged "$notes" def5678 2026-10-13
exp="$sb/exp-b.md"
printf '# Notes\n\ntext\n\n## Checks\n\n- 2026-10-12, abc1234: checked, no change.\n- 2026-10-13, def5678: checked, no change.\n' > "$exp"
expect_file "$notes" "$exp" "case B"
cp "$notes" "$sb/case-b.md"

# C. Prose has one blank line before the entry and before the next heading.
notes="$sb/notes-c.md"
printf '# Notes\n\n## Checks\n\nIntro line.\n\n## After\n\ntext\n' > "$notes"
unchanged "$notes" abc1234 2026-10-12
exp="$sb/exp-c.md"
printf '# Notes\n\n## Checks\n\nIntro line.\n\n- 2026-10-12, abc1234: checked, no change.\n\n## After\n\ntext\n' > "$exp"
expect_file "$notes" "$exp" "case C"
cp "$notes" "$sb/case-c.md"

# D. An empty section before a heading gains a blank line on each side of the entry.
notes="$sb/notes-d.md"
printf '# Notes\n\n## Checks\n## After\n\ntext\n' > "$notes"
unchanged "$notes" abc1234 2026-10-12
exp="$sb/exp-d.md"
printf '# Notes\n\n## Checks\n\n- 2026-10-12, abc1234: checked, no change.\n\n## After\n\ntext\n' > "$exp"
expect_file "$notes" "$exp" "case D"
cp "$notes" "$sb/case-d.md"

for f in "$sb/case-a.md" "$sb/case-b.md" "$sb/case-c.md" "$sb/case-d.md"; do
  lint_notes "$f" "$f"
done

if command -v markdownlint-cli2 >/dev/null 2>&1; then
  for f in "$sb/case-a.md" "$sb/case-b.md" "$sb/case-c.md" "$sb/case-d.md"; do
    markdownlint-cli2 "$f" || { echo "FAIL: markdownlint-cli2 $f"; fail=1; }
  done
else
  echo "NOTE: markdownlint-cli2 is not on PATH. The awk layout check ran instead."
fi

rm -rf "$sb"
[ "$fail" -eq 0 ] && echo "PASS: Checks entries keep a blank line under the heading"
exit "$fail"
