#!/usr/bin/env bash
# Deterministic helper for the /duty skill. See SKILL.md for the contract.
set -uo pipefail

die() { printf 'duty: %s\n' "$*" >&2; exit 2; }
need_jq() { command -v jq >/dev/null 2>&1 || die "jq is required"; }

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# jq helper: ISO-8601 with optional fractional seconds and Z or +HH:MM offset -> epoch.
JQ_EPOCH='def epoch: if . == null or . == "" then null else
  (sub("\\.[0-9]+"; "")) as $t
  | if ($t | test("Z$")) then ($t | fromdateiso8601)
    else (($t | capture("^(?<b>.{19})(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$")) // error("bad timestamp: \($t)")) as $c
      | (($c.b + "Z") | fromdateiso8601)
        - ((if $c.s == "+" then 1 else -1 end) * (($c.h | tonumber) * 3600 + ($c.m | tonumber) * 60))
    end end;'

cfg_num() {
  local key="$1" fallback="$2" v=""
  if [ -n "${DUTY_CONFIG_JSON:-}" ]; then
    v=$(printf '%s' "$DUTY_CONFIG_JSON" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null)
  fi
  printf '%s' "${v:-$fallback}"
}

cmd_state_dir_check() {
  local dir="$1" probe="$1"
  [ -n "$dir" ] || die "state dir is empty"
  while [ ! -d "$probe" ] && [ "$probe" != "/" ] && [ -n "$probe" ]; do
    probe=$(dirname "$probe")
  done
  if git -C "$probe" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'INSIDE_REPO %s\n' "$(git -C "$probe" rev-parse --show-toplevel)"
    return 1
  fi
  printf 'OK\n'
}

cmd_init() {
  local state="$1" scope="${2:-$(iso_now)}"
  [ -f "$state" ] && die "state file exists: $state (run stop to archive it)"
  jq -en --arg s "$scope" "$JQ_EPOCH"'$s | epoch' >/dev/null 2>&1 || die "bad scope timestamp: $scope"
  mkdir -p "$(dirname "$state")"
  jq -n --arg s "$scope" '{
    shift: {scope_timestamp: $s, started: $s},
    last_watcher_tick: null, last_review_tick: null,
    items: {}, actions: []
  }' > "$state"
}

cmd_stop() {
  local state="$1" at="${2:-$(iso_now)}" dest
  [ -f "$state" ] || die "no state file: $state"
  dest="$(dirname "$state")/archive/state-${at//:/}.json"
  mkdir -p "$(dirname "$dest")"
  jq --arg at "$at" '.shift.stopped = $at' "$state" > "$dest" || die "archive failed"
  rm -f "$state"
  printf '%s\n' "$dest"
}

cmd_liveness() {
  local state="$1" now="${2:-$(iso_now)}"
  local w_stale r_stale
  w_stale=$(cfg_num watcher_stale_minutes 45)
  r_stale=$(cfg_num review_stale_minutes 90)
  jq -r --arg now "$now" --argjson ws "$w_stale" --argjson rs "$r_stale" "$JQ_EPOCH"'
    def age($f): if .[$f] == null then null
      else (((($now | epoch) - (.[$f] | epoch)) / 60) | floor) end;
    if .shift.scope_timestamp == null then "NO_SHIFT"
    else
      [ (age("last_watcher_tick") as $a
          | if $a == null then "NEVER watcher"
            elif $a > $ws then "STALE watcher \($a)" else empty end),
        (age("last_review_tick") as $a
          | if $a == null then empty
            elif $a > $rs then "STALE review \($a)" else empty end) ]
      | if length == 0 then "OK" else .[] end
    end' "$state"
}

