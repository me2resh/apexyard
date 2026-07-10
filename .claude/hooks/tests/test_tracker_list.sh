#!/bin/bash
# test_tracker_list.sh — the #710 / AgDR-0093 listing abstraction.
#
# tracker_list lists a SET of issues from a project's tracker, mirroring
# tracker_view/tracker_create. Callers express intent in a generic filter
# vocabulary (state/assignee/author/labels/search/since/limit); each per-kind
# adapter renders those into native CLI flags. Returns a normalised JSON ARRAY
# on stdout, exit 0; `[]` + exit 1 on failure. GitHub's search DSL is NOT parsed.
#
# Tests use MOCK CLIs (a fake gh/glab/custom on PATH) — no real API calls.
#
# Cases:
#   1.  gh happy path → array normalised {ref,number,state,title,url,labels,updatedAt}
#   2.  gh filter render → state/assignee/author/labels/search/limit reach gh as flags
#   3.  gh assignee=none → appended as `no:assignee` search qualifier (no --assignee)
#   4.  gh since + state=closed → `closed:>=<date>` search qualifier
#   5.  gh empty result `[]` → exit 0 (empty set is success, not failure)
#   6.  gh CLI failure → `[]` + exit 1
#   7.  kind=none → `[]` + exit 1 (no CLI to call)
#   8.  per-project glab override → dispatches glab, normalises iid/web_url/updated_at
#           [needs YAML parser]
#   9.  glab labels csv → repeated --label flags; glab since → client-side filter
#           [needs YAML parser]
#   10. per-project custom list_command → filters via ENV, NO shell injection
#           [needs YAML parser]
#
# Exit 0 = all pass. Exit 1 on first failure.

set -u
unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACKER_LIB="$HOOK_DIR/_lib-tracker.sh"
CONFIG_LIB="$HOOK_DIR/_lib-read-config.sh"
PORTFOLIO_LIB="$HOOK_DIR/_lib-portfolio-paths.sh"
OPSROOT_LIB="$HOOK_DIR/_lib-ops-root.sh"

PASS=0
FAIL=0
FAILED=""
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; echo "FAIL: $1"; echo "    expected: [$2]"; echo "    actual:   [$3]"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }

HAVE_YAML=no
if command -v yq >/dev/null 2>&1 || python3 -c 'import yaml' >/dev/null 2>&1; then HAVE_YAML=yes; fi

# Build a single-fork sandbox; $1 optional registry body (per-project trackers).
make_sandbox() {
  local sb registry_body="${1:-}"
  sb=$(mktemp -d); sb=$(cd "$sb" && pwd -P)
  mkdir -p "$sb/.claude/hooks" "$sb/bin"
  touch "$sb/onboarding.yaml"
  cp "$TRACKER_LIB"   "$sb/.claude/hooks/_lib-tracker.sh"
  cp "$CONFIG_LIB"    "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$PORTFOLIO_LIB" "$sb/.claude/hooks/_lib-portfolio-paths.sh"
  [ -f "$OPSROOT_LIB" ] && cp "$OPSROOT_LIB" "$sb/.claude/hooks/_lib-ops-root.sh"
  cat > "$sb/.claude/project-config.defaults.json" <<'JSON'
{ "tracker": { "kind": "gh" } }
JSON
  if [ -n "$registry_body" ]; then
    printf '%s\n' "$registry_body" > "$sb/apexyard.projects.yaml"
  else
    printf 'version: 1\nprojects: []\n' > "$sb/apexyard.projects.yaml"
  fi
  echo "$sb"
}

# Mock gh: capture argv (one per line) to $GH_CAPTURE, print a JSON array for
# `issue list`. The array uses gh's --json shape (labels as {name} objects,
# state UPPERCASE, updatedAt camelCase).
install_gh_mock() {
  local sb="$1"
  cat > "$sb/bin/gh" <<'EOF'
#!/bin/bash
[ -n "${GH_CAPTURE:-}" ] && printf '%s\n' "$@" > "$GH_CAPTURE"
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  cat <<'JSON'
[
  {"number":42,"title":"Fix login","url":"https://github.com/o/r/issues/42","labels":[{"name":"blocked"}],"state":"OPEN","updatedAt":"2026-07-01T10:00:00Z"},
  {"number":7,"title":"Add export","url":"https://github.com/o/r/issues/7","labels":[],"state":"OPEN","updatedAt":"2026-06-20T09:00:00Z"}
]
JSON
fi
EOF
  chmod +x "$sb/bin/gh"
}

# ---------------------------------------------------------------------------
SB=$(make_sandbox)
install_gh_mock "$SB"
cd "$SB" || { echo "FAIL: cd sandbox"; exit 1; }
# shellcheck source=/dev/null
. "$SB/.claude/hooks/_lib-tracker.sh"

