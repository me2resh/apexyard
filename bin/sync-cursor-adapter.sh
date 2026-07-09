#!/usr/bin/env bash
# Generate Cursor-facing adapter files from the canonical .claude runtime.
#
# .claude remains the source of truth. This script emits .cursor/hooks.json
# (Cursor's native hook config) plus a minimal .cursor/rules/apexyard.mdc
# advisory bridge, while delegating every gate to the unmodified
# .claude/hooks/*.sh scripts — same declarative-generate pattern as
# bin/sync-codex-adapter.sh (AgDR-0088). See docs/agdr/AgDR-0091.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK=0
CLEAN=0

usage() {
  cat <<'USAGE'
Usage: bin/sync-cursor-adapter.sh [--check] [--clean] [--root <path>]

Generate the Cursor adapter from .claude:
  .claude/settings.json -> .cursor/hooks.json  (commands still exec .claude/hooks)
  (static)               -> .cursor/rules/apexyard.mdc  (advisory bridge)

Options:
  --check       Do not write files; fail if generated output would differ.
  --clean       Remove generated .cursor before writing.
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
  echo "ERROR: jq is required to generate the Cursor adapter safely" >&2
  exit 1
fi

TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/cursor-adapter.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

OUT_CURSOR="$TMPDIR/.cursor"
mkdir -p "$OUT_CURSOR/rules"

# Security-critical gates get failClosed:true (a hook crash/timeout BLOCKS
# instead of failing open) — Cursor hardening Codex doesn't offer. The list
# is derived from hook class, not hand-picked per-PR: merge gates (the four
# hooks that guard `gh pr merge` / `gh api .../merge`), the secrets scanner,
# and the trust/leak-protection class (no-direct-main, no-git-add-all, the
# leak-protection scrubber, and the onboarding-config leak guard). Every
# other hook (ticket-vocabulary format checks, ticket-first gates, advisory
# banners) stays fail-open — same default Cursor ships and the same posture
# those hooks already have under Claude Code (they exit 0 on error today).
FAIL_CLOSED_HOOKS=(
  block-unreviewed-merge.sh
  block-merge-on-red-ci.sh
  require-design-review-for-ui.sh
  require-architecture-review.sh
  check-secrets.sh
  block-git-add-all.sh
  block-main-push.sh
  block-private-refs-in-public-repos.sh
  block-onboarding-in-git.sh
)
fail_closed_json=$(printf '%s\n' "${FAIL_CLOSED_HOOKS[@]}" | jq -R . | jq -s .)

# Cursor's beforeShellExecution event puts the command at the TOP LEVEL
# ({"command": "...", "cwd": "...", "sandbox": ...}), while every .claude
# hook parses Claude Code's stdin shape (.tool_name / .tool_input.command).
# This is the stdin remap shim called out in #831: read the top-level
# `command`, apply the same Bash(glob) preflight filter Claude's handler-
# level `if` predicate encodes (glob "*" when no `if` was present, so
# unconditional Bash hooks still get remapped even though they have no
# predicate to check), then re-wrap into the canonical shape before
# delegating to the unmodified hook script. Built as a real (unexpanded)
# heredoc and passed through jq's --arg + @sh so quoting is handled by jq
# instead of by hand — the previous adapter (Codex) had to hand-escape a
# shell script embedded in a jq string literal; passing it as an argument
# avoids that entirely.
CURSOR_SHELL_REMAP=$(cat <<'SH'
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.command // empty')
[[ "$cmd" == $APEXYARD_CURSOR_HOOK_GLOB ]] || exit 0
cmdjson=$(printf '%s' "$input" | jq -c '.command // null')
printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$cmdjson" | bash -c "$APEXYARD_CURSOR_ORIGINAL_HOOK"
SH
)

generate_hooks_json() {
  jq --argjson failClosedList "$fail_closed_json" \
     --arg shellRemap "$CURSOR_SHELL_REMAP" '
    def hook_basename:
      if (.command | test("[a-zA-Z0-9_-]+\\.sh")) then
        (.command | capture("(?<f>[a-zA-Z0-9_-]+\\.sh)")).f
      else
        ""
      end;

    def is_fail_closed:
      (hook_basename) as $b | ($failClosedList | index($b)) != null;

    # Bash(glob) -> glob. Absent `if` means the hook is unconditional under
    # Claude Code (runs on every Bash call) — represented here as glob "*"
    # so the remapped command still applies to every shell invocation.
    def if_glob:
      if has("if") then
        (.if | capture("^(?<tool>[^()]+)\\((?<glob>.*)\\)$")).glob
      else
        "*"
      end;

    def to_shell_entry:
      . as $orig
      | ($orig | if_glob) as $glob
      | { command: (
            "APEXYARD_CURSOR_HOOK_GLOB=" + ($glob | @sh) +
            " APEXYARD_CURSOR_ORIGINAL_HOOK=" + ($orig.command | @sh) +
            " bash -c " + ($shellRemap | @sh)
          ) }
        + (if ($orig | is_fail_closed) then { failClosed: true } else {} end);

    def to_passthrough_entry(cursorMatcher):
      { command: .command }
      + (if cursorMatcher != null then { matcher: cursorMatcher } else {} end)
      + (if is_fail_closed then { failClosed: true } else {} end);

    (.hooks.PreToolUse // [])       as $pre
    | (.hooks.PostToolUse // [])      as $post
    | (.hooks.SessionStart // [])     as $session
    | (.hooks.UserPromptSubmit // []) as $prompt

    # PreToolUse/Bash -> beforeShellExecution (remapped; the dedicated
    # pre-shell-command block point, closest analog to our per-command
    # PreToolUse:Bash matcher).
    | ([$pre[] | select(.matcher == "Bash") | .hooks[] | to_shell_entry]) as $beforeShell

    # PreToolUse/{Edit|Write|MultiEdit, Write} -> preToolUse (generic event;
    # its tool_name/tool_input shape is the closest match to what the bash
    # hooks already parse, so no remap — passthrough). Cursor tool-type
    # matcher values are Shell/Read/Write/Grep/Delete/Task, so Edit and
    # MultiEdit both fold into "Write" (a known conformance gap: Cursor
    # does not distinguish Edit vs MultiEdit vs Write the way Claude Code
    # does — see docs/cursor-adapter.md).
    | ([$pre[] | select(.matcher == "Edit|Write|MultiEdit" or .matcher == "Write")
       | .hooks[] | to_passthrough_entry("Write")]) as $preWrite
    | ([$pre[] | select(.matcher == "Read|Glob|Grep")
       | .hooks[] | to_passthrough_entry("Read|Grep")]) as $preRead
    | ($preWrite + $preRead) as $preToolUse

    | ([$post[] | select(.matcher == "Bash")
       | .hooks[] | to_passthrough_entry("Shell")]) as $postShell
    | ([$post[] | select(.matcher == "Write|Edit|MultiEdit")
       | .hooks[] | to_passthrough_entry("Write")]) as $postWrite
    | ($postShell + $postWrite) as $postToolUse

    | ([$session[] | .hooks[] | to_passthrough_entry(null)]) as $sessionStart
    | ([$prompt[] | .hooks[] | to_passthrough_entry(null)]) as $beforeSubmitPrompt

    | { version: 1,
        hooks: (
          { beforeShellExecution: $beforeShell,
            preToolUse: $preToolUse,
            postToolUse: $postToolUse,
            sessionStart: $sessionStart,
            beforeSubmitPrompt: $beforeSubmitPrompt
          } | with_entries(select(.value | length > 0))
        )
      }
  ' "$CLAUDE_DIR/settings.json"
}

write_rules_mdc() {
  cat <<'MDC'
---
description: ApexYard governance bridge for Cursor — the mechanical gates run via .cursor/hooks.json; this file is the advisory pointer.
alwaysApply: true
---

# ApexYard governance (Cursor)

This repo is governed by ApexYard's SDLC framework. The gates are
**mechanical, not this file** — `.cursor/hooks.json` (generated by
`bin/sync-cursor-adapter.sh`) delegates every hook to the same audited
`.claude/hooks/*.sh` scripts Claude Code enforces: ticket-first edits,
merge gates (Rex + CEO + design + architecture review), the red-CI block,
secrets scanning, branch/PR/commit format, and the trust-chain / leak-
protection checks. A blocked action here means one of those scripts
exited 2 — read its message, it names the fix.

For the full rules (why a gate exists, how to satisfy it, the escape
hatches) read `CLAUDE.md` at the repo root and the modular rule files
under `.claude/rules/*.md`. Load-bearing ones to know before you start:

- One ticket at a time — `/start-ticket <N>` before editing (`.claude/rules/workflow-gates.md`)
- Branch `{type}/{TICKET-ID}-{description}`, PR title `type(TICKET): description` (`.claude/rules/git-conventions.md`)
- Every PR needs a Glossary + narrative Summary bullets (`.claude/rules/pr-quality.md`)
- Merges need an explicit per-PR human nod — no plan-level "go" (`.claude/rules/pr-workflow.md`)
- Technical decisions get an AgDR before Build (`.claude/rules/agdr-decisions.md`)

Regenerate this adapter after any `.claude/settings.json` or
`.claude/hooks/*.sh` change: `bin/sync-cursor-adapter.sh`. Drift check:
`bin/sync-cursor-adapter.sh --check`.
MDC
}

generate_hooks_json > "$OUT_CURSOR/hooks.json"
write_rules_mdc > "$OUT_CURSOR/rules/apexyard.mdc"

if grep -R "$(printf '%s' "$ROOT" | sed 's/[.[\*^$()+?{}|]/\\&/g')" "$OUT_CURSOR" >/dev/null 2>&1; then
  echo "ERROR: generated adapter contains an absolute path to $ROOT" >&2
  exit 1
fi

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

if [ "$CHECK" = "1" ]; then
  rc=0
  check_drift "$ROOT/.cursor" "$OUT_CURSOR" ".cursor" || rc=1
  exit "$rc"
fi

if [ "$CLEAN" = "1" ]; then
  rm -rf "$ROOT/.cursor"
fi

mkdir -p "$ROOT/.cursor/rules"
rm -f "$ROOT/.cursor/hooks.json" "$ROOT/.cursor/rules/apexyard.mdc"
cp "$OUT_CURSOR/hooks.json" "$ROOT/.cursor/hooks.json"
cp "$OUT_CURSOR/rules/apexyard.mdc" "$ROOT/.cursor/rules/apexyard.mdc"

echo "Generated Cursor adapter from .claude:"
echo "  .cursor/hooks.json"
echo "  .cursor/rules/apexyard.mdc"
