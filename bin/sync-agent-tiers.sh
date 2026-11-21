#!/bin/bash
# bin/sync-agent-tiers.sh: write agent model and effort, and skill effort,
# from the tier map in .claude/harness-models.json (me2resh/apexyard#2033,
# AgDR-0294-model-and-effort-tier-map).
#
# The tier map is the one source. Agent and skill files keep concrete values
# because Claude Code reads only the frontmatter. This script copies the
# values from the map into the files. `--check` writes nothing and exits 1
# when a file differs from the map.
#
# Routing overrides (agent-routing.yaml, apply-agent-routing.sh):
#   The SessionStart routing hook rewrites `model:` lines in the working tree.
#   It records each agent it rewrote in .claude/agents/.framework-defaults.json
#   (gitignored). This script leaves the `model:` line of a listed agent as it
#   is, in both modes. It still checks and writes `effort:`, because the
#   routing hook does not change effort. CI has no such file, so CI checks
#   every model.
#
# Files outside the map are not changed. The script prints a note for an agent
# file that has no map entry, and for a skill that declares effort but has no
# map entry. The framework test suite requires full coverage for its own files.
#
# Requires: bash 3.2+, jq, awk.
#
# Exit codes:
#   0  files match the map (--check), or the write finished
#   1  drift found (--check), or a mapped file is missing or malformed
#   2  usage error, missing jq, or an invalid map

set -u

usage() {
  cat <<'USAGE'
Usage: bin/sync-agent-tiers.sh [--check] [--list] [--root <path>]

Write `model:` and `effort:` in .claude/agents/*.md, and `effort:` in
.claude/skills/*/SKILL.md, from the tier map in .claude/harness-models.json.

Options:
  --check       Write nothing. Exit 1 when a file differs from the map.
  --list        Print the resolved values as tab-separated rows and exit.
  --root PATH   Repository root to use instead of this script's parent.
USAGE
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK=0
LIST=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --list) LIST=1 ;;
    --root)
      [ "$#" -ge 2 ] || { echo "ERROR: --root requires a path" >&2; exit 2; }
      ROOT="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || { echo "ERROR: root not found" >&2; exit 2; }
