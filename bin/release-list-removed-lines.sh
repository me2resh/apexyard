#!/usr/bin/env bash
# bin/release-list-removed-lines.sh — List every line a release removes from main.
#
# Used by the /release skill (#1490 / AgDR-0197) before the release PR opens.
# A release cut from `dev` can delete content that still exists on `main`
# (the v5.6.3 sync dropped contributor rows from README on `dev`; v5.7.0
# then removed them from `main`). This helper surfaces those deletions so
# the operator can stop before the PR lands.
#
# Environment variables (all required):
#   MAIN_REF  — the main-side tip (e.g. upstream/main)
#   HEAD_REF  — the release-side tip (e.g. release/v5.8.0 or upstream/dev)
#
# Output:
#   One line per deleted content line, prefixed with "- " (the raw diff
#   minus-line with the leading "-" kept so the operator sees exact text).
#   Empty stdout means the release removes nothing from MAIN_REF.
#
# Uses `git diff MAIN_REF..HEAD_REF` (two-dot): the set of changes to turn
# MAIN_REF into HEAD_REF. Lines that start with "-" are content removed from
# MAIN_REF, except the per-file `--- a/...` (or `--- /dev/null`) old-file
# header that follows each `diff --git` block. Content lines that happen to
# start with `--` or `---` (YAML front matter, markdown rules, titles) MUST
# still appear — a blanket `^---` filter wrongly hid those (#1490 review).
#
# Exit codes:
#   0 — success (including the empty-removal case)
#   1 — missing required env var or git diff failure
#
# Success path writes only to stdout. Errors go to stderr.

set -euo pipefail

for var in MAIN_REF HEAD_REF; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is required but not set." >&2
    echo "Usage: MAIN_REF=upstream/main HEAD_REF=release/v1.2.0 bash bin/release-list-removed-lines.sh" >&2
    exit 1
  fi
done

# --unified=0 keeps the listing tight (no context lines). Emit deleted
# content lines only. Skip the old-file header that belongs to each
# `diff --git` block (the first `--- ` line after that marker), not every
# line that merely starts with `---`.
# `|| true` keeps set -e from aborting when awk/grep find zero removals —
# empty output is a valid, successful answer.
git diff --unified=0 "${MAIN_REF}..${HEAD_REF}" \
  | awk '
      /^diff --git / { want_old_header = 1; next }
      want_old_header && /^--- / { want_old_header = 0; next }
      want_old_header { want_old_header = 0 }
      /^-/ { print }
    ' \
  || true
