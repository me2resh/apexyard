#!/usr/bin/env bash
# Generate Codex-facing adapter files from the canonical .claude runtime.
#
# .claude remains the source of truth. This script emits Codex-facing skills,
# agents, and hook wiring while delegating every gate to the unmodified
# .claude/hooks/*.sh scripts.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK=0
CLEAN=0

usage() {
  cat <<'USAGE'
Usage: bin/sync-codex-adapter.sh [--check] [--clean] [--root <path>]

Generate Codex adapter files from .claude:
  .claude/skills   -> .agents/skills
  .claude/agents   -> .codex/agents/*.toml
  .claude/settings.json -> .codex/hooks.json (commands still exec .claude/hooks)

Options:
  --check       Do not write files; fail if generated output would differ.
  --clean       Remove generated .agents/.codex before writing.
  --root PATH   Repository root to use instead of this script's parent.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --clean) CLEAN=1 ;;
    --root)
      [ "$#" -ge 2 ] || { echo "ERROR: --root requires a path" >&2; exit 2; }
      ROOT="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

ROOT="$(cd "$ROOT" && pwd)"
CLAUDE_DIR="$ROOT/.claude"

[ -d "$CLAUDE_DIR" ] || { echo "ERROR: .claude not found under $ROOT" >&2; exit 1; }
[ -f "$CLAUDE_DIR/settings.json" ] || { echo "ERROR: .claude/settings.json not found" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to generate TOML strings safely" >&2
  exit 1
fi

TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-adapter.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

OUT_AGENTS="$TMPDIR/.agents"
OUT_CODEX="$TMPDIR/.codex"
mkdir -p "$OUT_AGENTS" "$OUT_CODEX/agents"

rewrite_skill_paths() {
  perl -0pi -e '
    s/\.claude\/skills/.agents\/skills/g;
  ' "$@"
}

# Map a Claude model-tier label to a harness-native model via the shared
# .claude/harness-models.json matrix — the single source of truth every harness
# adapter reads (pi/opencode add their own column instead of a second mapping).
# Falls back to the label unchanged when the file, tier, or 'codex' column is
# absent (jq treats a missing key as null, so `// $l` yields the label).
map_codex_model() {
  jq -r --arg l "$1" '.[$l].codex // $l' "$CLAUDE_DIR/harness-models.json" 2>/dev/null \
    || printf '%s\n' "$1"
}

copy_tree() {
  local src="$1" dst="$2"
  [ -d "$src" ] || return 0
  mkdir -p "$(dirname "$dst")"
  cp -R "$src" "$dst"
}

generate_hooks_json() {
  jq '
    def wrap_if_handler:
      if has("if") then
        (.if | capture("^(?<tool>[^()]+)\\((?<glob>.*)\\)$")) as $predicate
        | .command = (
            "APEXYARD_CODEX_HOOK_TOOL=" + ($predicate.tool | @sh) +
            " APEXYARD_CODEX_HOOK_GLOB=" + ($predicate.glob | @sh) +
            " APEXYARD_CODEX_ORIGINAL_HOOK=" + (.command | @sh) +
            " bash -c " +
            ("input=$(cat); tool=$(printf \"%s\" \"$input\" | jq -r \".tool_name // \\\"\\\"\"); cmd=$(printf \"%s\" \"$input\" | jq -r \".tool_input.command // \\\"\\\"\"); [ \"$tool\" = \"$APEXYARD_CODEX_HOOK_TOOL\" ] || exit 0; [[ \"$cmd\" == $APEXYARD_CODEX_HOOK_GLOB ]] || exit 0; printf \"%s\" \"$input\" | bash -c \"$APEXYARD_CODEX_ORIGINAL_HOOK\"" | @sh)
          )
        | del(.if)
      else
        del(.if)
      end;

    { hooks:
      (.hooks
       | with_entries(
           .value |= map(
             .hooks |= map(wrap_if_handler)
           )
         ))
    }
  ' "$CLAUDE_DIR/settings.json"
}

copy_tree "$CLAUDE_DIR/skills" "$OUT_AGENTS/skills"
generate_hooks_json > "$OUT_CODEX/hooks.json"

# Fail loud on a silent gate-hole (Rex, #838/#840): generate_hooks_json's jq
# filter is written to be matcher-agnostic (it walks every event/matcher
# group generically rather than selecting by name), so nothing in this
# generator drops a hook today. This assertion is the regression backstop —
# if a future edit to the jq filter above narrows it to a recognized-matcher
# allowlist (the way the Cursor generator's event-mapping table already
# does), a silently dropped hook becomes a build error here instead of a
# quietly-inert gate in .codex/hooks.json.
assert_hook_counts_match() {
  local source_count generated_count matchers
  source_count=$(jq '[.hooks[][].hooks[]] | length' "$CLAUDE_DIR/settings.json")
  generated_count=$(jq '[.hooks[][].hooks[]] | length' "$OUT_CODEX/hooks.json")
  if [ "$source_count" != "$generated_count" ]; then
    matchers=$(jq -r '
      [.hooks | to_entries[] | .key as $event | .value[] | "\($event):\(.matcher // "(none)"):\(.hooks | length)"]
      | join(", ")
    ' "$CLAUDE_DIR/settings.json")
    echo "ERROR: generated .codex/hooks.json carries $generated_count hook(s) but .claude/settings.json wires $source_count — a matcher group was silently dropped during generation." >&2
    echo "ERROR: source matcher groups (event:matcher:hookCount) were: $matchers" >&2
    exit 1
  fi
}
assert_hook_counts_match

while IFS= read -r -d '' generated_file; do
  rewrite_skill_paths "$generated_file"
done < <(find "$OUT_AGENTS" -type f -print0)

generate_agent_toml() {
  local src="$1"
  local name description model body dst
  dst="$OUT_CODEX/agents/$(basename "${src%.md}").toml"

  name=$(awk -F': ' '/^name: / { print $2; exit }' "$src")
  description=$(awk -F': ' '/^description: / { sub(/^description: /, ""); print; exit }' "$src")
  model=$(awk -F': ' '/^model: / { print $2; exit }' "$src")
  [ -n "$model" ] && model=$(map_codex_model "$model")
  body=$(awk 'BEGIN { front=0; body=0 } /^---$/ { front++; if (front == 2) { body=1; next } } body { print }' "$src")
  body=$(printf '%s\n' "$body" | perl -0pe '
    s/\.claude\/skills/.agents\/skills/g;
  ')

  {
    printf 'name = %s\n' "$(printf '%s' "$name" | jq -Rs .)"
    printf 'description = %s\n' "$(printf '%s' "$description" | jq -Rs .)"
    [ -n "$model" ] && printf 'model = %s\n' "$(printf '%s' "$model" | jq -Rs .)"
    printf 'developer_instructions = %s\n' "$(printf '%s' "$body" | jq -Rs .)"
  } > "$dst"
}

if [ -d "$CLAUDE_DIR/agents" ]; then
  while IFS= read -r agent; do
    generate_agent_toml "$agent"
  done < <(find "$CLAUDE_DIR/agents" -maxdepth 1 -type f -name '*.md' | sort)
fi

if grep -R "$(printf '%s' "$ROOT" | sed 's/[.[\*^$()+?{}|]/\\&/g')" "$OUT_AGENTS" "$OUT_CODEX" >/dev/null 2>&1; then
  echo "ERROR: generated adapter contains an absolute path to $ROOT" >&2
  exit 1
fi

check_drift() {
  local actual="$1" expected="$2" label="$3"
  if [ ! -e "$actual" ]; then
    echo "DRIFT: $label is missing; run bin/sync-codex-adapter.sh" >&2
    return 1
  fi
  if ! diff -qr "$expected" "$actual" >/dev/null; then
    echo "DRIFT: $label differs from generated output; run bin/sync-codex-adapter.sh" >&2
    diff -qr "$expected" "$actual" >&2 || true
    return 1
  fi
}

if [ "$CHECK" = "1" ]; then
  rc=0
  check_drift "$ROOT/.agents" "$OUT_AGENTS" ".agents" || rc=1
  check_drift "$ROOT/.codex" "$OUT_CODEX" ".codex" || rc=1
  exit "$rc"
fi

if [ "$CLEAN" = "1" ]; then
  rm -rf "$ROOT/.agents" "$ROOT/.codex"
fi

mkdir -p "$ROOT/.agents" "$ROOT/.codex"
rm -rf "$ROOT/.agents/skills" "$ROOT/.codex/agents" "$ROOT/.codex/hooks" "$ROOT/.codex/rules" \
  "$ROOT/.codex/migrations" "$ROOT/.codex/registries" "$ROOT/.codex/hooks.json" \
  "$ROOT/.codex/project-config.defaults.json" "$ROOT/.codex/framework-version"
cp -R "$OUT_AGENTS/skills" "$ROOT/.agents/skills"
cp -R "$OUT_CODEX/agents" "$ROOT/.codex/agents"
cp "$OUT_CODEX/hooks.json" "$ROOT/.codex/hooks.json"

echo "Generated Codex adapter from .claude:"
echo "  .agents/skills"
echo "  .codex/agents"
echo "  .codex/hooks.json"
