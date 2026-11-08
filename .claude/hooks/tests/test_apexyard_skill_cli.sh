#!/usr/bin/env bash
# Offline skill and ticket dispatch checks.
# Literal command substitutions are intentional test data.
# shellcheck disable=SC2016
# shellcheck disable=SC1091,SC2154
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_lib-apexyard-cli.sh"
sb=$(cd "$sb" && pwd -P)
exec </dev/null
root=$(cd "$(dirname "$CLI")/.." && pwd)
mkdir -p "$sb/ops/.claude/skills" "$sb/ops/bin"
cp -R "$root/.claude/hooks" "$sb/ops/.claude/"
printf 'company: test\n' > "$sb/ops/onboarding.yaml"
printf 'projects: []\n' > "$sb/ops/apexyard.projects.yaml"
git -C "$sb/ops" init -b main >/dev/null
export APEXYARD_DISABLE_RESOLUTION_CACHE=1 APEXYARD_AGENT_CMD="$sb/tools/agent" AGENT_LOG="$sb/agent.log"
cat > "$APEXYARD_AGENT_CMD" <<'EOF'
#!/bin/bash
printf '%s\n' "$PWD" "$#" "$@" > "$AGENT_LOG"
EOF
chmod +x "$APEXYARD_AGENT_CMD"
for name in inbox approve status; do
  mkdir -p "$sb/ops/.claude/skills/$name"
  printf '%s\ndescription: "One line"\n' --- > "$sb/ops/.claude/skills/$name/SKILL.md"
  if [ "$name" = approve ]; then echo 'disable-model-invocation: true' >> "$sb/ops/.claude/skills/$name/SKILL.md"; fi
  echo --- >> "$sb/ops/.claude/skills/$name/SKILL.md"
done
run() {
  rc=0
  (cd "$sb/ops" && /bin/bash "$CLI" "$@") > "$sb/out" 2>&1 || rc=$?
}
run inbox 'two words' '$(touch nope)'
check launch test "$rc" = 0
check cwd test "$(head -1 "$AGENT_LOG")" = "$sb/ops"
check 'single argument' grep -qx 1 "$AGENT_LOG"
check literal grep -Fqx '/inbox two words $(touch nope)' "$AGENT_LOG"
check 'no evaluation' test ! -e "$sb/ops/nope"
mkdir -p "$sb/ops/nested/deeper"
(cd "$sb/ops/nested/deeper" && /bin/bash "$CLI" inbox)
check 'nested ops root' test "$(head -1 "$AGENT_LOG")" = "$sb/ops"
check 'no argument prompt' grep -Fxq /inbox "$AGENT_LOG"
run unknown
check unknown test "$rc" = 2
check 'unknown message' grep -Fq "apexyard: unknown command or skill 'unknown'. Run 'apexyard skills' to list them." "$sb/out"
rc=0
(cd "$sb" && /bin/bash "$CLI" inbox) > "$sb/out" 2>&1 || rc=$?
check outside test "$rc" = 2
check 'outside message' grep -q 'not inside an apexyard fork' "$sb/out"
run skills
printf '  approve  One line (inside the agent only)\n  inbox  One line\n  status  One line\n' > "$sb/expected"
check listing cmp "$sb/expected" "$sb/out"
run status
check priority grep -q 'briefing helper not found' "$sb/out"
run approve
check human test "$rc" = 2
check 'human message' grep -Fq '/approve records a human approval.' "$sb/out"
APEXYARD_AGENT_CMD="$sb/missing" run inbox
check fallback test "$rc" = 0
check instruction grep -Fq "Run this in your agent tool, from $sb/ops: /inbox" "$sb/out"
run ticket invalid
check shape test "$rc" = 2
run ticket org/app#12
check unregistered test "$rc" = 2
check registration grep -Fq 'org/app is not in the registry. Register it with /handover first.' "$sb/out"
printf 'projects:\n  - name: app\n    repo: org/app\n' > "$sb/ops/apexyard.projects.yaml"
run ticket org/app#12
check 'missing clone' test "$rc" = 2
check 'clone command' grep -Fxq "gh repo clone org/app $sb/ops/workspace/app" "$sb/out"
mkdir -p "$sb/ops/workspace"
git clone "$sb/fixture" "$sb/ops/workspace/app" >/dev/null 2>&1
cat > "$APEXYARD_GH" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
echo '[Feature] Add useful thing!'
EOF
export APEXYARD_START_TICKET="$sb/tools/start" START_LOG="$sb/start.log"
cat > "$APEXYARD_START_TICKET" <<'EOF'
#!/bin/bash
printf '%s\n' "$PWD" "$@" > "$START_LOG"
[ "${FAIL_START:-0}" = 0 ] || { echo 'start failed'; exit 1; }
EOF
chmod +x "$APEXYARD_START_TICKET"
clone="$sb/ops/workspace/app"
git -C "$clone" worktree add -b feature/GH-123-other "$sb/other" >/dev/null 2>&1
run ticket org/app#12
check ticket test "$rc" = 0
wt="$clone.worktrees/gh-12-add-useful-thing"
check path test -d "$wt"
check branch test "$(git -C "$wt" branch --show-current)" = feature/GH-12-add-useful-thing
check 'ticket agent cwd' test "$(head -1 "$AGENT_LOG")" = "$wt"
check 'ticket prompt' grep -Fxq '/start-ticket org/app#12' "$AGENT_LOG"
check 'helper cwd' test "$(head -1 "$START_LOG")" = "$wt"
check 'helper target' grep -Fxq org/app#12 "$START_LOG"
run ticket org/app#12
check reuse test "$rc" = 0
check 'issue read once' test "$(grep -c 'issue view' "$FAKE_GH_LOG")" = 1
FAIL_START=1 run ticket org/app#12
check 'helper failure' test "$rc" = 2
check 'helper message' grep -Fxq 'start failed' "$sb/out"
# Exercise every remaining title prefix with the same local origin.
number=20
for pair in 'Bug:fix' 'Docs:docs' 'Refactor:refactor' 'CI:ci' 'Testing:test' 'Other:chore'; do
  prefix=${pair%:*}; expected_type=${pair#*:}
  cat > "$APEXYARD_GH" <<EOF
#!/bin/bash
echo '[$prefix] Small change'
EOF
  run ticket "org/app#$number"
  check "$prefix launch" test "$rc" = 0
  check "$prefix branch" test "$(git -C "$clone.worktrees/gh-$number-small-change" branch --show-current)" = "$expected_type/GH-$number-small-change"
  number=$((number + 1))
done
finish
