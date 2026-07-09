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
USER_MODE=0
USER_DIR="${HOME:-}/.cursor"

usage() {
  cat <<'USAGE'
Usage: bin/sync-cursor-adapter.sh [--check] [--clean] [--root <path>]
                                   [--user [--user-dir <path>]]

Generate the Cursor adapter from .claude:
  .claude/settings.json -> .cursor/hooks.json  (commands still exec .claude/hooks)
  (static)               -> .cursor/rules/apexyard.mdc  (advisory bridge)

Options:
  --check       Do not write files; fail if generated output would differ.
  --clean       Remove generated .cursor before writing (project-level only).
  --root PATH   Repository root to use instead of this script's parent.
  --user        MERGE the generated hooks.json into Cursor's USER-level config
                (<--user-dir>/hooks.json, default ~/.cursor/hooks.json) instead
                of writing a project .cursor/hooks.json. Cursor 3.x only loads
                hooks from the user config (me2resh/apexyard#840 finding #3) —
                prefer `bin/install-cursor-adapter.sh` over this flag directly
                unless you need the raw merge without its uninstall/backup
                ergonomics. The project .cursor/rules/apexyard.mdc advisory
                bridge is still written either way. Existing non-apexyard
                entries in the user file (any event, any hook not sourced from
                a .claude/hooks/*.sh path) are preserved; only apexyard's own
                entries are replaced, so this is safe to re-run.
  --user-dir PATH  Override the user Cursor config directory (default
                    $HOME/.cursor). Only meaningful with --user; primarily for
                    tests, which must never write into a real $HOME.
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
# the trust/leak-protection class (no-direct-main, no-git-add-all, the
# leak-protection scrubber, and the onboarding-config leak guard), and the
# migration blast-radius gate (require-migration-ticket.sh — schema/data
# migrations are high blast-radius the same way a merge is; a crashed or
# timed-out hook here should block the edit, not silently wave it through —
# decided on #840 B3, see docs/agdr/AgDR-0091's "Update (GH-840)" section).
# Every other hook (ticket-vocabulary format checks, the general ticket-first
# gate, advisory banners) stays fail-open — same default Cursor ships and the
# same posture those hooks already have under Claude Code (they exit 0 on
# error today).
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
  require-migration-ticket.sh
)
fail_closed_json=$(printf '%s\n' "${FAIL_CLOSED_HOOKS[@]}" | jq -R . | jq -s .)

# Recognized PreToolUse/PostToolUse matcher values this generator maps to a
# Cursor event (see generate_hooks_json below). Kept as a single source of
# truth so assert_hook_counts_match's "which matcher got dropped" diagnostic
# can never drift from the actual mapping logic.
RECOGNIZED_PRE_MATCHERS_JSON='["Bash","Edit|Write|MultiEdit","Write","Read|Glob|Grep"]'
RECOGNIZED_POST_MATCHERS_JSON='["Bash","Write|Edit|MultiEdit"]'

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

# Fail loud on a silent gate-hole (Rex, #838; hardening tracked as #840 B2).
# generate_hooks_json's jq filter hardcodes a recognized-matcher allowlist
# (Axis 1 of AgDR-0091 — an explicit per-matcher mapping table, chosen over
# a generic passthrough) — a future new matcher shape wired into
# .claude/settings.json (e.g. a Claude Code release adding a new tool
# matcher) would silently fall through every `select(.matcher == …)` clause
# and be dropped from .cursor/hooks.json with no error. This assertion turns
# that silent drop into a build error, naming the exact matcher group that
# didn't make it across.
assert_hook_counts_match() {
  local source_count generated_count unmapped
  source_count=$(jq '[.hooks[][].hooks[]] | length' "$CLAUDE_DIR/settings.json")
  generated_count=$(jq '[.hooks[][]] | length' "$OUT_CURSOR/hooks.json")
  if [ "$source_count" != "$generated_count" ]; then
    # NOTE: each comma-separated branch below is wrapped in its own parens.
    # jq's `as` binding scopes across a bare top-level comma inside `[...]`,
    # so without the parens the $g/$m bound while iterating PreToolUse would
    # leak into the PostToolUse branch and misindex there — a real footgun,
    # not stylistic parens.
    unmapped=$(jq -r --argjson pre "$RECOGNIZED_PRE_MATCHERS_JSON" --argjson post "$RECOGNIZED_POST_MATCHERS_JSON" '
      [
        ((.hooks.PreToolUse // [])[] | . as $g | ($g.matcher) as $m
          | select(($pre | index($m)) == null) | "PreToolUse:\($m // "(none)"):\($g.hooks | length)"),
        ((.hooks.PostToolUse // [])[] | . as $g | ($g.matcher) as $m
          | select(($post | index($m)) == null) | "PostToolUse:\($m // "(none)"):\($g.hooks | length)")
      ] | join(", ")
    ' "$CLAUDE_DIR/settings.json")
    echo "ERROR: generated .cursor/hooks.json carries $generated_count hook(s) but .claude/settings.json wires $source_count — a matcher group was silently dropped during generation." >&2
    if [ -n "$unmapped" ]; then
      echo "ERROR: unrecognized matcher group(s) not mapped by this generator (event:matcher:hookCount): $unmapped" >&2
    fi
    exit 1
  fi
}
assert_hook_counts_match

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

# Apexyard-owned hook entries are identified structurally, not by a custom
# JSON field (Cursor's hook-entry schema is not documented to tolerate extra
# keys, so we don't risk adding one) — every entry this generator emits execs
# a `.claude/hooks/*.sh` script somewhere in its `command` string, whether via
# the beforeShellExecution remap shim's $APEXYARD_CURSOR_ORIGINAL_HOOK or a
# plain passthrough `exec $r/.claude/hooks/<name>.sh`. Filtering on that
# substring is what lets --user merge (and install-cursor-adapter.sh
# --uninstall) tell "ours, safe to replace/remove" from "the user's own
# unrelated hook, must not touch" without any out-of-band bookkeeping file.
owned_hooks_only() {
  jq -S '(.hooks // {})
    | with_entries(.value |= map(select((.command // "") | test("\\.claude/hooks/"))))
    | with_entries(select(.value | length > 0))'
}

check_user_drift() {
  local target="$USER_DIR/hooks.json"
  if [ ! -f "$target" ]; then
    echo "DRIFT: $target is missing; run bin/install-cursor-adapter.sh" >&2
    return 1
  fi
  local actual_owned expected_owned
  actual_owned=$(owned_hooks_only <"$target" 2>/dev/null) || actual_owned="{}"
  expected_owned=$(owned_hooks_only <"$OUT_CURSOR/hooks.json")
  if [ "$actual_owned" != "$expected_owned" ]; then
    echo "DRIFT: apexyard-managed entries in $target differ from generated output; run bin/install-cursor-adapter.sh" >&2
    return 1
  fi
}

# Merge $OUT_CURSOR/hooks.json into $USER_DIR/hooks.json: every existing
# entry whose command is NOT apexyard-owned (see owned_hooks_only above) is
# kept untouched, in whatever event array it already lives in — a user's own
# hooks, or another tool's, survive re-running this script. Apexyard's own
# entries are dropped and replaced wholesale with the freshly generated ones,
# so a re-run (or an upgrade to a newer .claude/hooks/*.sh) is idempotent
# rather than accumulating duplicates. A timestamped backup is written before
# every overwrite of a pre-existing, valid target file.
install_user_hooks() {
  mkdir -p "$USER_DIR"
  local target="$USER_DIR/hooks.json"
  local existing_json='{"version":1,"hooks":{}}'
  if [ -f "$target" ]; then
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
  ' <(printf '%s' "$existing_json") "$OUT_CURSOR/hooks.json" > "$TMPDIR/merged-user-hooks.json"
  mv "$TMPDIR/merged-user-hooks.json" "$target"
}

if [ "$CHECK" = "1" ]; then
  rc=0
  if [ "$USER_MODE" = "1" ]; then
    check_user_drift || rc=1
  else
    check_drift "$ROOT/.cursor" "$OUT_CURSOR" ".cursor" || rc=1
  fi
  exit "$rc"
fi

if [ "$CLEAN" = "1" ]; then
  rm -rf "$ROOT/.cursor"
fi

mkdir -p "$ROOT/.cursor/rules"
rm -f "$ROOT/.cursor/rules/apexyard.mdc"
cp "$OUT_CURSOR/rules/apexyard.mdc" "$ROOT/.cursor/rules/apexyard.mdc"

if [ "$USER_MODE" = "1" ]; then
  install_user_hooks
  echo "Merged the apexyard Cursor hook adapter into the USER config (the"
  echo "location Cursor 3.x actually loads — me2resh/apexyard#840 finding #3):"
  echo "  $USER_DIR/hooks.json"
  echo "  $ROOT/.cursor/rules/apexyard.mdc  (project-level advisory bridge, unaffected by the location finding)"
else
  rm -f "$ROOT/.cursor/hooks.json"
  cp "$OUT_CURSOR/hooks.json" "$ROOT/.cursor/hooks.json"
  echo "Generated Cursor adapter from .claude:"
  echo "  .cursor/hooks.json"
  echo "  .cursor/rules/apexyard.mdc"
fi
