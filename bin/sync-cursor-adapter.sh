#!/usr/bin/env bash
# Generate the thin Cursor overlay from the canonical .claude runtime.
#
# Native-first (AgDR-0151): Cursor loads .claude/settings.json hooks when
# third-party configs are enabled. This generator does NOT copy those
# gates. It emits:
#   - .cursor/hooks.json with a sessionStart pin overlay only
#   - .cursor/rules/apexyard.mdc advisory pointer
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

Read `AGENTS.md` for the Cursor operator bridge. Read `CLAUDE.md` and
`.claude/rules/*.md` for the full rules.

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

Regenerate this overlay after any change to
`.claude/hooks/cursor-session-pin.sh`: `bin/sync-cursor-adapter.sh`.
Drift check: `bin/sync-cursor-adapter.sh --check`.
MDC
}

if [ "$USER_MODE" = "1" ]; then
  write_hooks_json "$USER_PIN_CMD" > "$OUT_OVERLAY/hooks.json"
else
  write_hooks_json "$PROJECT_PIN_CMD" > "$OUT_OVERLAY/hooks.json"
fi
write_rules_mdc > "$OUT_OVERLAY/rules/apexyard.mdc"

if grep -R "$(printf '%s' "$ROOT" | sed 's/[.[\*^$()+?{}|]/\\&/g')" "$OUT_OVERLAY" >/dev/null 2>&1; then
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
  exit "$rc"
fi

if [ "$CLEAN" = "1" ]; then
  rm -rf "$ROOT/.cursor"
fi

mkdir -p "$ROOT/.cursor/rules"
rm -f "$ROOT/.cursor/rules/apexyard.mdc"
cp "$OUT_OVERLAY/rules/apexyard.mdc" "$ROOT/.cursor/rules/apexyard.mdc"

if [ "$USER_MODE" = "1" ]; then
  install_user_hooks
  echo "Merged the thin apexyard Cursor overlay into the USER config:"
  echo "  $USER_DIR/hooks.json"
  echo "  $ROOT/.cursor/rules/apexyard.mdc"
  echo "Enable Settings → Rules, Skills, Subagents → Include third-party"
  echo "Plugins, Skills, and other configs so .claude/settings.json gates load."
else
  rm -f "$ROOT/.cursor/hooks.json"
  cp "$OUT_OVERLAY/hooks.json" "$ROOT/.cursor/hooks.json"
  echo "Generated thin Cursor overlay from .claude:"
  echo "  .cursor/hooks.json"
  echo "  .cursor/rules/apexyard.mdc"
fi
