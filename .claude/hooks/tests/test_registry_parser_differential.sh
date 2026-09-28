#!/bin/bash
# apexyard#1457 review round 7 (coordinator item 3) — a differential/
# regression test for _lib-registry-parser.sh.
#
# Rounds 4-6 rewrote the private-token scan as a new, hand-written
# "greedy" awk pass meant to be a strict superset of the three leak
# hooks' pre-#1455 (dev, commit 9ac9d9e) extraction. Every one of those
# rounds' findings (Rex B6, Hakim HIGH-7, Hakim HIGH-8) was a fresh edge
# case where that rewrite silently produced FEWER tokens than dev's own
# code did on the same registry. Round 7 stopped rewriting the private
# side and made `registry_parse_entries` run dev's own extraction
# byte-for-byte instead (see _lib-registry-parser.sh's header).
#
# This file is the mechanical guarantee that promise holds: it re-derives
# dev's ORIGINAL two awk programs (one shared by check-private-refs-
# staged.sh and block-private-refs-in-public-repos.sh, one private to
# check-private-refs-runtime.sh — verified byte-identical to
# `git show 9ac9d9e:<path>` when this file was written) and, for every
# registry fixture used anywhere in this test suite, asserts that every
# token VALUE dev's extraction finds also appears somewhere in
# registry_parse_entries's output for the matching style — never silently
# dropped, only ever reclassified from PUBLIC=0 to PUBLIC=1 when the
# structural pass proves the entry public. A missing value here means the
# rewrite regressed dev's own coverage; that is what every round 4-6
# finding looked like, and what this file exists to catch mechanically
# instead of by review.
#
# All fixture names/slugs are SYNTHETIC.

set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
LIB="$ROOT/.claude/hooks/_lib-registry-parser.sh"

if [ ! -r "$LIB" ]; then
  echo "FAIL: library not found at $LIB" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$LIB"

