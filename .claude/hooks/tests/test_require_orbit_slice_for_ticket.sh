#!/bin/bash
# ORBIT issue gate against a local project checkout and fake remote refs.
set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

src=$(cd "$(dirname "$0")/../../.." && pwd)
if [ ! -x "$src/.claude/hooks/require-orbit-slice-for-ticket.sh" ]; then
  echo 'FAIL: ORBIT gate must be executable for dispatch-bash.sh' >&2
  exit 1
fi
sb=$(mktemp -d "${TMPDIR:-/tmp}/orbit-gate-test.XXXXXX") || exit 1
trap 'rm -rf "$sb"' EXIT
mkdir -p "$sb/.claude/hooks" "$sb/workspace"
cp "$src/.claude/hooks/require-orbit-slice-for-ticket.sh" "$src/.claude/hooks/_lib-read-config.sh" \
  "$src/.claude/hooks/_lib-portfolio-paths.sh" "$src/.claude/hooks/_lib-ops-root.sh" \
  "$src/.claude/hooks/_lib-resolution-cache.sh" "$sb/.claude/hooks/"
cp "$src/.claude/project-config.defaults.json" "$sb/.claude/"
printf '{}\n' > "$sb/.claude/project-config.json"
: > "$sb/onboarding.yaml"
cat > "$sb/apexyard.projects.yaml" <<'YAML'
projects:
  - name: demo
    repo: demo-org/demo
    workspace: workspace/demo
    orbit:
      default_planning: true
YAML
git -C "$sb/workspace" init -q -b main demo
project="$sb/workspace/demo"
git -C "$project" config user.email test@example.com
git -C "$project" config user.name test
mkdir -p "$project/docs/orbit/slices"
printf '{"id":"slice-demo-o1"}\n' > "$project/docs/orbit/slices/slice-demo-o1.json"
git -C "$project" add docs/orbit/slices/slice-demo-o1.json
git -C "$project" commit -qm fixture
git -C "$project" update-ref refs/remotes/origin/main HEAD
git -C "$project" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
printf '{"id":"slice-demo-o2"}\n' > "$project/docs/orbit/slices/slice-demo-o2.json"
git -C "$project" add docs/orbit/slices/slice-demo-o2.json
git -C "$project" commit -qm nondefault

body_file="$sb/body.md"
verb=create
fail=0
check() {
  label=$1 want=$2 cmd=$3
  payload=$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  (cd "$sb" && printf '%s' "$payload" | /bin/bash .claude/hooks/require-orbit-slice-for-ticket.sh) > "$sb/out" 2> "$sb/err"
  got=$?
  if [ "$got" -ne "$want" ]; then
    printf 'FAIL %s: expected %s, got %s: %s\n' "$label" "$want" "$got" "$(cat "$sb/err")"
    fail=1
  else
    printf 'PASS %s\n' "$label"
  fi
}
make_cmd() {
  printf 'gh issue %s --repo demo-org/demo --title "[%s] Demo" --body "%s"' "$verb" "$1" "$2"
}

check valid 0 "$(make_cmd Feature 'ORBIT slice: slice-demo-o1')"
check bold 0 "$(make_cmd Task '**ORBIT slice:** `slice-demo-o1`')"
check missing 2 "$(make_cmd Feature 'ORBIT slice: slice-demo-o9')"
check nondefault 2 "$(make_cmd Task 'ORBIT slice: slice-demo-o2')"
check no_line 2 "$(make_cmd Feature 'plain body')"
check empty_reason 2 "$(make_cmd Task 'ORBIT slice: none —   ')"
check none 0 "$(make_cmd Feature 'ORBIT slice: none — urgent repair')"
if ! grep -q 'urgent repair' "$sb/err"; then echo 'FAIL exception reason log'; fail=1; fi
check none_ascii 0 "$(make_cmd Feature 'ORBIT slice: none -- urgent repair')"
check bug 0 "$(make_cmd Bug 'plain body')"
check spike 0 "$(make_cmd Spike 'plain body')"
check traversal_parent 2 "$(make_cmd Feature 'ORBIT slice: ../x')"
check traversal_slash 2 "$(make_cmd Task 'ORBIT slice: a/b')"
printf 'ORBIT slice: slice-demo-o1\n' > "$body_file"
check body_file 0 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body-file '$body_file'"
check short_file 0 "gh issue $verb --repo demo-org/demo --title '[Task] Demo' -F '$body_file'"
check tracker_file 0 "tracker_create demo-org/demo '[Feature] Demo' '$body_file'"
check tracker_wrapped 0 "result=\$(tracker_create demo-org/demo '[Feature] Demo' '$body_file')"
check api_body_file 0 "gh api repos/demo-org/demo/issues -X POST -f title='[Feature] Demo' -F body=@$body_file"
check api_missing 2 "gh api repos/demo-org/demo/issues -X POST -f title='[Task] Demo' -f body='plain body'"
check unreadable 2 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body-file '$sb/absent'"
printf '{"orbit":{"default_planning":false}}\n' > "$sb/.claude/project-config.json"
awk '!/    orbit:/ && !/      default_planning: true/' "$sb/apexyard.projects.yaml" > "$sb/registry.tmp"
mv "$sb/registry.tmp" "$sb/apexyard.projects.yaml"
check orbit_off 0 "$(make_cmd Feature 'plain body')"
exit "$fail"
