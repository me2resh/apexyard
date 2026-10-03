#!/bin/bash
# test_tracker_fetch_status.sh — completeness reporting for tracker_list (#1441).
#
# A list call that fills its limit may be a short read. A failed call prints
# `[]` and returns non-zero, which a caller that ignores the return code reads
# as an empty set. Both cases used to be indistinguishable from a complete read.
#
# Cases:
#   1. tracker_fetch_status verdicts: COMPLETE / TRUNCATED / UNKNOWN
#   2. glab page cap: a 100-item read stays TRUNCATED even at limit=200
#   3. tracker_list sets TRACKER_LIST_STATUS on success and on failure
#   4. tracker_list passes an explicit limit when the caller gives none
#   5. the status reads the server count, not the client-side `since` filter

set -u
unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s (expected [%s], got [%s])\n' "$1" "$2" "$3"
  fi
}

SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/.claude/hooks" "$SB/bin"
for lib in _lib-tracker.sh _lib-read-config.sh _lib-portfolio-paths.sh _lib-ops-root.sh \
           _lib-resolution-cache.sh _lib-self-location.sh; do
  [ -f "$HOOK_DIR/$lib" ] && cp "$HOOK_DIR/$lib" "$SB/.claude/hooks/"
done
cp "$HOOK_DIR/../project-config.defaults.json" "$SB/.claude/" 2>/dev/null
printf 'company:\n  name: test\n' > "$SB/onboarding.yaml"
printf 'version: 1\nprojects: []\n' > "$SB/apexyard.projects.yaml"

# Mock gh: emit COUNT issues, capture argv.
cat > "$SB/bin/gh" <<'EOF'
#!/bin/bash
[ -n "${GH_CAPTURE:-}" ] && printf '%s\n' "$@" > "$GH_CAPTURE"
[ "${GH_FAIL:-0}" = "1" ] && exit 1
n="${GH_COUNT:-2}"
i=1
printf '['
while [ "$i" -le "$n" ]; do
  [ "$i" -gt 1 ] && printf ','
  printf '{"number":%d,"title":"t%d","url":"u","labels":[],"state":"OPEN","updatedAt":"2026-06-%02dT00:00:00Z"}' \
    "$i" "$i" $(( (i % 28) + 1 ))
  i=$((i + 1))
done
printf ']'
EOF
chmod +x "$SB/bin/gh"

cd "$SB" || { echo "FAIL: cd sandbox"; exit 1; }
# shellcheck source=/dev/null
. "$SB/.claude/hooks/_lib-tracker.sh"
export PATH="$SB/bin:$PATH"

# Case 1 — verdicts.
assert_eq "short read is COMPLETE"        "COMPLETE"  "$(tracker_fetch_status 0 28 100)"
assert_eq "full page is TRUNCATED"        "TRUNCATED" "$(tracker_fetch_status 0 100 100)"
assert_eq "failed call is UNKNOWN"        "UNKNOWN"   "$(tracker_fetch_status 1 0 100)"
assert_eq "unreadable count is UNKNOWN"   "UNKNOWN"   "$(tracker_fetch_status 0 '' 100)"
assert_eq "unreadable limit is UNKNOWN"   "UNKNOWN"   "$(tracker_fetch_status 0 5 abc)"
assert_eq "zero limit is UNKNOWN"         "UNKNOWN"   "$(tracker_fetch_status 0 0 0)"
assert_eq "empty result is COMPLETE"      "COMPLETE"  "$(tracker_fetch_status 0 0 30)"

# Case 2 — glab page cap.
assert_eq "gh has no page cap"   "0"   "$(tracker_page_cap 'o/r')"
tracker_clear_cache
printf 'version: 1\nprojects:\n  - name: g\n    repo: g/p\n    tracker:\n      kind: glab\n' \
  > "$SB/apexyard.projects.yaml"
assert_eq "glab caps a page at 100" "100" "$(tracker_page_cap 'g/p')"
assert_eq "glab 100 items stays TRUNCATED at limit 200" "TRUNCATED" "$(tracker_fetch_status 0 100 200 'g/p')"
assert_eq "glab 99 items is COMPLETE"                   "COMPLETE"  "$(tracker_fetch_status 0 99 200 'g/p')"
printf 'version: 1\nprojects: []\n' > "$SB/apexyard.projects.yaml"
tracker_clear_cache

# Case 3 — tracker_list sets the status.
TRACKER_LIST_STATUS=""
GH_COUNT=2 tracker_list "o/r" limit=10 >/dev/null
assert_eq "short list sets COMPLETE" "COMPLETE" "$TRACKER_LIST_STATUS"

