#!/usr/bin/env bash
# Validate presentation only. This script makes no gate decision.
set -eu
[ "$#" -eq 1 ] || { echo 'Usage: check-review-body.sh <body-file>' >&2; exit 2; }
awk '
NR == 1 && $0 !~ /^Not covered by the checks: .+/ { bad=1 }
NR == 2 {
  if ($0 !~ /^Important [0-9]+ \| Nit [0-9]+ \| Pre-existing [0-9]+$/) bad=1
  total=$5; pre=$8
}
/^- Pre-existing: / {
  prelisted++
  if ($0 !~ /Suggested ticket title: [^ ]/) bad=1
  if ($0 ~ /(CRITICAL|HIGH|MEDIUM)/ && $0 !~ /SLA: [0-9]+ days\. Due: [0-9]{4}-[0-9]{2}-[0-9]{2}/) bad=1
}
/^- Nit: .+/ { listed++ }
/^Additional nits: / {
  if ($0 !~ /^Additional nits: [0-9]+$/) bad=1
  extra=$3; summaries++
}
END {
  if (NR<2 || listed>5 || summaries>1 || total != listed+extra) bad=1
  if (pre != prelisted+0) bad=1
  if (total>listed && summaries!=1) bad=1
  if (bad) { print "Invalid review tally or nit list" > "/dev/stderr"; exit 1 }
}' "$1"
