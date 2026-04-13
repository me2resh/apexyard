#!/bin/bash
# PreToolUse hook on `gh issue create`: reminds the user to use /feature, /bug,
# or /task instead of freeform gh issue create. These skills ensure every ticket
# has the right structure (user story, bug scenario, or driver + ACs).
#
# This is advisory, not blocking — exit 0 always. The reminder prints to stderr
# so Claude sees it and can suggest the skill to the user.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Only trigger on gh issue create (not gh issue view, gh issue list, etc.)
if ! echo "$COMMAND" | grep -qE '\bgh\s+issue\s+create\b'; then
  exit 0
fi

cat >&2 <<MSG
NOTE: ApexStack has structured ticket templates. Consider using:

  /feature  — for user-facing features (includes user story + ACs)
  /bug      — for bug reports (includes Given/When/Then + repro steps)
  /task     — for tech debt, refactoring, CI, or non-user-facing work

These ensure every ticket has the right structure and labels.
If this is a quick operational issue (closing, commenting, labeling),
proceed with gh issue create as-is.
MSG

# Advisory only — don't block
exit 0
