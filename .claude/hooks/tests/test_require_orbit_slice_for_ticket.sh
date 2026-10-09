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
git -C "$sb" init -q
mkdir -p "$sb/.claude/hooks" "$sb/workspace"
cp "$src/.claude/hooks/require-orbit-slice-for-ticket.sh" "$src/.claude/hooks/_lib-read-config.sh" \
  "$src/.claude/hooks/_lib-portfolio-paths.sh" "$src/.claude/hooks/_lib-ops-root.sh" \
  "$src/.claude/hooks/_lib-resolution-cache.sh" "$src/.claude/hooks/_lib-registry-parser.sh" \
  "$src/.claude/hooks/_lib-flag-value.sh" \
  "$sb/.claude/hooks/"
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
check slice_valid 0 "$(make_cmd Slice 'ORBIT slice: slice-demo-o1')"
check slice_missing 2 "$(make_cmd Slice 'plain body')"
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
check env_api_missing 2 "env gh api repos/demo-org/demo/issues -X POST -f title='[Task] Demo' -f body='plain body'"
check path_api_missing 2 "/usr/local/bin/gh api repos/demo-org/demo/issues -X POST -f title='[Task] Demo' -f body='plain body'"
check api_duplicate_title 2 "gh api repos/demo-org/demo/issues -X POST -f title='[Bug] Demo' -f title='[Feature] Demo' -f body='ORBIT slice: slice-demo-o1'"
check api_duplicate_body 2 "gh api repos/demo-org/demo/issues -X POST -f title='[Feature] Demo' -f body='ORBIT slice: slice-demo-o1' -f body='plain body'"
check unreadable 2 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body-file '$sb/absent'"
check leading_title 2 "gh issue $verb --repo demo-org/demo --title ' [Feature] Demo' --body 'plain body'"
check mid_title 2 "gh issue $verb --repo demo-org/demo --title 'Demo [Task]' --body 'plain body'"
check lower_title 2 "gh issue $verb --repo demo-org/demo --title '[feature] Demo' --body 'plain body'"
check unicode_title 2 "gh issue $verb --repo demo-org/demo --title '［Feature］ Demo' --body 'plain body'"
check upper_title 2 "gh issue $verb --repo demo-org/demo --title '[FEATURE] Demo' --body 'plain body'"
check no_title 2 "gh issue $verb --repo demo-org/demo --body 'ORBIT slice: slice-demo-o1'"
check quoted_directive 2 "$(make_cmd Feature '> ORBIT slice: slice-demo-o1')"
check comment_directive 2 "$(make_cmd Feature '<!-- ORBIT slice: slice-demo-o1 -->')"
check late_directive 2 "$(make_cmd Feature 'plain body
ORBIT slice: slice-demo-o1')"
check encoded_traversal 2 "$(make_cmd Feature 'ORBIT slice: slice-%2e%2e')"
check newline_id 2 "$(make_cmd Feature 'ORBIT slice: slice-demo-o1
evil')"
check stdin_file 2 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body-file -"
check equals_file 0 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body-file='$body_file'"
check equals_repo 0 "gh issue $verb --repo=demo-org/demo --title='[Feature] Demo' --body-file='$body_file'"
check equals_repo_missing 2 "gh issue $verb --repo=demo-org/demo --title='[Feature] Demo' --body 'plain body'"
check equals_body 0 "gh issue $verb --repo=demo-org/demo --title='[Feature] Demo' --body='ORBIT slice: slice-demo-o1'"
check duplicate_repo 2 "gh issue $verb --repo demo-org/demo --repo demo-org/other --title '[Feature] Demo' --body 'ORBIT slice: slice-demo-o1'"
check duplicate_repo_equals 2 "gh issue $verb --repo=demo-org/demo --repo=demo-org/other --title '[Feature] Demo' --body 'ORBIT slice: slice-demo-o1'"
check duplicate_title 2 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --title '[Bug] Demo' --body 'ORBIT slice: slice-demo-o1'"
check duplicate_title_equals 2 "gh issue $verb --repo demo-org/demo --title='[Feature] Demo' --title='[Bug] Demo' --body='ORBIT slice: slice-demo-o1'"
check repo_in_body 2 "gh issue $verb --body 'ORBIT slice: slice-demo-o1
--repo demo-org/other' --repo demo-org/demo --title '[Feature] Demo'"
check title_in_body 2 "gh issue $verb --repo demo-org/demo --body 'plain body --title [Bug]' --title '[Feature] Demo'"
check duplicate_body 2 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'ORBIT slice: slice-demo-o1' --body 'plain body'"
check duplicate_body_equals 2 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body='ORBIT slice: slice-demo-o1' --body='plain body'"
check mixed_body 2 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'plain body' --body-file '$body_file'"
check duplicate_body_file 2 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body-file='$body_file' --body-file '$sb/absent'"
check duplicate_short_file 2 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' -F '$body_file' -F '$sb/absent'"
check mixed_short_file 2 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body='plain body' -F '$body_file'"
check variable_file 2 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body-file '\$body_file'"
check wrapped_bash 2 "bash -c \"gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'plain body'\""
check wrapped_sh 2 "sh -c \"gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'plain body'\""
check wrapped_zsh 2 "zsh -c \"gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'plain body'\""
check wrapped_xargs 2 "printf x | xargs gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'plain body'"
check wrapped_xargs_replace 2 "printf x | xargs -I{} gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'plain body'"
check env_gh 2 "env gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'plain body'"
check command_gh 2 "command gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'plain body'"
check full_path_gh 2 "/usr/local/bin/gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'plain body'"
check env_gh_valid 0 "env gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'ORBIT slice: slice-demo-o1'"
check wrapped_substitution 2 "result=\$(gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'plain body')"
check wrapped_bash_ambiguous 2 "bash -c \"gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'ORBIT slice: slice-demo-o1'\""
check wrapped_duplicate_body 2 "bash -c \"gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'ORBIT slice: slice-demo-o1' --body 'plain body'\""
check tracker_variable 2 "tracker_create demo-org/demo '[Feature] Demo' '\$body_file'"
check tracker_in_bash 2 "bash -c \"tracker_create demo-org/demo '[Feature] Demo' '$body_file'\""
check api_two_fields 0 "gh api repos/demo-org/demo/issues -X POST -F title='[Feature] Demo' -F body=@$body_file"
ln -s slice-demo-o1.json "$project/docs/orbit/slices/slice-symlink.json"
git -C "$project" add docs/orbit/slices/slice-symlink.json
git -C "$project" commit -qm symlink
git -C "$project" update-ref refs/remotes/origin/main HEAD
check symlink_record 2 "$(make_cmd Feature 'ORBIT slice: slice-symlink')"
cat > "$sb/apexyard.projects.yaml" <<'YAML'
projects:
  - name: other
    repo: demo-org/other
    workspace: workspace/other
    orbit:
      default_planning: true
  - name: demo
    repo: demo-org/demo
    workspace: workspace/demo
    orbit:
      default_planning: true
