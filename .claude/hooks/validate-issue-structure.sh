#!/bin/bash
# Validates `gh issue create` body shape per title prefix.
#
# Fires on PreToolUse Bash(gh issue create …). Enforces the team's ticket
# schema (required sections per bracketed prefix) as a mechanical backstop
# for the /feature, /task, /bug skills: agents that bypass the interactive
# skills and file raw `gh issue create` calls with bespoke body shapes get
# blocked here with a message that names the missing sections and points
# at the matching skill.
#
# Schema source:
#   .claude/project-config.defaults.json → .ticket.required_sections (map)
#   .claude/project-config.json          → user overrides (shallow-merged)
# Read via the shared _lib-read-config.sh landed in apexyard#109. If the
# lib is missing (very bare checkout), the hook falls back to inlined
# defaults that match the shipped schema.
#
# Behaviour:
#   - Non-`gh issue create` command          → exit 0 silently.
#   - No body (interactive issue editor)     → exit 0 silently.
#   - Skip marker in body                    → exit 0, WARN on stderr.
#   - Prefix not in prefix_whitelist         → exit 2, name accepted prefixes.
#   - Prefix has no schema entry             → exit 0 silently (nothing to check).
#   - Required section missing (or empty)    → exit 2 with per-section messages.
#   - Config lib + defaults both absent      → exit 0 silently (no-op).
#
# Section matching:
#   - Case-insensitive.
#   - Whitespace-tolerant: `## User Story`, `##  User  Story`, `##User Story`.
#   - Slash variants are canonicalised: a section named "Given / When / Then"
#     matches headings like `## Given/When/Then`, `## Given / When / Then`,
#     `## given when then`. Slashes and the spaces around them are optional.
#   - Content check: the heading must be followed by at least one non-empty,
#     non-heading line before the next `##` heading.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Only fire on `gh issue create`. Any other invocation is a silent no-op.
if ! echo "$COMMAND" | grep -qE '\bgh\s+issue\s+create\b'; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Arg extraction — lifted from block-private-refs-in-public-repos.sh so that
# quoting / spacing variants are handled consistently across the gh hooks.
# ---------------------------------------------------------------------------

extract_flag_value() {
  # $1 = python-flag regex (e.g. --title|-t). Matches (possibly multi-line):
  #   --title "value"
  #   --title 'value'
  #   --title value
  #
  # Agents commonly pass `--body "…literal newlines…"`, so the extractor
  # must handle multi-line values. Portable awk doesn't have a reliable way
  # to consume stdin as a single record (`RS="\0"` triggers paragraph mode
  # on BSD awk), so we build up one big string line-by-line in awk and run
  # match() against it in END.
  #
  # Quoted-value regex is GREEDY and anchored on the next flag boundary
  # (whitespace + `--<letter>`) or end-of-string. The earlier non-greedy
  # form `"([^"]*)"` truncated values at the first embedded double quote
  # (me2resh/apexyard#227), so bodies that quoted prose like "admin notice"
  # in a `## Scope` bullet lost every `##` heading that lived past the
  # first internal `"`. Greedy + boundary anchor matches the closing `"`
  # of the FLAG argument, not the first internal `"` inside the body.
  # Backslash-escaped quotes (`\"...\"`) are not detected — they pass
  # through as content, which is fine because shell-quoted heredoc bodies
  # (the `$(cat <<'EOF' ... EOF)` shape Claude generates) don't produce
  # backslash escapes.
  local flag_re="$1"
  local cmd="$2"
  printf '%s' "$cmd" | awk -v FLAG_RE="$flag_re" -v SQ="'" '
    { buf = (NR == 1 ? $0 : buf "\n" $0) }
    END {
      s = buf
      # Double-quoted value: greedy `(.*)` anchored on next flag or EOS.
      re = "(" FLAG_RE ")[[:space:]]+\"(.*)\"([[:space:]]+--[a-zA-Z]|[[:space:]]*$)"
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^(" FLAG_RE ")[[:space:]]+\"", "", chunk)
        sub("\"([[:space:]]+--[a-zA-Z].*)?$", "", chunk)
        sub("\"[[:space:]]*$", "", chunk)
        print chunk
        exit
      }
      # Single-quoted value: same greedy + anchor treatment.
      re = "(" FLAG_RE ")[[:space:]]+" SQ "(.*)" SQ "([[:space:]]+--[a-zA-Z]|[[:space:]]*$)"
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^(" FLAG_RE ")[[:space:]]+" SQ, "", chunk)
        sub(SQ "([[:space:]]+--[a-zA-Z].*)?$", "", chunk)
        sub(SQ "[[:space:]]*$", "", chunk)
        print chunk
        exit
      }
      # Unquoted value: single token, embedded quotes irrelevant.
      re = "(" FLAG_RE ")[[:space:]]+[^[:space:]]+"
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^(" FLAG_RE ")[[:space:]]+", "", chunk)
        print chunk
        exit
      }
    }
  '
}