PASS=0
FAIL=0
pass() { echo "  ok   $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; FAIL=$((FAIL + 1)); }

WORKDIR=$(mktemp -d -t registry-differential.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Dev's (9ac9d9e) original extraction programs, reproduced verbatim apart
# from dropping the "\t"NR line-number suffix _lib-registry-parser.sh adds
# — the differential check compares VALUES, not line numbers. Verified
# against `git show 9ac9d9e:.claude/hooks/check-private-refs-staged.sh`
# and `git show 9ac9d9e:.claude/hooks/check-private-refs-runtime.sh` when
# this file was written.
# ---------------------------------------------------------------------------
dev_extract_standard() {
  awk '
    function unquote(value) { gsub(/^["\x27]|["\x27]$/, "", value); return value }
    /^[[:space:]]*- name:/ {
      pending_name = unquote($3)
      print "NAME=" pending_name; current_list = ""; next
    }
    /^[[:space:]]*repo:/ {
      repo_val = unquote($2)
      print "REPO=" repo_val
      pending_name = ""; current_list = ""; next
    }
    /^[[:space:]]*workspace:/ {
      print "WORKSPACE=" unquote($2); current_list = ""; next
    }
    /^[[:space:]]*repos:[[:space:]]*\[/ {
      value = $0; sub(/^[^\[]*\[/, "", value); sub(/\].*$/, "", value)
      count = split(value, items, ",")
      for (i = 1; i <= count; i++) {
        item = items[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
        if (item != "") print "REPO=" unquote(item)
      }
      pending_name = ""; current_list = ""; next
    }
    /^[[:space:]]*repos:[[:space:]]*(#.*)?$/ { pending_name = ""; current_list = "repos"; next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:/ { current_list = ""; next }
    /^[[:space:]]*-[[:space:]]+/ {
      if (current_list == "repos") {
        value = $0; sub(/^[[:space:]]*-[[:space:]]+/, "", value)
        gsub(/[[:space:]]+$/, "", value); print "REPO=" unquote(value)
      }
    }
  ' "$1"
}

dev_extract_runtime() {
  awk '
    function unquote(value) { gsub(/^["\x27]|["\x27]$/, "", value); return value }
    function emit_repos(value,    n, parts, i, item) {
      gsub(/^[[:space:]]*\[[[:space:]]*/, "", value)
      gsub(/[[:space:]]*\][[:space:]]*$/, "", value)
      n = split(value, parts, ",")
      for (i = 1; i <= n; i++) {
        item = unquote(parts[i])
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
        if (item != "") print "REPO=" item
      }
    }
    in_repos = 0
    /^[[:space:]]*- name:/ { print "NAME=" unquote($3); next }
    /^[[:space:]]*repo:/ { print "REPO=" unquote($2); next }
    /^[[:space:]]*repos:[[:space:]]*\[/ {
      value = $0
      sub(/^[^:]*:[[:space:]]*/, "", value)
      emit_repos(value)
      in_repos = 0
      next
    }
    /^[[:space:]]*repos:[[:space:]]*$/ { in_repos = 1; next }
    in_repos && /^[[:space:]]*-[[:space:]]+/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      if (value !~ /^[[:alnum:]_.-]+:/) print "REPO=" unquote(value)
      next
    }
    /^[^[:space:]-]/ { in_repos = 0 }
    /^[[:space:]]*workspace:/ { print "WORKSPACE=" unquote($2); next }
  ' "$1"
}

# assert_superset LABEL REGISTRY_FILE STYLE
# Runs both dev's original extraction and the new registry_parse_entries
# against REGISTRY_FILE, and asserts every distinct token value dev finds
# is present somewhere in the new parser's output (either PUBLIC=0 or
# PUBLIC=1 — reclassification is fine, disappearance is not).
assert_superset() {
  local label="$1" registry="$2" style="$3"
  local dev_values new_values missing

  if [ "$style" = "runtime" ]; then
    dev_values=$(dev_extract_runtime "$registry" | sed -E 's/^(NAME|REPO|WORKSPACE)=//' | sort -u)
  else
    dev_values=$(dev_extract_standard "$registry" | sed -E 's/^(NAME|REPO|WORKSPACE)=//' | sort -u)
  fi

  new_values=$(registry_parse_entries "$registry" "$style" 2>/dev/null \
    | grep -E '^(NAME|REPO|WORKSPACE)=' \
    | sed -E 's/^(NAME|REPO|WORKSPACE)=//' | sort -u)

  missing=""
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    if ! printf '%s\n' "$new_values" | grep -qxF -- "$v"; then
      missing="$missing|$v"
    fi
  done <<EOF
$dev_values
EOF

  if [ -n "$missing" ]; then
    fail "$label" "dev found a value the new parser dropped: ${missing#|}"
  else
    pass "$label"
  fi
}

run_fixture() {
  local name="$1" content="$2"
  local f="$WORKDIR/$name.yaml"
  printf '%s' "$content" > "$f"
  assert_superset "$name (standard style)" "$f" standard
  assert_superset "$name (runtime style)" "$f" runtime
}

echo "== Differential: every fixture shape used across the suite, dev vs new parser"

run_fixture "normal" 'projects:
  - name: aa-app
    repo: acme-org/aa-repo-one
    workspace: workspace/aa-app
  - name: bb-app
    repo: acme-org/bb-repo-one
    workspace: workspace/bb-app
    public: true
'

run_fixture "X1-map-item-before-shared-slug" 'projects:
  - name: aa-open
    public: true
    repos:
      - primary: org/open-x1
        mirror: true
      - org/shared-x1
  - name: bb-private
    repo: org/shared-x1
'

run_fixture "X1b-dash-repo-item-before-shared-slug" 'projects:
  - name: cc-open
    public: true
    repos:
      - repo: org/open-x1b
      - org/shared-x1b
  - name: dd-private
    repo: org/shared-x1b
'

run_fixture "S1-two-top-level-projects-keys" 'projects:
  - name: aa-decoy
    repo: acme-org/site-one
    public: true
projects:
  - name: bb-target
    repo: acme-org/vault-one
'

run_fixture "S4-block-scalar-holding-projects-and-dash-name" 'notes: |
  projects:
  - name: cc-fake
projects:
  - name: dd-target
    repo: acme-org/vault-two
'

run_fixture "S5-nested-projects-key" 'meta:
  projects:
    - name: ee-fake
projects:
  - name: ff-target
    repo: acme-org/vault-three
'

run_fixture "S8-projects-anchor" 'projects: &all
  - name: gg-target
    repo: acme-org/vault-four
'

run_fixture "S9-quoted-projects-key" '"projects":
  - name: hh-target
    repo: acme-org/vault-five
'

run_fixture "N3-top-level-list-before-projects" 'maintainers:
- ops-team
- infra-team
projects:
  - name: aa-app
    repo: acme-org/aa-repo-one
    workspace: workspace/aa-app
'

run_fixture "N3b-top-level-block-scalar-with-dash-line" 'description: |
    Some prose about this registry.
    - not a real project entry
projects:
  - name: bb-app
    repo: acme-org/bb-repo-one
    workspace: workspace/bb-app
'

run_fixture "N1b-compact-repos-list" 'projects:
  - name: cc-app
    repos:
    - acme-org/cc-repo-one
    - acme-org/cc-repo-two
'

run_fixture "N2b-indentless-projects-with-compact-repos" 'projects:
- name: dd-app
  repos:
  - acme-org/dd-repo-one
  - acme-org/dd-repo-two
'

run_fixture "N4-bare-dash-entry-keys-on-next-lines" 'projects:
  - name: ee-app
    repo: acme-org/ee-repo-one
  -
    name: ff-app
    repo: acme-org/ff-repo-one
    workspace: workspace/ff-app
'

run_fixture "B6-dash-repo-item-does-not-close-list" 'projects:
  - name: pp-priv1
    repos:
      - repo: org/decoy-b6-repo
      - org/target-b6-after-repo
'

run_fixture "B6-dash-workspace-item-does-not-close-list" 'projects:
  - name: qq-priv2
    repos:
      - workspace: w/decoy-b6-ws
      - org/target-b6-after-ws
'

run_fixture "D1-duplicate-name-repo-key" 'projects:
  - name: ss-pub1
    public: true
    repo: org/decoy-d1-primary
    name: tt-typo1
    repo: org/target-d1-shared
'

run_fixture "G1-B7-indented-repos-first-entry" 'projects:
  - repos:
      - priv-g1
    workspace: workspace/wsg1
  - name: priv-g1-target
    repo: acme-org/priv-g1-target-repo
    workspace: workspace/priv-g1-target
'

run_fixture "G2-B7-indentless-repos-first-entry" 'projects:
- repos:
    - priv-g2
  workspace: workspace/wsg2
- name: priv-g2-target
  repo: acme-org/priv-g2-target-repo
  workspace: workspace/priv-g2-target
'

run_fixture "G3-map-item-continuation-mirror-true" 'projects:
  - name: priv-g3
    repos:
      - primary: acme-org/priv-g3-primary
        mirror: true
'

run_fixture "T1-tab-in-indentation" 'projects:
	- name: uu-tab
	  repo: acme-org/uu-tab-repo
'

run_fixture "PT2-second-public-key" 'projects:
  - name: vv-pub2
    public: true
    public: true
    repo: acme-org/vv-pub2-repo
'

echo
echo "== Differential: the G3 map-item continuation never yields a bare true VALUE"
# Belt-and-suspenders on top of assert_superset above (which only checks
# dev's set is covered): the new parser's own overall output must not
# contain a bare "true" REPO/NAME/WORKSPACE value either, since dev never
# produced one for this shape and nothing downstream should invent one.
g3_file="$WORKDIR/G3-map-item-continuation-mirror-true.yaml"
g3_new_values=$(registry_parse_entries "$g3_file" standard 2>/dev/null \
  | grep -E '^(NAME|REPO|WORKSPACE)=' | sed -E 's/^(NAME|REPO|WORKSPACE)=//' | sort -u)
if printf '%s\n' "$g3_new_values" | grep -qxF -- "true"; then
  fail "G3: the new parser does not invent a bare true value dev never produced"
else
  pass "G3: the new parser does not invent a bare true value dev never produced"
fi

echo
echo "===== test_registry_parser_differential.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