YAML
git -C "$sb/workspace" init -q -b main other
other="$sb/workspace/other"
git -C "$other" config user.email test@example.com
git -C "$other" config user.name test
mkdir -p "$other/docs/orbit/slices"
printf '{"id":"slice-other"}\n' > "$other/docs/orbit/slices/slice-other.json"
git -C "$other" add docs/orbit/slices/slice-other.json
git -C "$other" commit -qm fixture
git -C "$other" update-ref refs/remotes/origin/main HEAD
git -C "$other" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
check other_repo_valid 0 "gh issue $verb --repo demo-org/other --title '[Feature] Demo' --body 'ORBIT slice: slice-other'"
check other_repo_wrong_slice 2 "gh issue $verb --repo demo-org/other --title '[Feature] Demo' --body 'ORBIT slice: slice-demo-o1'"
cp "$src/.claude/hooks/require-skill-for-issue-create.sh" \
  "$src/.claude/hooks/validate-issue-structure.sh" "$sb/.claude/hooks/"
mkdir -p "$sb/.claude/session"
printf 'orbit\n' > "$sb/.claude/session/active-issue-skill"
payload=$(jq -n --arg c "gh issue $verb --repo demo-org/demo --title '[Slice] Demo' --body-file '$body_file'" '{tool_name:"Bash",tool_input:{command:$c}}')
for gate in require-skill-for-issue-create.sh validate-issue-structure.sh require-orbit-slice-for-ticket.sh; do
  (cd "$sb" && printf '%s' "$payload" | /bin/bash ".claude/hooks/$gate") > "$sb/out" 2> "$sb/err"
  if [ "$?" -ne 0 ]; then
    printf 'FAIL handoff_%s: %s\n' "$gate" "$(cat "$sb/err")"
    fail=1
  else
    printf 'PASS handoff_%s\n' "$gate"
  fi