TITLE=$(extract_flag_value '--title|-t' "$COMMAND")
BODY=$(extract_flag_value '--body|-b' "$COMMAND")

# --body-file <path> / -F <path> (only when -F's value is NOT a key=val pair,
# because some gh shapes reuse -F for field values).
BODY_FILE=$(extract_flag_value '--body-file' "$COMMAND")
if [ -z "$BODY_FILE" ]; then
  F_VAL=$(echo "$COMMAND" | sed -nE "s/.*(^|[[:space:]])-F[[:space:]]+\"([^\"]*)\".*/\2/p" | head -1)
  if [ -z "$F_VAL" ]; then
    F_VAL=$(echo "$COMMAND" | sed -nE "s/.*(^|[[:space:]])-F[[:space:]]+'([^']*)'.*/\2/p" | head -1)
  fi
  if [ -z "$F_VAL" ]; then
    F_VAL=$(echo "$COMMAND" | sed -nE "s/.*(^|[[:space:]])-F[[:space:]]+([^[:space:]]+).*/\2/p" | head -1)
  fi
  if [ -n "$F_VAL" ] && ! echo "$F_VAL" | grep -q '='; then
    BODY_FILE="$F_VAL"
  fi
fi

BODY_FILE_CONTENT=""
if [ -n "$BODY_FILE" ] && [ -f "$BODY_FILE" ]; then
  BODY_FILE_CONTENT=$(cat "$BODY_FILE" 2>/dev/null)
fi

# Full body text to inspect — inline --body and/or file contents.
FULL_BODY=$(printf '%s\n%s\n' "$BODY" "$BODY_FILE_CONTENT")

# Strip the leading / trailing blank line the printf inevitably adds, so
# "empty body" detection is accurate.
BODY_STRIPPED=$(echo "$FULL_BODY" | tr -d '[:space:]')

if [ -z "$BODY_STRIPPED" ]; then
  # No body — `gh issue create` opens the editor. Nothing to validate.
  exit 0
fi

# ---------------------------------------------------------------------------
# Config: load prefix_whitelist, required_sections, skip_marker.
# ---------------------------------------------------------------------------

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
PREFIX_WHITELIST=""
SKIP_MARKER=""
HAVE_CONFIG_LIB=0

if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.claude/hooks/_lib-read-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$REPO_ROOT/.claude/hooks/_lib-read-config.sh"
  HAVE_CONFIG_LIB=1
  PREFIX_WHITELIST=$(config_get '.ticket.prefix_whitelist[]' 2>/dev/null | tr '\n' ' ')
  SKIP_MARKER=$(config_get_or '.ticket.skip_marker' '<!-- validate-issue-structure: skip -->' 2>/dev/null)
fi

# Inline defaults for bare checkouts predating apexyard#109. Mirror the
# shipped .claude/project-config.defaults.json so behaviour is identical.
if [ -z "$PREFIX_WHITELIST" ]; then
  PREFIX_WHITELIST="Feature Bug Chore Refactor Testing CI Docs Spike"
fi
SKIP_MARKER="${SKIP_MARKER:-<!-- validate-issue-structure: skip -->}"

