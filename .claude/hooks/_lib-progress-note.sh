#!/bin/bash
# Per-worktree progress notes. Bash 3.2. No gate decisions.
progress_note_path() {
  local dir
  dir=$(git -C "$1" rev-parse --absolute-git-dir) || return 1
  [ -f "$dir/apexyard-ticket" ] && [ ! -L "$dir/apexyard-ticket" ] || return 1
  REPLY="$dir/apexyard-progress.md"
}

# Serialize read/modify/rename so concurrent writers cannot lose evidence.
# A busy or abandoned lock requires operator attention, never silent recovery.
progress_note_write() (
  local tree=$1 field=$2 value=$3 mode=${4:-update} note tmp task branch
  case "$field" in Task|Outputs|Completed|Decisions|'Open issues'|'Next action') ;; *) return 1 ;; esac
  progress_note_path "$tree" || return 1
  note=$REPLY
  mkdir "$note.lock" || return 1
  tmp=''
  trap 'rm -f -- "$tmp"; rmdir "$note.lock"' EXIT
  trap 'exit 1' HUP INT TERM
  [ ! -L "$note" ] || return 1
  [ ! -e "$note" ] || [ -f "$note" ] || return 1
  task=$(awk -F= '$1=="repo" {r=substr($0,6)} $1=="number" {n=substr($0,8)} END {print r "#" n}' "${note%/*}/apexyard-ticket")
  tmp=$(mktemp "$note.tmp.XXXXXX") || return 1
  if [ "$mode" = create ]; then
    if [ -f "$note" ] && grep -Fqx "Task: $task" "$note"; then return 0; fi
    branch=$(git -C "$tree" symbolic-ref --short -q HEAD || printf detached)
    printf 'Task: %s\nOutputs: branch=%s; PR=none; files=none\nCompleted: Ticket started\nDecisions: None\nOpen issues: None\nNext action: Read the ticket acceptance criteria\n' "$task" "$branch" > "$tmp" || return 1
  else
    [ -f "$note" ] && grep -Fqx "Task: $task" "$note" || return 1
    # Keep each field on one line, even when evidence contains newlines.
    value=$(printf '%s' "$value" | tr '\r\n' '  ')
    PN_FIELD=$field PN_VALUE=$value awk '
      index($0, ENVIRON["PN_FIELD"] ": ")==1 {
        if (ENVIRON["PN_FIELD"]=="Completed") print $0 "; " ENVIRON["PN_VALUE"]
        else print ENVIRON["PN_FIELD"] ": " ENVIRON["PN_VALUE"]
        next
      }
      {print}
    ' "$note" > "$tmp" || return 1
  fi
  mv -f "$tmp" "$note"
)
progress_note_create() { progress_note_write "$1" Task '' create; }
progress_note_update() { progress_note_write "$1" "$2" "$3"; }

progress_note_print() {
  local note age modified now
  progress_note_path "$1" || return 0
  note=$REPLY
  [ -f "$note" ] && [ ! -L "$note" ] || return 0
  local task
  task=$(awk -F= '$1=="repo" {r=substr($0,6)} $1=="number" {n=substr($0,8)} END {print r "#" n}' "${note%/*}/apexyard-ticket")
  grep -Fqx "Task: $task" "$note" || return 0
  modified=$(stat -f %m "$note" 2>/dev/null) || modified=$(stat -c %Y "$note") || return 0
  now=$(date +%s)
  age=$((now - modified))
  printf 'Ticket progress (age: %s hours)\n' "$((age / 3600))"
  if [ "$age" -gt 86400 ]; then printf 'WARN: progress note is older than 24 hours. Verify evidence before resuming.\n'; fi
  awk '/^(Task|Outputs|Completed|Decisions|Open issues|Next action): / {print substr($0,1,2000); n++; if(n==6) exit}' "$note"
}
