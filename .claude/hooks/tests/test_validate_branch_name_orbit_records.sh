#!/bin/bash
# Records branch and title regressions (#1673). Git writes stay in sandboxes.
set -eu
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=_lib-mock-gh.sh
. "$ROOT/.claude/hooks/tests/_lib-mock-gh.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
make_sandbox() {
  sb="$TMP/$1"
  mkdir -p "$sb/.claude/hooks"
  for lib in validate-branch-name.sh validate-pr-create.sh _lib-extract-push-ref.sh \
    _lib-strip-heredoc.sh _lib-read-config.sh _lib-pr-repo.sh _lib-tracker.sh \
    _lib-orbit-records.sh _lib-fail-closed-json.sh _lib-ops-root.sh \
    _lib-awk-fallback.sh _lib-review-markers.sh; do
    cp "$ROOT/.claude/hooks/$lib" "$sb/.claude/hooks/"
  done
  cp "$ROOT/.claude/project-config.defaults.json" "$sb/.claude/"
  git -C "$sb" init -q
  git -C "$sb" config user.email test@example.com
  git -C "$sb" config user.name test
  git -C "$sb" checkout -q -b dev
  mkdir -p "$sb/src"
  echo base > "$sb/src/base.sh"
  git -C "$sb" add src/base.sh
  git -C "$sb" commit -qm base
  git init -q --bare "$sb/remote.git"
  git -C "$sb" remote add origin "$sb/remote.git"
  git -C "$sb" push -q origin dev
  git -C "$sb" checkout -qb orbit/scaffold-initiative
}
records_commit() {
  mkdir -p "$sb/docs/orbit/plans"
  echo records > "$sb/docs/orbit/plan.md"
  printf '{"id":"plan-scaffold"}\n' > "$sb/docs/orbit/plans/plan-scaffold.json"
  git -C "$sb" add docs/orbit/plan.md docs/orbit/plans/plan-scaffold.json
  git -C "$sb" commit -qm records
}
check() {
  local label="$1" hook="$2" cmd="$3" expected="$4" text="${5:-}" rc=0 output
  output=$(cd "$sb" && jq -nc --arg c "$cmd" '{tool_input:{command:$c}}' |
    bash ".claude/hooks/$hook" 2>&1) || rc=$?
  if [ "$rc" != "$expected" ]; then
    printf 'FAIL %s: rc %s expected %s\n%s\n' "$label" "$rc" "$expected" "$output" >&2
    exit 1
  fi
  if [ -n "$text" ] && ! printf '%s\n' "$output" | grep -qF "$text"; then
    printf 'FAIL %s: missing %s\n%s\n' "$label" "$text" "$output" >&2
    exit 1
  fi
  echo "PASS $label"
  PASS=$((PASS + 1))
}
branch_check() { check "$1" validate-branch-name.sh "$2" "$3" "${4:-}"; }
make_sandbox clean
records_commit
branch_check A 'git push origin orbit/scaffold-initiative' 0
branch_check G-source 'git push origin HEAD:orbit/scaffold-initiative' 2 '{type}/{TICKET-ID}-{description}'
branch_check G-tags 'git push origin orbit/scaffold-initiative --tags' 2 '{type}/{TICKET-ID}-{description}'
branch_check G-two 'git push origin orbit/scaffold-initiative; git push origin orbit/scaffold-initiative' 2
branch_check G-multiple 'git push origin orbit/scaffold-initiative feature/GH-1-x' 2
branch_check G-same-source 'git push origin +orbit/scaffold-initiative:refs/heads/orbit/scaffold-initiative' 0
for name in orbit/single orbit/Scaffold-Initiative orbit/; do
  branch_check "H-$name" "git push origin $name" 2
 done