cmd_plan() {
  local state="$1" now="${2:-$(iso_now)}" interval due
  interval=$(cfg_num review_interval_minutes 30)
  due=$(jq -r --arg now "$now" --argjson iv "$interval" "$JQ_EPOCH"'
    if .last_review_tick == null then "yes"
    elif ((($now | epoch) - (.last_review_tick | epoch)) / 60) >= $iv
    then "yes" else "no" end' "$state")
  printf '%s\n' liveness watcher stamp_watcher
  [ "$due" = "yes" ] && printf '%s\n' review stamp_review
  printf '%s\n' report journal
}

cmd_verify_tick() {
  local log="$1" plan="${2:-}"
  local -a steps=()
  local s
  while IFS= read -r s; do
    [ -n "$s" ] && steps+=("$s")
  done < "$log"
  local i idx_live=-1 idx_watch=-1 idx_wstamp=-1 idx_review=-1
  for i in "${!steps[@]}"; do
    case "${steps[$i]}" in
      liveness)      [ "$idx_live" -lt 0 ] && idx_live=$i ;;
      watcher)       [ "$idx_watch" -lt 0 ] && idx_watch=$i ;;
      stamp_watcher) [ "$idx_wstamp" -lt 0 ] && idx_wstamp=$i ;;
      review)        [ "$idx_review" -lt 0 ] && idx_review=$i ;;
    esac
  done
  [ "$idx_live" -eq 0 ] || { echo "FAILED liveness gate did not run first"; return 1; }
  [ "$idx_watch" -ge 0 ] || { echo "FAILED watcher pass skipped"; return 1; }
  [ "$idx_wstamp" -gt "$idx_watch" ] || { echo "FAILED watcher stamp missing or before watcher"; return 1; }
  if [ "$idx_review" -ge 0 ] && [ "$idx_review" -lt "$idx_wstamp" ]; then
    echo "FAILED review ran before the watcher stamp"; return 1
  fi
  if [ -n "$plan" ] && grep -qx review "$plan" && [ "$idx_review" -lt 0 ]; then
    echo "FAILED planned review pass skipped"; return 1
  fi
  echo "OK"
}

cmd_stamp() {
  local state="$1" which="$2" at="${3:-$(iso_now)}" field tmp
  case "$which" in
    watcher) field=last_watcher_tick ;;
    review)  field=last_review_tick ;;
    *) die "stamp: watcher|review" ;;
  esac
  tmp=$(mktemp) || die "mktemp failed"
  jq --arg f "$field" --arg at "$at" '.[$f] = $at' "$state" > "$tmp" && mv "$tmp" "$state"
}

cmd_record_action() {
  local state="$1" item="$2" action="$3" at="${4:-$(iso_now)}" tmp
  tmp=$(mktemp) || die "mktemp failed"
  jq --arg i "$item" --arg a "$action" --arg at "$at" \
    '.actions += [{item: $i, action: $a, at: $at}]' "$state" > "$tmp" && mv "$tmp" "$state"
}

cmd_fetch_status() {
  local rc="$1" count="$2" limit="$3" cap="${4:-}" effective
  if [ "$rc" != "0" ]; then echo "UNKNOWN"; return 0; fi
  case "$count" in ''|*[!0-9]*) echo "UNKNOWN"; return 0 ;; esac
  effective="$limit"
  if [ -n "$cap" ] && [ "$cap" -lt "$limit" ]; then effective="$cap"; fi
  if [ "$count" -lt "$effective" ]; then echo "COMPLETE"; else echo "TRUNCATED"; fi
}