# ---------------------------------------------------------------------------
# Skip marker — visible bypass, logs to stderr.
# ---------------------------------------------------------------------------

if echo "$FULL_BODY" | grep -qF -- "$SKIP_MARKER"; then
  echo "WARN: $SKIP_MARKER present — validate-issue-structure bypassed." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Extract title prefix: `[Feature]`, `[Bug]`, etc. Leading whitespace allowed.
# Case-insensitive whitelist check.
# ---------------------------------------------------------------------------

if [ -z "$TITLE" ]; then
  # Title not resolvable — likely an unusual invocation shape; hook cannot
  # meaningfully validate body against prefix. Fall through to prefix-less
  # handling (no-op).
  exit 0
fi

PREFIX=$(echo "$TITLE" | sed -nE 's/^[[:space:]]*\[([A-Za-z]+)\].*/\1/p' | head -1)

if [ -z "$PREFIX" ]; then
  # No bracketed prefix — nothing to key the schema on. Let it through; the
  # hook only enforces shape when a prefix is declared.
  exit 0
fi

# Case-insensitive whitelist match. Capture the canonical-cased name from
# the whitelist so downstream lookups hit the JSON key exactly.
PREFIX_LC=$(echo "$PREFIX" | tr '[:upper:]' '[:lower:]')
CANONICAL_PREFIX=""
for p in $PREFIX_WHITELIST; do
  p_lc=$(echo "$p" | tr '[:upper:]' '[:lower:]')
  if [ "$p_lc" = "$PREFIX_LC" ]; then
    CANONICAL_PREFIX="$p"
    break
  fi
done

if [ -z "$CANONICAL_PREFIX" ]; then
  # Prefix not on the whitelist.
  ACCEPTED=$(echo "$PREFIX_WHITELIST" | sed -E 's/[[:space:]]+/, /g; s/, $//')
  cat >&2 <<MSG
BLOCKED: issue title '[${PREFIX}]' uses an unrecognised prefix.

Accepted prefixes (from .claude/project-config.*.json → .ticket.prefix_whitelist):
  ${ACCEPTED}

Either fix the bracketed prefix in the title, or extend prefix_whitelist in
.claude/project-config.json if this team actually uses a new category.

See docs/project-config.md for the config schema.
MSG
  exit 2
fi

# ---------------------------------------------------------------------------
# Required sections for this prefix. If the schema has no entry, silent pass.
# ---------------------------------------------------------------------------

REQUIRED_SECTIONS=""
if [ "$HAVE_CONFIG_LIB" = "1" ]; then
  # Read the array for this prefix. jq handles missing keys by emitting null,
  # which config_get swallows to an empty string.
  REQUIRED_SECTIONS=$(config_get ".ticket.required_sections[\"${CANONICAL_PREFIX}\"][]? // empty" 2>/dev/null)
fi

# Inline fallback matching the shipped defaults, keyed by canonical prefix.
if [ -z "$REQUIRED_SECTIONS" ] && [ "$HAVE_CONFIG_LIB" = "0" ]; then
  case "$CANONICAL_PREFIX" in
    Feature) REQUIRED_SECTIONS=$(printf 'User Story\nAcceptance Criteria\n') ;;
    Chore)   REQUIRED_SECTIONS=$(printf 'Driver\nScope\nAcceptance Criteria\n') ;;
    Bug)     REQUIRED_SECTIONS=$(printf 'Given / When / Then\nRepro\n') ;;
    Docs)    REQUIRED_SECTIONS=$(printf 'Driver\nAcceptance Criteria\n') ;;
    Spike)   REQUIRED_SECTIONS=$(printf 'Hypothesis\nBudget\nKill Criteria\nDisposition\n') ;;
    *)       REQUIRED_SECTIONS="" ;;
  esac
fi

if [ -z "$REQUIRED_SECTIONS" ]; then
  # No schema for this prefix — hook has nothing to enforce, silent pass.
  exit 0
fi