branch_check I-feature 'git push origin feature/GH-1-x' 0
branch_check I-bogus 'git push origin not-conforming' 2
branch_check I-trunk 'git push origin dev' 0
mock_gh_install "$sb"
cat > "$sb/body.md" <<'BODY'
## Summary
Add records.
## Testing
Run hook tests.
## Glossary
ORBIT: planning lifecycle.
Initiative: plan-scaffold
BODY
pr_check() {
  check "$1" validate-pr-create.sh "gh pr create --repo me2resh/apexyard --title '$2' --head $3 --body-file $sb/body.md" "$4" "${5:-}"
}
pr_check K 'docs(orbit/scaffold): add initiative records' orbit/scaffold-initiative 0
pr_check M 'docs(orbit/scaffold): x' feature/GH-1-x 2 '{type}/{TICKET-ID}-{description}'
pr_check wrong-title 'docs(orbit/other): x' orbit/scaffold-initiative 2
pr_check legacy-title 'docs(orbit): x' orbit/scaffold-initiative 2
pr_check N-initiative-only 'feat(#1): x' feature/GH-1-x 2 'Closes or Refs'
sed -i.bak 's/Initiative: plan-scaffold/Initiative: plan-other/' "$sb/body.md"
pr_check wrong-body 'docs(orbit/scaffold): x' orbit/scaffold-initiative 2
sed -i.bak 's/Initiative: plan-other/Refs #1673/' "$sb/body.md"
pr_check missing-initiative 'docs(orbit/scaffold): x' orbit/scaffold-initiative 2
pr_check N 'feat(#1): x' feature/GH-1-x 0
sed -i.bak 's/Refs #1673/Initiative: plan-scaffold/' "$sb/body.md"
git -C "$sb" branch orbit/unknown-records
branch_check unknown 'git push origin orbit/unknown-records' 2 'No matching plan record'
pr_check unknown-pr 'docs(orbit/unknown): x' orbit/unknown-records 2
printf '{"id":"plan-scaffold-initiative"}\n' > "$sb/docs/orbit/plans/long.json"
git -C "$sb" add docs/orbit/plans/long.json
git -C "$sb" commit -qm longer
git -C "$sb" branch orbit/scaffold-initiative-cycle
sed -i.bak 's/plan-scaffold$/plan-scaffold-initiative/' "$sb/body.md"
pr_check longest 'docs(orbit/scaffold-initiative): x' orbit/scaffold-initiative-cycle 0
pr_check shorter 'docs(orbit/scaffold): x' orbit/scaffold-initiative-cycle 2
sed -i.bak 's/plan-scaffold-initiative$/plan-scaffold/' "$sb/body.md"
echo extra > "$sb/src/app.sh"
git -C "$sb" add src/app.sh
git -C "$sb" commit -qm extra
branch_check B 'git push origin orbit/scaffold-initiative' 2 '{type}/{TICKET-ID}-{description}'
pr_check L 'docs(orbit/scaffold): add initiative records' orbit/scaffold-initiative 2 '{type}/{TICKET-ID}-{description}'
make_sandbox lookalike
mkdir -p "$sb/docs/orbit-extra"
echo extra > "$sb/docs/orbit-extra/x.md"
git -C "$sb" add docs/orbit-extra/x.md
git -C "$sb" commit -qm lookalike
branch_check C 'git push origin orbit/scaffold-initiative' 2 '{type}/{TICKET-ID}-{description}'
make_sandbox deletion
records_commit
git -C "$sb" rm -q src/base.sh
git -C "$sb" commit -qm deletion
branch_check D 'git push origin orbit/scaffold-initiative' 2 '{type}/{TICKET-ID}-{description}'
make_sandbox rename-out
records_commit
git -C "$sb" mv docs/orbit/plan.md src/moved.md
git -C "$sb" commit -qm rename
branch_check D-rename-out 'git push origin orbit/scaffold-initiative' 2 '{type}/{TICKET-ID}-{description}'
make_sandbox nul-paths
records_commit
printf records > "$sb/docs/orbit/line"$'\n'"break.md"
git -C "$sb" add docs/orbit/
git -C "$sb" commit -qm newline
branch_check nul-records 'git push origin orbit/scaffold-initiative' 0
printf outside > "$sb/src/line"$'\n'"break.sh"
git -C "$sb" add src/
git -C "$sb" commit -qm outside
branch_check nul-outside 'git push origin orbit/scaffold-initiative' 2
make_sandbox no-remote
records_commit
git -C "$sb" remote remove origin
# A forged local trunk must never hide the records diff.
git -C "$sb" branch -f dev HEAD
branch_check E 'git push origin orbit/scaffold-initiative' 2 'No remote-tracking trunk base'
make_sandbox empty
branch_check F 'git push origin orbit/scaffold-initiative' 2 'no changed files'
records_commit
rm "$sb/.claude/hooks/_lib-orbit-records.sh"
branch_check J 'git push origin orbit/scaffold-initiative' 2
printf '%s cases passed.\n' "$PASS"