done
printf '{broken\n' > "$sb/.claude/project-config.json"
check config_invalid 2 "$(make_cmd Feature 'ORBIT slice: slice-demo-o1')"
printf '{}\n' > "$sb/.claude/project-config.json"
mv "$other" "$sb/workspace/other-hidden"
check checkout_missing 2 "gh issue $verb --repo demo-org/other --title '[Feature] Demo' --body 'ORBIT slice: slice-other'"
mv "$sb/workspace/other-hidden" "$other"
git -C "$other" symbolic-ref --delete refs/remotes/origin/HEAD
check branch_unknown 2 "gh issue $verb --repo demo-org/other --title '[Feature] Demo' --body 'ORBIT slice: slice-other'"
git -C "$other" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
mkdir -p "$sb/bin"
cat > "$sb/bin/git" <<'SH'
#!/bin/sh
exit 127
SH
chmod +x "$sb/bin/git"
payload=$(jq -n --arg c "$(make_cmd Feature 'ORBIT slice: slice-demo-o1')" '{tool_name:"Bash",tool_input:{command:$c}}')
(cd "$sb" && printf '%s' "$payload" | PATH="$sb/bin:$PATH" /bin/bash .claude/hooks/require-orbit-slice-for-ticket.sh) > "$sb/out" 2> "$sb/err"
if [ "$?" -ne 2 ]; then echo 'FAIL git_missing'; fail=1; else echo 'PASS git_missing'; fi
# Hide jq with a curated PATH. Do not use PATH=/bin: on Ubuntu /bin → /usr/bin,
# so jq in /usr/bin stays visible and this case false-passes on Linux CI.
jq_hide=$(mktemp -d "$sb/jq-hide.XXXXXX") || exit 1
for tool in bash sh git awk sed grep egrep fgrep tr cat head cut dirname mkdir printf env; do
  tool_path=$(type -P "$tool" 2>/dev/null) || continue
  ln -sf "$tool_path" "$jq_hide/$tool"
done
if type -P jq >/dev/null 2>&1 && [ -e "$jq_hide/jq" ]; then
  echo 'FAIL jq_missing setup: jq must not be linked into the hide dir' >&2
  fail=1
fi
payload=$(jq -n --arg c "$(make_cmd Feature 'ORBIT slice: slice-demo-o1')" '{tool_name:"Bash",tool_input:{command:$c}}')
(cd "$sb" && printf '%s' "$payload" | PATH="$jq_hide" /bin/bash .claude/hooks/require-orbit-slice-for-ticket.sh) > "$sb/out" 2> "$sb/err"
if [ "$?" -ne 2 ] || ! grep -q 'jq is unavailable' "$sb/err"; then
  echo "FAIL jq_missing: expected exit 2 with jq-unavailable message: $(cat "$sb/err")"
  fail=1
else
  echo 'PASS jq_missing'