# ---------------------------------------------------------------------------
# Section presence + content checks.
#
# For each required section:
#   1. Build a whitespace-tolerant, slash-tolerant regex for the heading.
#   2. Find the line of the first match.
#   3. Scan forward until the next `##` heading or EOF. If no non-heading,
#      non-whitespace line appears in that range, the section is empty.
# ---------------------------------------------------------------------------

# Skill suggestion per prefix. Chore / Refactor / Testing / CI / Docs all
# use /task; Feature uses /feature; Bug uses /bug; Spike uses /spike.
case "$CANONICAL_PREFIX" in
  Feature)                              SUGGESTED_SKILL="/feature" ;;
  Bug)                                  SUGGESTED_SKILL="/bug" ;;
  Spike)                                SUGGESTED_SKILL="/spike" ;;
  Chore|Refactor|Testing|CI|Docs)       SUGGESTED_SKILL="/task" ;;
  *)                                    SUGGESTED_SKILL="" ;;
esac

# Build a regex that matches a heading case-insensitively, with flexible
# whitespace around slashes. Called per-section.
heading_regex() {
  local section="$1"
  # Escape regex-special characters except '/', which we'll soften.
  local esc
  esc=$(printf '%s' "$section" | sed -E 's/[][\\.^$*+?(){}|]/\\&/g')
  # Collapse whitespace to a single space, then replace spaces with a
  # regex fragment that matches any whitespace (including zero around a
  # slash separator).
  esc=$(echo "$esc" | tr -s ' ')
  # Convert ` / ` (with surrounding spaces) to `[[:space:]]*/[[:space:]]*`,
  # then remaining single spaces to `[[:space:]]+`. Order matters.
  esc=$(echo "$esc" | sed -E 's# +/ +#[[:space:]]*/[[:space:]]*#g')
  esc=$(echo "$esc" | sed -E 's# +#[[:space:]]+#g')
  # Also accept bare `/` without surrounding spaces (already handled when
  # the input had spaces; no change needed for bare).
  echo "^[[:space:]]*##[[:space:]]*${esc}[[:space:]]*\$"
}

ERRORS=""

# Iterate required sections line-by-line. REQUIRED_SECTIONS is newline-separated.
while IFS= read -r section; do
  [ -z "$section" ] && continue

  regex=$(heading_regex "$section")

  # Find the line number of the first matching heading (case-insensitive).
  line_no=$(echo "$FULL_BODY" | grep -n -iE "$regex" | head -1 | cut -d: -f1)

  if [ -z "$line_no" ]; then
    ERRORS="${ERRORS}  - missing section: ## ${section}
"
    continue
  fi

  # Slice from line_no+1 to the next `## ` heading (or EOF). awk is clearer
  # than sed for this range.
  content=$(echo "$FULL_BODY" | awk -v start="$line_no" '
    NR <= start { next }
    /^[[:space:]]*##[[:space:]]/ { exit }
    { print }
  ')

  # Non-empty = at least one line with a non-whitespace, non-heading char.
  stripped=$(echo "$content" | sed -E '/^[[:space:]]*$/d; /^[[:space:]]*##[[:space:]]/d' | tr -d '[:space:]')
  if [ -z "$stripped" ]; then
    ERRORS="${ERRORS}  - empty section: ## ${section} (heading present, no content)
"
  fi
done <<EOF
$REQUIRED_SECTIONS
EOF

if [ -z "$ERRORS" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Block with a message naming missing / empty sections and the right skill.
# ---------------------------------------------------------------------------

cat >&2 <<MSG
BLOCKED: issue body for '[${CANONICAL_PREFIX}]' does not match the required schema.

Problems:
${ERRORS}
Fix the body and retry, or use the matching interactive skill${SUGGESTED_SKILL:+ (${SUGGESTED_SKILL})}.
The skill produces a body that satisfies this check by construction.

Escape hatch (rare — legitimate off-template tickets like epics or meta-threads):
  Add this marker anywhere in the body:
    ${SKIP_MARKER}

Schema source: .claude/project-config.*.json → .ticket.required_sections.
See docs/project-config.md for the full config reference.
MSG

exit 2
