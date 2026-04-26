#!/bin/bash
# voice-prompt-on-pause.sh — speak the assistant's question aloud when it
# pauses for user input (Jarvis-from-Iron-Man style, macOS only initial phase).
#
# Stop hook: fires on assistant turn end. Receives JSON on stdin from
# Claude Code:
#   { "session_id": "...", "transcript_path": "/path/to/transcript.jsonl", ... }
#
# Behaviour:
#   - Reads project config via _lib-read-config.sh
#   - If `voice_prompts.enabled` ≠ "true" → exit 0 immediately (fast-path)
#   - If `say` not on PATH → exit 0 (Linux/Windows fall-through; cross-platform
#     is Phase 2 per AgDR-0009)
#   - Parses the JSONL transcript, extracts the last assistant message's text
#   - Applies a configurable trigger heuristic (default `questions-only`):
#       * Last paragraph ends with `?` (after stripping trailing markdown emphasis), OR
#       * Last paragraph contains a recognised "Reply with X" / "Approved?" /
#         "a/b/c" / etc. pattern
#   - Strips markdown (backticks, bold/italic, link syntax, bullets, table pipes)
#   - Truncates to `max_chars` at the nearest sentence boundary
#   - Runs `say -v <voice> -r <rate_wpm> "<text>" &` (fire-and-forget so the
#     conversation never blocks on TTS)
#   - ALWAYS exits 0 — TTS errors must not interrupt the conversation
#
# Cross-platform / cloud-TTS providers are deferred to Phase 2/3 per AgDR-0009.

set -u

# Read the JSON event from stdin (Claude Code passes Stop hook events here).
INPUT=$(cat)

# ---------------------------------------------------------------------------
# 1. Locate repo + config library. If we're not in an apexyard fork, no-op.
# ---------------------------------------------------------------------------

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

LIB="$REPO_ROOT/.claude/hooks/_lib-read-config.sh"
if [ ! -f "$LIB" ]; then
  exit 0
fi
# shellcheck disable=SC1090,SC1091
. "$LIB"

# ---------------------------------------------------------------------------
# 2. Fast-path: feature disabled → exit immediately, no extra work.
# ---------------------------------------------------------------------------

