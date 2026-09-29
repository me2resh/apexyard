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
# Round 8 (Hakim HIGH-9, Rex) extends the comparison two ways: it applies
# each hook's EFFECTIVE word-splitting (dev's own hook body looped over a
# space-joined string, splitting a multi-word value into separate words —
# see `dev_word_split` below) before comparing, and it compares (TYPE,
# value) pairs rather than a bare value, so a token can never silently
# reappear under the wrong type without this test noticing.
#
# Round 9 (Rex B8) narrows `dev_word_split` to match `split_words()`'s own
# round-9 fix: a trailing YAML comment is stripped before splitting, and a
# resulting word that is only a YAML key shape is dropped, so this test's
# floor does not still demand a "#" or "repo:"-shaped token that round 9
# deliberately removed as a false-positive source.
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

# apexyard#1457 round 8 (Hakim HIGH-9) — dev's own hooks did not check
# an extracted value as one whole string; they looped over a
# space-joined string, so the shell's own unquoted-variable expansion
# split a multi-word value (e.g. a `repos:` map item like
# "primary: acme-org/x") into separate words and checked each word on
# its own. "What dev really scanned" for a given registry is therefore
# not the raw TYPE=value lines dev's awk prints — it is those lines PLUS
# one extra TYPE=word line per word of any value that has more than one.
#
# apexyard#1457 round 9 (Rex B8) — narrows that floor to match
# split_words()'s own round-9 fix: a trailing YAML comment
# (`[[:space:]]+#.*$`) is stripped before splitting (its words, and the
# "#" itself, are never real content), and a resulting word that is only
# a YAML key shape (`^[A-Za-z_][A-Za-z0-9_-]*:$`, e.g. "repo:", "primary:")
# is dropped — round 8's split introduced both as accidental new tokens
# that round 9 intentionally removes, so the floor this test enforces
# must not still demand them.
# Reads "TYPE=value" lines on stdin; for a value with embedded
# whitespace, `for w in $stripped` deliberately reuses the same
# unquoted expansion dev's shell loop relied on, so this models dev's
# hook behaviour (as narrowed by round 9) rather than re-deriving it
# with new logic.
dev_word_split() {
  local line type value stripped w
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    type="${line%%=*}"
    value="${line#*=}"
    echo "$type=$value"
    stripped=$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')
    # Unconditional, like split_words()'s own split() call — a stripped
    # value with no remaining whitespace still needs this pass: stripping
    # a trailing comment can turn a multi-word value into a single real
    # word (e.g. "acme-org/x  # note" -> "acme-org/x"), and that word is
    # new relative to $value (which still carries the comment) and must
    # still be emitted.
    for w in $stripped; do
      [ -z "$w" ] && continue
      if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_-]*:$ ]]; then
        continue
      fi
      echo "$type=$w"
    done
  done
}

