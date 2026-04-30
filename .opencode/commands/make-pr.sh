#!/bin/bash
# Create a PR with proper format
# Usage: make-pr "title" "description"

TITLE="$1"
DESC="$2"

if [ -z "$TITLE" ] || [ -z "$DESC" ]; then
  echo "Usage: make-pr TITLE description"
  exit 1
fi

BRANCH=$(git branch --show-current)
TICKET=$(echo "$BRANCH" | grep -oE '[A-Z]+-[0-9]+|#[0-9]+' | head -1)

if [ -z "$TICKET" ]; then
  echo "Error: No ticket ID found in branch name"
  exit 1
fi

gh pr create --title "${TITLE}(${TICKET}): ${DESC}" --body "## Summary
$DESC

## Test Plan
- [ ] Test item 1
- [ ] Test item 2

## Glossary
| Term | Definition |
|------|------------|
| | |

Closes $TICKET"
echo "Created PR with title: ${TITLE}(${TICKET}): ${DESC}"