TRACKER_LIST_STATUS=""
GH_COUNT=10 tracker_list "o/r" limit=10 >/dev/null
assert_eq "full list sets TRUNCATED" "TRUNCATED" "$TRACKER_LIST_STATUS"

TRACKER_LIST_STATUS=""
GH_FAIL=1 tracker_list "o/r" limit=10 > "$SB/failed.out" 2>/dev/null; rc=$?
assert_eq "failed list returns non-zero" "1" "$rc"
assert_eq "failed list prints []"        "[]" "$(cat "$SB/failed.out")"
assert_eq "failed list sets UNKNOWN"     "UNKNOWN" "$TRACKER_LIST_STATUS"

TRACKER_LIST_STATUS=""
tracker_list "" limit=10 >/dev/null
assert_eq "missing repo sets UNKNOWN" "UNKNOWN" "$TRACKER_LIST_STATUS"

# Case 4 — an explicit limit reaches the CLI when the caller gives none.
GH_COUNT=2 GH_CAPTURE="$SB/cap" tracker_list "o/r" >/dev/null
assert_eq "default limit is passed to gh" "30" "$(awk 'p{print;exit} $0=="--limit"{p=1}' "$SB/cap")"

TRACKER_LIST_STATUS=""
GH_COUNT=30 tracker_list "o/r" >/dev/null
assert_eq "a full default page is TRUNCATED" "TRUNCATED" "$TRACKER_LIST_STATUS"

# Case 4b — the config key is honoured, and the assertion discriminates: the
# sandbox asks for 75, which is not the hardcoded fallback of 30.
printf '{ "tracker": { "kind": "gh", "list_default_limit": 75 } }\n' > "$SB/.claude/project-config.json"
tracker_clear_cache
GH_COUNT=2 GH_CAPTURE="$SB/cap75" tracker_list "o/r" >/dev/null
assert_eq "configured default limit reaches the CLI" "75" "$(awk 'p{print;exit} $0=="--limit"{p=1}' "$SB/cap75")"

printf '{ "tracker": { "kind": "gh", "list_default_limit": "; touch %s/pwned; echo " } }\n' "$SB" \
  > "$SB/.claude/project-config.json"
tracker_clear_cache
GH_COUNT=2 GH_CAPTURE="$SB/capbad" tracker_list "o/r" >/dev/null
assert_eq "a hostile config limit falls back to 30" "30" "$(awk 'p{print;exit} $0=="--limit"{p=1}' "$SB/capbad")"
assert_eq "a hostile config limit runs nothing"     "absent" "$([ -e "$SB/pwned" ] && echo present || echo absent)"
rm -f "$SB/.claude/project-config.json"
tracker_clear_cache

# Case 4c — tracker_list_to carries the verdict through a command substitution,
# which is the shape a caller reaches for first and the one TRACKER_LIST_STATUS
# cannot survive.
TRACKER_LIST_STATUS="COMPLETE"   # a stale value from an earlier call
status=$(GH_COUNT=10 tracker_list_to "$SB/items.json" "o/r" limit=10)
assert_eq "tracker_list_to returns TRUNCATED through a subshell" "TRUNCATED" "$status"
assert_eq "tracker_list_to wrote the array"                      "10" "$(jq -r 'length' < "$SB/items.json")"

TRACKER_LIST_STATUS="COMPLETE"
status=$(GH_FAIL=1 tracker_list_to "$SB/items.json" "o/r" limit=10 2>/dev/null); rc=$?
assert_eq "a failed read reports UNKNOWN, not the stale COMPLETE" "UNKNOWN" "$status"
assert_eq "a failed read still returns non-zero"                  "1" "$rc"

status=$(GH_COUNT=2 tracker_list_to "" "o/r" limit=10 2>/dev/null); rc=$?
assert_eq "tracker_list_to with no outfile reports UNKNOWN" "UNKNOWN" "$status"
assert_eq "tracker_list_to with no outfile fails"           "1" "$rc"

# Case 4d — an oversized limit does not reach `[` as a number.
assert_eq "an oversized count is UNKNOWN" "UNKNOWN" "$(tracker_fetch_status 0 99999999999999999999 100)"
assert_eq "an oversized limit is UNKNOWN" "UNKNOWN" "$(tracker_fetch_status 0 5 99999999999999999999)"
err=$(tracker_fetch_status 0 99999999999999999999 100 2>&1 >/dev/null)
assert_eq "an oversized value writes nothing to stderr" "" "$err"

# Case 5 — the client-side `since` filter must not turn a full page into COMPLETE.
tracker_clear_cache
printf 'version: 1\nprojects:\n  - name: c\n    repo: c/p\n    tracker:\n      kind: custom\n      list_command: "gh issue list"\n' \
  > "$SB/apexyard.projects.yaml"
