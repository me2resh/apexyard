#!/bin/bash
# Non-blocking advisory hook: detects intent phrases in the user's prompt
# that map to an existing shipped skill, and emits a system-reminder-style
# banner naming the skill + its template (per me2resh/apexyard#894).
#
# This is the SKILL-side sibling of detect-role-trigger.sh (the ROLE-side
# advisory). Same advisory shape as detect-role-trigger.sh and
# check-upstream-drift.sh: it can never force the skill, only surface it.
# Exit 0 in every path.
#
# Motivation (from #894): "do a threat model", "make a DFD", "write it up"
# all map to shipped skills (/threat-model, /dfd, /write-spec), but an
# agent relying on its own discipline can quietly do the work by hand
# instead — losing the skill's template, frontmatter, and structured
# exports. detect-role-trigger.sh already closes this gap for ROLE
# activation; nothing closed it for SKILL activation until now.
#
# Data-driven (acceptance criterion #2): the phrase → skill map lives at
# .claude/project-config.defaults.json → skill_intent.map, NOT hard-coded
# in this script. Adopters extend/override it via .claude/project-config.json
# (shallow-merge REPLACES the whole array — copy entries you want to keep)
# without touching this file. See .claude/rules/skill-first.md.
#
# Matching: each map entry lists literal phrases. The prompt is normalised
# (lowercased, punctuation stripped to spaces) and each phrase is checked
# as a literal substring (grep -F) against the normalised prompt. Multi-word
# phrases are the noise guard here — a single generic word like "audit"
# would over-fire; "accessibility audit" is high-signal.
#
# Event: UserPromptSubmit only. Unlike detect-role-trigger.sh, this hook
# has no path- or label-based trigger family — skill intent lives in what
# the user is ASKING for, not in which file is being edited.

set -u

INPUT=$(cat)

HOOK_EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)

# Only UserPromptSubmit is relevant. Exit quietly (advisory, non-blocking)
# for every other event — mirrors detect-role-trigger.sh's dispatch shape.
if [ "$HOOK_EVENT" != "UserPromptSubmit" ]; then
  exit 0
fi

PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
[ -z "$PROMPT" ] && exit 0

# ---------------------------------------------------------------------------
# Load the phrase → skill map from project config (data-driven, #894 AC 2).
# HOOK_DIR resolves via BASH_SOURCE so this works regardless of the
# caller's cwd (same pattern _lib-read-config.sh uses to find its
# sibling _lib-ops-root.sh).
# ---------------------------------------------------------------------------
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "$HOOK_DIR" ] || [ ! -f "$HOOK_DIR/_lib-read-config.sh" ]; then
  # Can't locate the config lib — degrade silently. Advisory hook, no map,
  # nothing to fire.
  exit 0
fi
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-read-config.sh"

# config_get is hard-coded to `jq -r`; wrapping the array in `tojson`
# collapses it to a single-line JSON string that -r then prints raw
# (no outer quotes) — lets us read a JSON array through the existing
# helper without needing a second jq flag or touching the shared lib.
MAP_JSON=$(config_get '.skill_intent.map // [] | tojson' 2>/dev/null)
if [ -z "$MAP_JSON" ] || [ "$MAP_JSON" = "null" ]; then
  MAP_JSON='[]'
fi

# Nothing to match against — no-op.
if [ "$MAP_JSON" = "[]" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Normalise the prompt: lowercase, punctuation → spaces, collapse
# whitespace. Same normalisation shape as detect-role-trigger.sh's
# detect_prompt_triggers / detect_contrarian_triggers.
# ---------------------------------------------------------------------------
NORM=$(printf '%s' "$PROMPT" \
  | tr '[:upper:]' '[:lower:]' \
  | tr ',.;:!?()[]{}"'"'" ' ' \
  | tr -s '[:space:]' ' ')
[ -z "$NORM" ] && exit 0

# ---------------------------------------------------------------------------
# Iterate map entries. Each entry: {skill, template, phrases:[...]}.
# On the FIRST matching phrase for an entry, emit one banner and move to
# the next entry (de-duped per skill within a single prompt). Multiple
# DIFFERENT skills can fire from one prompt — over-triggering is cheap
# (the agent no-ops on a false positive), consistent with
# detect-role-trigger.sh's philosophy.
# ---------------------------------------------------------------------------
entry_count=$(printf '%s' "$MAP_JSON" | jq 'length' 2>/dev/null)
[ -z "$entry_count" ] && exit 0

i=0
while [ "$i" -lt "$entry_count" ]; do
  entry=$(printf '%s' "$MAP_JSON" | jq -c ".[$i]" 2>/dev/null)
  i=$((i + 1))
  [ -z "$entry" ] && continue

  skill=$(printf '%s' "$entry" | jq -r '.skill // empty' 2>/dev/null)
  template=$(printf '%s' "$entry" | jq -r '.template // empty' 2>/dev/null)
  [ -z "$skill" ] && continue

  phrases=$(printf '%s' "$entry" | jq -r '.phrases[]? // empty' 2>/dev/null)
  [ -z "$phrases" ] && continue

  matched_phrase=""
  while IFS= read -r phrase; do
    [ -z "$phrase" ] && continue
    if printf '%s' "$NORM" | grep -qF -- "$phrase"; then
      matched_phrase="$phrase"
      break
    fi
  done <<PHRASES
$phrases
PHRASES

  if [ -n "$matched_phrase" ]; then
    if [ -n "$template" ]; then
      printf 'SKILL TRIGGER: intent matches the /%s skill (matched phrase: "%s") per .claude/rules/skill-first.md. Advisory only — consider running /%s instead of doing this by hand; it produces %s. See .claude/skills/%s/SKILL.md.\n' \
        "$skill" "$matched_phrase" "$skill" "$template" "$skill" >&2
    else
      printf 'SKILL TRIGGER: intent matches the /%s skill (matched phrase: "%s") per .claude/rules/skill-first.md. Advisory only — consider running /%s instead of doing this by hand. See .claude/skills/%s/SKILL.md.\n' \
        "$skill" "$matched_phrase" "$skill" "$skill" >&2
    fi
  fi
done

exit 0