MAP="$ROOT/.claude/harness-models.json"
AGENTS_DIR="$ROOT/.claude/agents"
SKILLS_DIR="$ROOT/.claude/skills"
ROUTED_FILE="$AGENTS_DIR/.framework-defaults.json"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required (https://jqlang.org)" >&2; exit 2; }
[ -f "$MAP" ] || { echo "ERROR: tier map not found: .claude/harness-models.json" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Validate the map. Each finding is one line. No output means a valid map.
# ---------------------------------------------------------------------------
MAP_ERRORS=$(jq -r '
  def ceff: ["low", "medium", "high", "xhigh", "max"];
  def xeff: ["minimal", "low", "medium", "high", "xhigh"];
  def name_ok: type == "string" and test("^[a-z0-9][a-z0-9-]*$");
  def str_ok: type == "string" and length > 0 and (test("[[:space:]]") | not);
  (.tiers // {}) as $tiers
  | (.stages // {}) as $stages
  | [
      (if .schema != 2 then "schema must be 2" else empty end),
      (if ($tiers | type) != "object" or ($tiers | length) == 0
       then "tiers must be a non-empty object" else empty end),
      ($tiers | to_entries[] | .key as $t | .value as $v
        | (if ($t | name_ok) | not then "tier \($t): name must match [a-z0-9-]" else empty end),
          (if ($v.rank | type) != "number" then "tier \($t): rank must be a number" else empty end),
          (if ($v.claude.model | str_ok) | not then "tier \($t): claude.model must be a non-empty string" else empty end),
          (if ($v.claude.effort | IN(ceff[])) | not
           then "tier \($t): claude.effort must be one of \(ceff | join(", "))" else empty end),
          (if $v.codex == null then empty
           else
             (if ($v.codex.model | str_ok) | not then "tier \($t): codex.model must be a non-empty string" else empty end),
             (if $v.codex.effort == null or ($v.codex.effort | IN(xeff[])) then empty
              else "tier \($t): codex.effort must be one of \(xeff | join(", "))" end)
           end)),
      (if ([$tiers[].rank] | length) != ([$tiers[].rank] | unique | length)
       then "tier ranks must be unique" else empty end),
      (if (.agents | type) != "object" then "agents must be an object" else empty end),
      ((.agents // {}) | to_entries[] | .key as $a | .value as $v
        | (if ($a | name_ok) | not then "agent \($a): name must match [a-z0-9-]" else empty end),
          (if ($v | type) != "object" then "agent \($a): entry must be an object"
           elif ($v.tier | type) != "string" or ($tiers | has($v.tier) | not)
           then "agent \($a): tier must name a tier in tiers" else empty end),
          (if ($v | type) == "object" and $v.effort != null and (($v.effort | IN(ceff[] , "inherit")) | not)
           then "agent \($a): effort must be one of \(ceff | join(", ")), inherit" else empty end)),
      ($stages | to_entries[]
        | if (.value | IN(ceff[])) | not
          then "stage \(.key): effort must be one of \(ceff | join(", "))" else empty end),
      ((.skills // {}) | to_entries[] | .key as $s | .value as $st
        | (if ($s | name_ok) | not then "skill \($s): name must match [a-z0-9-]" else empty end),
          (if ($st | type) != "string" or ($stages | has($st) | not)
           then "skill \($s): stage must name a stage in stages" else empty end))
    ]
  | .[]
' "$MAP" 2>&1)
jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
  echo "ERROR: cannot read the tier map: $MAP_ERRORS" >&2
  exit 2
fi
if [ -n "$MAP_ERRORS" ]; then
  echo "ERROR: invalid tier map (.claude/harness-models.json):" >&2
  printf '%s\n' "$MAP_ERRORS" | sed 's/^/  - /' >&2
  exit 2
fi

# Rows: kind <TAB> name <TAB> group <TAB> model <TAB> effort
# kind is agent or skill. group is the tier or the stage. A skill row has
# model "-". effort "inherit" means: no effort line.
ROWS=$(jq -r '
  .tiers as $tiers
  | ((.agents // {}) | to_entries[]
      | ["agent", .key, .value.tier, $tiers[.value.tier].claude.model,
         (.value.effort // $tiers[.value.tier].claude.effort)] | @tsv),
    (.stages as $stages | (.skills // {}) | to_entries[]
      | ["skill", .key, .value, "-", $stages[.value]] | @tsv)
' "$MAP")

if [ "$LIST" -eq 1 ]; then
  printf 'kind\tname\tgroup\tmodel\teffort\n'
  printf '%s\n' "$ROWS"
  exit 0
fi

# Agents whose model line the routing hook owns in this working tree.
ROUTED=""
if [ -f "$ROUTED_FILE" ]; then
  ROUTED=$(jq -r 'if type == "object" then keys[] else empty end' "$ROUTED_FILE" 2>/dev/null || true)
fi

is_routed() {
  [ -n "$ROUTED" ] || return 1
  printf '%s\n' "$ROUTED" | grep -Fxq -- "$1"
}

# Value of a key in the first frontmatter block. Empty when absent.
fm_value() {
  awk -v key="$2" '
    NR == 1 && !/^---[[:space:]]*$/ { exit }
    /^---[[:space:]]*$/ { n++; if (n == 2) exit; next }
    n == 1 && index($0, key ":") == 1 {
      v = substr($0, length(key) + 2)
      sub(/^[[:space:]]+/, "", v)
      sub(/[[:space:]]+$/, "", v)
      print v
      exit
    }
  ' "$1"
}

has_frontmatter() {
  awk '
    NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit 1; next }
    /^---[[:space:]]*$/ { found = 1; exit }
    END { exit !found }
  ' "$1"
}

# Print the file with the frontmatter set to the wanted values.
#   set_model  1 to write model:, 0 to leave it unchanged
#   effort     a value to write, or "inherit" to remove the effort line
# A missing model: or effort: line goes after model:, or before the closing ---.
render() {
  awk -v set_model="$2" -v model="$3" -v effort="$4" '
    BEGIN { n = 0; seen_model = 0; seen_effort = 0 }
    n < 2 && /^---[[:space:]]*$/ {
      n++
      if (n == 2) {
        if (set_model == 1 && !seen_model) print "model: " model
        if (effort != "inherit" && !seen_effort) print "effort: " effort
      }
      print
      next
    }
    n == 1 && /^model:/ {
      seen_model = 1
      if (set_model == 1) print "model: " model
      else print
      if (effort != "inherit" && !seen_effort && !has_effort) {
        print "effort: " effort
        seen_effort = 1
      }
      next
    }
    n == 1 && /^effort:/ {
      if (seen_effort) next
      seen_effort = 1
      if (effort != "inherit") print "effort: " effort
      next
    }
    { print }
  ' has_effort="$5" "$1"
}

DRIFT=0
CHANGED=0
TMP=$(mktemp 2>/dev/null) || { echo "ERROR: mktemp failed" >&2; exit 2; }
trap 'rm -f "$TMP"' EXIT

sync_file() {
  local kind="$1" name="$2" model="$3" effort="$4" file="$5" rel="$6"
  local set_model=0 cur_model="" cur_effort="" has_effort=0 want_effort=""

  if [ ! -f "$file" ]; then
    echo "drift: $rel is in the tier map but the file does not exist" >&2
    DRIFT=1
    return 0
  fi
  if ! has_frontmatter "$file"; then
    echo "drift: $rel has no frontmatter block" >&2
    DRIFT=1
    return 0
  fi

  cur_model=$(fm_value "$file" model)
  cur_effort=$(fm_value "$file" effort)
  [ -n "$cur_effort" ] && has_effort=1

  if [ "$kind" = agent ]; then
    set_model=1
    if [ "$cur_model" != "$model" ] && is_routed "$name"; then
      # The routing hook owns this model line in this working tree.
      set_model=0
      echo "note: $rel model: $cur_model is a routing override; map value $model not applied" >&2
    fi
  fi

  render "$file" "$set_model" "$model" "$effort" "$has_effort" > "$TMP" || {
    echo "drift: $rel could not be read" >&2
    DRIFT=1
    return 0
  }
  if cmp -s "$TMP" "$file"; then
    return 0
  fi

  want_effort="$effort"
  [ "$want_effort" = inherit ] && want_effort="(none)"
  [ -n "$cur_effort" ] || cur_effort="(none)"
  if [ "$CHECK" -eq 1 ]; then
    if [ "$set_model" -eq 1 ] && [ "$cur_model" != "$model" ]; then
      echo "drift: $rel model: ${cur_model:-(none)} (map: $model)" >&2
    fi
    if [ "$cur_effort" != "$want_effort" ]; then
      echo "drift: $rel effort: $cur_effort (map: $want_effort)" >&2
    fi
    DRIFT=1
    return 0
  fi
  cat "$TMP" > "$file"
  CHANGED=$((CHANGED + 1))
  echo "updated: $rel" >&2
}

while IFS="$(printf '\t')" read -r kind name _group model effort; do
  [ -n "$kind" ] || continue
  case "$kind" in
    agent) sync_file agent "$name" "$model" "$effort" "$AGENTS_DIR/$name.md" ".claude/agents/$name.md" ;;
    skill) sync_file skill "$name" "-" "$effort" "$SKILLS_DIR/$name/SKILL.md" ".claude/skills/$name/SKILL.md" ;;
  esac
done <<EOF
$ROWS
EOF

# Notes for files outside the map. These never fail the run.
MAPPED_AGENTS=$(printf '%s\n' "$ROWS" | awk -F'\t' '$1 == "agent" { print $2 }')
MAPPED_SKILLS=$(printf '%s\n' "$ROWS" | awk -F'\t' '$1 == "skill" { print $2 }')
if [ -d "$AGENTS_DIR" ]; then
  for f in "$AGENTS_DIR"/*.md; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .md)
    if ! printf '%s\n' "$MAPPED_AGENTS" | grep -Fxq -- "$n"; then
      echo "note: .claude/agents/$n.md is not in the tier map; left unchanged" >&2
    fi
  done
fi
if [ -d "$SKILLS_DIR" ]; then
  for f in "$SKILLS_DIR"/*/SKILL.md; do
    [ -f "$f" ] || continue
    n=$(basename "$(dirname "$f")")
    [ -n "$(fm_value "$f" effort)" ] || continue
    if ! printf '%s\n' "$MAPPED_SKILLS" | grep -Fxq -- "$n"; then
      echo "note: .claude/skills/$n/SKILL.md declares effort but is not in the tier map; left unchanged" >&2
    fi
  done
fi

if [ "$CHECK" -eq 1 ]; then
  if [ "$DRIFT" -ne 0 ]; then
    echo "sync-agent-tiers: files differ from the tier map. Run: bash bin/sync-agent-tiers.sh" >&2
    exit 1
  fi
  echo "sync-agent-tiers: agent and skill files match the tier map." >&2
  exit 0
fi

[ "$DRIFT" -ne 0 ] && exit 1
echo "sync-agent-tiers: $CHANGED file(s) updated." >&2
exit 0
