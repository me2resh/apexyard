#!/usr/bin/env bash
# SLA records live in tracker issues. Call sla_track only from the orchestrator.
# Serialize calls per repository. Never retry a failed create automatically.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib-tracker.sh"
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib-read-config.sh"

# Canonical JSON arrays preserve case and delimiters without ambiguous joins.
sla_fingerprint() (
  set -o pipefail
  case "${1:-}:$#" in dependency:3|code:4) ;; *) return 1 ;; esac
  local part
  for part in "$@"; do [ -n "$part" ] || return 1; done
  jq -cn --args '$ARGS.positional' "$@" | python3 -c \
    'import hashlib,sys; print("sha256:"+hashlib.sha256(sys.stdin.buffer.read().rstrip(b"\n")).hexdigest())'
)

sla_days() {
  local key fallback value
  case "$1" in
    CRITICAL) key=critical; fallback=7 ;;
    HIGH) key=high; fallback=30 ;;
    MEDIUM) key=medium; fallback=90 ;;
    LOW) echo none; return ;;
    *) return 1 ;;
  esac
  value=$(config_get_or ".security.remediation_sla_days.$key" "$fallback") || return 1
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$value"
}

# sla_due_date <tracker-createdAt> <days|none>. UTC calendar days, not local time.
sla_due_date() {
  python3 - "$1" "$2" <<'PY'
import datetime,sys
start=datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00'))
if start.tzinfo:
    start=start.astimezone(datetime.timezone.utc)
print('none' if sys.argv[2]=='none' else (start.date()+datetime.timedelta(days=int(sys.argv[2]))).isoformat())
PY
}

# No shared tracker API exposes creation dates, paginated comments, or body edits.
# These adapters support gh only. Other tracker kinds fail closed.
sla_details() {
  [ "$(tracker_issue_kind "$1")" = gh ] || return 1
  local issue comments common
  common=$(tracker_view "$2" "$1") || return 1
  issue=$(apexyard_gh api "repos/$1/issues/$2") || return 1
  comments=$(apexyard_gh api "repos/$1/issues/$2/comments" --paginate --slurp) || return 1
  jq -cen --argjson i "$issue" --argjson c "$comments" --argjson common "$common" \
    '$i | {ref:(.number|tostring),url:.html_url,body:$common.body,createdAt:.created_at,state,
    comments:($c|add // []|map({body,author:.user.login}))}
    | select((.body|type)=="string" and (.createdAt|type)=="string" and (.comments|type)=="array")'
}

sla_update_body() {
  [ "$(tracker_issue_kind "$1")" = gh ] || return 1
  apexyard_gh api --method PATCH "repos/$1/issues/$2" -f "body=$(cat "$3")" >/dev/null
}

# A capped list is incomplete evidence. Never treat it as no match.
sla_open_issues() (
  local tmp status
  tmp=$(mktemp) || return 1
  trap 'rm -f "$tmp"' EXIT
  status=$(tracker_list_to "$tmp" "$1" state=open labels=sla limit=10000) || return 1
  [ "$status" = COMPLETE ] || { echo 'SLA issue list is incomplete.' >&2; return 1; }
  jq -ce 'select(type=="array" and all(.[]; (.ref|type)=="string" and (.ref|test("^[0-9]+$"))))' "$tmp"
)

# Exit 0: one record. Exit 4: no record. Exit 1: error or duplicate records.
sla_find_open() {
  local issues ref detail matches='[]'
  issues=$(sla_open_issues "$1") || return 1
  for ref in $(printf '%s' "$issues" | jq -r '.[].ref'); do
    detail=$(sla_details "$1" "$ref") || return 1
    if printf '%s' "$detail" | jq -e --arg line "Fingerprint: $2" \
      '.body | split("\n") | index($line) != null' >/dev/null; then
      matches=$(jq -cn --argjson a "$matches" --argjson b "$detail" '$a+[$b]') || return 1
    fi
  done
  case "$(printf '%s' "$matches" | jq length)" in
    0) return 4 ;;
    1) printf '%s' "$matches" | jq -c '.[0]' ;;
    *) echo 'Duplicate SLA fingerprints require reconciliation.' >&2; return 1 ;;
  esac
}

