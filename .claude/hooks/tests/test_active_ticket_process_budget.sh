#!/bin/bash
# Process budget of the git-dir ticket marker resolver.
#
# The lookup functions in _lib-active-ticket.sh must make no fork and no exec.
# Three checks hold that line:
#   1. Every lookup function runs with PATH=/nonexistent and gives the same
#      result as with the normal PATH. Any external command would fail.
#   2. The writer runs through counting wrappers and makes at most three
#      external commands after init.
#   3. A static scan of the lookup function bodies fails on a command
#      substitution, a backtick, a pipe, a subshell, a background job or exec.
#
# On the commit before the resolver none of the functions exist, so the
# first two checks fail there.

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$SRC_ROOT/.claude/hooks/_lib-active-ticket.sh"

export APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

PASS=0
FAIL=0
ok() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

# shellcheck source=/dev/null
. "$LIB"
if ! command -v active_ticket_lookup >/dev/null 2>&1; then
  bad "resolver functions exist" "active_ticket_lookup is not defined"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

REAL_PATH="$PATH"
B=$(mktemp -d)
B=$(cd -P "$B" && pwd)
trap 'rm -rf "$B"' EXIT

mkrepo() {
  git init -q -b main "$1" 2>/dev/null || git init -q "$1"
  git -C "$1" commit -q --allow-empty -m init
}

OPS="$B/ops"
WS="$OPS/workspace"
mkrepo "$OPS"
: > "$OPS/.apexyard-fork"
printf 'projects:\n  - name: p1\n    repo: org/p1\n' > "$OPS/apexyard.projects.yaml"
mkdir -p "$WS" "$OPS/.claude/session/tickets"
mkrepo "$WS/p1"
git -C "$WS/p1" worktree add -q "$B/wt1" -b wt1
mkrepo "$B/rogue"
printf 'repo=org/p1\nnumber=5\n' > "$WS/p1/.git/apexyard-ticket"
printf 'repo=org/p1\nnumber=6\n' > "$WS/p1/.git/worktrees/wt1/apexyard-ticket"
printf 'repo=org/ops\nnumber=7\n' > "$OPS/.git/apexyard-ticket"

ctx() {
  active_ticket_set_context "$OPS" "$WS"
  _AT_REG="$OPS/apexyard.projects.yaml"
  _at_memo_clear
}
ctx

# --- 1. empty PATH -----------------------------------------------------------
# Each entry is "label|function|path". The legacy cases remove the new markers
# first, then add an old-layout file.
run_all() {
  local out="" e label fn arg
  for e in \
    "main|active_ticket_lookup|$WS/p1/src/a.ts" \
    "linked|active_ticket_lookup|$B/wt1/src/a.ts" \
    "ops|active_ticket_lookup|$OPS/src/a.ts" \
    "refusal|active_ticket_lookup|$B/rogue/a.ts" \
    "tilde|active_ticket_lookup|~nobody/x" \
    "gitdir|active_ticket_gitdir|$WS/p1/src" \
    "cwd|active_ticket_lookup_cwd|" \
    "target_yes|active_ticket_is_marker_target|$WS/p1/.git/apexyard-ticket" \
    "target_tmp|active_ticket_is_marker_target|$WS/p1/.git/apexyard-ticket.tmp.Ab3dE9" \
    "target_no|active_ticket_is_marker_target|$WS/p1/.git/config" \
    "field|active_ticket_read_field|$WS/p1/.git/apexyard-ticket"; do
    label="${e%%|*}"
    fn="${e#*|}"
    arg="${fn#*|}"
    fn="${fn%%|*}"
    _at_memo_clear
    case "$fn" in
      active_ticket_lookup_cwd) "$fn" 2> "$B/err" ;;
      active_ticket_read_field) "$fn" "$arg" number 2> "$B/err" ;;
      *) "$fn" "$arg" 2> "$B/err" ;;
    esac
    out="$out$label:rc=$?:reply=$REPLY:reason=$AT_REASON:err=$(wc -c < "$B/err" 2>/dev/null)
