#!/usr/bin/env bash
# Generate the thin Cursor overlay from the canonical .claude runtime.
#
# Native-first (AgDR-0151): Cursor loads .claude/settings.json hooks when
# third-party configs are enabled. This generator does NOT copy those
# gates. It emits:
#   - .cursor/hooks.json with a sessionStart pin overlay only
#   - .cursor/rules/apexyard.mdc advisory pointer
#   - .cursorignore managed block so sibling custom-skills/ and framework
#     skill backups are not a second skill root (AgDR-0187 / #1377)
#
# --user merges the overlay into ~/.cursor/hooks.json and replaces any
# leftover full generated adapter (entries that exec .claude/hooks/*.sh).
# See docs/cursor-adapter.md and docs/agdr/AgDR-0151.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK=0
CLEAN=0
USER_MODE=0
USER_DIR="${HOME:-}/.cursor"

usage() {
  cat <<'USAGE'
Usage: bin/sync-cursor-adapter.sh [--check] [--clean] [--root <path>]
                                   [--user [--user-dir <path>]]

Generate the thin Cursor overlay (native-first):
  (static) -> .cursor/hooks.json  (sessionStart pin only)
  (static) -> .cursor/rules/apexyard.mdc
  (managed block) -> .cursorignore  (skill-root dedupe for #1377)

Options:
  --check       Do not write files; fail if generated output would differ.
  --clean       Remove generated .cursor before writing (project-level only).
  --root PATH   Repository root to use instead of this script's parent.
  --user        MERGE the overlay into Cursor USER config
                (<--user-dir>/hooks.json, default ~/.cursor/hooks.json).
                Existing non-apexyard entries are preserved. Any leftover
                full generated adapter (commands that exec .claude/hooks/*.sh)
                is replaced by the thin overlay.
  --user-dir PATH  Override the user Cursor config directory (default
                    $HOME/.cursor). Only meaningful with --user.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --clean) CLEAN=1 ;;
    --user) USER_MODE=1 ;;
    --root)
      [ "$#" -ge 2 ] || { echo "ERROR: --root requires a path" >&2; exit 2; }
      ROOT="$2"
      shift
      ;;
    --user-dir)
      [ "$#" -ge 2 ] || { echo "ERROR: --user-dir requires a path" >&2; exit 2; }
      USER_DIR="$2"
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

if [ "$USER_MODE" = "1" ] && [ -z "$USER_DIR" ]; then
  echo "ERROR: --user requires \$HOME to be set, or pass --user-dir explicitly" >&2
  exit 2
fi

ROOT="$(cd "$ROOT" && pwd)"
CLAUDE_DIR="$ROOT/.claude"
LIB_CURSOR_SKILLS="$CLAUDE_DIR/hooks/_lib-cursor-skills.sh"

[ -d "$CLAUDE_DIR" ] || { echo "ERROR: .claude not found under $ROOT" >&2; exit 1; }
[ -f "$CLAUDE_DIR/hooks/cursor-session-pin.sh" ] || {
  echo "ERROR: .claude/hooks/cursor-session-pin.sh not found under $ROOT" >&2
  exit 1
}

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to generate the Cursor adapter safely" >&2
  exit 1
fi

TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/cursor-adapter.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

OUT_OVERLAY="$TMPDIR/overlay"
OUT_CURSORIGNORE="$TMPDIR/cursorignore.managed"
mkdir -p "$OUT_OVERLAY/rules"

# Project hooks run from the repo root. User hooks run from ~/.cursor, so
# they need the same ops-root walk the canonical wrappers already use.
PROJECT_PIN_CMD='.claude/hooks/cursor-session-pin.sh'
USER_PIN_CMD=$(printf '%s' "bash -c 'valid(){ [ -d \"\$1/.claude/hooks\" ] && { [ -f \"\$1/.apexyard-fork\" ] || { [ -f \"\$1/onboarding.yaml\" ] && [ -f \"\$1/apexyard.projects.yaml\" ]; }; }; };r=\"\";if [ -n \"\${CLAUDE_CODE_SESSION_ID:-}\" ];then p=\"\${APEXYARD_OPS_PIN_DIR:-\$HOME/.claude/apexyard}/ops-root-\${CLAUDE_CODE_SESSION_ID}\";[ -f \"\$p\" ] && IFS= read -r r < \"\$p\" && valid \"\$r\" || r=\"\";fi;if [ -z \"\$r\" ];then r=\${CURSOR_PROJECT_DIR:-\$PWD};while [ -n \"\$r\" ] && [ \"\$r\" != / ];do valid \"\$r\" && break;r=\${r%/*};done;fi;valid \"\$r\" || { printf \"%s\\n\" \"{}\"; exit 0; };CURSOR_PROJECT_DIR=\"\$r\" exec \"\$r/.claude/hooks/cursor-session-pin.sh\"'")

write_hooks_json() {
  local cmd="$1"
  jq -n --arg cmd "$cmd" '{
    version: 1,
    hooks: {
      sessionStart: [
        { command: $cmd }
      ]
    }
  }'
}

write_rules_mdc() {
  cat <<'MDC'
---
description: ApexYard governance bridge for Cursor. Mechanical gates load from .claude/settings.json when third-party configs are on. This file is the advisory pointer.
alwaysApply: true
---

# ApexYard governance (Cursor)

This repo is governed by ApexYard. Cursor loads the canonical
`.claude/hooks/*.sh` gates from `.claude/settings.json` when
**Settings → Rules, Skills, Subagents → Include third-party Plugins,
Skills, and other configs** is enabled.

The generated `.cursor/hooks.json` is a **thin overlay**. It only maps
Cursor `session_id` onto `CLAUDE_CODE_SESSION_ID` so the ops-root pin
works. It does not copy the 86 Claude Code gate entries. A leftover
full copy in `~/.cursor/hooks.json` can double-fire or fail closed.
Remove it with `bin/install-cursor-adapter.sh --uninstall` then
re-install.

Read `AGENTS.md` for the Cursor operator bridge. Read `CLAUDE.md` as the
index. Load a named file under `.claude/rules/` only when the work needs it.

Load-bearing rules before you start:

- One ticket at a time — `/start-ticket <N>` before editing (`.claude/rules/workflow-gates.md`)
- Branch `{type}/{TICKET-ID}-{description}`, PR title `type(TICKET): description` (`.claude/rules/git-conventions.md`)
- Ground factual claims in verified evidence (`.claude/rules/evidence-grounding.md`)
- Match work and ceremony to the change (`.claude/rules/right-size-ceremony.md`)
- Every PR needs a Glossary plus narrative Summary bullets (`.claude/rules/pr-quality.md`)
- Merges need an explicit per-PR human nod (`.claude/rules/pr-workflow.md`)
- Technical decisions get an AgDR before Build (`.claude/rules/agdr-decisions.md`)
- Report status like a colleague (`.claude/rules/reporting-style.md`)
- Use the controlled technical writing profile for durable artifacts (`.claude/rules/writing-standard.md`)

Open this ops fork directory in Cursor. Do not open a parent folder that
also contains the portfolio repo. A parent workspace can list the same
skill twice. Cursor's skill root here is `.claude/skills/` (AgDR-0187).

Regenerate this overlay after any change to
`.claude/hooks/cursor-session-pin.sh`: `bin/sync-cursor-adapter.sh`.
Drift check: `bin/sync-cursor-adapter.sh --check`.
MDC
}

CURSORIGNORE_BEGIN='# BEGIN apexyard-cursor-skills'
CURSORIGNORE_END='# END apexyard-cursor-skills'

cursorignore_managed_block() {
  cat <<'IGNORE'
# BEGIN apexyard-cursor-skills
# Keep Cursor skill discovery on one root: .claude/skills (AgDR-0187).
# Ignore override sources and framework backups that share skill names.
custom-skills/
**/custom-skills/
.claude/skill-framework-bak/
.claude/skills/*.framework.bak/
# END apexyard-cursor-skills
IGNORE
}

write_cursorignore() {
  local target="$1"
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/cursorignore.XXXXXX")
  if [ -f "$target" ]; then
    # Drop a previous managed block, keep adopter lines.
    awk -v begin="$CURSORIGNORE_BEGIN" -v end="$CURSORIGNORE_END" '
      $0 == begin { skip=1; next }
      $0 == end { skip=0; next }
      skip { next }
      { print }
    ' "$target" > "$tmp"
    if [ -s "$tmp" ] && [ -n "$(tail -n 1 "$tmp")" ]; then
      printf '\n' >> "$tmp"
    fi
  else
    : > "$tmp"
  fi
  cursorignore_managed_block >> "$tmp"
  mv "$tmp" "$target"
}

extract_cursorignore_managed_block() {
  local target="$1"
  [ -f "$target" ] || return 1
  awk -v begin="$CURSORIGNORE_BEGIN" -v end="$CURSORIGNORE_END" '
    $0 == begin { show=1 }
    show { print }
    $0 == end { exit }
  ' "$target"
}

warn_parent_workspace() {
  local root="$1"
  local parent
  [ -f "$LIB_CURSOR_SKILLS" ] || return 0
  # shellcheck source=/dev/null
  . "$LIB_CURSOR_SKILLS"
  parent=$(dirname "$root")
  if cursor_skills_parent_workspace_risk "$parent" 2>/dev/null; then
    echo "WARNING: parent of $root also looks like a split-portfolio workspace." >&2
    echo "WARNING: open the ops fork in Cursor, not the parent directory." >&2
    echo "WARNING: a parent workspace can list the same custom skill twice." >&2
  fi
}

check_skill_name_uniqueness() {
  local root="$1"
  local dups
  [ -f "$LIB_CURSOR_SKILLS" ] || return 0
  # shellcheck source=/dev/null
  . "$LIB_CURSOR_SKILLS"
  if dups=$(cursor_skills_duplicate_names "$root" 2>/dev/null); then
    return 0
  fi
  if [ -n "$dups" ]; then
    echo "WARNING: duplicate Cursor skill names under $root:" >&2
    printf '%s\n' "$dups" | sed 's/^/WARNING:   /' >&2
    echo "WARNING: run SessionStart link-custom-skills or see AgDR-0187." >&2
  fi
  return 0
}

if [ "$USER_MODE" = "1" ]; then
  write_hooks_json "$USER_PIN_CMD" > "$OUT_OVERLAY/hooks.json"
else
  write_hooks_json "$PROJECT_PIN_CMD" > "$OUT_OVERLAY/hooks.json"
fi
write_rules_mdc > "$OUT_OVERLAY/rules/apexyard.mdc"
cursorignore_managed_block > "$OUT_CURSORIGNORE"

if grep -R "$(printf '%s' "$ROOT" | sed 's/[.[\*^$()+?{}|]/\\&/g')" "$OUT_OVERLAY" "$OUT_CURSORIGNORE" >/dev/null 2>&1; then
  echo "ERROR: generated adapter contains an absolute path to $ROOT" >&2
  exit 1
fi

# Overlay entries exec cursor-session-pin.sh. Leftover full-adapter
# entries exec any .claude/hooks/*.sh. Both are apexyard-owned so a
# re-install replaces the lock-the-session copy with the thin overlay.
owned_hooks_only() {
  jq -S '(.hooks // {})
    | with_entries(.value |= map(select((.command // "") | test("\\.claude/hooks/"))))
    | with_entries(select(.value | length > 0))'
}

count_owned() {
  jq '[((.hooks // {})[]?[]?) | select((.command // "") | test("\\.claude/hooks/"))] | length'
}

warn_full_adapter() {
  local target="$1"
  [ -f "$target" ] || return 0
  local owned
  owned=$(count_owned <"$target" 2>/dev/null) || owned=0
  if grep -F 'APEXYARD_CURSOR_HOOK_GLOB' "$target" >/dev/null 2>&1 || [ "${owned:-0}" -gt 1 ]; then
    echo "WARNING: $target still has a full generated apexyard adapter ($owned owned entries)." >&2
    echo "WARNING: that copy can fail-closed-block every Shell/Write call. Re-install replaces it with the thin overlay." >&2
  fi
}

check_drift() {
  local actual="$1" expected="$2" label="$3"
  if [ ! -e "$actual" ]; then
    echo "DRIFT: $label is missing; run bin/sync-cursor-adapter.sh" >&2
    return 1
  fi
  if ! diff -qr "$expected" "$actual" >/dev/null; then
    echo "DRIFT: $label differs from generated output; run bin/sync-cursor-adapter.sh" >&2
    diff -qr "$expected" "$actual" >&2 || true
    return 1
  fi
}

check_cursorignore_drift() {
  local actual="$ROOT/.cursorignore"
  local expected="$OUT_CURSORIGNORE"
  local actual_block
  if [ ! -f "$actual" ]; then
    echo "DRIFT: .cursorignore is missing; run bin/sync-cursor-adapter.sh" >&2
    return 1
  fi
  actual_block=$(extract_cursorignore_managed_block "$actual") || actual_block=""
  if [ "$actual_block" != "$(cat "$expected")" ]; then
    echo "DRIFT: apexyard-managed block in .cursorignore differs; run bin/sync-cursor-adapter.sh" >&2
    return 1
  fi
  return 0
}

check_user_drift() {
  local target="$USER_DIR/hooks.json"
  if [ ! -f "$target" ]; then
    echo "DRIFT: $target is missing; run bin/install-cursor-adapter.sh" >&2
    return 1
  fi
  local actual_owned expected_owned
  actual_owned=$(owned_hooks_only <"$target" 2>/dev/null) || actual_owned="{}"
  expected_owned=$(owned_hooks_only <"$OUT_OVERLAY/hooks.json")
  if [ "$actual_owned" != "$expected_owned" ]; then
    echo "DRIFT: apexyard-managed entries in $target differ from generated output; run bin/install-cursor-adapter.sh" >&2
    return 1
  fi
}

install_user_hooks() {
  mkdir -p "$USER_DIR"
  local target="$USER_DIR/hooks.json"
  local existing_json='{"version":1,"hooks":{}}'
  if [ -f "$target" ]; then
    warn_full_adapter "$target"
    if jq empty "$target" >/dev/null 2>&1; then
      existing_json=$(cat "$target")
      cp "$target" "$target.bak-$(date +%Y%m%d%H%M%S)"
    else
      local ts; ts=$(date +%Y%m%d%H%M%S)
      cp "$target" "$target.bak-$ts.invalid"
      echo "WARNING: $target was not valid JSON; backed up to $target.bak-$ts.invalid and starting fresh" >&2
    fi
  fi

  jq -s '
    .[0] as $existing
    | .[1] as $generated
    | ($existing.hooks // {}) as $ehooks
    | ($generated.hooks // {}) as $ghooks
    | (($ehooks | keys) + ($ghooks | keys) | unique) as $allKeys
    | {
        version: ($generated.version // $existing.version // 1),
        hooks: (
          reduce $allKeys[] as $k ({};
            . + { ($k): (
              (($ehooks[$k] // []) | map(select(((.command // "") | test("\\.claude/hooks/")) | not)))
              + ($ghooks[$k] // [])
            ) }
          )
        )
      }
  ' <(printf '%s' "$existing_json") "$OUT_OVERLAY/hooks.json" > "$TMPDIR/merged-user-hooks.json"
  mv "$TMPDIR/merged-user-hooks.json" "$target"
}

if [ "$CHECK" = "1" ]; then
  rc=0
  if [ "$USER_MODE" = "1" ]; then
    check_user_drift || rc=1
  else
    check_drift "$ROOT/.cursor" "$OUT_OVERLAY" ".cursor" || rc=1
  fi
  check_cursorignore_drift || rc=1
  exit "$rc"
fi

if [ "$CLEAN" = "1" ]; then
  rm -rf "$ROOT/.cursor"
fi

mkdir -p "$ROOT/.cursor/rules"
rm -f "$ROOT/.cursor/rules/apexyard.mdc"
cp "$OUT_OVERLAY/rules/apexyard.mdc" "$ROOT/.cursor/rules/apexyard.mdc"
write_cursorignore "$ROOT/.cursorignore"
warn_parent_workspace "$ROOT"
check_skill_name_uniqueness "$ROOT"

if [ "$USER_MODE" = "1" ]; then
  install_user_hooks
  echo "Merged the thin apexyard Cursor overlay into the USER config:"
  echo "  $USER_DIR/hooks.json"
  echo "  $ROOT/.cursor/rules/apexyard.mdc"
  echo "  $ROOT/.cursorignore"
  echo "Enable Settings → Rules, Skills, Subagents → Include third-party"
  echo "Plugins, Skills, and other configs so .claude/settings.json gates load."
  echo "Open the ops fork in Cursor, not a parent that also holds the portfolio."
  echo "Cursor skill root: .claude/skills/ (one entry per name; override wins)."
else
  rm -f "$ROOT/.cursor/hooks.json"
  cp "$OUT_OVERLAY/hooks.json" "$ROOT/.cursor/hooks.json"
  echo "Generated thin Cursor overlay from .claude:"
  echo "  .cursor/hooks.json"
  echo "  .cursor/rules/apexyard.mdc"
  echo "  .cursorignore"
  echo "Open the ops fork in Cursor, not a parent that also holds the portfolio."
  echo "Cursor skill root: .claude/skills/ (one entry per name; override wins)."
fi