# Case 1 — gh happy path: normalised array.
tracker_clear_cache
out=$(PATH="$SB/bin:$PATH" tracker_list "o/r"); rc=$?
assert_eq "tracker_list gh → exit 0"                  "0"          "$rc"
assert_eq "tracker_list gh → 2 items"                 "2"          "$(printf '%s' "$out" | jq -r 'length' 2>/dev/null)"
assert_eq "tracker_list gh → ref is a STRING"         "42"         "$(printf '%s' "$out" | jq -r '.[0].ref' 2>/dev/null)"
assert_eq "tracker_list gh → number is numeric"       "42"         "$(printf '%s' "$out" | jq -r '.[0].number' 2>/dev/null)"
assert_eq "tracker_list gh → title normalised"        "Fix login"  "$(printf '%s' "$out" | jq -r '.[0].title' 2>/dev/null)"
assert_eq "tracker_list gh → url normalised"          "https://github.com/o/r/issues/42" "$(printf '%s' "$out" | jq -r '.[0].url' 2>/dev/null)"
assert_eq "tracker_list gh → labels flattened"        "blocked"    "$(printf '%s' "$out" | jq -r '.[0].labels[0]' 2>/dev/null)"
assert_eq "tracker_list gh → updatedAt carried"       "2026-07-01T10:00:00Z" "$(printf '%s' "$out" | jq -r '.[0].updatedAt' 2>/dev/null)"

# Case 2 — filter render: state/assignee/author/labels/search/limit → gh flags.
tracker_clear_cache
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/cap2" \
  tracker_list "o/r" state=closed assignee=@me author=octocat labels=bug,ci search="oauth flow" limit=50 >/dev/null
CAP=$(cat "$SB/cap2")
assert_eq "gh render → --state closed"     "1" "$(printf '%s\n' "$CAP" | grep -cx -- 'closed' )"
val_after() { awk -v f="$1" 'p{print;exit} $0==f{p=1}' "$SB/cap2"; }
assert_eq "gh render → --assignee value"   "@me"        "$(val_after '--assignee')"
assert_eq "gh render → --author value"     "octocat"    "$(val_after '--author')"
assert_eq "gh render → --label value"      "bug,ci"     "$(val_after '--label')"
assert_eq "gh render → --search value"     "oauth flow" "$(val_after '--search')"
assert_eq "gh render → --limit value"      "50"         "$(val_after '--limit')"

# Case 3 — assignee=none appends `no:assignee` to --search, no --assignee flag.
tracker_clear_cache
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/cap3" tracker_list "o/r" assignee=none >/dev/null
assert_eq "gh assignee=none → no --assignee flag"       "0" "$(grep -cx -- '--assignee' "$SB/cap3")"
assert_eq "gh assignee=none → no:assignee in --search"  "no:assignee" "$(awk 'p{print;exit} $0=="--search"{p=1}' "$SB/cap3")"

# Case 4 — since + state=closed → `closed:>=<date>` search qualifier.
tracker_clear_cache
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/cap4" tracker_list "o/r" state=closed since=2026-06-01 >/dev/null
assert_eq "gh since+closed → closed:>= qualifier" "closed:>=2026-06-01" "$(awk 'p{print;exit} $0=="--search"{p=1}' "$SB/cap4")"

# Case 4b — since with DEFAULT state (open) → `updated:>=<date>` qualifier (the
# non-closed branch of the since mapping).
tracker_clear_cache
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/cap4b" tracker_list "o/r" since=2026-06-01 >/dev/null
assert_eq "gh since default(open) → updated:>= qualifier" "updated:>=2026-06-01" "$(awk 'p{print;exit} $0=="--search"{p=1}' "$SB/cap4b")"

# Case 5 — empty result `[]` is SUCCESS (exit 0), not a failure.
cat > "$SB/bin/gh" <<'EOF'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then echo "[]"; fi
EOF
chmod +x "$SB/bin/gh"
tracker_clear_cache
out=$(PATH="$SB/bin:$PATH" tracker_list "o/r"); rc=$?
assert_eq "tracker_list gh empty set → exit 0" "0"  "$rc"
assert_eq "tracker_list gh empty set → []"     "[]" "$out"

# Case 6 — CLI failure → `[]` + exit 1.
cat > "$SB/bin/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$SB/bin/gh"
tracker_clear_cache
out=$(PATH="$SB/bin:$PATH" tracker_list "o/r"); rc=$?
assert_eq "tracker_list gh failure → exit 1" "1"  "$rc"
assert_eq "tracker_list gh failure → []"     "[]" "$out"
rm -rf "$SB"