"
  done
  RESULT="$out"
}

# The err length uses wc, so measure it with the normal PATH only. Under the
# empty PATH the stderr file is checked by size with a builtin read instead.
run_all_nopath() {
  local out="" e label fn arg errtxt
  for e in \
    "main|active_ticket_lookup|$WS/p1/src/a.ts" \
    "linked|active_ticket_lookup|$B/wt1/src/a.ts" \
    "ops|active_ticket_lookup|$OPS/src/a.ts" \
    "refusal|active_ticket_lookup|$B/rogue/a.ts" \
    "tilde|active_ticket_lookup|~nobody/x" \
    "gitdir|active_ticket_gitdir|$WS/p1/src" \
    "cwd|active_ticket_lookup_cwd|" \
    "target_yes|active_ticket_is_marker_target|$WS/p1/.git/apexyard-ticket" \
    "target_tmp|active_ticket_is_marker_target|$WS/p1/.git/apexyard-ticket.tmp.Ab3dE9" \
    "target_no|active_ticket_is_marker_target|$WS/p1/.git/config" \
    "field|active_ticket_read_field|$WS/p1/.git/apexyard-ticket"; do
    label="${e%%|*}"
    fn="${e#*|}"
    arg="${fn#*|}"
    fn="${fn%%|*}"
    _at_memo_clear
    : > "$B/err"
    case "$fn" in
      active_ticket_lookup_cwd) "$fn" 2> "$B/err" ;;
      active_ticket_read_field) "$fn" "$arg" number 2> "$B/err" ;;
      *) "$fn" "$arg" 2> "$B/err" ;;
    esac
    rc=$?
    errtxt=""
    IFS= read -r errtxt < "$B/err" || true
    if [ -n "$errtxt" ]; then errtxt="nonempty"; fi
    out="$out$label:rc=$rc:reply=$REPLY:reason=$AT_REASON:err=${errtxt:-0}
"
  done
  RESULT="$out"
}

cd "$WS/p1" || exit 1
# Baseline with the normal PATH (the err field is the stderr byte count).
run_all
BASE="$RESULT"
BASE_NORM="${BASE//err=0$'\n'/err=0$'\n'}"
hash -r
# shellcheck disable=SC2123
PATH=/nonexistent
hash -r
run_all_nopath
NOPATH="$RESULT"
PATH="$REAL_PATH"
hash -r
# Normalise the baseline stderr count the same way.
BASE_CMP=$(printf '%s' "$BASE_NORM" | sed -E 's/err= *[0-9]+/err=X/')
NOPATH_CMP=$(printf '%s' "$NOPATH" | sed -E 's/err=[^ ]*/err=X/')
if [ "$BASE_CMP" = "$NOPATH_CMP" ]; then
  ok "1a lookup functions give the same result with PATH=/nonexistent"
else
  bad "1a" "differs"
  diff <(printf '%s' "$BASE_CMP") <(printf '%s' "$NOPATH_CMP") >&2
fi
case "$NOPATH" in
  *"err=nonempty"*) bad "1b stderr is empty under an empty PATH" "$NOPATH" ;;
  *) ok "1b stderr is empty under an empty PATH" ;;
esac
case "$NOPATH" in
  *"main:rc=0:reply=$WS/p1/.git/apexyard-ticket"*"linked:rc=0:reply=$WS/p1/.git/worktrees/wt1/apexyard-ticket"*"ops:rc=0:reply=$OPS/.git/apexyard-ticket"*"refusal:rc=1:reply=:"*)
    ok "1c the results are the expected markers and a refusal" ;;
  *) bad "1c" "$NOPATH" ;;
esac