TRACKER_LIST_STATUS=""
GH_COUNT=10 tracker_list "c/p" limit=10 since=2099-01-01 > "$SB/since.out"
assert_eq "since filter drops every row"        "0"         "$(jq -r 'length' < "$SB/since.out")"
assert_eq "but the server page was still full"  "TRUNCATED" "$TRACKER_LIST_STATUS"

# Case 6 — a custom adapter may emit a wrapper object, which is not a JSON
# array. Only a raw array is countable, so the verdict is UNKNOWN: the
# operator's list_normalise_jq is free to select rows, and counting its output
# would count that selection rather than the server page.
tracker_clear_cache
cat > "$SB/bin/wrapped" <<'EOF'
#!/bin/bash
n="${TRACKER_COUNT:-10}"
i=1
printf '{"items":['
while [ "$i" -le "$n" ]; do
  [ "$i" -gt 1 ] && printf ','
  printf '{"number":%d,"title":"t","url":"u","labels":[],"state":"OPEN","updatedAt":"2026-06-01T00:00:00Z"}' "$i"
  i=$((i + 1))
done
printf ']}'
EOF
chmod +x "$SB/bin/wrapped"
printf 'version: 1\nprojects: []\n' > "$SB/apexyard.projects.yaml"
printf '{ "tracker": { "kind": "custom", "list_command": "wrapped", "list_normalise_jq": ".items" } }\n' \
  > "$SB/.claude/project-config.json"
TRACKER_LIST_STATUS=""
TRACKER_COUNT=10 tracker_list "w/p" limit=10 > "$SB/wrapped.out" 2>/dev/null
assert_eq "a wrapper payload normalises to 10 rows" "10" "$(jq -r 'length' < "$SB/wrapped.out")"
assert_eq "an uncountable wrapper page is UNKNOWN"  "UNKNOWN" "$TRACKER_LIST_STATUS"

# The dangerous shape: a normalise expression that SELECTS rows. Counting its
# output would report this full server page as COMPLETE.
printf '{ "tracker": { "kind": "custom", "list_command": "wrapped", "list_normalise_jq": ".items | map(select(.number <= 5))" } }\n' \
  > "$SB/.claude/project-config.json"
tracker_clear_cache
TRACKER_LIST_STATUS=""
TRACKER_COUNT=10 tracker_list "w/p" limit=10 > "$SB/sel.out" 2>/dev/null
assert_eq "a selecting normalise never reports COMPLETE" "UNKNOWN" "$TRACKER_LIST_STATUS"

# A wrapper payload with no list_normalise_jq mapping is not countable either.
printf '{ "tracker": { "kind": "custom", "list_command": "wrapped" } }\n' > "$SB/.claude/project-config.json"
tracker_clear_cache
TRACKER_LIST_STATUS=""
TRACKER_COUNT=10 tracker_list "w/p" limit=10 > /dev/null 2>&1
assert_eq "an unmapped payload is UNKNOWN" "UNKNOWN" "$TRACKER_LIST_STATUS"
rm -f "$SB/.claude/project-config.json"


# Case 7 — a custom adapter with no caller limit keeps its previous behaviour:
# TRACKER_LIMIT stays empty, so the returned set does not change. The verdict
# is then UNKNOWN, because no limit was chosen to judge completeness against.
cat > "$SB/bin/showlimit" <<'EOF'
#!/bin/bash
printf '%s' "${TRACKER_LIMIT-unset}" > "$SHOWLIMIT_OUT"
printf '[]'
EOF
chmod +x "$SB/bin/showlimit"
printf 'version: 1\nprojects:\n  - name: s\n    repo: s/p\n    tracker:\n      kind: custom\n      list_command: "showlimit"\n' \
  > "$SB/apexyard.projects.yaml"
tracker_clear_cache
TRACKER_LIST_STATUS=""
SHOWLIMIT_OUT="$SB/limit.seen" tracker_list "s/p" >/dev/null
assert_eq "custom adapter keeps an empty TRACKER_LIMIT" "" "$(cat "$SB/limit.seen")"
assert_eq "custom adapter with no limit is UNKNOWN"     "UNKNOWN" "$TRACKER_LIST_STATUS"

TRACKER_LIST_STATUS=""
SHOWLIMIT_OUT="$SB/limit2.seen" tracker_list "s/p" limit=25 >/dev/null
assert_eq "custom adapter still receives a caller limit" "25" "$(cat "$SB/limit2.seen")"

printf '\ntracker_fetch_status: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
