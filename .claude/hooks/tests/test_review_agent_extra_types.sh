#!/bin/bash
# Config review types: me2resh/apexyard#1653, AgDR-0145.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
SRC_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOKS="$SRC_ROOT/.claude/hooks"
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-review-extra.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/.claude/hooks" "$SANDBOX/.claude/session"
touch "$SANDBOX/.apexyard-fork"
git -C "$SANDBOX" init -q
cp "$SRC_ROOT/.claude/project-config.defaults.json" "$SANDBOX/.claude/"
for f in block-reviewer-repo-mutation.sh _lib-strip-heredoc.sh _lib-path-resolve.sh \
         _lib-review-markers.sh _lib-read-config.sh _lib-ops-root.sh _lib-resolution-cache.sh; do
  [ ! -f "$HOOKS/$f" ] || cp "$HOOKS/$f" "$SANDBOX/.claude/hooks/"
done
PASS=0 FAIL=0
check() {
  if [ "$2" = ok ]; then echo "PASS: $1"; PASS=$((PASS + 1)); else echo "FAIL: $1 (${3:-})" >&2; FAIL=$((FAIL + 1)); fi
}
expect_eq() {
  if [ "$2" = "$3" ]; then check "$1" ok; else check "$1" no "got '$2' want '$3'"; fi
}
config() { printf '%s' "$1" > "$SANDBOX/.claude/project-config.json"; }
class() {
  local out rc
  out=$(bash -uc 'cd "$1" || exit; . "$2/_lib-review-markers.sh"; review_caller_class "$(jq -cn --arg t "$3" '\''{agent_type:$t,agent_id:"a1"}'\'')" "$1"' bash "$SANDBOX" "$HOOKS" "$2" 2> "$SANDBOX/stderr")
  rc=$?
  expect_eq "$1: $2" "$out" "$3"
  expect_eq "$1: $2 exits zero" "$rc" 0
  expect_eq "$1: $2 has no stderr" "$(cat "$SANDBOX/stderr")" ''
}
builtins() {
  local t
  for t in code-reviewer security-reviewer solution-architect; do class "$1" "$t" reviewer; done
}
builtins default
class default acme-reviewer other-agent
class default backend-engineer other-agent
config '{"review_markers":{"extra_review_agents":["acme-reviewer","plugin:code-reviewer"]}}'
builtins added
class added acme-reviewer reviewer
class added plugin:code-reviewer reviewer
for t in backend-engineer acme-reviewer-2 acme; do class 'exact match' "$t" other-agent; done
for cfg in \
  '{"review_markers":{"extra_review_agents":[]}}' \
  '{"review_markers":{"extra_review_agents":["acme-reviewer"]}}' \
  '{"review_markers":{"extra_review_agents":["!code-reviewer","-code-reviewer","code-reviewer-off"]}}' \
  '{"review_markers":{"remove_review_agents":["code-reviewer"],"review_agents":["x"]}}'; do
  config "$cfg"
  builtins "cannot remove: $cfg"
done
for cfg in 'invalid JSON' '' '{}' \
  '{"review_markers":{"extra_review_agents":"acme-reviewer"}}' \
  '{"review_markers":{"extra_review_agents":null}}' \
  '{"review_markers":{"extra_review_agents":{"a":"b"}}}' \
  '{"review_markers":{"extra_review_agents":[1,true,null,["acme-reviewer"],{"x":1}]}}'; do
  config "$cfg"
  builtins "malformed or empty: $cfg"
  class "malformed or empty: $cfg" acme-reviewer other-agent
  out=$(bash -uc 'cd "$1" || exit; . "$2/_lib-review-markers.sh"; review_agent_extra_slugs' bash "$SANDBOX" "$HOOKS" 2> "$SANDBOX/stderr")
  expect_eq 'malformed extras return zero' "$?" 0
  expect_eq 'malformed extras print nothing' "$out" ''
  expect_eq 'malformed extras have no stderr' "$(cat "$SANDBOX/stderr")" ''
done
config '{"review_markers":{"extra_review_agents":["*","?","a*","[a-z]*",".*","acme reviewer","","acme\nreviewer","acme-reviewer"]}}'
for t in backend-engineer general-purpose anything acme reviewer; do class 'invalid patterns skipped' "$t" other-agent; done
class 'valid sibling' acme-reviewer reviewer
# A sentinel proves the fast paths never call config_get.
out=$(bash -uc '. "$1/_lib-review-markers.sh"; config_get() { echo READ >&2; return 1; }; review_agent_slug_match code-reviewer; echo "builtin=$?"; review_agent_slug_match ""; echo "empty=$?"; review_caller_class "{}"' bash "$HOOKS" 2> "$SANDBOX/stderr")
expect_eq 'direct built-in and empty fast paths' "$out" $'builtin=0\nempty=1\nmain'
expect_eq 'fast paths do not read config' "$(cat "$SANDBOX/stderr")" ''
printf '%s\n' 'acme/app#1:rex' > "$SANDBOX/.claude/session/active-reviewer"
run_hook() {
  local out rc json
  json=$(jq -cn --arg t "$2" '{agent_type:$t,agent_id:"a1",tool_input:{command:"git commit -m x"}}')
  out=$(cd "$SANDBOX" && printf '%s' "$json" | bash .claude/hooks/block-reviewer-repo-mutation.sh 2>&1)
  rc=$?
  expect_eq "$1 exit" "$rc" "$3"
  if [ "$3" = 2 ]; then
    if printf '%s' "$out" | grep -q 'BLOCKED:'; then check "$1 message" ok; else check "$1 message" no "$out"; fi
  fi
}
config '{"review_markers":{"extra_review_agents":["acme-reviewer"]}}'
run_hook 'configured reviewer blocked' acme-reviewer 2
run_hook 'build agent allowed' backend-engineer 0
config '{}'
run_hook 'unconfigured custom type allowed' acme-reviewer 0
# Share the same extraction for the real fallback and both mutated copies.
fallback_matches() {
  local fallback builtins
  fallback=$(sed -n 's/^[[:space:]]*\([^ )]*\)) CALLER_CLASS=reviewer ;;$/\1/p' "$1" | tr '|' '\n' | LC_ALL=C sort)
  builtins=$(bash -c '. "$1/_lib-review-markers.sh"; printf "%s\n" $REVIEW_AGENT_SLUGS' bash "$HOOKS" | LC_ALL=C sort)
  [ "$fallback" = "$builtins" ]
}
if fallback_matches "$HOOKS/block-reviewer-repo-mutation.sh"; then check 'fallback matches built-ins' ok; else check 'fallback matches built-ins' no mismatch; fi
sed 's/code-reviewer|security-reviewer|solution-architect) CALLER_CLASS=reviewer ;;/code-reviewer|security-reviewer) CALLER_CLASS=reviewer ;;/' "$HOOKS/block-reviewer-repo-mutation.sh" > "$SANDBOX/missing.sh"
sed 's/code-reviewer|security-reviewer|solution-architect) CALLER_CLASS=reviewer ;;/code-reviewer|security-reviewer|solution-architect|extra-reviewer) CALLER_CLASS=reviewer ;;/' "$HOOKS/block-reviewer-repo-mutation.sh" > "$SANDBOX/extra.sh"
for f in missing extra; do
  if fallback_matches "$SANDBOX/$f.sh"; then check "fallback detects $f name" no matched; else check "fallback detects $f name" ok; fi
done
echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