# The old-layout resolution, also under an empty PATH. It may run git, which
# then fails quietly, and it must still give the same answer: for a main clone
# git reports no linked worktree either way.
rm -f "$WS/p1/.git/apexyard-ticket"
printf 'repo=org/p1\nnumber=9\n' > "$OPS/.claude/session/tickets/p1"
_at_memo_clear
active_ticket_lookup "$WS/p1/a.ts"
legacy_normal="rc=$?:$REPLY"
# shellcheck disable=SC2123
PATH=/nonexistent
hash -r
_at_memo_clear
active_ticket_lookup "$WS/p1/a.ts" 2> "$B/err"
legacy_nopath="rc=$?:$REPLY"
PATH="$REAL_PATH"
hash -r
if [ "$legacy_normal" = "$legacy_nopath" ] && [ "$legacy_normal" = "rc=0:$OPS/.claude/session/tickets/p1" ]; then ok "1d the old-layout pass gives the same answer under an empty PATH"; else bad "1d" "$legacy_normal vs $legacy_nopath"; fi
printf 'repo=org/other\nnumber=9\n' > "$OPS/.claude/session/tickets/p1"
# shellcheck disable=SC2123
PATH=/nonexistent
hash -r
_at_memo_clear
active_ticket_lookup "$WS/p1/a.ts" 2> "$B/err"
legacy_mismatch="rc=$?:$REPLY"
PATH="$REAL_PATH"
hash -r
if [ "$legacy_mismatch" = "rc=0:$OPS/.claude/session/tickets/p1" ]; then ok "1e an old file naming another repo still passes, as before, under an empty PATH"; else bad "1e" "$legacy_mismatch"; fi
rm -f "$OPS/.claude/session/tickets/p1"
printf 'repo=org/p1\nnumber=5\n' > "$WS/p1/.git/apexyard-ticket"

# 1f. The registry path is unknown and no trusted resolver exists. The lookup
# fails closed, runs no external command and writes nothing to stderr.
SAVED_REG="$_AT_REG"
_AT_REG=""
_at_memo_clear
# shellcheck disable=SC2123
PATH=/nonexistent
hash -r
active_ticket_lookup "$WS/p1/src/a.ts" 2> "$B/err"
noreg_rc=$?
noreg_reason="$AT_REASON"
noreg_err=""
IFS= read -r noreg_err < "$B/err" || true
PATH="$REAL_PATH"
hash -r
_AT_REG="$SAVED_REG"
_at_memo_clear
if [ "$noreg_rc" = 1 ] && [ -z "$REPLY" ] && [ "$noreg_reason" = "unregistered common dir" ] && [ -z "$noreg_err" ]; then ok "1f an unknown registry path fails closed with empty stderr"; else bad "1f" "rc=$noreg_rc reason=$noreg_reason err=$noreg_err"; fi

# 1g. A lookup that finds a new marker never enters the old-layout resolution,
# so the old cost never applies to it.
ATD_CALLS=0
_atd_lookup() { ATD_CALLS=$((ATD_CALLS + 1)); REPLY=""; return 1; }
for p in "$WS/p1/src/a.ts" "$B/wt1/src/a.ts" "$OPS/src/a.ts"; do
  _at_memo_clear
  active_ticket_lookup "$p" >/dev/null 2>&1
done
_at_memo_clear
active_ticket_lookup "$B/rogue/a.ts" >/dev/null 2>&1
# shellcheck source=/dev/null
. "$LIB"
ctx
if [ "$ATD_CALLS" = 1 ]; then ok "1g only the lookup without a trusted new marker runs the old-layout resolution"; else bad "1g" "calls=$ATD_CALLS (want 1)"; fi

# --- 2. writer counter -------------------------------------------------------
SHIM="$B/shim"
mkdir -p "$SHIM"
COUNT="$B/count"
: > "$COUNT"
for tool in mktemp chmod mv date rm; do
  real=$(command -v "$tool")
  cat > "$SHIM/$tool" <<EOF
#!/bin/bash
printf '%s\n' "$tool" >> "$COUNT"
exec "$real" "\$@"
EOF
  chmod +x "$SHIM/$tool"
