#!/usr/bin/env bash
# Generate Codex-facing adapter files from the canonical .claude runtime.
#
# .claude remains the source of truth. This script mirrors the portable pieces
# into .agents/ and .codex/ so Codex can consume the same skills, agents, and
# hooks without hand-maintained drift.

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
  .claude/hooks    -> .codex/hooks
  .claude/rules    -> .codex/rules
  .claude/migrations, registries, config defaults -> .codex/
  .claude/settings.json -> .codex/hooks.json

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

rewrite_codex_paths() {
  perl -0pi -e '
    s/\.claude\/skills/.agents\/skills/g;
    s/\.claude\/settings\.json/.codex\/hooks.json/g;
    s/\.claude/.codex/g;
    s/Claude Code/Codex/g;
    s/Claude/Codex/g;
  ' "$@"
}

copy_tree() {
  local src="$1" dst="$2"
  [ -d "$src" ] || return 0
  mkdir -p "$(dirname "$dst")"
  cp -R "$src" "$dst"
}

copy_tree "$CLAUDE_DIR/skills" "$OUT_AGENTS/skills"
copy_tree "$CLAUDE_DIR/hooks" "$OUT_CODEX/hooks"
copy_tree "$CLAUDE_DIR/rules" "$OUT_CODEX/rules"
copy_tree "$CLAUDE_DIR/migrations" "$OUT_CODEX/migrations"
copy_tree "$CLAUDE_DIR/registries" "$OUT_CODEX/registries"
cp "$CLAUDE_DIR/settings.json" "$OUT_CODEX/hooks.json"
[ -f "$CLAUDE_DIR/project-config.defaults.json" ] && cp "$CLAUDE_DIR/project-config.defaults.json" "$OUT_CODEX/project-config.defaults.json"
[ -f "$CLAUDE_DIR/framework-version" ] && cp "$CLAUDE_DIR/framework-version" "$OUT_CODEX/framework-version"

while IFS= read -r -d '' generated_file; do
  rewrite_codex_paths "$generated_file"
done < <(find "$OUT_AGENTS" "$OUT_CODEX" -type f -print0)

generate_agent_toml() {
  local src="$1"
  local name description model body dst
  dst="$OUT_CODEX/agents/$(basename "${src%.md}").toml"

  name=$(awk -F': ' '/^name: / { print $2; exit }' "$src")
  description=$(awk -F': ' '/^description: / { sub(/^description: /, ""); print; exit }' "$src")
  model=$(awk -F': ' '/^model: / { print $2; exit }' "$src")
  body=$(awk 'BEGIN { front=0; body=0 } /^---$/ { front++; if (front == 2) { body=1; next } } body { print }' "$src")
  body=$(printf '%s\n' "$body" | perl -0pe '
    s/\.claude\/skills/.agents\/skills/g;
    s/\.claude/.codex/g;
    s/Claude Code/Codex/g;
    s/Claude/Codex/g;
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

if grep -R '\.claude' "$OUT_AGENTS" "$OUT_CODEX" >/dev/null 2>&1; then
  echo "ERROR: generated adapter still contains .claude references" >&2
  grep -R '\.claude' "$OUT_AGENTS" "$OUT_CODEX" >&2 || true
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
cp -R "$OUT_CODEX/hooks" "$ROOT/.codex/hooks"
[ -d "$OUT_CODEX/rules" ] && cp -R "$OUT_CODEX/rules" "$ROOT/.codex/rules"
[ -d "$OUT_CODEX/migrations" ] && cp -R "$OUT_CODEX/migrations" "$ROOT/.codex/migrations"
[ -d "$OUT_CODEX/registries" ] && cp -R "$OUT_CODEX/registries" "$ROOT/.codex/registries"
cp "$OUT_CODEX/hooks.json" "$ROOT/.codex/hooks.json"
[ -f "$OUT_CODEX/project-config.defaults.json" ] && cp "$OUT_CODEX/project-config.defaults.json" "$ROOT/.codex/project-config.defaults.json"
[ -f "$OUT_CODEX/framework-version" ] && cp "$OUT_CODEX/framework-version" "$ROOT/.codex/framework-version"

echo "Generated Codex adapter from .claude:"
echo "  .agents/skills"
echo "  .codex/agents"
echo "  .codex/hooks"
[ -d "$ROOT/.codex/rules" ] && echo "  .codex/rules"
[ -d "$ROOT/.codex/migrations" ] && echo "  .codex/migrations"
[ -d "$ROOT/.codex/registries" ] && echo "  .codex/registries"
echo "  .codex/hooks.json"
