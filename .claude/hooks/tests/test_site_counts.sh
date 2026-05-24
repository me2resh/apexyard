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

# Helper: multi-line lookback. The per-line check_count misses claims where
# the digit and noun straddle a line break (e.g. `<digits>\n   <noun>` —
# the common shape in `site/llms-full.txt`'s wrapped layer-card prose).
# This pass flattens consecutive whitespace (including newlines) and
# re-scans. Reports `file:multiline` as the locus when a flattened-only
# match fires; same-line matches are already covered by check_count and
# de-duped here.
#
# Closes #342's § 2(b) (multiline-flatten pre-pass).
check_multiline_count() {
  local file="$1" expected="$2" noun_pattern="$3" label="$4"
  [ -f "$file" ] || return 0

  # Per-line numbers already reported (for any pattern in this file) —
  # used to de-dupe so a same-line match doesn't get double-reported by
  # the multiline pass.
  local seen_same_line
  seen_same_line=$(grep -oE "[0-9]+ +${noun_pattern}" "$file" 2>/dev/null \
    | grep -oE '^[0-9]+' | sort -u | tr '\n' '|')

  # Flatten + scan + dedupe.
  local flat_matches
  flat_matches=$(tr '\n' ' ' < "$file" | tr -s '[:space:]' ' ' \
    | grep -oE "[0-9]+ +${noun_pattern}" 2>/dev/null | sort -u)

  while IFS= read -r match; do
    [ -z "$match" ] && continue
    local num
    num=$(echo "$match" | grep -oE '^[0-9]+')
    [ -z "$num" ] && continue
    # Skip small numbers (narrative copy; same heuristic as check_count).
    [ "$num" -lt 10 ] && continue
    # Skip if this digit already appeared on a single line (avoid
    # double-counting — check_count's report has the line number).
    case "|$seen_same_line" in
      *"|$num|"*) continue ;;
    esac
    if [ "$num" != "$expected" ]; then
      echo "DRIFT: $file:multiline — claims $num $label (across newline), actual is $expected"
      DRIFT=$((DRIFT + 1))
    fi
  done <<< "$flat_matches"
}

for f in "${FILES_TO_SCAN[@]}"; do
  check_multiline_count "$f" "$actual_skills" "skills"            "skills"
  check_multiline_count "$f" "$actual_skills" "slash +commands?"   "slash commands"
  check_multiline_count "$f" "$actual_hooks"  "hooks"             "hooks"
  check_multiline_count "$f" "$actual_hooks"  "shell +scripts?"    "shell scripts (hook count)"
  check_multiline_count "$f" "$actual_hooks"  "shell +gates?"      "shell gates (hook count)"
  check_multiline_count "$f" "$actual_hooks"  "mechanical +gates?" "mechanical gates (hook count)"
  check_multiline_count "$f" "$actual_hooks"  "shell +hooks?"      "shell hooks (hook count)"
  check_multiline_count "$f" "$actual_roles"  "roles?"            "roles"
  check_multiline_count "$f" "$actual_roles"  "role +definitions" "role definitions"
done

# --- Self-test: prove the multiline pass actually catches what the per-line
# --- pass would miss. Synthesise a temp file with a known-bad cross-line
# --- claim (`52\n   slash commands` — the exact shape #342 § 2(b) names)
# --- and run the multiline detector against it inside a subshell so its
# --- DRIFT++ stays isolated. Assert the expected output line; if absent,
# --- the detector is broken — bump DRIFT to fail the suite.
SYNTHETIC_FIXTURE=$(mktemp -t "test_site_counts_multiline.XXXXXX")
cat > "$SYNTHETIC_FIXTURE" <<'FIXTURE'
2. **Capability layer** — the runnable spec: `.claude/skills/` (52
   slash commands), `.claude/agents/` (23 sub-agents).
FIXTURE

self_test_output=$(check_multiline_count "$SYNTHETIC_FIXTURE" "$actual_skills" "slash +commands?" "slash commands (self-test)" 2>&1)
rm -f "$SYNTHETIC_FIXTURE"

if ! echo "$self_test_output" | grep -qE 'DRIFT:.*:multiline — claims 52 slash commands'; then
  echo "FAIL: multiline-detector self-test did not fire on a known-bad fixture"
  echo "      output was: $self_test_output"
  DRIFT=$((DRIFT + 1))
fi

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

# --- LLM payload-size meta tags (#333 item C) ---
# Each main marketing page carries <meta name="llm:token-count" content="N">
# and <meta name="llm:doc-length" content="M chars">. The token estimate is
# chars/4 — a cross-vendor approximation. This check enforces the meta
# values stay within 5% of the actual chars/4 (catches drift when a page
# is edited without refreshing the meta tags). 5% tolerance handles:
#   - The meta-tag self-impact (the tags themselves add ~150 bytes)
#   - Small content edits that don't justify a meta refresh
# Anything beyond 5% means the page has materially changed and the meta
# should be re-measured.
LLM_DRIFT=0
echo
echo "LLM payload-size meta tags (per-page token-count + doc-length):"
for f in site/index.html site/architecture.html site/skills.html; do
  [ -f "$f" ] || continue
  actual_chars=$(wc -c < "$f" | tr -d ' ')
  actual_tokens=$((actual_chars / 4))

  meta_tokens=$(grep -oE 'name="llm:token-count" content="[0-9]+"' "$f" 2>/dev/null \
    | grep -oE '[0-9]+' | head -1)
  meta_chars=$(grep -oE 'name="llm:doc-length" content="[0-9]+ chars"' "$f" 2>/dev/null \
    | grep -oE '[0-9]+' | head -1)

  if [ -z "$meta_tokens" ] || [ -z "$meta_chars" ]; then
    echo "  DRIFT: $f — missing llm:token-count or llm:doc-length meta tag"
    LLM_DRIFT=$((LLM_DRIFT + 1))
    continue
  fi

  # Tolerance: 5% in either direction. Use integer arithmetic.
  diff_tokens=$(( actual_tokens > meta_tokens ? actual_tokens - meta_tokens : meta_tokens - actual_tokens ))
  pct_tokens=$(( actual_tokens > 0 ? diff_tokens * 100 / actual_tokens : 0 ))

  diff_chars=$(( actual_chars > meta_chars ? actual_chars - meta_chars : meta_chars - actual_chars ))
  pct_chars=$(( actual_chars > 0 ? diff_chars * 100 / actual_chars : 0 ))

  if [ "$pct_tokens" -gt 5 ] || [ "$pct_chars" -gt 5 ]; then
    echo "  DRIFT: $f — meta token-count=$meta_tokens chars=$meta_chars vs actual tokens=$actual_tokens chars=$actual_chars (diff: ${pct_tokens}% tokens / ${pct_chars}% chars; >5% tolerance)"
    LLM_DRIFT=$((LLM_DRIFT + 1))
  else
    echo "  ok   $f — meta=$meta_tokens tok / $meta_chars chars vs actual=$actual_tokens tok / $actual_chars chars (within 5%)"
  fi
done

if [ "$LLM_DRIFT" -gt 0 ]; then
  echo
  echo "FAIL: $LLM_DRIFT LLM-meta mismatch(es). Refresh the <meta name=\"llm:*\"> tags."
  echo "To recompute: wc -c < <file> for chars; tokens ≈ chars / 4."
  exit 1
fi

echo "PASS: site framework counts match actuals across all scanned files."
exit 0
