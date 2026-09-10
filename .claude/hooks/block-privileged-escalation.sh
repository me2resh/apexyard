#!/bin/bash
# Block agent attempts to escalate privileges or bypass required verification.
# The operator may perform exceptional privileged work directly outside the
# agent workflow. This hook never grants an escape hatch.

set -u

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

if printf '%s\n' "$COMMAND" | grep -Eq '(^|[;&|])[[:space:]]*sudo([[:space:]]|$)|(^|[;&|])[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)[^|;&]*([[:space:]])--admin([[:space:]]|$)|(^|[;&|])[[:space:]]*git[[:space:]]+push[^|;&]*([[:space:]]--force(-with-lease)?|[[:space:]]-f)([[:space:]]|$)|(^|[;&|])[[:space:]]*git[[:space:]]+[^|;&]*--no-verify([[:space:]]|$)|(^|[;&|])[[:space:]]*(aws[[:space:]]+sts[[:space:]]+assume-role|gcloud[[:space:]]+auth[[:space:]]+activate-service-account)([[:space:]]|$)'; then
  echo "BLOCKED: privilege escalation or verification bypass is not available to agents. Use the normal least-privileged path, or perform exceptional privileged work directly outside the agent workflow." >&2
  exit 2
fi

exit 0
