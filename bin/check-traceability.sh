#!/bin/bash
# bin/check-traceability.sh — mechanical requirements-traceability check.
#
# Checks that each requirement in a PRD reaches the technical design, and,
# when ORBIT records exist, an ORBIT slice. It uses the IDs that ApexYard
# already has: US-n and FR-n in the PRD, task rows in the design's
# Implementation Plan, and acN-M in the ORBIT records.
#
# Usage:
#   bin/check-traceability.sh --prd <file> [--design <file>] [--base <ref>]
#                             [--orbit <dir>]
#
#   --prd     The PRD (templates/prd.md shape). Required.
#   --design  The technical design (templates/technical-design.md shape).
#             Adds the coverage checks and the PRD version check.
#   --base    A git ref, such as origin/dev. The check reads the PRD from
#             this ref, not from the working copy. A design branch can hold
#             an old copy of the PRD, so a review must compare the design
#             with the PRD on the base branch. If the current branch itself
#             changes the PRD, the check reads the working copy and says so.
#   --orbit   An ORBIT record directory (docs/orbit). Used only when the PRD
#             has the optional traceability table. Needs jq.
#
# Output: PASS, WARN and BLOCK lines, then one Result line.
# Exit:   0 = no BLOCK, 1 = one or more BLOCK, 2 = usage or input error.
#
# A BLOCK line is a review finding. /write-spec and /design-review run this
# check and report each BLOCK line. No hook, CI check or merge gate runs it.
# me2resh/apexyard#1749.
#
# Bash 3.2 compatible: no associative arrays, no awk interval expressions.
# Lists are newline-separated strings.

set -u

PRD="" DESIGN="" BASE="" ORBIT=""
SEP=$(printf '\037')
BLOCKS=0 WARNS=0

usage() {
  sed -n '9,26p' "$0" | sed 's/^# //; s/^#$//' >&2
  exit 2
}

