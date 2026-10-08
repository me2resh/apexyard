#!/bin/bash
# AgDR-0222 must state the decision, the options and the limits that the
# resolver design depends on. The older AgDRs that it supersedes or amends
# must carry a note that says so, and the CHANGELOG must tell adopters what to
# do.

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
AGDR="$SRC_ROOT/docs/agdr/AgDR-0222-ticket-marker-in-worktree-git-dir.md"

PASS=0
FAIL=0
ok() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

has() {
  local name="$1" rx="$2"
  if grep -Eqi -- "$rx" "$AGDR"; then ok "$name"; else bad "$name" "AgDR-0222 lacks /$rx/"; fi
}

if [ ! -f "$AGDR" ]; then
  bad "AgDR-0222 exists" "$AGDR is missing"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi
ok "AgDR-0222 exists"

has "frontmatter id" '^id: AgDR-0222$'
has "status executed" '^status: executed$'
has "marker is a process gate, not an authorization boundary" 'process gate'
has "not an authorization boundary" 'not an authorization boundary'
has "options: file reads chosen" 'read git.s own files'
has "options: scrubbed rev-parse rejected" 'scrubbed .git rev-parse'
has "options: allowed-set cache rejected" 'allowed-set cache'
has "legacy markers: main clone only was the first choice" 'main clone only'
has "D1 reversed for full backward compatibility" 'reversed D1'
has "backward compatibility section" '^## Backward compatibility$'
has "dual read" '^### Dual read$'
has "dual write" '^### Dual write$'
has "every place the new hooks differ is listed" 'Places where the new hooks differ'
has "ownership check replaces safe.directory" 'safe\.directory'
has "legacy removal needs an explicit breaking release" 'explicit breaking release'
has "stale old file limit stated" 'stale old file that passes a different ticket'
has "environment-controlling attacker is out of scope" 'controls the hook process environment'
has "sandbox allowlist never names .git/**" 'never `\.git/\*\*`'
has "partly supersedes AgDR-0066 and AgDR-0141" 'partly supersedes AgDR-0066 and AgDR-0141'
has "amends AgDR-0168 and AgDR-0017" 'amends AgDR-0168 and AgDR-0017'
has "workspace roots and every .git must be real" 'must be real directories'
has "ambiguous common dir is refused" 'ambiguous'

# The older AgDRs say where AgDR-0222 changes them.
note() {
  local name="$1" file="$2" rx="$3"
  if [ ! -f "$SRC_ROOT/docs/agdr/$file" ]; then bad "$name" "$file is missing"; return; fi
  if grep -Eq -- "$rx" "$SRC_ROOT/docs/agdr/$file"; then ok "$name"; else bad "$name" "$file has no note matching /$rx/"; fi
}
note "AgDR-0066 is partly superseded by AgDR-0222" AgDR-0066-per-worktree-ticket-marker-tier.md '^> \*\*Partly superseded by AgDR-0222\.'
note "AgDR-0141 is partly superseded by AgDR-0222" AgDR-0141-normalize-linked-worktree-ops-root.md '^> \*\*Partly superseded by AgDR-0222\.'
note "AgDR-0168 is amended by AgDR-0222" AgDR-0168-unextractable-target-honors-session-ticket-only.md '^> \*\*Amended by AgDR-0222\.'
note "AgDR-0017 is amended by AgDR-0222" AgDR-0017-spike-skill-schema-and-exemptions.md '^> \*\*Amended by AgDR-0222\.'

# The CHANGELOG tells adopters to re-read /start-ticket.
if grep -q 're-read\|read `/start-ticket` again' "$SRC_ROOT/CHANGELOG.md" && grep -q 'AgDR-0222' "$SRC_ROOT/CHANGELOG.md"; then ok "CHANGELOG names AgDR-0222 and the /start-ticket re-read"; else bad "CHANGELOG" "no AgDR-0222 entry with the /start-ticket instruction"; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
