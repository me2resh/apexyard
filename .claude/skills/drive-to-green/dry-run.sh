#!/usr/bin/env bash
# Print a plan from fake state. Never execute the plan.
set -eu
[ "$#" -ge 2 ] && [ "$#" -le 3 ] && [ "$1" = --dry-run ] || {
  echo 'Usage: dry-run.sh --dry-run <state-file> [max-rounds]' >&2; exit 2;
}
cap=${3:-2}
case "$cap" in ''|*[!0-9]*|0) echo 'Invalid max-rounds' >&2; exit 2 ;; esac
round=0
while IFS= read -r state || [ -n "$state" ]; do
  if [ "$round" -ge "$cap" ]; then echo 'Blocker: review-round cap'; exit 0; fi
  round=$((round + 1))
  echo "Round $round: wait for CI with Monitor"
  case "$state" in
    pending) echo 'Blocker: CI pending'; exit 0 ;;
    failed)
      if [ "$round" -ge "$cap" ]; then echo 'Blocker: review-round cap, CI failed'; exit 0; fi
      echo 'Plan: build agent fixes CI, then wait for CI' ;;
    changes|unknown)
      [ "$state" != unknown ] || echo 'Plan: rex_approval_carries_over -> unknown'
      echo 'Plan: /code-review reviewer spawn'
      if [ "$round" -ge "$cap" ]; then echo 'Blocker: review-round cap'; exit 0; fi
      echo 'Plan: build agent fixes and tests'
      echo 'Plan: /code-review delta review after green CI'
      ;;
    approved) echo 'Plan: /code-review reviewer spawn'; echo 'Pending: human approval'; exit 0 ;;
    carry) echo 'Plan: rex_approval_carries_over -> true'; echo 'Pending: human approval'; exit 0 ;;
    *) echo 'Invalid fake PR state' >&2; exit 2 ;;
  esac
done < "$2"
echo 'Blocker: fake state exhausted'