done
_at_memo_clear
# shellcheck disable=SC2123
PATH="$SHIM"
hash -r
active_ticket_write "$WS/p1" org/p1 11 "counted" "http://x/11" "feature/count" 2> "$B/werr"
wrc=$?
PATH="$REAL_PATH"
hash -r
n_main=$(grep -cE '^(mktemp|chmod|mv)$' "$COUNT")
n_date=$(grep -c '^date$' "$COUNT")
if [ "$wrc" = 0 ] && grep -q '^number=11$' "$WS/p1/.git/apexyard-ticket"; then ok "2a the writer works with counting wrappers"; else bad "2a" "rc=$wrc $(cat "$B/werr")"; fi
if [ "$n_main" -le 3 ]; then ok "2b the writer makes at most 3 external commands ($n_main)"; else bad "2b" "$n_main commands"; fi
if [ "$n_date" -le 1 ] && { [ "$n_date" = 0 ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; }; then ok "2c date is used only on a bash older than 4.2"; else bad "2c" "date ran $n_date times on bash $BASH_VERSION"; fi

# 4 (the hook-level count) is at the end of the file.

# --- 3. static fork scan -----------------------------------------------------
# The awk program masks quoted text and strips comments. A double-quoted
# string keeps a command substitution and a backtick, because those still run.
mask_awk() {
  awk '
    {
      line = $0; out = ""; state = 0; n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1); d = substr(line, i + 1, 1)
        if (state == 0) {
          if (c == "\\") { out = out "Q"; i++; continue }
          if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;&|(]/)) break
          if (c == "\047") { state = 1; out = out "Q"; continue }
          if (c == "\"") { state = 2; out = out "Q"; continue }
          out = out c
        } else if (state == 1) {
          if (c == "\047") state = 0
          out = out "Q"
        } else {
          if (c == "\\") { out = out "Q"; i++; continue }
          if (c == "\"") { state = 0; out = out "Q"; continue }
          if (c == "`") { out = out c; continue }
          if (c == "$" && d == "(") { out = out c; continue }
          out = out "Q"
        }
      }
      print out
    }'
}

# classify <masked line>: prints a reason when the line forks, else nothing.
classify() {
  local l="$1" t
  case "$l" in
    *'`'*) echo "backtick"; return ;;
    *'<('*|*'>('*) echo "process substitution"; return ;;
  esac
  if printf '%s\n' "$l" | grep -Eq '(^|[^$])\$\(([^(]|$)|^\$\(([^(]|$)'; then echo "command substitution"; return; fi
  if printf '%s\n' "$l" | grep -Eq '(^|[^[:alnum:]_])(coproc|exec)([^[:alnum:]_]|$)'; then echo "coproc or exec"; return; fi
  if printf '%s\n' "$l" | grep -Eq '(^|;|&&|\|\||[[:space:]])(then|do|else)[[:space:]]*\(|(^|;|&&|\|\|)[[:space:]]*\('; then echo "subshell"; return; fi
  t="${l//&&/}"
  t="${t//&>/}"
  t="${t//>&/}"
  case "$t" in
    *'&'*) echo "background job"; return ;;
  esac
  t="${l//||/}"
  case "$t" in
    *'|'*)
      if ! printf '%s\n' "$l" | grep -Eq '^[[:space:]]*[^[:space:]()]+\)'; then echo "pipe"; return; fi
      ;;
  esac
}

# Known-good and known-bad lines keep the classifier honest.
good=(
  'a || b'
  '*/*|.|..|Q) _at_fail Q; return 1 ;;'
  'x=$((n + 1))'
  '*Q|*Q)'
  'case Q in'
  'cmd >Q 2>&1'
  'exec_count=1'
  '[ -L Q ] && return 1'
  '{ IFS= read -r a; IFS= read -r b; } <<<Q'
)
badl=(
  'x=$(cmd)'
  'x=`cmd`'
  'a | b'
  'cmd &'
  '( cd x )'
  'x && ( cd y )'
  'exec foo'
  'diff <(a) <(b)'
  'coproc x'
  'then (a)'
)
cls_ok=1
for l in "${good[@]}"; do
  r=$(classify "$l")
  [ -z "$r" ] || { cls_ok=0; bad "3a classifier accepts [$l]" "got [$r]"; }
