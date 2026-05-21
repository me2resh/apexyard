#!/bin/bash
# Site framework-counts drift detection.
#
# Asserts that the count claims quoted in site/*.html (and the markdown
# alternates site/*.md.gen, and llms.txt / llms-full.txt) match the actual
# framework counts on disk for skills, hooks, and roles. Fails the PR if
# any drift is detected; passes silently otherwise.
#
# Wired into CI via .github/workflows/site-counts-check.yml. Operators can
# also run this locally before pushing: `bash .claude/hooks/tests/test_site_counts.sh`.
#
# Rationale: docs/agdr/AgDR-0046-site-counts-drift-prevention.md.

set -u

# Resolve the framework root — the test sits at .claude/hooks/tests/,
# the framework root is two levels up.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

cd "$FRAMEWORK_ROOT" || {
  echo "FAIL: could not cd to framework root ($FRAMEWORK_ROOT)" >&2
  exit 1
}

# --- Compute actual counts ---------------------------------------------------

actual_skills=$(find .claude/skills -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')
actual_hooks=$(find .claude/hooks -maxdepth 1 -name '*.sh' ! -name '_lib*' 2>/dev/null | wc -l | tr -d ' ')
actual_roles=$(find roles -name '*.md' -not -name 'README*' -not -path '*/agdr/*' 2>/dev/null | wc -l | tr -d ' ')

if [ "$actual_skills" = "0" ] || [ "$actual_hooks" = "0" ] || [ "$actual_roles" = "0" ]; then
  echo "FAIL: one or more actual counts came out as zero — script is mis-positioned or framework layout changed:" >&2
  echo "  skills=$actual_skills hooks=$actual_hooks roles=$actual_roles" >&2
  exit 1
fi

echo "Actual framework counts:"
echo "  skills: $actual_skills"
echo "  hooks:  $actual_hooks"
echo "  roles:  $actual_roles"
echo

# --- Scan site files for drift -----------------------------------------------

DRIFT=0
FILES_TO_SCAN=(
  site/index.html
  site/architecture.html
  site/skills.html
  site/index.md.gen
  site/architecture.md.gen
  site/skills.md.gen
  site/llms.txt
  site/llms-full.txt
  site/skill.md
)

# Helper: scan a file for a regex like `<count> <noun>` and assert the count
# matches the expected actual.
#
# Args: $1=file, $2=expected_count, $3=noun (singular/plural pattern), $4=label
check_count() {
  local file="$1"
  local expected="$2"
  local noun_pattern="$3"
  local label="$4"

  [ -f "$file" ] || return 0

  # Match `<digits> <noun>` — case-insensitive, word-boundary on the noun.
  # Surface every match so a drift report names file + the matched number.
  local matches
  matches=$(grep -inE "[0-9]+ +${noun_pattern}" "$file" 2>/dev/null || true)

  [ -z "$matches" ] && return 0

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Extract the line number and the matched number.
    local lineno num
    lineno=$(echo "$line" | cut -d: -f1)
    num=$(echo "$line" | grep -oE "[0-9]+ +${noun_pattern}" | head -1 | grep -oE '^[0-9]+')

    [ -z "$num" ] && continue

    # Skip per-line opt-outs: lines tagged with `<!-- counts-check: skip -->`
    # or that contain "demo" / "demos" markers — these are illustrative
    # walkthrough copy describing a SPECIFIC ticket flow (e.g. "this demo
    # uses 6 skills"), not framework-total claims. The drift fence only
    # cares about framework totals.
    local line_content
    line_content=$(echo "$line" | cut -d: -f3-)
    if echo "$line_content" | grep -qE 'counts-check: *skip|demo__caption|<pre class="demo__body"'; then
      continue
    fi

    # Small numbers (<10) are almost never framework totals — the framework
    # has 19+ roles, 29+ hooks, 53+ skills. Pre-empts false positives in
    # narrative copy ("6 skills read one registry file" etc.).
    if [ "$num" -lt 10 ]; then
      continue
    fi

    if [ "$num" != "$expected" ]; then
      echo "DRIFT: $file:$lineno — claims $num $label, actual is $expected"
      DRIFT=$((DRIFT + 1))
    fi
  done <<< "$matches"
}

for f in "${FILES_TO_SCAN[@]}"; do
  # `N skills`  (covers "53 skills" anywhere; the most-quoted phrasing)
  check_count "$f" "$actual_skills" "skills"            "skills"
  # `N slash commands`  (the alternate phrasing on architecture.html + skills.html)
  check_count "$f" "$actual_skills" "slash +commands?"   "slash commands"
  # `N hooks`  + `N shell scripts` (the alternate phrasing in the layer card)
  check_count "$f" "$actual_hooks"  "hooks"             "hooks"
  check_count "$f" "$actual_hooks"  "shell +scripts?"    "shell scripts (hook count)"
  check_count "$f" "$actual_hooks"  "shell +gates?"      "shell gates (hook count)"
  check_count "$f" "$actual_hooks"  "mechanical +gates?" "mechanical gates (hook count)"
  check_count "$f" "$actual_hooks"  "shell +hooks?"      "shell hooks (hook count)"
  # `N roles`  (the role-count claim)
  check_count "$f" "$actual_roles"  "roles?"            "roles"
  check_count "$f" "$actual_roles"  "role +definitions" "role definitions"
done

# --- Verdict ------------------------------------------------------------------

if [ "$DRIFT" -gt 0 ]; then
  echo
  echo "FAIL: $DRIFT count-drift mismatch(es) detected in site/ marketing copy."
  echo
  echo "To fix: update the offending file(s) so quoted counts match the actuals above."
  echo "If you added a new skill/hook/role in this PR, the failure is expected — refresh"
  echo "the counts in site/*.html, site/*.md.gen, and site/llms*.txt in the same PR."
  exit 1
fi

echo "PASS: site framework counts match actuals across all scanned files."
exit 0
