#!/bin/bash
# Blocks issue/PR/comment creation on a public framework repo when the title
# or body references any registered private project from the fork's
# apexyard.projects.yaml.
#
# The leak vector: an agent diagnoses a framework bug while working inside a
# private project, then files the upstream ticket with "discovered during
# <private-project> rebuild". Once filed, the project's name is indexed
# forever on a public issue tracker.
#
# Fires on PreToolUse Bash for the five gh shapes that write to a remote
# tracker:
#   - gh issue create --repo <repo>
#   - gh pr create --repo <repo>
#   - gh issue comment <n> --repo <repo>
#   - gh pr comment <n> --repo <repo>
#   - gh api repos/<owner>/<repo>/{issues,pulls}[...]
#
# Behaviour:
#   - Target repo not public-class → exit 0 silently.
#   - apexyard.projects.yaml missing → exit 0 silently (no scrub list).
#   - Body empty (no title + no body + no body-file) → exit 0 silently.
#   - Skip marker `<!-- private-refs: allow -->` in body → exit 0 with a
#     single-line warning to stderr.
#   - Match against any registered project `name`, `repo`, `workspace`, or
#     an `<owner>/<repo>#<N>` reference to a registered repo → exit 2 with a
#     message naming each leaked token and suggesting abstract replacements.
#
# Configuration (future): a `.claude/project-config.json` may override
# `leak_protection.public_framework_repos` and `leak_protection.skip_marker`.
# For now the defaults are inlined below.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Match the five covered gh shapes. If the command is anything else,
#    silently exit 0.
# ---------------------------------------------------------------------------

IS_GH_SUBCMD=0      # gh issue create | gh pr create | gh issue comment | gh pr comment
IS_GH_API=0         # gh api .../issues | .../pulls

if echo "$COMMAND" | grep -qE '\bgh\s+issue\s+create\b'; then IS_GH_SUBCMD=1; fi
if echo "$COMMAND" | grep -qE '\bgh\s+pr\s+create\b'; then IS_GH_SUBCMD=1; fi
if echo "$COMMAND" | grep -qE '\bgh\s+issue\s+comment\b'; then IS_GH_SUBCMD=1; fi
if echo "$COMMAND" | grep -qE '\bgh\s+pr\s+comment\b'; then IS_GH_SUBCMD=1; fi
if echo "$COMMAND" | grep -qE '\bgh\s+api\b.*\b(issues|pulls)\b'; then IS_GH_API=1; fi

