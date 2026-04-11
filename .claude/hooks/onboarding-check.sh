#!/bin/bash
# SessionStart hook: checks whether this repo has been onboarded to ApexStack.
# If not, injects a visible reminder so Claude prompts the user to run /onboard
# before doing any work.
#
# "Onboarded" means .claude/session/onboarded exists. The /onboard skill creates
# it after asking the discovery questions (project identity, tracker repo,
# required CI checks, reviewers, UI/backend, deploy targets, sensitive topics).
#
# Same principle as the role-triggers rule: don't start work until you know
# who, what, why, and under which constraints.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
MARKER="${REPO_ROOT:-.}/.claude/session/onboarded"

if [ -f "$MARKER" ]; then
  exit 0
fi

cat <<MSG
APEXSTACK ONBOARDING NOT RUN

This repository has no onboarding marker at:
  ${MARKER}

ApexStack needs a short discovery pass before the first session so hooks,
reviewers, and gates know:

  - What project this is and where its code + tickets live
  - Which CI checks must run before push (lint, typecheck, test, build,
    framework-specific validators like \`sam validate --lint\` or \`terraform validate\`)
  - Who the reviewers are (Rex + human approver — Tech Lead, CEO, owner)
  - Whether this repo has UI work (design-review gate)
  - Deploy targets (staging, prod, where URLs live, auto-on-merge or manual)
  - Sensitive topics (anything that must never land in git or public issues)

Before starting any work in this repo, ask the user to run:

  /onboard

The skill will ask the questions and write both the marker above and
.claude/project-config.json. If the user wants to skip onboarding for a quick
one-off, they can:
  touch ${MARKER}
MSG
exit 0
