#!/bin/bash
# Create a new feature branch with ticket
# Usage: new-feature "ticket-id" "description"

TICKET="$1"
DESC="$2"

if [ -z "$TICKET" ] || [ -z "$DESC" ]; then
  echo "Usage: new-feature TICKET-ID description"
  exit 1
fi

BRANCH="feature/${TICKET}-${DESC}"
git checkout -b "$BRANCH"
echo "Created branch: $BRANCH"
echo "Next: make changes, then run commit-and-pr"