ENABLED=$(config_get_or '.voice_prompts.enabled' 'false')
if [ "$ENABLED" != "true" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Platform check. macOS only in initial phase. Phase 2 adds Linux/Windows
#    paths via OS detection — for now just skip silently.
# ---------------------------------------------------------------------------

if ! command -v say >/dev/null 2>&1; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Read remaining config with sensible defaults.
# ---------------------------------------------------------------------------

VOICE=$(config_get_or '.voice_prompts.voice' 'Daniel')
MAX_CHARS=$(config_get_or '.voice_prompts.max_chars' '200')
RATE_WPM=$(config_get_or '.voice_prompts.rate_wpm' '180')
TRIGGER=$(config_get_or '.voice_prompts.trigger' 'questions-only')

# Sanity: max_chars / rate_wpm should be integers. Fall back to defaults if not.
echo "$MAX_CHARS" | grep -qE '^[0-9]+$' || MAX_CHARS=200
echo "$RATE_WPM" | grep -qE '^[0-9]+$' || RATE_WPM=180

# ---------------------------------------------------------------------------
# 5. Parse the transcript path from the input. Bail if missing or unreadable.
# ---------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 6. Extract the LAST assistant message's text content from the JSONL.
#
#    Each line in the transcript is a JSON object. Assistant lines have
#    `.type == "assistant"` and `.message.content` as either an array of
#    blocks (we want the `text`-typed ones) or, for older formats, a string.
#    `jq -s` slurps all lines into one array so we can take the last match.
# ---------------------------------------------------------------------------

LAST_TEXT=$(jq -sr '
  [
    .[]
    | select(.type == "assistant")
    | (
        .message.content // []
        | if type == "array"
          then [.[] | select(.type == "text") | .text] | join("\n\n")
          else tostring
          end
      )
    | select(length > 0)
  ]
  | last // ""
' "$TRANSCRIPT_PATH" 2>/dev/null)

if [ -z "$LAST_TEXT" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 7. Take the LAST paragraph (separated by blank line). The trailing paragraph
#    is where the question / call-to-action usually lives.
# ---------------------------------------------------------------------------

LAST_PARA=$(echo "$LAST_TEXT" | awk 'BEGIN{RS=""} END{print}')

# ---------------------------------------------------------------------------
# 8. Apply the trigger heuristic.
# ---------------------------------------------------------------------------

should_speak=false

if [ "$TRIGGER" = "always" ]; then
  should_speak=true
elif [ "$TRIGGER" = "questions-only" ]; then
  # Strip trailing whitespace + trailing markdown-emphasis chars before
  # checking the last char. Examples we want to match: `answered?`,
  # `**approved?**`, `_approved?_`, `` `merge`? ``.
  trimmed=$(echo "$LAST_PARA" | sed -E 's/[[:space:]]*$//' | sed -E 's/[*_`]+$//')
  last_char=$(printf '%s' "$trimmed" | tail -c 1)
  if [ "$last_char" = "?" ]; then
    should_speak=true
  else
    lower=$(echo "$LAST_PARA" | tr '[:upper:]' '[:lower:]')
    # Recognised "we want input" patterns. Matched case-insensitively.
    if echo "$lower" | grep -qE 'approved\?|reply with|reply `|confirm|a/b/c|\(a\)|\(b\)|\(c\)|which path|which one|proceed\?'; then
      should_speak=true
    fi
  fi
else
  # Unknown trigger value — be conservative, don't speak.
  exit 0
fi

if [ "$should_speak" != "true" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 9. Strip markdown so `say` doesn't read backticks / asterisks / link syntax.
# ---------------------------------------------------------------------------

SPOKEN=$(printf '%s' "$LAST_PARA" | sed -E '
  s/`([^`]*)`/\1/g
  s/\*\*([^*]+)\*\*/\1/g
  s/\*([^*]+)\*/\1/g
  s/_([^_]+)_/\1/g
  s/\[([^]]+)\]\([^)]+\)/\1/g
  s/^#+[[:space:]]+//
  s/^[-*][[:space:]]+//
  s/\|//g
')

# Collapse runs of whitespace (from emoji or stripped chars) to single spaces.
SPOKEN=$(echo "$SPOKEN" | tr -s '[:space:]' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

# ---------------------------------------------------------------------------
# 10. Truncate to MAX_CHARS at sentence boundary. Walk forward, keeping
#     sentences until adding the next would exceed the cap.
# ---------------------------------------------------------------------------

if [ "${#SPOKEN}" -gt "$MAX_CHARS" ]; then
  truncated=""
  remaining="$SPOKEN"
  while [ -n "$remaining" ]; do
    # Match next sentence ending in . ! or ?, plus optional trailing space.
    sentence=$(printf '%s' "$remaining" | sed -nE 's/^([^.!?]*[.!?])([[:space:]]|$).*/\1/p')
    if [ -z "$sentence" ]; then
      # No sentence terminator left — take whatever remains as the last unit.
      sentence="$remaining"
    fi
    next_len=$(( ${#truncated} + ${#sentence} + 1 ))
    if [ "$next_len" -gt "$MAX_CHARS" ]; then
      break
    fi
    if [ -z "$truncated" ]; then
      truncated="$sentence"
    else
      truncated="$truncated $sentence"
    fi
    remaining=${remaining#"$sentence"}
    remaining=$(printf '%s' "$remaining" | sed -E 's/^[[:space:]]+//')
  done
  if [ -n "$truncated" ]; then
    SPOKEN="$truncated"
  else
    # No sentence fit under the cap — hard-cut at MAX_CHARS, ending on a word
    # boundary if reasonably close.
    SPOKEN=$(printf '%s' "$SPOKEN" | cut -c1-"$MAX_CHARS")
    SPOKEN=$(printf '%s' "$SPOKEN" | sed -E 's/[[:space:]][^[:space:]]*$//')
  fi
fi

# Final guard: if stripping left us with nothing useful, don't invoke `say`
# with an empty string.
if [ -z "$SPOKEN" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 11. Speak — fire-and-forget by default. Detach so a long utterance can't
#     block the hook's exit. Errors swallowed; TTS must never disrupt the
#     conversation.
#
#     Tests set VOICE_PROMPTS_SYNC=1 to run synchronously instead — the
#     orphaned-bg-process reparenting interacts badly with subshell-wrapped
#     test runners, so async mode produces flaky test runs. Real production
#     invocations always run async.
# ---------------------------------------------------------------------------

if [ "${VOICE_PROMPTS_SYNC:-}" = "1" ]; then
  say -v "$VOICE" -r "$RATE_WPM" "$SPOKEN" >/dev/null 2>&1
else
  (
    say -v "$VOICE" -r "$RATE_WPM" "$SPOKEN" >/dev/null 2>&1
  ) &
  # Best-effort detach — `disown` is bash-builtin and not always available
  # in `sh`. Falls through on failure.
  disown 2>/dev/null || true
fi

exit 0