fi
# Sanity: with jq present, the same valid create is allowed (not a false jq miss).
check jq_present_sanity 0 "$(make_cmd Feature 'ORBIT slice: slice-demo-o1')"
# Repo spellings gh accepts — all must resolve to the registered slug.
check repo_upper 2 "gh issue $verb --repo DEMO-ORG/DEMO --title '[Feature] Demo' --body 'plain body'"
check repo_upper_valid 0 "gh issue $verb --repo DEMO-ORG/DEMO --title '[Feature] Demo' --body 'ORBIT slice: slice-demo-o1'"
check repo_https 2 "gh issue $verb --repo https://github.com/demo-org/demo --title '[Feature] Demo' --body 'plain body'"
check repo_https_valid 0 "gh issue $verb --repo https://github.com/demo-org/demo --title '[Feature] Demo' --body 'ORBIT slice: slice-demo-o1'"
check repo_https_git 2 "gh issue $verb --repo https://github.com/demo-org/demo.git --title '[Feature] Demo' --body 'plain body'"
check repo_host 2 "gh issue $verb --repo github.com/demo-org/demo --title '[Feature] Demo' --body 'plain body'"
check repo_host_valid 0 "gh issue $verb --repo github.com/demo-org/demo --title '[Feature] Demo' --body 'ORBIT slice: slice-demo-o1'"
check repo_ssh 2 "gh issue $verb --repo git@github.com:demo-org/demo.git --title '[Feature] Demo' --body 'plain body'"
check repo_ssh_valid 0 "gh issue $verb --repo git@github.com:demo-org/demo.git --title '[Feature] Demo' --body 'ORBIT slice: slice-demo-o1'"
# Inline repos: […] and block-list items with trailing comments (example shapes).
cat > "$sb/apexyard.projects.yaml" <<'YAML'
projects:
  - name: demo
    repos: [demo-org/demo]
    workspace: workspace/demo
    orbit:
      default_planning: true
YAML
check inline_repos_missing 2 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'plain body'"
check inline_repos_valid 0 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'ORBIT slice: slice-demo-o1'"
check inline_repos_upper 2 "gh issue $verb --repo DEMO-ORG/DEMO --title '[Feature] Demo' --body 'plain body'"
cat > "$sb/apexyard.projects.yaml" <<'YAML'
projects:
  - name: demo
    repos:
      - demo-org/demo  # primary service
    workspace: workspace/demo
    orbit:
      default_planning: true
YAML
check repos_comment_missing 2 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'plain body'"
check repos_comment_valid 0 "gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'ORBIT slice: slice-demo-o1'"
check repos_comment_https 2 "gh issue $verb --repo https://github.com/demo-org/demo --title '[Feature] Demo' --body 'plain body'"
# YAML 1.1 boolean spellings in the per-project override must not turn the
# gate off. An unknown value warns and falls back to the global default.
set_override() {
  cat > "$sb/apexyard.projects.yaml" <<YAML
projects:
  - name: demo
    repo: demo-org/demo
    workspace: workspace/demo
    orbit:
      default_planning: $1
YAML
}
for spelling in True TRUE '"True"' yes On; do
  set_override "$spelling"
  check "override_$spelling" 2 "$(make_cmd Feature 'plain body')"
done
set_override False
check override_False 0 "$(make_cmd Feature 'plain body')"
set_override maybe
printf '{"orbit":{"default_planning":true}}\n' > "$sb/.claude/project-config.json"
check override_unknown_global_on 2 "$(make_cmd Feature 'plain body')"
if ! grep -q 'unknown value' "$sb/err"; then echo 'FAIL unknown override warning'; fail=1; fi
printf '{"orbit":{"default_planning":false}}\n' > "$sb/.claude/project-config.json"
check override_unknown_global_off 0 "$(make_cmd Feature 'plain body')"
set_override true
printf '{"orbit":{"default_planning":false}}\n' > "$sb/.claude/project-config.json"
awk '!/    orbit:/ && !/      default_planning: true/' "$sb/apexyard.projects.yaml" > "$sb/registry.tmp"
mv "$sb/registry.tmp" "$sb/apexyard.projects.yaml"
check orbit_off 0 "$(make_cmd Feature 'plain body')"
check orbit_off_wrapped 0 "bash -c \"gh issue $verb --repo demo-org/demo --title '[Feature] Demo' --body 'plain body'\""
exit "$fail"
