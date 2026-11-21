#!/usr/bin/env bash
# Validate presentation only. This script makes no gate decision.
set -eu
# Usage: check-review-body.sh [--security] <body-file>
# --security checks only the Pre-existing lines (the Hakim report has no tally prefix).
mode=full
if [ "${1:-}" = "--security" ]; then mode=security; shift; fi
[ "$#" -eq 1 ] || { echo 'Usage: check-review-body.sh [--security] <body-file>' >&2; exit 2; }
# SLA days come from .security.remediation_sla_days through the shared reader.
# An unset or null value falls back to the defaults 7, 30 and 90.
sla_c=7; sla_h=30; sla_m=90
reader="$(cd "$(dirname "$0")/../../hooks" && pwd)/_lib-read-config.sh"
if [ -f "$reader" ]; then
  # shellcheck source=/dev/null
  . "$reader"
  sla_c=$(config_get_or '.security.remediation_sla_days.critical' 7 2>/dev/null || echo 7)
  sla_h=$(config_get_or '.security.remediation_sla_days.high' 30 2>/dev/null || echo 30)
  sla_m=$(config_get_or '.security.remediation_sla_days.medium' 90 2>/dev/null || echo 90)
fi
# A value that is not a whole number falls back to its default.
case "$sla_c" in ''|*[!0-9]*) sla_c=7 ;; esac
case "$sla_h" in ''|*[!0-9]*) sla_h=30 ;; esac
case "$sla_m" in ''|*[!0-9]*) sla_m=90 ;; esac
today=$(date +%Y-%m-%d)
awk -v mode="$mode" -v today="$today" -v sc="$sla_c" -v sh="$sla_h" -v sm="$sla_m" '
function validdate(y, m, d,   dim, leap) {
  y += 0; m += 0; d += 0
  if (m < 1 || m > 12 || d < 1) return 0
  dim = 31
  if (m == 4 || m == 6 || m == 9 || m == 11) dim = 30
  if (m == 2) { leap = (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)); dim = leap ? 29 : 28 }
  return d <= dim
}
# Read the level only from the "Severity: <level>" label, never from prose.
# Rex lines carry no label and get no SLA check. In --security mode each
# Pre-existing line must carry the label. A LOW finding has no SLA.
function checksla(line,   low, sev, s, a, due) {
  low = tolower(line)
  if (!match(low, /severity: (critical|high|medium|low)([^a-z]|$)/)) {
    if (mode == "security") bad=1
    return
  }
  s = substr(low, RSTART + 10, RLENGTH - 10)
  if (s ~ /^low/) return
  sev = (s ~ /^critical/) ? sc : (s ~ /^high/ ? sh : sm)
  if (!match(line, /SLA: [0-9]+ days\. Due: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) { bad=1; return }
  split(substr(line, RSTART, RLENGTH), a, /[^0-9]+/)
  if (a[2] + 0 != sev + 0) bad=1
  if (!validdate(a[3], a[4], a[5])) { bad=1; return }
  due = a[3] "-" a[4] "-" a[5]
  if (due < today) bad=1
}
mode == "full" && NR == 1 && $0 !~ /^Not covered by the checks: .+/ { bad=1 }
mode == "full" && NR == 2 {
  if ($0 !~ /^Important [0-9]+ \| Nit [0-9]+ \| Pre-existing [0-9]+$/) bad=1
  total=$5; pre=$8
}
/^- Pre-existing: / {
  prelisted++
  if ($0 !~ /Suggested ticket title: [^ ]/) bad=1
  checksla($0)
}
/^- Nit: .+/ { listed++ }
/^Additional nits: / {
  if ($0 !~ /^Additional nits: [0-9]+$/) bad=1
  extra=$3; summaries++
}
END {
  if (mode == "security") {
    if (bad) { print "Invalid Pre-existing finding" > "/dev/stderr"; exit 1 }
    exit 0
  }
  if (NR<2 || listed>5 || summaries>1 || total != listed+extra) bad=1
  if (pre != prelisted+0) bad=1
  if (total>listed && summaries!=1) bad=1
  if (bad) { print "Invalid review tally or nit list" > "/dev/stderr"; exit 1 }
}' "$1"