# assert_superset LABEL REGISTRY_FILE STYLE
# Runs both dev's original extraction (word-split as dev's own hook body
# would have) and the new registry_parse_entries against REGISTRY_FILE,
# and asserts every distinct (TYPE, value) pair dev finds is present
# somewhere in the new parser's output (either PUBLIC=0 or PUBLIC=1 —
# reclassification is fine, disappearance is not). Compared by TYPE and
# value together, per Rex's round-8 review — a bare value match alone
# would let a token silently reappear under the WRONG type (a REPO
# becoming a NAME, say) without this test noticing.
assert_superset() {
  local label="$1" registry="$2" style="$3"
  local dev_values new_values missing

  if [ "$style" = "runtime" ]; then
    dev_values=$(dev_extract_runtime "$registry" | dev_word_split | sort -u)
  else
    dev_values=$(dev_extract_standard "$registry" | dev_word_split | sort -u)
  fi

  new_values=$(registry_parse_entries "$registry" "$style" 2>/dev/null \
    | grep -E '^(NAME|REPO|WORKSPACE)=' | sort -u)

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
    fail "$label" "dev found a (type, value) pair the new parser dropped: ${missing#|}"
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

# apexyard#1457 round 8 (Hakim HIGH-9) — a one-key "- repo:" item inside
# a block repos: list is the shape dev's extraction emits as ONE value
# with an embedded space ("repo: acme-org/mm-target-b"). dev_word_split
# above models dev's shell loop splitting it into "repo:" and the real
# slug; this fixture exercises that through the full differential check.
run_fixture "M1b-dash-repo-item-in-repos-list" 'projects:
  - name: mm-priv-m1b
    repos:
      - repo: acme-org/mm-target-m1b
'

# apexyard#1457 round 9 (Rex B8) — a bare repos: list item with a
# trailing YAML comment. dev's whole-line capture keeps the comment
# verbatim ("acme-org/b8-target  # primary service"); dev_word_split
# above now strips the comment before splitting, matching split_words()'s
# own round-9 fix, so this fixture must still find the real slug as its
# own word without also demanding "#"/"primary"/"service".
run_fixture "B8-trailing-comment-on-repos-item" 'projects:
  - name: b8-priv
    repos:
      - acme-org/b8-target  # primary service
'

# apexyard#1457 round 8 (Hakim LOW-1) — a CRLF registry. Unlike the other
# fixtures, dev's own extraction here still carries a trailing "\r" on
# every value (dev never stripped it) while the new parser runs against
# a CR-stripped copy, so dev's raw "\r"-suffixed value is, by design, NOT
# expected to reappear verbatim in the new parser's output — only its
# stripped form is. assert_superset is not used here for that reason;
# this only checks the new parser finds the CR-stripped slug, which is
# the whole point of the round-8 hardening.
crlf_file="$WORKDIR/CRLF-private-entry.yaml"
printf 'projects:\r\n  - name: ww-crlf\r\n    repo: acme-org/ww-crlf-repo\r\n' > "$crlf_file"
crlf_new_values=$(registry_parse_entries "$crlf_file" standard 2>/dev/null \
  | grep -E '^(NAME|REPO|WORKSPACE)=' | sort -u)
if printf '%s\n' "$crlf_new_values" | grep -qxF -- "REPO=acme-org/ww-crlf-repo"; then
  pass "CRLF-private-entry: the new parser finds the CR-stripped slug"
else
  fail "CRLF-private-entry: the new parser finds the CR-stripped slug" "$crlf_new_values"
fi

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
echo "== Differential: the B8 comment does not yield a bare # or key-shaped VALUE"
# apexyard#1457 round 9 (Rex B8) — the new parser's own overall output
# must not contain a bare "#" token, nor a bare "repo:"/"primary:"-shaped
# YAML-key token, for any fixture. This is the specific regression class
# B8 caught: split_words() producing a token that blocks every Markdown
# heading. Checked across the two fixtures most likely to regress it.
b8_bad_found=""
for b8_fixture in "B8-trailing-comment-on-repos-item" "M1b-dash-repo-item-in-repos-list" "X1-map-item-before-shared-slug"; do
  b8_file="$WORKDIR/${b8_fixture}.yaml"
  b8_values=$(registry_parse_entries "$b8_file" standard 2>/dev/null \
    | grep -E '^(NAME|REPO|WORKSPACE)=' | sed -E 's/^(NAME|REPO|WORKSPACE)=//' | sort -u)
  if printf '%s\n' "$b8_values" | grep -qxE -- '#|[A-Za-z_][A-Za-z0-9_-]*:'; then
    b8_bad_found="$b8_bad_found $b8_fixture"
  fi
done
if [ -n "$b8_bad_found" ]; then
  fail "B8: the new parser does not invent a bare # or key-shaped value" "found in:$b8_bad_found"
else
  pass "B8: the new parser does not invent a bare # or key-shaped value"
fi

echo
echo "===== test_registry_parser_differential.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