done
for l in "${badl[@]}"; do
  r=$(classify "$l")
  [ -n "$r" ] || { cls_ok=0; bad "3a classifier flags [$l]" "got nothing"; }
done
[ "$cls_ok" = 1 ] && ok "3a the classifier handles known-good and known-bad lines"

# Extract the scanned function bodies from the library. The old-layout
# resolution (_atd_*) keeps the cost it had before markers moved and is not
# scanned. Check 1g shows that a lookup that finds a new marker never runs it.
SCAN_NAMES='^(_at_[a-z_]+|active_ticket_(lookup|lookup_cwd|gitdir|is_marker_target|read_field|set_context|marker_for_path|project_markers))$'
EXTRA_SCAN="${ACTIVE_TICKET_EXTRA_SCAN:-}"
scan_fail=0
scanned=0
while IFS= read -r name; do
  if ! printf '%s\n' "$name" | grep -Eq "$SCAN_NAMES"; then
    case " $EXTRA_SCAN " in *" $name "*) ;; *) continue ;; esac
  fi
  scanned=$((scanned + 1))
  body=$(awk -v fn="$name" '$0 ~ "^"fn"\\(\\) \\{" {on=1; next} on && /^}/ {exit} on {print}' "$LIB")
  [ -n "$body" ] || { bad "3b body of $name" "empty"; scan_fail=1; continue; }
  masked=$(printf '%s\n' "$body" | mask_awk)
  lineno=0
  while IFS= read -r ml; do
    lineno=$((lineno + 1))
    r=$(classify "$ml")
    if [ -n "$r" ]; then
      bad "3b $name line $lineno" "$r: $ml"
      scan_fail=1
    fi
  done <<< "$masked"
done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{' "$LIB" | sed -E 's/\(\) \{$//')
if [ "$scan_fail" = 0 ] && [ "$scanned" -ge 20 ]; then ok "3b no lookup function forks ($scanned functions scanned)"; else [ "$scan_fail" != 0 ] || bad "3b" "only $scanned functions scanned"; fi

# The scan must catch a regression: add a command substitution to a copy.
sed 's/^_at_owned() { \[ -O "\$1" \]; }/_at_owned() { local x; x=$(true); [ -O "$1" ]; }/' "$LIB" > "$B/mutant.sh"
mbody=$(awk '$0 ~ "^_at_owned\\(\\) \\{" {print; exit}' "$B/mutant.sh")
mmask=$(printf '%s\n' "$mbody" | mask_awk)
r=$(classify "$mmask")
if [ -n "$r" ]; then ok "3c a command substitution in a lookup function is caught"; else bad "3c" "mutant not caught: $mmask"; fi

# --- 4. hook-level process count ---------------------------------------------
# One run of the real hook per shape, traced with strace. The test counts
# process clones (it skips CLONE_THREAD) and successful execve calls. Each
# count must not exceed the count of the same hook before the marker moved
# into the git dir, on the same fixture.
#
# The limits in budget_limits were measured on the fixture of this test with
# the dev hooks at b312ca8, on a developer
# machine. Confirm them on the CI ubuntu leg, and re-measure when the runner,
# the fixture or the merge base changes:
#   APEXYARD_BUDGET_MEASURE=1 bash test_active_ticket_process_budget.sh
# The limits are the dev counts, with no added margin, except for the exempt
# case. The current hooks match the dev count of that case exactly,
# so its limits are the dev counts plus 2. A failure message
# names the measured and the allowed counts. A small rise on a new git or
# bash version on the runner calls for a re-measure, not a code change.
# To measure another hook version, point APEXYARD_BUDGET_HOOKS_DIR at its
# .claude/hooks directory. That version needs an old-layout current-ticket to
# pass.
#
# The case needs strace and a working ptrace. On Linux in CI (the CI variable
# is set), a missing strace or a denied ptrace fails the case. Elsewhere the
# case prints a note and runs nothing.

# budget_limits <shape>: sets max_f and max_e
budget_limits() {
  case "$1" in
    ops) max_f=130; max_e=52 ;;
    wt) max_f=135; max_e=57 ;;
    main) max_f=142; max_e=61 ;;
    exempt) max_f=32; max_e=16 ;;
    bash) max_f=566; max_e=236 ;;
    mig) max_f=386; max_e=123 ;;
    legmain) max_f=142; max_e=61 ;;
    legwt) max_f=149; max_e=67 ;;
    *) max_f=0; max_e=0 ;;
  esac
}