die() { echo "ERROR: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --prd)    [ $# -ge 2 ] || usage; PRD="$2"; shift 2 ;;
    --design) [ $# -ge 2 ] || usage; DESIGN="$2"; shift 2 ;;
    --base)   [ $# -ge 2 ] || usage; BASE="$2"; shift 2 ;;
    --orbit)  [ $# -ge 2 ] || usage; ORBIT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$PRD" ] || usage
[ -f "$PRD" ] || [ -n "$BASE" ] || die "PRD not found: $PRD"
[ -z "$DESIGN" ] || [ -f "$DESIGN" ] || die "design not found: $DESIGN"
[ -z "$ORBIT" ] || [ -d "$ORBIT" ] || die "ORBIT directory not found: $ORBIT"

pass()  { echo "PASS:  $*"; }
warn()  { echo "WARN:  $*"; WARNS=$((WARNS + 1)); }
block() { echo "BLOCK: $*"; BLOCKS=$((BLOCKS + 1)); }

# A PR can add a PRD or design as a symbolic link to a file outside the
# repository. The check still reads it, but says so.
[ ! -L "$PRD" ] || warn "the PRD path is a symbolic link, so check that it points inside the repository"
[ -z "$DESIGN" ] || [ ! -L "$DESIGN" ] || warn "the design path is a symbolic link, so check that it points inside the repository"

# in_list ITEM LIST — true when ITEM is a whole line of LIST.
in_list() { printf '%s\n' "$2" | grep -qxF -- "$1"; }

# count LIST — number of non-empty lines.
count() { printf '%s\n' "$1" | grep -c . ; }

# ids PATTERN — print each match of an ERE from stdin, one per line, unique.
ids() { grep -oE -- "$1" | awk '!seen[$0]++'; }

# table_rows KEY_ERE — read Markdown from stdin. For each table row whose
# first cell matches KEY_ERE, print: key, has_serves, serves_cell and
# rest_of_row, separated by the unit separator (octal 037). A tab would not
# work: read merges two tabs in a row, so an empty cell would shift fields.
# The Serves column comes from the most recent header row.
table_rows() {
  awk -v keyre="$1" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^[ \t]*[|]/ {
      n = split($0, c, "|")
      first = trim(c[2])
      if (first !~ keyre) {
        sc = 0
        for (i = 2; i < n; i++) if (tolower(trim(c[i])) == "serves") sc = i
        if (sc > 0 || first == "ID" || first == "#") serves_col = sc
        next
      }
      s = (serves_col > 0) ? trim(c[serves_col]) : ""
      rest = ""
      for (i = 3; i < n; i++) if (i != serves_col) rest = rest " " c[i]
      printf "%s\037%s\037%s\037%s\n", first, (serves_col > 0 ? 1 : 0), s, rest
    }'
}

# ---------------------------------------------------------------------------
# Read the PRD.
# ---------------------------------------------------------------------------
PRD_TEXT="" PRD_REL="" GIT_TOP="" PRD_SOURCE="working copy" VERSION_REF=""
if [ -n "$BASE" ]; then
  prd_dir=$(cd "$(dirname "$PRD")" 2>/dev/null && pwd) || die "PRD directory not found: $PRD"
  GIT_TOP=$(git -C "$prd_dir" rev-parse --show-toplevel 2>/dev/null) || die "--base needs the PRD inside a git repository"
  # pwd and git can disagree on symlinked paths, so ask git for the path.
  PRD_REL=$(cd "$prd_dir" && git ls-files --full-name -- "$(basename "$PRD")" 2>/dev/null | head -1)
  [ -n "$PRD_REL" ] || PRD_REL="$(cd "$prd_dir" && git rev-parse --show-prefix)$(basename "$PRD")"
  git -C "$GIT_TOP" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null \
    || die "base ref not found: $BASE (run git fetch first)"

  mb=$(git -C "$GIT_TOP" merge-base "$BASE" HEAD 2>/dev/null || true)
  branch_changes_prd=0
  if [ -n "$mb" ] && [ -f "$PRD" ]; then
    git -C "$GIT_TOP" diff --quiet --no-ext-diff --no-textconv "$mb" -- "$PRD_REL" 2>/dev/null || branch_changes_prd=1
  fi

  if [ "$branch_changes_prd" -eq 1 ]; then
    PRD_TEXT=$(tr -d '\r' < "$PRD")
    VERSION_REF="HEAD"
    warn "this branch changes the PRD, so the check reads the working copy, not $BASE"
    git -C "$GIT_TOP" diff --quiet --no-ext-diff --no-textconv "$mb" "$BASE" -- "$PRD_REL" 2>/dev/null \
      || warn "the PRD also changed on $BASE since this branch started, so rebase to check against both changes"
  elif PRD_TEXT=$(git -C "$GIT_TOP" show --no-textconv "$BASE:$PRD_REL" 2>/dev/null | tr -d '\r') && [ -n "$PRD_TEXT" ]; then
    PRD_SOURCE="$BASE"
  elif [ -f "$PRD" ]; then
    PRD_TEXT=$(tr -d '\r' < "$PRD")
    warn "the PRD is not on $BASE yet, so the check reads the working copy"
  else
    die "PRD not found on $BASE or in the working copy: $PRD"
  fi
else
  PRD_TEXT=$(tr -d '\r' < "$PRD")
fi

echo "Checking PRD: $PRD ($PRD_SOURCE)"

STORIES=$(printf '%s\n' "$PRD_TEXT" | grep -E '^##+ US-[0-9]+' | ids 'US-[0-9]+')
FR_ROWS=$(printf '%s\n' "$PRD_TEXT" | table_rows '^FR-[0-9]+$')
FRS=$(printf '%s\n' "$FR_ROWS" | cut -d "$SEP" -f1 | grep . || true)

[ -n "$STORIES" ] || block "the PRD has no user stories (### US-n headings)"
[ -n "$FRS" ] || block "the PRD has no functional requirements (FR-n table rows)"

# ---------------------------------------------------------------------------
# PRD checks: each US has an FR, each FR serves a known US.
# ---------------------------------------------------------------------------
FR_HAS_SERVES=$(printf '%s\n' "$FR_ROWS" | cut -d "$SEP" -f2 | grep -c '^1$' || true)
STORY_OF_FR=""   # lines: FR-n US-n
if [ -n "$FRS" ] && [ "$FR_HAS_SERVES" -eq 0 ]; then
  warn "the requirements table has no Serves column, so FR-to-story checks are skipped"
elif [ -n "$FRS" ]; then
  bad=0
  while IFS="$SEP" read -r fr _has serves _rest; do
    [ -n "$fr" ] || continue
    served=$(printf '%s\n' "$serves" | ids 'US-[0-9]+')
    if [ -z "$served" ]; then
      block "$fr serves no user story (empty Serves cell)"; bad=1; continue
    fi
    for us in $served; do
      if in_list "$us" "$STORIES"; then
        STORY_OF_FR="$STORY_OF_FR
$fr $us"
      else
        block "$fr serves $us, which is not in the PRD"; bad=1
      fi
    done
  done <<EOF
$FR_ROWS
EOF
  [ "$bad" -eq 0 ] && pass "every functional requirement serves a user story in the PRD ($(count "$FRS")/$(count "$FRS"))"

  missing=0
  for us in $STORIES; do
    if ! printf '%s\n' "$STORY_OF_FR" | grep -q " $us\$"; then
      block "$us has no functional requirement (no FR row serves it)"; missing=1
    fi
  done
  [ "$missing" -eq 0 ] && [ -n "$STORIES" ] && pass "every user story has a functional requirement ($(count "$STORIES")/$(count "$STORIES"))"
fi

# ---------------------------------------------------------------------------
# Optional PRD traceability table: US-n -> acN-M.
# ---------------------------------------------------------------------------
TRACE_ROWS=$(printf '%s\n' "$PRD_TEXT" \
  | awk '/^##+ .*[Tt]raceability/ { f = 1; next } /^#+ / { f = 0 } f' \
  | table_rows '^US-[0-9]+$')
ACS_OF_STORY=""   # lines: US-n acN-M
if [ -n "$TRACE_ROWS" ]; then
  while IFS="$SEP" read -r us _has _serves rest; do
    [ -n "$us" ] || continue
    in_list "$us" "$STORIES" || block "the traceability table lists $us, which is not in the PRD"
    acs=$(printf '%s\n' "$rest" | ids 'ac[0-9]+-[0-9]+')
    if [ -z "$acs" ]; then
      warn "$us has no ORBIT criterion in the traceability table yet"
    fi
    for ac in $acs; do ACS_OF_STORY="$ACS_OF_STORY
$us $ac"; done
  done <<EOF
$TRACE_ROWS
EOF
  for us in $STORIES; do
    printf '%s\n' "$TRACE_ROWS" | cut -d "$SEP" -f1 | grep -qxF "$us" \
      || warn "$us has no row in the traceability table"
  done
fi

# ---------------------------------------------------------------------------
# Design checks: coverage and PRD version.
# ---------------------------------------------------------------------------
if [ -n "$DESIGN" ]; then
  echo "Checking design: $DESIGN"
  DESIGN_TEXT=$(tr -d '\r' < "$DESIGN")
  PLAN=$(printf '%s\n' "$DESIGN_TEXT" | awk '/^## Implementation Plan/ { f = 1; next } /^## / { f = 0 } f')
  TASK_ROWS=$(printf '%s\n' "$PLAN" | table_rows '^[0-9]+$')

  if [ -z "$TASK_ROWS" ]; then
    block "the design has no Implementation Plan task rows"
  elif ! printf '%s\n' "$TASK_ROWS" | cut -d "$SEP" -f2 | grep -q '^1$' \
    && ! printf '%s\n' "$TASK_ROWS" | cut -d "$SEP" -f4 | grep -qE '(US|FR)-[0-9]+'; then
    # An old design: no Serves column and no ID in any task row.
    warn "the design does not link tasks to the PRD, so coverage checks are skipped"
  else
    TASK_HAS_SERVES=$(printf '%s\n' "$TASK_ROWS" | cut -d "$SEP" -f2 | grep -c '^1$' || true)
    [ "$TASK_HAS_SERVES" -gt 0 ] \
      || warn "the Implementation Plan has no Serves column, so the check reads IDs from the whole task row"

    SERVED=""   # every US-n / FR-n that a task names
    while IFS="$SEP" read -r task has serves rest; do
      [ -n "$task" ] || continue
      if [ "$has" = 1 ]; then cell="$serves"; else cell="$rest"; fi
      named=$(printf '%s\n' "$cell" | ids '(US|FR)-[0-9]+')
      if [ -z "$named" ] && [ "$has" = 1 ]; then
        warn "task $task serves no user story or requirement"
      fi
      for id in $named; do
        if in_list "$id" "$STORIES" || in_list "$id" "$FRS"; then
          SERVED="$SERVED
$id"
        else
          block "task $task serves $id, which is not in the PRD"
        fi
      done
    done <<EOF
$TASK_ROWS
EOF

    gap=0
    for us in $STORIES; do
      covered=0
      in_list "$us" "$SERVED" && covered=1
      if [ "$covered" -eq 0 ]; then
        for fr in $(printf '%s\n' "$STORY_OF_FR" | awk -v us="$us" '$2 == us { print $1 }'); do
          in_list "$fr" "$SERVED" && covered=1
        done
      fi
      [ "$covered" -eq 1 ] || { block "$us is not served by any Implementation Plan task"; gap=1; }
    done
    for fr in $FRS; do
      in_list "$fr" "$SERVED" || { block "$fr is not served by any Implementation Plan task"; gap=1; }
    done
    [ "$gap" -eq 0 ] && pass "every user story and requirement is served by an Implementation Plan task"
  fi

  # PRD version: the commit SHA of the PRD that the design was written from.
  version=$(printf '%s\n' "$DESIGN_TEXT" | sed -n 's/^\*\*PRD version\*\*:[[:space:]]*//p' | head -1 | awk '{ print $1 }')
  if [ -z "$GIT_TOP" ]; then
    prd_dir=$(cd "$(dirname "$PRD")" 2>/dev/null && pwd) || prd_dir=""
    if [ -n "$prd_dir" ]; then
      GIT_TOP=$(git -C "$prd_dir" rev-parse --show-toplevel 2>/dev/null || true)
      PRD_REL=$(cd "$prd_dir" && git ls-files --full-name -- "$(basename "$PRD")" 2>/dev/null | head -1)
    fi
  fi
  ref="${VERSION_REF:-${BASE:-HEAD}}"
  if [ -z "$version" ]; then
    warn "the design has no PRD version field, so the PRD change check is skipped"
  elif ! printf '%s' "$version" | grep -qE '^[0-9a-fA-F]+$' || [ "${#version}" -lt 7 ]; then
    warn "the design PRD version is not a commit SHA, so the PRD change check is skipped"
  elif [ -z "$GIT_TOP" ] || [ -z "$PRD_REL" ]; then
    warn "the PRD is not tracked by git, so the PRD change check is skipped"
  else
    latest=$(git -C "$GIT_TOP" log -1 --format=%H "$ref" -- "$PRD_REL" 2>/dev/null || true)
    lower=$(printf '%s' "$version" | tr 'A-F' 'a-f')
    case "$latest" in
      "") warn "the PRD has no commit on $ref, so the PRD change check is skipped" ;;
      "$lower"*) pass "the design PRD version matches the PRD on $ref (${latest%"${latest#???????}"})" ;;
      *) warn "the PRD changed since this design was written (design: $version, $ref: ${latest%"${latest#???????}"})" ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# Optional ORBIT checks: each mapped acN-M exists and is in a slice.
# ---------------------------------------------------------------------------
if [ -n "$ORBIT" ]; then
  if [ -z "$ACS_OF_STORY" ]; then
    echo "INFO:  no traceability table in the PRD, so the ORBIT checks are skipped"
  elif ! command -v jq >/dev/null 2>&1; then
    warn "jq is not installed, so the ORBIT checks are skipped"
  else
    PLAN_ACS=""
    for f in "$ORBIT"/plans/*.json; do
      [ -f "$f" ] || continue
      PLAN_ACS="$PLAN_ACS
$(jq -r '.acceptanceCriteria[]?.id // empty' "$f" 2>/dev/null)"
    done
    SLICE_ACS=""
    for f in "$ORBIT"/slices/*.json; do
      [ -f "$f" ] || continue
      SLICE_ACS="$SLICE_ACS
$(jq -r '.contributesTo[]? // empty' "$f" 2>/dev/null)"
    done
    gap=0
    while read -r us ac; do
      [ -n "$ac" ] || continue
      if printf '%s\n' "$PLAN_ACS" | grep -q . && ! in_list "$ac" "$PLAN_ACS"; then
        block "$us maps to $ac, which is in no ORBIT plan"; gap=1; continue
      fi
      in_list "$ac" "$SLICE_ACS" || { block "$ac ($us) is in no ORBIT slice's contributesTo"; gap=1; }
    done <<EOF
$ACS_OF_STORY
EOF
    [ "$gap" -eq 0 ] && pass "every mapped ORBIT criterion is in a slice"
  fi
fi

echo "Result: $BLOCKS BLOCK, $WARNS WARN"
[ "$BLOCKS" -eq 0 ]
