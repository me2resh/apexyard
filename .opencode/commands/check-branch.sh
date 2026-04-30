#!/bin/bash
# Quick branch validation
# Checks: branch name format, ticket exists

BRANCH=$(git branch --show-current)
echo "Branch: $BRANCH"

# Extract ticket ID
TICKET=$(echo "$BRANCH" | grep -oE '[A-Z]+-[0-9]+|#[0-9]+' | head -1)

if [ -z "$TICKET" ]; then
  echo "❌ No ticket ID in branch name"
  exit 1
fi

echo "Ticket: $TICKET"

# Check if ticket exists
gh issue view "${TICKET#\#}" --json number >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "✅ Ticket exists"
else
  echo "⚠️  Ticket not found in tracker"
fi