HOOKSDIR="${APEXYARD_BUDGET_HOOKS_DIR:-$SRC_ROOT/.claude/hooks}"
FIXBASE="${RUNNER_TEMP:-$HOME/.cache/apexyard-tests}"

hook_count_case() {
  if ! command -v strace >/dev/null 2>&1 || ! strace -qq -o /dev/null true >/dev/null 2>&1; then
    if [ -n "${CI:-}" ] && [ "$(uname -s)" = Linux ] && [ -z "${APEXYARD_BUDGET_MEASURE:-}" ]; then
      bad "4 hook-level process count" "strace is missing or ptrace is denied on a Linux CI runner"
    else
      echo "INFO: hook-level process count not run: strace is missing or ptrace is denied"
    fi
    return 0
  fi
  mkdir -p "$FIXBASE" || { echo "INFO: hook-level process count not run: no fixture directory"; return 0; }
  local sb f
  sb=$(mktemp -d "$FIXBASE/budget.XXXXXX")
  sb=$(cd -P "$sb" && pwd)
  mkrepo "$sb"
  : > "$sb/.apexyard-fork"
  : > "$sb/onboarding.yaml"
  printf 'projects:\n  - name: p1\n    repo: org/p1\n' > "$sb/apexyard.projects.yaml"
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session" "$sb/workspace"
  for f in require-active-ticket.sh require-migration-ticket.sh _lib-detect-bash-write.sh _lib-read-config.sh \
           _lib-path-resolve.sh _lib-active-ticket.sh _lib-mask-quoted.sh _lib-ticket-path-exemptions.sh _lib-portfolio-paths.sh \
           _lib-ops-root.sh _lib-resolution-cache.sh _lib-tracker.sh; do
    cp "$HOOKSDIR/$f" "$sb/.claude/hooks/$f"
  done
  cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  printf '{ "tracker": { "kind": "none" } }\n' > "$sb/.claude/project-config.json"
  mkrepo "$sb/workspace/p1"
  git -C "$sb/workspace/p1" worktree add -q "$sb/wt1" -b wt1
  mkdir -p "$sb/src" "$sb/db/migrations" "$sb/workspace/p1/src" "$sb/workspace/p1/lib" "$sb/wt1/src"
  # New layout markers, and an old-layout marker for a hook of the old layout.
  printf 'repo=org/ops\nnumber=1\n' > "$sb/.git/apexyard-ticket"
  printf 'repo=org/p1\nnumber=2\n' > "$sb/workspace/p1/.git/apexyard-ticket"
  printf 'repo=org/p1\nnumber=3\n' > "$sb/workspace/p1/.git/worktrees/wt1/apexyard-ticket"
  printf 'repo=org/ops\nnumber=1\n' > "$sb/.claude/session/current-ticket"

  local names=(ops wt main exempt bash mig) payloads=() hooks=() i
  payloads[0]=$(jq -nc --arg p "$sb/src/a.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
  payloads[1]=$(jq -nc --arg p "$sb/wt1/src/a.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
  payloads[2]=$(jq -nc --arg p "$sb/workspace/p1/src/a.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
  payloads[3]=$(jq -nc --arg p "$sb/README.md" '{tool_name:"Edit", tool_input:{file_path:$p}}')
  payloads[4]=$(jq -nc --arg c "cat a > $sb/workspace/p1/src/a.ts; cat b > $sb/workspace/p1/src/b.ts; cat c > $sb/workspace/p1/lib/c.ts" '{tool_name:"Bash", tool_input:{command:$c}}')
  payloads[5]=$(jq -nc --arg p "$sb/db/migrations/001_add.sql" '{tool_name:"Edit", tool_input:{file_path:$p}}')
  hooks=(require-active-ticket.sh require-active-ticket.sh require-active-ticket.sh require-active-ticket.sh require-active-ticket.sh require-migration-ticket.sh)
  local forks execs rc max_f max_e
  # A Claude session caches the resolved workspace dir and registry path in
  # files, so the traced runs use that cache, after one warm-up run. The
  # config files must be older than the cache write guard allows.
  touch -t 202001010000 "$sb/.claude/project-config.defaults.json" "$sb/.claude/project-config.json"
  mkdir -p "$sb/pin"
  for i in 0 1 2 3 4 5; do
    printf '%s' "${payloads[$i]}" > "$sb/payload.json"
    ( cd "$sb" && CLAUDE_CODE_SESSION_ID="budget-$$" APEXYARD_OPS_PIN_DIR="$sb/pin" APEXYARD_DISABLE_RESOLUTION_CACHE='' \
        bash "$sb/.claude/hooks/${hooks[$i]}" < "$sb/payload.json" > /dev/null 2>&1 )
    ( cd "$sb" && CLAUDE_CODE_SESSION_ID="budget-$$" APEXYARD_OPS_PIN_DIR="$sb/pin" APEXYARD_DISABLE_RESOLUTION_CACHE='' \
        strace -f -qq -e trace=process -o "$sb/trace.$i" \
        bash "$sb/.claude/hooks/${hooks[$i]}" < "$sb/payload.json" > /dev/null 2>&1 )
    rc=$?
    forks=$(awk '/^[0-9]+ +(clone3?|fork|vfork)\(/ && !/CLONE_THREAD/ && !/= -1/ {n++} END {print n+0}' "$sb/trace.$i")
    execs=$(awk '/^[0-9]+ +execve\(/ && !/= -1/ {n++} END {print n+0}' "$sb/trace.$i")
    if [ -n "${APEXYARD_BUDGET_MEASURE:-}" ]; then
      echo "MEASURE ${names[$i]}: forks=$forks execs=$execs rc=$rc"
      continue
    fi
    budget_limits "${names[$i]}"
    if [ "$rc" != 0 ]; then bad "4 (${names[$i]}) the hook passes" "rc=$rc"; continue; fi
    if [ "$forks" -le "$max_f" ] && [ "$execs" -le "$max_e" ]; then
      ok "4 (${names[$i]}) forks=$forks (max $max_f) execs=$execs (max $max_e)"
    else
      bad "4 (${names[$i]})" "forks=$forks (max $max_f) execs=$execs (max $max_e); if the runner, the fixture or the merge base changed, re-measure with APEXYARD_BUDGET_MEASURE=1"
    fi
  done
  rm -rf "$sb"
}
hook_count_case

# --- 4b. hook-level process count, old-layout markers only --------------------
# The same count for targets that only an old-layout marker covers, so the
# fallback resolution runs: tickets/p1 for a main clone, and
# tickets/p2/<branch> for a linked worktree inside the workspace dir. The
# limits are the merge-base counts for the same fixture, measured the same
# way as above, against the same dev merge base.
legacy_count_case() {
  if ! command -v strace >/dev/null 2>&1 || ! strace -qq -o /dev/null true >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p "$FIXBASE" || return 0
  local sb f i rc forks execs max_f max_e
  sb=$(mktemp -d "$FIXBASE/budget-legacy.XXXXXX")
  sb=$(cd -P "$sb" && pwd)
  mkrepo "$sb"
  : > "$sb/.apexyard-fork"
  : > "$sb/onboarding.yaml"
  printf 'projects:\n  - name: p1\n    repo: org/p1\n  - name: p2\n    repo: org/p2\n' > "$sb/apexyard.projects.yaml"
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session/tickets/p2" "$sb/workspace"
  for f in require-active-ticket.sh require-migration-ticket.sh _lib-detect-bash-write.sh _lib-read-config.sh \
           _lib-path-resolve.sh _lib-active-ticket.sh _lib-mask-quoted.sh _lib-ticket-path-exemptions.sh _lib-portfolio-paths.sh \
           _lib-ops-root.sh _lib-resolution-cache.sh _lib-tracker.sh; do
    cp "$HOOKSDIR/$f" "$sb/.claude/hooks/$f"
  done
  cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  printf '{ "tracker": { "kind": "none" } }\n' > "$sb/.claude/project-config.json"
  mkrepo "$sb/workspace/p1"
  mkrepo "$sb/workspace/p2"
  git -C "$sb/workspace/p2" worktree add -q "$sb/workspace/p2/.wt/w" -b feature/w
  mkdir -p "$sb/workspace/p1/src" "$sb/workspace/p2/.wt/w/src"
  printf 'repo=org/p1\nnumber=4\n' > "$sb/.claude/session/tickets/p1"
  printf 'repo=org/p2\nnumber=5\n' > "$sb/.claude/session/tickets/p2/feature__w"
  local names=(legmain legwt) payloads=()
  payloads[0]=$(jq -nc --arg p "$sb/workspace/p1/src/a.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
  payloads[1]=$(jq -nc --arg p "$sb/workspace/p2/.wt/w/src/a.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
  touch -t 202001010000 "$sb/.claude/project-config.defaults.json" "$sb/.claude/project-config.json"
  mkdir -p "$sb/pin"
  for i in 0 1; do
    printf '%s' "${payloads[$i]}" > "$sb/payload.json"
    ( cd "$sb" && CLAUDE_CODE_SESSION_ID="budget-$$" APEXYARD_OPS_PIN_DIR="$sb/pin" APEXYARD_DISABLE_RESOLUTION_CACHE='' \
        bash "$sb/.claude/hooks/require-active-ticket.sh" < "$sb/payload.json" > /dev/null 2>&1 )
    ( cd "$sb" && CLAUDE_CODE_SESSION_ID="budget-$$" APEXYARD_OPS_PIN_DIR="$sb/pin" APEXYARD_DISABLE_RESOLUTION_CACHE='' \
        strace -f -qq -e trace=process -o "$sb/trace.$i" \
        bash "$sb/.claude/hooks/require-active-ticket.sh" < "$sb/payload.json" > /dev/null 2>&1 )
    rc=$?
    forks=$(awk '/^[0-9]+ +(clone3?|fork|vfork)\(/ && !/CLONE_THREAD/ && !/= -1/ {n++} END {print n+0}' "$sb/trace.$i")
    execs=$(awk '/^[0-9]+ +execve\(/ && !/= -1/ {n++} END {print n+0}' "$sb/trace.$i")
    if [ -n "${APEXYARD_BUDGET_MEASURE:-}" ]; then
      echo "MEASURE ${names[$i]}: forks=$forks execs=$execs rc=$rc"
      continue
    fi
    budget_limits "${names[$i]}"
    if [ "$rc" != 0 ]; then bad "4b (${names[$i]}) the hook passes" "rc=$rc"; continue; fi
    if [ "$forks" -le "$max_f" ] && [ "$execs" -le "$max_e" ]; then
      ok "4b (${names[$i]}) forks=$forks (max $max_f) execs=$execs (max $max_e)"
    else
      bad "4b (${names[$i]})" "forks=$forks (max $max_f) execs=$execs (max $max_e); if the runner, the fixture or the merge base changed, re-measure with APEXYARD_BUDGET_MEASURE=1"
    fi
  done
  rm -rf "$sb"
}
legacy_count_case

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
