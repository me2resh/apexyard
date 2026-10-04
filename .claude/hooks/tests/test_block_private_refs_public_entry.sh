#!/bin/bash
# apexyard#1455 — a registry entry marked `public: true` is not a leak.
#
# Kept in its own file, separate from test_block_private_refs.sh, because
# that file's fixture registry already carries real registered project
# names (a pre-existing, out-of-scope condition unrelated to this ticket)
# and this file must not go anywhere near that. Every name/repo/workspace
# below is synthetic.
#
# Exercises block-private-refs-in-public-repos.sh directly, mirroring the
# harness in test_block_private_refs.sh (JSON tool_input payload piped to
# the hook, run from a fixture fork directory so the registry-walk finds
# the fixture).

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOK="$REPO_ROOT/.claude/hooks/block-private-refs-in-public-repos.sh"

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook not found or not executable at $HOOK" >&2
  exit 1
fi

PASS=0
FAIL=0

TMPDIR=$(mktemp -d -t block-private-refs-public-entry.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/fork/subdir"
cat > "$TMPDIR/fork/onboarding.yaml" <<'YAML'
company: test
YAML
cat > "$TMPDIR/fork/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: open-marketing-site
    repo: acme-org/open-marketing-site
    public: true
    workspace: workspace/open-marketing-site
    status: active
  - name: secret-app
    repo: acme-org/secret-app
    workspace: workspace/secret-app
    status: active
YAML

make_payload() {
  local cmd="$1"
  jq -n --arg c "$cmd" '{tool_input: {command: $c}}'
}

run_case() {
  local name="$1" expected_exit="$2" expected_stderr_substr="$3" cmd="$4"
  local stderr_file actual_exit stderr_content ok
  stderr_file=$(mktemp)
  ( cd "$TMPDIR/fork/subdir" && make_payload "$cmd" | "$HOOK" ) 2> "$stderr_file"
  actual_exit=$?
  stderr_content=$(cat "$stderr_file")
  rm -f "$stderr_file"

  ok=1
  [ "$actual_exit" != "$expected_exit" ] && ok=0
  if [ -n "$expected_stderr_substr" ] && ! echo "$stderr_content" | grep -qF -- "$expected_stderr_substr"; then
    ok=0
  fi

  if [ "$ok" = 1 ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "   expected exit=$expected_exit, got $actual_exit"
    echo "   stderr was:"
    echo "$stderr_content" | sed 's/^/     /'
    FAIL=$((FAIL + 1))
  fi
}

run_case "public:true entry — name does not block" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'launch' --body 'announcing open-marketing-site'"

run_case "public:true entry — repo slug does not block" \
  0 "" \
  "gh pr create --repo me2resh/apexyard --title 'docs' --body 'see acme-org/open-marketing-site for source'"

run_case "public:true entry — workspace path does not block" \
  0 "" \
  "gh issue comment 3 --repo me2resh/apexyard --body 'lives in workspace/open-marketing-site/README.md'"

run_case "entry without public field still blocks (default private)" \
  2 "project name: secret-app" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'discovered during secret-app rebuild'"

run_case "public entry mention alongside a real leak still blocks on the leak" \
  2 "project name: secret-app" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'open-marketing-site is fine; secret-app is not'"

# ---------------------------------------------------------------------------
# apexyard#1457 review round 2 (Rex B2 / Hakim HIGH-1) — entry-boundary
# scoping. Swaps the fixture registry per case; each writes its own
# registry, so order after this point does not depend on the block above.
# ---------------------------------------------------------------------------

write_registry() {
  printf '%s' "$1" > "$TMPDIR/fork/apexyard.projects.yaml"
}

# Case A: private entry, then a public entry whose first key is repo:.
write_registry 'version: 1
projects:
  - name: secret-app
    repo: acme-org/secret-app
    workspace: workspace/secret-app
  - repo: acme-org/open-site
    name: open-site
    public: true
    workspace: workspace/open-site
'
run_case "case A: repo:-first public entry does not unblock the entry above it" \
  2 "project name: secret-app" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'discovered during secret-app rebuild'"

# Case A2: public entry, then a private entry whose first key is
# workspace:. apexyard#1457 round 7 — dev's (9ac9d9e) own "- name:"
# pattern requires the leading dash; its "repo:"/"workspace:" patterns
# do not allow one. So a bare, non-dash-prefixed field of this entry —
# its repo: line — is what dev's scan actually finds and what this now
# checks; the entry's own NAME line has no dash either here, and dev's
# scan never found that on its own. Not a regression: dev's own extent.
write_registry 'version: 1
projects:
  - name: open-site
    repo: acme-org/open-site
    public: true
    workspace: workspace/open-site
  - workspace: workspace/secret-app
    name: secret-app
    repo: acme-org/secret-app
'
run_case "case A2: workspace:-first private entry's repo: line still blocks" \
  2 "project repo: acme-org/secret-app" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'discovered during acme-org/secret-app rebuild'"

# Case C: private entry with a nested map holding public: true.
write_registry 'version: 1
projects:
  - name: secret-app
    repo: acme-org/secret-app
    deploy:
      public: true
      region: us
    workspace: workspace/secret-app
'
run_case "case C: public: true nested under a sub-map does not unscrub the entry" \
  2 "project name: secret-app" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'discovered during secret-app rebuild'"

# ---------------------------------------------------------------------------
# apexyard#1457 review round 3 (Rex B4 / Hakim HIGH-3, HIGH-4) — valid YAML
# shapes the parser dropped at 3a424f5. Each body names ONLY the private
# REPO SLUG, never the project name, so a surviving NAME token cannot mask
# a dropped REPO token. All names/slugs are SYNTHETIC.
# ---------------------------------------------------------------------------

# N3 — a top-level list before projects:, at a different indent.
write_registry 'maintainers:
- ops-team
- infra-team
projects:
  - name: aa-app
    repo: acme-org/aa-repo-one
    workspace: workspace/aa-app
'
run_case "N3: a top-level list before projects: does not drop the entry" \
  2 "project repo: acme-org/aa-repo-one" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme-org/aa-repo-one as well'"

# N3b — a top-level block scalar with a "- " line, at a column that does
# not match the real entries.
write_registry 'description: |
    Some prose about this registry.
    - not a real project entry
projects:
  - name: bb-app
    repo: acme-org/bb-repo-one
    workspace: workspace/bb-app
'
run_case "N3b: a top-level block scalar with a - line does not drop the entry" \
  2 "project repo: acme-org/bb-repo-one" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme-org/bb-repo-one as well'"

# N1b — a compact repos: sequence (item dashes at the SAME column as the
# repos: key).
write_registry 'projects:
  - name: cc-app
    repos:
    - acme-org/cc-repo-one
    - acme-org/cc-repo-two
'
run_case "N1b: a compact repos: list does not drop its items" \
  2 "project repo: acme-org/cc-repo-one" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme-org/cc-repo-one as well'"

# N2b — an indentless projects: list combined with a compact repos: list.
write_registry 'projects:
- name: dd-app
  repos:
  - acme-org/dd-repo-one
  - acme-org/dd-repo-two
'
run_case "N2b: an indentless projects: list with a compact repos: list does not drop its items" \
  2 "project repo: acme-org/dd-repo-one" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme-org/dd-repo-one as well'"

# N4 — a bare "-" entry, keys on the following lines.
write_registry 'projects:
  - name: ee-app
    repo: acme-org/ee-repo-one
  -
    name: ff-app
    repo: acme-org/ff-repo-one
    workspace: workspace/ff-app
'
run_case "N4: a bare - entry with keys on the next lines does not drop the entry" \
  2 "project repo: acme-org/ff-repo-one" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme-org/ff-repo-one as well'"

# Sanity gate (Hakim MEDIUM) — projects:/name: present, zero tokens
# parsed. apexyard#1457 round 4 — "name:" must sit at the START of a
# line to be caught by the greedy (private) pass, so a zero-token
# fixture has to put it mid-line, where the more lenient sanity-gate
# heuristic still matches it.
write_registry 'projects:
notes: the name: field is optional here
'
run_case "sanity gate: projects:/name: present, zero tokens parsed, still blocks" \
  2 "registry parse produced no tokens" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'nothing private mentioned here at all'"

# A genuinely empty registry must stay a no-op.
write_registry 'version: 1
'
run_case "sanity gate: a genuinely empty registry stays a no-op" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'nothing private mentioned here at all'"

# apexyard#1457 round 2 Rex suggestion — the non-zero parser-exit branch
# of B1: the library loads fine, but registry_parse_entries itself
# returns non-zero because the registry exists but cannot be read.
write_registry 'projects:
  - name: aa-app
    repo: acme-org/aa-repo-one
'
chmod 000 "$TMPDIR/fork/apexyard.projects.yaml"
run_case "public-tracker hook blocks when the registry exists but is unreadable (non-zero parser exit)" \
  2 "registry parse failed" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'irrelevant body'"
chmod 644 "$TMPDIR/fork/apexyard.projects.yaml"

# ---------------------------------------------------------------------------
# apexyard#1457 round 4 (Rex A/Hakim S5, Hakim S1, Hakim S4, Rex B/Hakim S9,
# Hakim S8) — the round-3 anchor still dropped a whole entry (name AND
# repo) when the real top-level projects: key was preceded by an
# ambiguous or unrecognized shape. Each "target" entry's repo slug shares
# NO substring with its own name. Verified by hand against 44c0fb6 before
# adding these: all five reproduced the drop. All names/slugs SYNTHETIC.
# ---------------------------------------------------------------------------

# S1 — two top-level projects: keys; the first holds a public entry.
write_registry 'projects:
  - name: aa-decoy
    repo: acme-org/site-one
    public: true
projects:
  - name: bb-target
    repo: acme-org/vault-one
'
run_case "S1: two top-level projects: keys do not drop the second entry" \
  2 "project repo: acme-org/vault-one" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme-org/vault-one as well'"

# S4 — a top-level block scalar whose TEXT holds "projects:" and a
# "- name:" line, before the real key.
write_registry 'notes: |
  projects:
  - name: cc-fake
projects:
  - name: dd-target
    repo: acme-org/vault-two
'
run_case "S4: a block scalar whose text holds projects: and - name: does not drop the real entry" \
  2 "project repo: acme-org/vault-two" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme-org/vault-two as well'"

# S5 / Rex A — a nested projects: list under another top-level map.
write_registry 'meta:
  projects:
    - name: ee-fake
projects:
  - name: ff-target
    repo: acme-org/vault-three
'
run_case "S5/Rex A: a nested projects: key under another map does not drop the real entry" \
  2 "project repo: acme-org/vault-three" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme-org/vault-three as well'"

# S8 — an anchored key, projects: &all.
write_registry 'projects: &all
  - name: gg-target
    repo: acme-org/vault-four
'
run_case "S8: projects: &all (an anchor) does not drop every entry" \
  2 "project repo: acme-org/vault-four" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme-org/vault-four as well'"

# S9 / Rex B — a quoted key, "projects":.
write_registry '"projects":
  - name: hh-target
    repo: acme-org/vault-five
'
run_case "S9/Rex B: a quoted projects: key does not drop every entry" \
  2 "project repo: acme-org/vault-five" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in acme-org/vault-five as well'"

# ---------------------------------------------------------------------------
# apexyard#1457 round 5 (Hakim HIGH-7) — the round-4 exemption rule
# compared per-value occurrence COUNTS, which the two passes'\'' differing
# repos: list boundaries could make equal even for a shared private slug.
# Fixed by comparing LINE NUMBERS instead. Verified by hand against
# 8196285 before adding these: X1 and X1b both marked the shared slug
# public there; X1c (control) already blocked. All slugs SYNTHETIC.
# ---------------------------------------------------------------------------

# X1 — a MAP item before the shared slug in a public entry's repos: list;
# the same slug also appears in a private entry via a plain repo: key.
write_registry 'projects:
  - name: aa-open
    public: true
    repos:
      - primary: org/open-x1
        mirror: true
      - org/shared-x1
  - name: bb-private
    repo: org/shared-x1
'
run_case "X1: a map item before the shared slug does not exempt it" \
  2 "project repo: org/shared-x1" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in org/shared-x1 as well'"

# X1b — a "- repo: ..." item before the shared slug.
write_registry 'projects:
  - name: cc-open
    public: true
    repos:
      - repo: org/open-x1b
      - org/shared-x1b
  - name: dd-private
    repo: org/shared-x1b
'
run_case "X1b: a - repo: item before the shared slug does not exempt it" \
  2 "project repo: org/shared-x1b" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in org/shared-x1b as well'"

# X1c (control) — a plain list, same shared slug, nothing before it.
write_registry 'projects:
  - name: ee-open
    public: true
    repos:
      - org/open-x1c
      - org/shared-x1c
  - name: ff-private
    repo: org/shared-x1c
'
run_case "X1c (control): a plain list with the same shared slug still blocks" \
  2 "project repo: org/shared-x1c" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in org/shared-x1c as well'"

# ---------------------------------------------------------------------------
# Round 6 (Rex B6) — a one-key "- repo: x" or "- workspace: x" LIST ITEM
# must not close an open repos: list; every plain item after it must
# stay in the private set. apexyard#1457 round 7 — re-verified here
# against dev's (9ac9d9e) own extraction: its per-line dash rule has no
# `next` and never resets `current_list`, so both shapes below already
# worked on dev without any change. A third B6 shape — a multi-key map
# item (`- primary: x` then a `mirror: true` continuation) — is NOT
# asserted here: dev's own generic "any key: line closes the list" rule
# closes it on that continuation line too, so the item after it was
# never scrubbed on dev either. Dev's own gap, kept unchanged and out of
# scope this round. Each body names only the private slug that came
# after the map-shaped item. All names/slugs SYNTHETIC.
# ---------------------------------------------------------------------------

write_registry 'projects:
  - name: pp-priv1
    repos:
      - repo: org/decoy-b6-repo
      - org/target-b6-after-repo
'
run_case "B6: a - repo: item does not close the repos: list early" \
  2 "project repo: org/target-b6-after-repo" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in org/target-b6-after-repo as well'"

write_registry 'projects:
  - name: qq-priv2
    repos:
      - workspace: w/decoy-b6-ws
      - org/target-b6-after-ws
'
run_case "B6: a - workspace: item does not close the repos: list early" \
  2 "project repo: org/target-b6-after-ws" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in org/target-b6-after-ws as well'"

# apexyard#1457 round 6 (Hakim D1, advisory) — a duplicate name:/repo:/
# workspace:/repos: key in one entry (a missing "- " typo) makes the
# entry private, the same as a duplicate public: key.
write_registry 'projects:
  - name: ss-pub1
    public: true
    repo: org/decoy-d1-primary
    name: tt-typo1
    repo: org/target-d1-shared
'
run_case "D1: a duplicate name:/repo: key (missing - typo) makes the entry private" \
  2 "project repo: org/target-d1-shared" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'reproduces in org/target-d1-shared as well'"

# ---------------------------------------------------------------------------
# apexyard#1457 round 7 (Hakim HIGH-8, Rex B7) — an entry whose first key
# is - repos: must not swallow every later entry. Fixed by deleting the
# round 4-6 rewritten greedy scan rather than patching it again: the
# private set is now dev's (9ac9d9e) own unmodified extraction, which
# never depended on this entry-boundary logic. Covers both the indented
# and indentless projects: styles. All names/slugs SYNTHETIC.
# ---------------------------------------------------------------------------

write_registry 'projects:
  - repos:
      - priv-g1
    workspace: workspace/wsg1
  - name: priv-g1-target
    repo: acme-org/priv-g1-target-repo
    workspace: workspace/priv-g1-target
'
run_case "G1/B7 (indented): an entry starting with - repos: does not swallow the next entry's name" \
  2 "project name: priv-g1-target" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'See priv-g1-target/api for details'"

write_registry 'projects:
  - repos:
      - priv-g1
    workspace: workspace/wsg1
  - name: priv-g1-target
    repo: acme-org/priv-g1-target-repo
    workspace: workspace/priv-g1-target
'
run_case "G1/B7 (indented): an entry starting with - repos: does not swallow the next entry's repo" \
  2 "project repo: acme-org/priv-g1-target-repo" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'The priv-g1-target-api service uses acme-org/priv-g1-target-repo'"

write_registry 'projects:
  - repos:
      - priv-g1
    workspace: workspace/wsg1
  - name: priv-g1-target
    repo: acme-org/priv-g1-target-repo
    workspace: workspace/priv-g1-target
'
run_case "G1/B7 (indented): an entry starting with - repos: does not swallow the next entry's workspace" \
  2 "workspace path: workspace/priv-g1-target" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'Edit workspace/priv-g1-target/README.md'"

write_registry 'projects:
- repos:
    - priv-g2
  workspace: workspace/wsg2
- name: priv-g2-target
  repo: acme-org/priv-g2-target-repo
  workspace: workspace/priv-g2-target
'
run_case "G2/B7 (indentless): an entry starting with - repos: does not swallow the next entry's name" \
  2 "project name: priv-g2-target" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'See priv-g2-target/api for details'"

write_registry 'projects:
- repos:
    - priv-g2
  workspace: workspace/wsg2
- name: priv-g2-target
  repo: acme-org/priv-g2-target-repo
  workspace: workspace/priv-g2-target
'
run_case "G2/B7 (indentless): an entry starting with - repos: does not swallow the next entry's repo" \
  2 "project repo: acme-org/priv-g2-target-repo" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'The priv-g2-target-api service uses acme-org/priv-g2-target-repo'"

write_registry 'projects:
- repos:
    - priv-g2
  workspace: workspace/wsg2
- name: priv-g2-target
  repo: acme-org/priv-g2-target-repo
  workspace: workspace/priv-g2-target
'
run_case "G2/B7 (indentless): an entry starting with - repos: does not swallow the next entry's workspace" \
  2 "workspace path: workspace/priv-g2-target" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'Edit workspace/priv-g2-target/README.md'"

# G3 — a map-item continuation (mirror: true) must not produce a bare
# "true" token, because dev's own extraction never captured one either
# (its generic "any key: line closes the list" rule fires on the
# continuation line itself). A commit that merely says "true" must not
# block.
write_registry 'projects:
  - name: priv-g3
    repos:
      - primary: acme-org/priv-g3-primary
        mirror: true
'
run_case "G3: a map-item continuation (mirror: true) does not make true a private token" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'Set the flag to true and merge to main when ready'"

# ---------------------------------------------------------------------------
# apexyard#1457 round 8 (Hakim HIGH-9) — dev's own hook looped over a
# space-joined string, so the shell split a multi-word token (a `repos:`
# map item like "primary: acme-org/x", or a one-key "- repo: acme-org/x"
# list item — both of which dev's extraction emits as ONE value with an
# embedded space) into separate words and checked each word on its own.
# Round 2's move to indexed arrays checks each value as one whole string
# instead, which normal issue-body text never contains verbatim, so it
# never matched. _lib-registry-parser.sh now restores dev's per-word
# behaviour once, in the shared path, so this hook gets it the same way
# the staged hook does. M1a is the map-item shape; M1b is the one-key
# `- repo:` shape. All names/slugs SYNTHETIC.
# ---------------------------------------------------------------------------

write_registry 'projects:
  - name: mm-priv-a
    repos:
      - primary: acme-org/mm-target-a
        mirror: true
'
run_case "M1a: a map-item repos: value blocks via its split word (Hakim HIGH-9)" \
  2 "project repo: acme-org/mm-target-a" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'Reproduces in acme-org/mm-target-a as well'"

write_registry 'projects:
  - name: mm-priv-b
    repos:
      - repo: acme-org/mm-target-b
'
run_case "M1b: a - repo: item inside repos: blocks via its split word (Hakim HIGH-9)" \
  2 "project repo: acme-org/mm-target-b" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'Reproduces in acme-org/mm-target-b as well'"

# ---------------------------------------------------------------------------
# apexyard#1457 round 9 (Rex B8, blocking) — round 8's word-split ran on
# dev's whole-line capture of a repos: block-list item, which includes a
# trailing YAML comment verbatim ("- acme-org/dd-one  # primary service"
# -> dev value "acme-org/dd-one  # primary service"). Splitting that on
# whitespace alone produced "#", "primary", and "service" as standalone
# private tokens, and "#" then blocked every Markdown heading. Fixed by
# stripping a trailing "[[:space:]]+#.*$" comment before the split. The
# real slug must still block. All names/slugs SYNTHETIC.
# ---------------------------------------------------------------------------

write_registry 'projects:
  - name: dd-priv-b8
    repos:
      - acme-org/dd-one  # primary service
'
run_case "B8: a Markdown heading (# ...) is not blocked by a commented repos: item" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body '# Release notes'"

run_case "B8: the comment's own words (primary service) are not blocked" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'This is the primary service for the team'"

run_case "B8: the real slug (acme-org/dd-one) still blocks" \
  2 "project repo: acme-org/dd-one" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'Reproduces in acme-org/dd-one as well'"

# ---------------------------------------------------------------------------
# apexyard#1458 items 1-3 — follow-up to #1457. Each is verified to fail
# against the PRE-fix library before the corresponding fix landed (see
# the differential-test probes and PR description). All names/slugs
# SYNTHETIC.
# ---------------------------------------------------------------------------

# Item 1 — a comment-only repos: block-list item ("- # note") is one dev
# token whose value IS the comment, with no whitespace before the "#" for
# the old split_words() strip to anchor on. It split into "#" and "note"
# as their own standalone tokens; "#" then blocked every Markdown
# heading.
write_registry 'projects:
  - name: ee-priv-it1
    repos:
      - acme-org/it1-target
      - # note
'
run_case "IT1: a Markdown heading (# ...) is not blocked by a comment-only repos: item" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body '# Release notes'"

run_case "IT1: the comment word (note) is not blocked" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'Please note the deadline'"

run_case "IT1: the real slug (acme-org/it1-target) still blocks" \
  2 "project repo: acme-org/it1-target" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'Reproduces in acme-org/it1-target as well'"

# Item 2 — DROPPED (round 11, Hakim HIGH-1). The GARBAGE classification
# round 10 added here (exempting a nested "- name:" line whenever it sat
# deeper than the entry's own dash column) could not tell a genuinely
# nested sub-item from a real project entry that legitimately sits
# deeper than the FIRST entry's column. GA1/GA2/GA5 below are the three
# valid YAML shapes Hakim found where that column test wrongly exempted
# a REAL private project name. dev over-blocks a nested "- name:" (item
# 2's original report); that stays an accepted usability gap, not a
# leak — see AgDR-0180. These three cases must still BLOCK.

# GA1 — grouped projects: a "- group:" entry (not "- name:") holding a
# nested "projects:" list with a real project entry inside it.
write_registry 'projects:
  - group: team-a
    projects:
      - name: priv-ga1
        repo: acme-org/priv-ga1-repo
        workspace: workspace/priv-ga1
'
run_case "GA1: a real project name nested under a - group: entry still blocks" \
  2 "project name: priv-ga1" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'See priv-ga1 today'"

# GA2 — projects: as a map of lists, with "archived:" indented MORE
# deeply than "active:". The uneven indentation makes the deeper entry
# look nested inside the shallower one to a column-only reader.
write_registry 'projects:
  active:
    - name: priv-ga2a
      repo: acme-org/priv-ga2a-repo
  archived:
      - name: priv-ga2b
        repo: acme-org/priv-ga2b-repo
'
run_case "GA2: a real project name in an unevenly-indented archived: list still blocks" \
  2 "project name: priv-ga2b" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'See priv-ga2b today'"

# GA5 — an entry that is itself a sequence: a bare "-" opens a nested
# list, and the real project entry is the nested "- name:" inside it.
write_registry 'projects:
  -
    - name: priv-ga5
      repo: acme-org/priv-ga5-repo
'
run_case "GA5: a real project name nested under a bare - sequence entry still blocks" \
  2 "project name: priv-ga5" \
  "gh issue create --repo me2resh/apexyard --title 'bug' --body 'See priv-ga5 today'"

# Item 3 — re-verified against the current (post-#1457 round 9) library:
# a public entry's own slug, written as a one-key "- repo:" map item
# inside its own repos: list, is correctly exempted already (the greedy
# private scan this was originally reported against, PR #1457 rounds
# 4-6, was deleted outright in round 7). Regression coverage only, no
# code change for this item.
write_registry 'projects:
  - name: gg-pub-it3
    public: true
    repos:
      - repo: acme-org/it3-pub-repo
'
run_case "IT3: a public entry own slug via a - repo: map item does not block" \
  0 "" \
  "gh issue create --repo me2resh/apexyard --title 'docs' --body 'see acme-org/it3-pub-repo for source'"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