# Case 7 — kind=none → `[]` + exit 1 (no CLI to call).
SBN=$(make_sandbox)
cat > "$SBN/.claude/project-config.defaults.json" <<'JSON'
{ "tracker": { "kind": "none" } }
JSON
(
  cd "$SBN" || exit 1
  # shellcheck source=/dev/null
  . "$SBN/.claude/hooks/_lib-tracker.sh"
  tracker_clear_cache
  out=$(tracker_list "o/r"); rc=$?
  printf '%s|%s\n' "$rc" "$out"
) > "$SBN/r"
IFS="|" read -r n_rc n_out < "$SBN/r"
assert_eq "tracker_list kind=none → exit 1" "1"  "$n_rc"
assert_eq "tracker_list kind=none → []"     "[]" "$n_out"
rm -rf "$SBN"

# Case 8 & 9 — per-project glab override (needs a YAML parser).
if [ "$HAVE_YAML" = yes ]; then
  SB2=$(make_sandbox "version: 1
projects:
  - name: gl
    repo: g/p
    tracker:
      kind: glab")
  # Mock glab: capture argv, print GitLab REST-shaped JSON array.
  cat > "$SB2/bin/glab" <<'EOF'
#!/bin/bash
[ -n "${GLAB_CAPTURE:-}" ] && printf '%s\n' "$@" > "$GLAB_CAPTURE"
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  cat <<'JSON'
[
  {"iid":45,"title":"GL bug","web_url":"https://gitlab.com/g/p/-/issues/45","labels":["blocked","ci"],"state":"opened","updated_at":"2026-07-02T08:00:00Z"},
  {"iid":9,"title":"GL old","web_url":"https://gitlab.com/g/p/-/issues/9","labels":[],"state":"opened","updated_at":"2026-05-01T08:00:00Z"}
]
JSON
fi
EOF
  chmod +x "$SB2/bin/glab"
  (
    cd "$SB2" || exit 1
    # shellcheck source=/dev/null
    . "$SB2/.claude/hooks/_lib-tracker.sh"
    tracker_clear_cache
    # Case 8: normalisation of GitLab shape.
    out=$(PATH="$SB2/bin:$PATH" GLAB_CAPTURE="$SB2/cap" tracker_list "g/p" labels=blocked,ci)
    len=$(printf '%s' "$out" | jq -r 'length' 2>/dev/null)
    ref=$(printf '%s' "$out" | jq -r '.[0].ref' 2>/dev/null)
    url=$(printf '%s' "$out" | jq -r '.[0].url' 2>/dev/null)
    state=$(printf '%s' "$out" | jq -r '.[0].state' 2>/dev/null)
    upd=$(printf '%s' "$out" | jq -r '.[0].updatedAt' 2>/dev/null)
    # Case 9a: labels csv → repeated --label flags.
    label_count=$(grep -cx -- '--label' "$SB2/cap")
    opened=$(grep -cx -- '--opened' "$SB2/cap")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$len" "$ref" "$url" "$state" "$upd" "$label_count" "$opened"
  ) > "$SB2/result"
  IFS=$'\t' read -r g_len g_ref g_url g_state g_upd g_labelc g_opened < "$SB2/result"
  assert_eq "tracker_list glab → normalised count"        "2"       "$g_len"
  assert_eq "tracker_list glab → ref from iid"            "45"      "$g_ref"
  assert_eq "tracker_list glab → url from web_url"        "https://gitlab.com/g/p/-/issues/45" "$g_url"
  assert_eq "tracker_list glab → state opened verbatim"   "opened"  "$g_state"
  assert_eq "tracker_list glab → updatedAt from updated_at" "2026-07-02T08:00:00Z" "$g_upd"
  assert_eq "tracker_list glab → labels csv → repeated --label" "2" "$g_labelc"
  assert_eq "tracker_list glab → default state --opened"  "1"       "$g_opened"

  # Case 9b: glab since → CLIENT-SIDE filter (drops the 2026-05 item).
  (
    cd "$SB2" || exit 1
    # shellcheck source=/dev/null
    . "$SB2/.claude/hooks/_lib-tracker.sh"
    tracker_clear_cache
    out=$(PATH="$SB2/bin:$PATH" tracker_list "g/p" since=2026-06-01)
    printf '%s\t%s\n' "$(printf '%s' "$out" | jq -r 'length')" "$(printf '%s' "$out" | jq -r '.[0].ref')"
  ) > "$SB2/result2"
  IFS=$'\t' read -r s_len s_ref < "$SB2/result2"
  assert_eq "tracker_list glab since → client-side filter keeps 1" "1"  "$s_len"
  assert_eq "tracker_list glab since → kept the recent item"       "45" "$s_ref"

  # Case 9c: an item MISSING updated_at must be KEPT by the client-side `since`
  # filter (recency unknowable → surface it, don't silently drop). Mock returns
  # one recent, one old, one with a null updated_at.
  cat > "$SB2/bin/glab" <<'EOF'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  cat <<'JSON'
[
  {"iid":45,"title":"recent","web_url":"https://gitlab.com/g/p/-/issues/45","labels":[],"state":"opened","updated_at":"2026-07-02T08:00:00Z"},
  {"iid":9,"title":"old","web_url":"https://gitlab.com/g/p/-/issues/9","labels":[],"state":"opened","updated_at":"2026-05-01T08:00:00Z"},
  {"iid":3,"title":"undated","web_url":"https://gitlab.com/g/p/-/issues/3","labels":[],"state":"opened","updated_at":null}
]
JSON
fi
EOF
  chmod +x "$SB2/bin/glab"
  (
    cd "$SB2" || exit 1
    # shellcheck source=/dev/null
    . "$SB2/.claude/hooks/_lib-tracker.sh"
    tracker_clear_cache
    out=$(PATH="$SB2/bin:$PATH" tracker_list "g/p" since=2026-06-01)
    # Expect the recent (45) AND the undated (3) kept; the old (9) dropped.
    len=$(printf '%s' "$out" | jq -r 'length')
    refs=$(printf '%s' "$out" | jq -r '[.[].ref] | sort | join(",")')
    printf '%s\t%s\n' "$len" "$refs"
  ) > "$SB2/result3"
  IFS=$'\t' read -r u_len u_refs < "$SB2/result3"
  assert_eq "tracker_list glab since → keeps recent + undated, drops old (count)" "2"    "$u_len"
  assert_eq "tracker_list glab since → undated item (3) NOT dropped"              "3,45" "$u_refs"
  rm -rf "$SB2"
else
  echo "SKIP: tracker_list glab per-project cases (no yq / python3+PyYAML)"
fi

# Case 10 — per-project custom list_command. Filters pass via ENV
# ($TRACKER_STATE / $TRACKER_LABELS / …), never string-substituted — so a
# filter value full of shell metacharacters cannot inject. (needs YAML parser.)
if [ "$HAVE_YAML" = yes ]; then
  SB3=$(make_sandbox "version: 1
projects:
  - name: cu
    repo: c/u
    tracker:
      kind: custom
      list_command: 'mycli list -R {owner_repo} --state \"\$TRACKER_STATE\" --search \"\$TRACKER_SEARCH\"'")
  cat > "$SB3/bin/mycli" <<'EOF'
#!/bin/bash
[ -n "${MYCLI_CAPTURE:-}" ] && printf '%s\n' "$@" > "$MYCLI_CAPTURE"
# Emit an already-normalised array (custom contract: identity normalise).
echo '[{"ref":"77","number":77,"state":"open","title":"custom","url":"https://example.com/c/u/issues/77","labels":[],"updatedAt":"2026-07-01T00:00:00Z"}]'
EOF
  chmod +x "$SB3/bin/mycli"
  (
    cd "$SB3" || exit 1
    # shellcheck source=/dev/null
    . "$SB3/.claude/hooks/_lib-tracker.sh"
    tracker_clear_cache
    EVIL='hi"; touch PWNED; echo "'
    out=$(PATH="$SB3/bin:$PATH" MYCLI_CAPTURE="$SB3/cap" tracker_list "c/u" state=open search="$EVIL")
    ref=$(printf '%s' "$out" | jq -r '.[0].ref' 2>/dev/null)
    search_seen=$(awk 'p{print;exit} $0=="--search"{p=1}' "$SB3/cap")
    pwned=no; [ -e "$SB3/PWNED" ] && pwned=yes
    printf '%s\t%s\t%s\n' "$ref" "$search_seen" "$pwned"
  ) > "$SB3/result"
  IFS=$'\t' read -r c_ref c_search c_pwned < "$SB3/result"
  assert_eq "tracker_list custom → ref parsed"                      "77" "$c_ref"
  assert_eq "tracker_list custom → search passed verbatim (env)"    'hi"; touch PWNED; echo "' "$c_search"
  assert_eq "tracker_list custom → NO shell injection (no PWNED)"   "no" "$c_pwned"
  rm -rf "$SB3"
else
  echo "SKIP: tracker_list custom per-project case (no yq / python3+PyYAML)"
fi

echo "=========================================="
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then printf "Failed:%b\n" "$FAILED"; exit 1; fi
exit 0