cmd_partition() {
  local items="$1" state="$2" me="$3"
  jq -n --slurpfile items "$items" --slurpfile st "$state" --arg me "$me" "$JQ_EPOCH"'
    ($st[0].shift.scope_timestamp | epoch) as $scope
    | ($st[0].actions | map(select((.at | epoch) >= $scope)) | map(.item | tostring) | unique) as $acted
    | ($items[0] | if type == "array" then . else [] end)
    | map(
        . as $it
        | ($it.id | tostring) as $id
        | ($it.assignee_known == true) as $ak
        | ($it.comments_known == true) as $ck
        | ($it.unresolved_known == true) as $uk
        | ($it.assignee_id // "" | tostring) as $who
        | (try ($it.created | epoch) catch null) as $created
        | (try ($it.last_comment_at | epoch) catch null) as $commented
        | ((($it.last_comment_at // "") != "") and $commented == null) as $comment_bad
        | [ { name: "new_in_scope",
              v: (if $created == null or ($ak | not) then null
                  else (($created >= $scope) and ($who == "" or $who == $me)) end) },
            { name: "mine_new_comment",
              v: (if ($ak | not) then null
                  elif $who != $me then false
                  elif ($ck | not) or $comment_bad then null
                  elif $commented == null then false
                  else (($commented >= $scope)
                        and (($it.last_comment_author_id // "" | tostring) != $me)) end) },
            { name: "acted_this_shift",
              v: ($acted | index($id) != null) },
            { name: "reviewer_waiting",
              v: (if ($uk | not) then null
                  else (($it.unresolved_waiting_on_me // 0) > 0) end) } ]
        | { id: $id,
            matched: map(select(.v == true) | .name),
            unknown: map(select(.v == null) | .name),
            owned: (map(select(.v == true)) | length > 0) }
      )'
}

item_set() {
  local state="$1" id="$2" to="$3" reason="$4" tmp
  tmp=$(mktemp) || die "mktemp failed"
  jq --arg id "$id" --arg to "$to" --arg r "$reason" --arg at "$(iso_now)" '
    .items[$id] = ((.items[$id] // {}) + {state: $to, since: $at, reason: $r})
  ' "$state" > "$tmp" && mv "$tmp" "$state"
}

cmd_item() {
  local state="$1" id="$2" event="$3" actor="${4:-loop}" reason="${5:-}"
  local cur
  cur=$(jq -r --arg id "$id" '.items[$id].state // "none"' "$state")
  case "$event:$cur" in
    escalate:none|escalate:closed) item_set "$state" "$id" open "$reason" ;;
    escalate:open|escalate:parked) echo "$cur"; return 0 ;;
    park:open)
      [ "$actor" = "operator" ] || { echo "REFUSED only the operator parks an item"; return 1; }
      item_set "$state" "$id" parked "$reason" ;;
    unpark:parked)
      [ "$actor" = "operator" ] || { echo "REFUSED only the operator unparks an item"; return 1; }
      item_set "$state" "$id" open "$reason" ;;
    close:open|close:parked) item_set "$state" "$id" closed "$reason" ;;
    *) echo "REFUSED $event from $cur"; return 1 ;;
  esac
  jq -r --arg id "$id" '.items[$id].state' "$state"
}

cmd_nag() {
  jq -r '.items | to_entries | map(select(.value.state == "open")) | .[].key' "$1"
}

cmd_handover_items() {
  jq -r '.items | to_entries
    | map(select(.value.state == "open" or .value.state == "parked"))
    | .[] | "\(.value.state)\t\(.key)\t\(.value.reason // "")"' "$1"
}

# Prints "<CLASS>\t<heading>" for the section holding the needle (mode text)
# or named by the needle (mode heading). CLASS is PROTECTED, CLASSA, or OPEN.
section_class() {
  local playbook="$1" mode="$2" needle="$3"
  DUTY_MODE="$mode" DUTY_NEEDLE="$needle" awk '
    BEGIN { mode = ENVIRON["DUTY_MODE"]; needle = ENVIRON["DUTY_NEEDLE"]; n = 0 }
    /^## / { sec = $0; order[++n] = sec }
    /<!-- duty:protected -->/ { prot[sec] = 1 }
    /<!-- duty:class-a -->/ { cla[sec] = 1 }
    { buf[sec] = buf[sec] "\n" $0 }
    END {
      if (needle == "") exit
      for (i = 1; i <= n; i++) {
        s = order[i]
        hit = (mode == "heading") ? (s == needle) : (index(buf[s], needle) > 0)
        if (hit) { print (prot[s] ? "PROTECTED" : (cla[s] ? "CLASSA" : "OPEN")) "\t" s; exit }
      }
    }
  ' "$playbook"
}

cmd_classify() {
  local proposal="$1" playbook="$2"
  local declared old new section reasons=()
  declared=$(jq -r '.class // "B"' "$proposal")
  old=$(jq -r '.old // ""' "$proposal")
  new=$(jq -r '.new // ""' "$proposal")
  section=$(jq -r '.section // ""' "$proposal")

  [ "$declared" = "A" ] || reasons+=("declared class $declared")

  local loc cls
  if [ -n "$old" ]; then
    loc=$(section_class "$playbook" text "$old")
  else
    loc=$(section_class "$playbook" heading "$section")
  fi
  cls="${loc%%	*}"
  case "$cls" in
    "")        reasons+=("target text or section not found") ;;
    PROTECTED) reasons+=("RAIL: edits protected section ${loc#*	}") ;;
    OPEN)      reasons+=("class A is limited to class-a sections; ${loc#*	} is not one") ;;
  esac

  [ -n "$old$new" ] || reasons+=("empty proposal")
  if printf '%s\n' "$new" | grep -qE '^[[:space:]]*#{1,6}[[:space:]]|duty:(protected|class-a)'; then
    reasons+=("RAIL: new text adds a heading or a section marker")
  fi

  local norm='(never|always|must|shall|should|do not|don.t|only|except|unless|instead|allowed|may |halt|stop|escalate|approv|gate|required|skip)'
  if printf '%s' "$new" | grep -qiE "$norm"; then
    reasons+=("RAIL: new text contains a normative word")
  fi
  local removed
  removed=$(printf '%s\n' "$old" | grep -iE "$norm" | while IFS= read -r l; do
    printf '%s\n' "$new" | grep -qF -- "$l" || printf '%s\n' "$l"
  done)
  [ -n "$removed" ] && reasons+=("RAIL: removes or rewrites a normative line")

  local old_nums new_nums
  old_nums=$(printf '%s' "$old" | grep -oE '[0-9]+' | sort | tr '\n' ' ')
  new_nums=$(printf '%s' "$new" | grep -oE '[0-9]+' | sort | tr '\n' ' ')
  if [ "$old_nums" != "$new_nums" ]; then
    reasons+=("RAIL: changes a number (threshold, cadence, or limit)")
  fi

  local act='(unattended|without (the )?(operator|approval|asking)|disable|relax|loosen|redundant|no longer|merg|approve|resolv|force|push|production|deploy|delete|migrat|yourself|bypass|--no-verify|sudo)'
  if printf '%s' "$new" | grep -qiE "$act"; then
    reasons+=("RAIL: new text names a gated action or widens unattended action")
  fi

  if [ "${#reasons[@]}" -eq 0 ]; then
    echo "A"
  else
    echo "B"
    printf '  %s\n' "${reasons[@]}"
  fi
}

cmd_apply() {
  local proposal="$1" playbook="$2" approval="${3:-}"
  local verdict
  verdict=$(cmd_classify "$proposal" "$playbook" | head -1)
  if [ "$verdict" != "A" ] && [ "$approval" != "--operator-approved" ]; then
    echo "REFUSED class $verdict needs operator approval"
    return 1
  fi
  local old new section tmp revert old_for_revert new_for_revert
  old=$(jq -r '.old // ""' "$proposal")
  new=$(jq -r '.new // ""' "$proposal")
  section=$(jq -r '.section // ""' "$proposal")
  revert="${proposal%.json}.revert.json"
  tmp=$(mktemp) || die "mktemp failed"
  if [ -z "$old" ]; then
    [ -n "$new" ] || { rm -f "$tmp"; echo "REFUSED empty proposal"; return 1; }
    DUTY_ANCHOR="$section" DUTY_NEW="$new" awk '
      BEGIN { s = ENVIRON["DUTY_ANCHOR"]; n = ENVIRON["DUTY_NEW"] }
      /^## / && in_s { print n; print ""; done = 1; in_s = 0 }
      /^## / && s != "" && $0 == s { in_s = 1 }
      { print }
      END { if (in_s) { print ""; print n; done = 1 } if (!done) exit 3 }
    ' "$playbook" > "$tmp" || { rm -f "$tmp"; echo "REFUSED section not found"; return 1; }
    old_for_revert="$new"
    new_for_revert=""
  else
    OLD="$old" NEW="$new" perl -0777 -pe '
      BEGIN { $o = $ENV{OLD}; $n = $ENV{NEW}; $c = 0 }
      $c = () = /\Q$o\E/g;
      die "old text matched $c times, need exactly 1\n" unless $c == 1;
      s/\Q$o\E/$n/;
    ' "$playbook" > "$tmp" || { rm -f "$tmp"; echo "REFUSED old text is not unique"; return 1; }
    old_for_revert="$new"
    new_for_revert="$old"
  fi
  mv "$tmp" "$playbook"
  jq --arg o "$old_for_revert" --arg n "$new_for_revert" \
    '. + {id: ((.id // "P") + "-revert"), class: "B", old: $o, new: $n}' "$proposal" > "$revert" \
    || die "applied, but writing the revert proposal failed: $revert"
  printf 'APPLIED\nREVERT %s\n' "$revert"
}

main() {
  need_jq
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    state-dir-check) cmd_state_dir_check "$@" ;;
    init)            cmd_init "$@" ;;
    stop)            cmd_stop "$@" ;;
    liveness)        cmd_liveness "$@" ;;
    plan)            cmd_plan "$@" ;;
    verify-tick)     cmd_verify_tick "$@" ;;
    stamp)           cmd_stamp "$@" ;;
    record-action)   cmd_record_action "$@" ;;
    fetch-status)    cmd_fetch_status "$@" ;;
    partition)       cmd_partition "$@" ;;
    item)            cmd_item "$@" ;;
    nag)             cmd_nag "$@" ;;
    handover-items)  cmd_handover_items "$@" ;;
    classify)        cmd_classify "$@" ;;
    apply)           cmd_apply "$@" ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
