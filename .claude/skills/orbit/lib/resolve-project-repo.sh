#!/usr/bin/env bash
# resolve-project-repo.sh — resolve one project's top-level `repo:` field
# from the portfolio registry, for /orbit handoff (apexyard#1446).
#
# Usage: resolve-project-repo.sh <registry-file> <project-name>
# Prints the repo on stdout as exactly one line, or nothing on stderr and
# exit 1 if the project or its repo: field is not found.
#
# Round-3 fix (Hakim N1 — reproduced against the real registry: a project
# that was not the last registry entry, e.g. "beta-widget", printed its
# repo TWICE):
#   - awk's `exit` still runs END (that is standard awk behavior — exit
#     jumps to END, it does not skip it). The old script re-checked
#     `name == target` in END without knowing a match had already printed,
#     so a middle-of-file match printed once from the pattern rule and
#     again from END. Fixed with an explicit `found` flag.
#   - the quote-stripping regex stripped only single quotes; a
#     double-quoted repo: value kept its quotes.
#   - a nested `repo:` key at any indentation under an entry could
#     overwrite that entry's own top-level `repo:` (last-write-wins).
#     Fixed by keeping only the FIRST `repo:` line seen after each
#     `- name:` line.
#
# Round-4 advisory (Rex, small): a value line now also has a trailing \r
# (CRLF registry file) and a trailing "  # comment" stripped, so either one
# does not become part of the resolved repo string.

set -u

registry="${1:-}"
target="${2:-}"

if [ -z "$registry" ] || [ -z "$target" ] || [ ! -f "$registry" ]; then
  echo "Usage: resolve-project-repo.sh <registry-file> <project-name>" >&2
  exit 1
fi

repo=$(awk -v target="$target" '
  function value(line) {
    sub(/^[^:]+:[[:space:]]*/, "", line)
    sub(/\r$/, "", line)
    if (line !~ /^["'"'"']/) { sub(/[[:space:]]+#.*$/, "", line) }
    gsub(/^["'"'"']|["'"'"']$/, "", line)
    return line
  }
  /^[[:space:]]*- name:/ {
    if (name == target) { print repo; found=1; exit }
    name=value($0); repo=""; next
  }
  /^[[:space:]]*repo:/ { if (repo == "") repo=value($0) }
  END { if (!found && name == target) print repo }
' "$registry")

[ -n "$repo" ] || exit 1
printf '%s\n' "$repo"
