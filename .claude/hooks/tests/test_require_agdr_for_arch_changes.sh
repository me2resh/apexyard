#!/bin/bash
# require-agdr-for-arch-changes.sh: the spike and prototype exemption reads the
# marker of the working tree that holds the commit (AgDR-0222). A spike ticket
# kept for another project, in any location, must not exempt this commit.
#
# Fixture: an ops fork that registers projects a and b. The commit stages a
# Dockerfile in project b, which is an architecture change with no AgDR.

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$SRC_ROOT/.claude/hooks/require-agdr-for-arch-changes.sh"

export APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

PASS=0
FAIL=0
ok() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
TMP=$(cd -P "$TMP" && pwd)
trap 'rm -rf "$TMP"' EXIT

# setup <mode>: builds the fixture, prints the path of project b
setup() {
  local mode="$1" ops b a
  ops=$(mktemp -d "$TMP/ops.XXXXXX")
  git init -q "$ops"
  git -C "$ops" config user.email t@example.com
  git -C "$ops" config user.name t
  : > "$ops/.apexyard-fork"
  : > "$ops/onboarding.yaml"
  printf 'projects:\n  - name: a\n    repo: test/a\n  - name: b\n    repo: test/b\n' > "$ops/apexyard.projects.yaml"
  git -C "$ops" add .apexyard-fork onboarding.yaml apexyard.projects.yaml
  git -C "$ops" commit -q -m init
  mkdir -p "$ops/workspace" "$ops/.claude/session/tickets"
  for n in a b; do
    git init -q "$ops/workspace/$n"
    git -C "$ops/workspace/$n" config user.email t@example.com
    git -C "$ops/workspace/$n" config user.name t
    git -C "$ops/workspace/$n" commit -q --allow-empty -m init
  done
  a="$ops/workspace/a"
  b="$ops/workspace/b"
  case "$mode" in
    none) ;;
    own) printf 'repo=test/b\nnumber=2\ntitle=[Spike] own ticket\n' > "$b/.git/apexyard-ticket" ;;
    a-new) printf 'repo=test/a\nnumber=1\ntitle=[Spike] other project\n' > "$a/.git/apexyard-ticket" ;;
    a-old-tickets) printf 'repo=test/a\nnumber=1\ntitle=[Spike] other project\n' > "$ops/.claude/session/tickets/a" ;;
    a-old-current) printf 'repo=test/a\nnumber=1\ntitle=[Spike] other project\n' > "$ops/.claude/session/current-ticket" ;;
    a-old-current-b) printf 'repo=test/a\nnumber=1\ntitle=[Spike] other project\n' > "$ops/.claude/session/current-ticket"
      printf 'repo=test/b\nnumber=2\ntitle=Plain b ticket\n' > "$ops/.claude/session/tickets/b" ;;
    b-old-tickets) printf 'repo=test/b\nnumber=2\ntitle=[Spike] own old ticket\n' > "$ops/.claude/session/tickets/b" ;;
  esac
  printf 'FROM scratch\n' > "$b/Dockerfile"
  git -C "$b" add Dockerfile
  echo "$b"
}

# run_case <name> <mode> <want rc>
run_case() {
  local name="$1" mode="$2" want="$3" dir rc err
  dir=$(setup "$mode")
  err=$(cd "$dir" && printf '%s' "$(jq -nc --arg c 'git commit -m "feat(#1): add a Dockerfile"' '{tool_input:{command:$c}}')" | bash "$HOOK" 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" = "$want" ]; then ok "$name"; else bad "$name" "want rc=$want got $rc (${err:0:200})"; fi
}

run_case "no marker: the architecture commit is blocked" none 2
run_case "the tree's own spike marker exempts the commit" own 0
run_case "spike_marker_in_project_a_does_not_exempt_project_b (new marker)" a-new 2
run_case "spike_marker_in_project_a_does_not_exempt_project_b (old tickets/a)" a-old-tickets 2
# The old current-ticket governs b when b has no marker of its own, as in the
# ticket gate, so its spike title exempts b. With a plain tickets/b file, the
# spike current-ticket does not govern b.
run_case "an old current-ticket that governs b exempts b" a-old-current 0
run_case "spike_marker_in_project_a_does_not_exempt_project_b (old current-ticket, plain tickets/b)" a-old-current-b 2
run_case "an old tickets/b spike file still exempts b's main clone" b-old-tickets 0

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