if [ "$IS_GH_SUBCMD" -eq 0 ] && [ "$IS_GH_API" -eq 0 ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Resolve the target repo.
#    - From `--repo owner/name` for the subcommand shape.
#    - From the URL path for the api shape: `gh api repos/<owner>/<repo>/...`.
# ---------------------------------------------------------------------------

TARGET_REPO=""

# --repo flag, supports quoted or unquoted value.
TARGET_REPO=$(echo "$COMMAND" | sed -nE 's/.*--repo[[:space:]]+["'"'"']?([^[:space:]"'"'"']+)["'"'"']?.*/\1/p' | head -1)

if [ -z "$TARGET_REPO" ] && [ "$IS_GH_API" -eq 1 ]; then
  # Accept both `repos/owner/repo/...` and `/repos/owner/repo/...`.
  TARGET_REPO=$(echo "$COMMAND" | grep -oE '/?repos/[^/[:space:]]+/[^/[:space:]]+' | head -1 | sed -E 's|^/?repos/||')
fi

if [ -z "$TARGET_REPO" ]; then
  # No target repo resolvable — the hook has nothing to evaluate. Default
  # gh behaviour (current-dir repo) is safe to ignore here: the hook is a
  # backstop against cross-repo leaks, not a universal scrubber.
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Determine whether the target is public / framework-class.
#    Sources (in order):
#      1. `.claude/project-config.*.json` → `leak_protection.public_framework_repos[]`
#         (read via the shared config lib landed in apexyard#109)
#      2. Shipped default: `me2resh/apexyard`
#      3. Auto-detected: whatever the fork's `upstream` remote resolves to
#         (unless `leak_protection.auto_detect_upstream` is set to `false`).
# ---------------------------------------------------------------------------

# Load the shared config reader if available. The hook still works without
# it — falls through to the shipped defaults.
REPO_ROOT_FOR_CONFIG=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$REPO_ROOT_FOR_CONFIG" ] && [ -f "$REPO_ROOT_FOR_CONFIG/.claude/hooks/_lib-read-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$REPO_ROOT_FOR_CONFIG/.claude/hooks/_lib-read-config.sh"
  CONFIG_REPOS=$(config_get '.leak_protection.public_framework_repos[]' 2>/dev/null | tr '\n' ' ')
  AUTO_DETECT_UPSTREAM=$(config_get_or '.leak_protection.auto_detect_upstream' 'true')
fi

PUBLIC_REPOS="${CONFIG_REPOS:-me2resh/apexyard}"

if [ "${AUTO_DETECT_UPSTREAM:-true}" != "false" ]; then
  UPSTREAM_URL=$(git remote get-url upstream 2>/dev/null)
  if [ -n "$UPSTREAM_URL" ]; then
    # Parse github.com/<owner>/<repo>(.git)? from either SSH or HTTPS form.
    UPSTREAM_SLUG=$(echo "$UPSTREAM_URL" | sed -nE 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|p' | sed -E 's/\.git$//')
    if [ -n "$UPSTREAM_SLUG" ]; then
      PUBLIC_REPOS="$PUBLIC_REPOS $UPSTREAM_SLUG"
    fi
  fi
fi

IS_PUBLIC_TARGET=0
for r in $PUBLIC_REPOS; do
  if [ "$TARGET_REPO" = "$r" ]; then
    IS_PUBLIC_TARGET=1
    break
  fi
done

if [ "$IS_PUBLIC_TARGET" -eq 0 ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Locate apexyard.projects.yaml (walk up from CWD to find the fork root).
# ---------------------------------------------------------------------------

REGISTRY=""
r="$PWD"
while [ -n "$r" ] && [ "$r" != "/" ]; do
  if [ -f "$r/apexyard.projects.yaml" ]; then
    REGISTRY="$r/apexyard.projects.yaml"
    break
  fi
  r=$(dirname "$r")
done

if [ -z "$REGISTRY" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Extract the title + body text that will land on the public tracker.
#    Supports --title, --body, --body-file, -F, -b, -t, and `gh api`-style
#    `-F body=@file` / `-f body=...`.
# ---------------------------------------------------------------------------

extract_flag_value() {
  # $1 = python-flag regex (e.g. --title | -t). Matches (possibly multi-line):
  #   --title "value with spaces"
  #   --title 'value'
  #   --title value
  #
  # Quoted-value regex is GREEDY and anchored on the next flag boundary
  # (whitespace + `--<letter>`) or end-of-string. The earlier sed form
  # `[^"]*` truncated at the first embedded double quote
  # (me2resh/apexyard#227); for the leak-protection hook that's a real
  # security tail — a body with an embedded `"` could let private refs in
  # the back half slip past the gate. awk + greedy + boundary anchor
  # gives us multi-line consumption and correct termination in one shot.
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
# because `gh api -F body=@file` uses the same flag letter).
BODY_FILE=$(extract_flag_value '--body-file' "$COMMAND")
if [ -z "$BODY_FILE" ]; then
  # gh pr create / gh issue create: -F <path>
  F_VAL=$(echo "$COMMAND" | sed -nE "s/.*(^|[[:space:]])-F[[:space:]]+\"([^\"]*)\".*/\2/p" | head -1)
  if [ -z "$F_VAL" ]; then
    F_VAL=$(echo "$COMMAND" | sed -nE "s/.*(^|[[:space:]])-F[[:space:]]+'([^']*)'.*/\2/p" | head -1)
  fi
  if [ -z "$F_VAL" ]; then
    F_VAL=$(echo "$COMMAND" | sed -nE "s/.*(^|[[:space:]])-F[[:space:]]+([^[:space:]]+).*/\2/p" | head -1)
  fi
  # Only treat as a body-file path if it does NOT look like key=value.
  if [ -n "$F_VAL" ] && ! echo "$F_VAL" | grep -q '='; then
    BODY_FILE="$F_VAL"
  fi
fi

BODY_FILE_CONTENT=""
if [ -n "$BODY_FILE" ] && [ -f "$BODY_FILE" ]; then
  BODY_FILE_CONTENT=$(cat "$BODY_FILE" 2>/dev/null)
fi

# `gh api` body field: -F body=@file or -f body='text' or -F body='text'.
API_BODY=""
if [ "$IS_GH_API" -eq 1 ]; then
  # Handle -F body=@<path> (file ref) and -f/-F body=<literal>.
  API_BODY_PATH=$(echo "$COMMAND" | sed -nE "s/.*-F[[:space:]]+body=@([^[:space:]\"']+).*/\1/p" | head -1)
  if [ -n "$API_BODY_PATH" ] && [ -f "$API_BODY_PATH" ]; then
    API_BODY=$(cat "$API_BODY_PATH" 2>/dev/null)
  else
    # Literal body=... — may be quoted. Strip surrounding quotes.
    API_BODY=$(echo "$COMMAND" | sed -nE "s/.*-[fF][[:space:]]+body=\"([^\"]*)\".*/\1/p" | head -1)
    if [ -z "$API_BODY" ]; then
      API_BODY=$(echo "$COMMAND" | sed -nE "s/.*-[fF][[:space:]]+body='([^']*)'.*/\1/p" | head -1)
    fi
    if [ -z "$API_BODY" ]; then
      API_BODY=$(echo "$COMMAND" | sed -nE "s/.*-[fF][[:space:]]+body=([^[:space:]]+).*/\1/p" | head -1)
    fi
  fi

  # Also pick up a `title` field on api-shape issue creation.
  if [ -z "$TITLE" ]; then
    API_TITLE=$(echo "$COMMAND" | sed -nE "s/.*-[fF][[:space:]]+title=\"([^\"]*)\".*/\1/p" | head -1)
    if [ -z "$API_TITLE" ]; then
      API_TITLE=$(echo "$COMMAND" | sed -nE "s/.*-[fF][[:space:]]+title='([^']*)'.*/\1/p" | head -1)
    fi
    if [ -z "$API_TITLE" ]; then
      API_TITLE=$(echo "$COMMAND" | sed -nE "s/.*-[fF][[:space:]]+title=([^[:space:]]+).*/\1/p" | head -1)
    fi
    TITLE="$API_TITLE"
  fi
fi

# Concatenate all candidate text. A newline between each part keeps
# line-anchored regexes honest.
HAYSTACK=$(printf '%s\n%s\n%s\n%s\n' "$TITLE" "$BODY" "$BODY_FILE_CONTENT" "$API_BODY")

# Short-circuit on truly empty input (no title + no body + no files). This is
# deliberate: `gh issue comment <n>` with no -b / -F triggers gh's editor and
# the hook has nothing to scan.
if [ -z "$(echo "$HAYSTACK" | tr -d '[:space:]')" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 6. Skip marker — lets a deliberate reference through (rare).
# ---------------------------------------------------------------------------

SKIP_MARKER=$(config_get_or '.leak_protection.skip_marker' '<!-- private-refs: allow -->' 2>/dev/null)
# Fallback if the config lib didn't source successfully (e.g. on a bare
# checkout predating apexyard#109).
SKIP_MARKER="${SKIP_MARKER:-<!-- private-refs: allow -->}"
if echo "$HAYSTACK" | grep -qF -- "$SKIP_MARKER"; then
  echo "WARN: private-refs: allow marker present — leak-protection hook bypassed for this ${TARGET_REPO} call. See .claude/rules/leak-protection.md." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# 7. Extract the scrub list from apexyard.projects.yaml — per-project
#    `name`, `repo`, and `workspace`. awk fallback mirrors the one used
#    by /start-ticket (see .claude/skills/start-ticket/SKILL.md) — we do
#    not depend on yq because many forks won't have it installed.
# ---------------------------------------------------------------------------

NAMES=""
REPOS=""
WORKSPACES=""

# awk parser: walk each `- name:` block and pull out `name`, `repo`,
# `workspace`. Strips surrounding quotes. Assumes `- name:` is the first
# key in each project entry (same assumption as /start-ticket).
PARSED=$(awk '
  function unquote(s) { gsub(/^["\x27]|["\x27]$/, "", s); return s }
  /^[[:space:]]*- name:/       { print "NAME=" unquote($3) }
  /^[[:space:]]*repo:/         { print "REPO=" unquote($2) }
  /^[[:space:]]*workspace:/    { print "WORKSPACE=" unquote($2) }
' "$REGISTRY")

while IFS= read -r line; do
  case "$line" in
    NAME=*)
      v=${line#NAME=}
      [ -n "$v" ] && NAMES="$NAMES $v"
      ;;
    REPO=*)
      v=${line#REPO=}
      [ -n "$v" ] && REPOS="$REPOS $v"
      ;;
    WORKSPACE=*)
      v=${line#WORKSPACE=}
      [ -n "$v" ] && WORKSPACES="$WORKSPACES $v"
      ;;
  esac
done <<EOF
$PARSED
EOF

# ---------------------------------------------------------------------------
# 8. Build the match list.
#
#   - `name` → whole-word match (grep -wE). Skip the target's own name, and
#     skip names that collide with the target repo's own name, so mentioning
#     "apexyard" in an apexyard upstream ticket is fine. Also skip the name
#     whose `repo:` matches $TARGET_REPO (belt-and-braces).
#   - `repo` slug → exact match, with optional `#<N>` suffix.
#   - `workspace` path → whole-word match.
# ---------------------------------------------------------------------------

# Derive the target's bare repo name for exemption (e.g. "apexyard" from
# "me2resh/apexyard").
TARGET_NAME=$(echo "$TARGET_REPO" | awk -F/ '{print $NF}')

LEAKS=""

# Reusable matcher: given a pattern regex, if it fires against HAYSTACK,
# append the token to LEAKS with a labelled prefix.
record_if_match() {
  local label="$1"
  local token="$2"
  local regex="$3"
  if echo "$HAYSTACK" | grep -qE "$regex"; then
    LEAKS="$LEAKS
  - ${label}: ${token}"
  fi
}

for n in $NAMES; do
  # Exempt the target repo's own name.
  if [ "$n" = "$TARGET_NAME" ]; then continue; fi
  # Whole-word, case-insensitive. Escape regex-special chars in $n.
  esc=$(printf '%s' "$n" | sed -E 's/[][\\/.^$*+?(){}|]/\\&/g')
  if echo "$HAYSTACK" | grep -qiwE "$esc"; then
    LEAKS="$LEAKS
  - project name: $n"
  fi
done

for rp in $REPOS; do
  if [ "$rp" = "$TARGET_REPO" ]; then continue; fi
  esc=$(printf '%s' "$rp" | sed -E 's/[][\\/.^$*+?(){}|]/\\&/g')
  # Either bare slug (with word-ish boundary) or slug#<N>.
  if echo "$HAYSTACK" | grep -qiE "(^|[^A-Za-z0-9_/-])${esc}(#[0-9]+)?([^A-Za-z0-9_/-]|$)"; then
    LEAKS="$LEAKS
  - project repo: $rp"
  fi
done

for ws in $WORKSPACES; do
  esc=$(printf '%s' "$ws" | sed -E 's/[][\\/.^$*+?(){}|]/\\&/g')
  # Workspace-path boundaries: path-chars `/` and `-` ARE allowed *after* the
  # match (e.g. `workspace/ws-marlow/app.ts` is a real reference — the
  # trailing `/` marks a sub-path, not a suffix extension of the token). The
  # leading boundary rejects alphanumeric/underscore/- to avoid matching
  # inside another token like `myworkspace/ws-marlow`.
  if echo "$HAYSTACK" | grep -qE "(^|[^A-Za-z0-9_-])${esc}([^A-Za-z0-9_-]|$)"; then
    LEAKS="$LEAKS
  - workspace path: $ws"
  fi
done

if [ -z "$LEAKS" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 9. Block with a message that names each leaked token and suggests abstract
#    replacement phrasing.
# ---------------------------------------------------------------------------

cat >&2 <<MSG
BLOCKED: private project reference detected in ${TARGET_REPO} (public framework repo).

Leaked tokens (from your fork's apexyard.projects.yaml):${LEAKS}

Why this is blocked:
  Public-framework issues are indexed and searchable forever. Referencing
  a registered private project by name, repo slug, or workspace path
  publishes that project's existence on a public tracker — usually not
  what you want.

Rewrite with abstract phrasing. Examples:
  "discovered during <private-project> rebuild"
    → "discovered during a managed-project rebuild"
  "same as <owner/repo>#42"
    → "same as a registered project's migration ticket"
  "in workspace/<private-project>/"
    → "in one of the registered project workspaces"

Escape hatch (rare — only when an upstream ticket legitimately needs to
reference a registered project by name):
  Add this HTML comment anywhere in the body:
    ${SKIP_MARKER}

See .claude/rules/leak-protection.md for the full rationale.
MSG

exit 2