# sla_track <repo> <fingerprint> <severity> <title> <base-proof>
# Returns the existing record unchanged, or creates and finalizes one record.
# A failed finalization leaves a pending record. Resolve it before release.
sla_track() (
  local repo="$1" fp="$2" severity="$3" title="$4" proof="$5"
  local record rc days tmp created ref first due
  [ -n "$proof" ] && [[ "$fp" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
  if record=$(sla_find_open "$repo" "$fp"); then
    printf '%s\n' "$record"
    return 0
  else
    rc=$?
    [ "$rc" = 4 ] || return 1
  fi
  days=$(sla_days "$severity") || return 1
  tmp=$(mktemp) || return 1
  trap 'rm -f "$tmp"' EXIT
  printf 'Fingerprint: %s\nSeverity: %s\nSLA days: %s\nDue: pending\n\nBase proof: %s\n' \
    "$fp" "$severity" "$days" "$proof" > "$tmp"
  [ "$(tracker_issue_kind "$repo")" = gh ] || return 1
  created=$(tracker_create "$repo" "Security SLA: $title" "$tmp" "security,$severity,sla") || return 1
  ref=$(printf '%s' "$created" | jq -er '.ref | select(type=="string" and length>0)') || return 1
  record=$(sla_details "$repo" "$ref") || return 1
  printf '%s' "$record" | jq -e --arg line "Fingerprint: $fp" \
    '.body | split("\n") | index($line) != null' >/dev/null || return 1
  first=$(printf '%s' "$record" | jq -er '.createdAt') || return 1
  due=$(sla_due_date "$first" "$days") || return 1
  printf 'Fingerprint: %s\nSeverity: %s\nSLA days: %s\nDue: %s\n\nBase proof: %s\n' \
    "$fp" "$severity" "$days" "$due" "$proof" > "$tmp"
  sla_update_body "$repo" "$ref" "$tmp" || return 1
  sla_details "$repo" "$ref"
)

# sla_release_check <repo> <owner-login> [today]. Only that owner's comments count.
sla_release_check() {
  local repo="$1" owner="$2" today="${3:-$(date -u +%F)}"
  local issues ref detail result failed=0
  [ -n "$owner" ] || return 1
  issues=$(sla_open_issues "$repo") || return 1
  for ref in $(printf '%s' "$issues" | jq -r '.[].ref'); do
    detail=$(sla_details "$repo" "$ref") || return 1
    result=$(printf '%s' "$detail" | python3 -c '
import datetime,json,re,sys
record=json.load(sys.stdin)
today=datetime.date.fromisoformat(sys.argv[1])
fields={}
for key in ("Fingerprint", "Severity", "SLA days", "Due"):
    lines=[line[len(key)+2:] for line in record["body"].splitlines() if line.startswith(key+": ")]
    if len(lines)!=1: raise ValueError("Missing or duplicate SLA field: "+key)
    fields[key]=lines[0]
if not re.fullmatch(r"sha256:[a-f0-9]{64}",fields["Fingerprint"]): raise ValueError("Invalid fingerprint")
severity=fields["Severity"]
if severity=="LOW":
    if fields["SLA days"]!="none" or fields["Due"]!="none": raise ValueError("Invalid LOW SLA")
    print("No SLA")
else:
    if severity not in ("CRITICAL","HIGH","MEDIUM"): raise ValueError("Invalid severity")
    if not re.fullmatch(r"[0-9]+", fields["SLA days"]): raise ValueError("Invalid SLA days")
    due=datetime.date.fromisoformat(fields["Due"])
    first=datetime.datetime.fromisoformat(record["createdAt"].replace("Z","+00:00")).astimezone(datetime.timezone.utc).date()
    if due!=first+datetime.timedelta(days=int(fields["SLA days"])): raise ValueError("Due date differs from creation date plus SLA")
    accepted=any(c["author"]==sys.argv[2] and any(re.fullmatch(r"Risk accepted by owner: \S.*",line) for line in c["body"].splitlines()) for c in record["comments"])
    print("BREACHED due "+str(due)+(" (risk accepted)" if accepted else " (BLOCKED)") if due<today else "Within SLA")
' "$today" "$owner") || return 1
    printf '%s: %s\n' "$ref" "$result"
    case "$result" in *'(BLOCKED)') failed=1 ;; esac
  done
  return "$failed"
}
