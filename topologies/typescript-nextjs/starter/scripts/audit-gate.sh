#!/usr/bin/env bash
set -euo pipefail
# Read npm audit output from a file or stdin. Production findings come from npm audit --omit=dev.
jq -se '
  def severe: . == "high" or . == "critical";
  length == 1 and (.[0] | type == "object" and .error == null and
    ((.vulnerabilities | type) == "object" or (.advisories | type) == "object") and
    ([ (.vulnerabilities // {} | .[] |
         select((.severity | severe) or any(.via[]?; type == "object" and (.severity | severe)))),
       (.advisories // {} | .[] | select(.severity | severe)) ] | length) == 0)
' "${1:--}" >/dev/null
