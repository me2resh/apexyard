#!/usr/bin/env bash
# Extracts the verbatim block message block-git-add-all.sh emits on a
# blocked command, and (in --check mode) asserts a given transcript file
# contains it.
#
# WHY THIS EXISTS
# ----------------
# The conformance workflow (.github/workflows/conformance.yml) needs to
# assert that a real, credentialed agent turn under opencode/pi/Codex was
# actually stopped by the DELEGATED bash hook — not a harness self-block,
# not a fail-closed error, not a lucky model refusal. The load-bearing
# signal is the hook's OWN verbatim output appearing in the harness's
# transcript. Hardcoding a copy of that message in the workflow YAML would
# silently drift the moment block-git-add-all.sh's wording changes — this
# script instead RUNS the real, unmodified hook against a synthetic
# `git add -A` stdin payload and captures its actual stderr, so the
# assertion is always checking against current, real behaviour.
#
# USAGE
# -----
#   bin/conformance-assert-block-message.sh --print
#       Prints the hook's live-captured block message to stdout (one
#       run of the real hook against a synthetic "git add -A" stdin).
#
#   bin/conformance-assert-block-message.sh --check <transcript-file>
#       Exits 0 if the transcript contains a distinctive substring of the
#       hook's live-captured block message; exits 1 otherwise, printing a
#       diagnostic. This is what the conformance workflow calls per
#       harness job after driving one gated turn.
#
# The "distinctive substring" (not the whole multi-line message) is the
# comparison unit deliberately: harnesses may wrap, truncate, reflow, or
# partially swallow multi-line stderr in their own transcript formatting.
# The fixed anchor line is stable, hook-internal wording that would only
# change if the hook's own message changed — at which point this script
# picking it up automatically (rather than a hardcoded copy) is exactly
# the point.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$ROOT/.claude/hooks/block-git-add-all.sh"

usage() {
  cat <<'USAGE'
Usage:
  bin/conformance-assert-block-message.sh --print
  bin/conformance-assert-block-message.sh --check <transcript-file>
USAGE
}

[ -f "$HOOK" ] || { echo "ERROR: hook not found: $HOOK" >&2; exit 1; }

live_block_message() {
  # Run the real hook against a synthetic PreToolUse stdin payload for
  # `git add -A`. The hook is expected to exit 2 and write its block
  # message to stderr; nothing here duplicates that wording by hand.
  local out rc
  out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git add -A"}}' | bash "$HOOK" 2>&1 1>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "ERROR: block-git-add-all.sh did not exit 2 against a synthetic 'git add -A' payload (got exit $rc) — hook behaviour may have changed; refusing to derive a stale assertion" >&2
    exit 1
  fi
  printf '%s\n' "$out"
}

# The anchor substring used for the transcript --check. Deliberately a
# short, single-line fragment (not the full multi-line message) so it
# survives a harness's own line-wrapping/reflow of captured stderr.
ANCHOR="are forbidden"

case "${1:-}" in
  --print)
    live_block_message
    ;;
  --check)
    [ "$#" -ge 2 ] || { echo "ERROR: --check requires a transcript file path" >&2; usage >&2; exit 2; }
    TRANSCRIPT="$2"
    [ -f "$TRANSCRIPT" ] || { echo "ERROR: transcript file not found: $TRANSCRIPT" >&2; exit 1; }

    msg="$(live_block_message)"
    if ! printf '%s' "$msg" | grep -qF "$ANCHOR"; then
      echo "ERROR: block-git-add-all.sh's own live output no longer contains the expected anchor ('$ANCHOR') — this script's ANCHOR needs updating to match the hook's current wording" >&2
      exit 1
    fi

    if grep -qF "$ANCHOR" "$TRANSCRIPT"; then
      echo "CONFORMANCE PASS — transcript contains the delegated hook's verbatim block anchor ('$ANCHOR')."
      exit 0
    else
      echo "CONFORMANCE FAIL — transcript does not contain the delegated hook's verbatim block anchor ('$ANCHOR')." >&2
      echo "This means the command was not blocked by the real, unmodified block-git-add-all.sh — check for a harness self-block, a fail-closed error, or the model simply not running the command." >&2
      exit 1
    fi
    ;;
  -h|--help|"")
    usage
    exit 0
    ;;
  *)
    echo "ERROR: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
esac
