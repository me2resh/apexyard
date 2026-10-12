#!/usr/bin/env bash
# Selector and executable workflow contract checks. Requires Node and yq/PyYAML.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/.claude/hooks/tests" "$tmp/.claude/agents/tests" "$tmp/.claude/skills"
cp bin/select-affected-tests.sh "$tmp/bin/"
printf '%s\n' 'bash .claude/hooks/example.sh' > "$tmp/.claude/hooks/tests/test_example.sh"
printf '%s\n' '# unrelated' > "$tmp/.claude/hooks/tests/test_other.sh"
printf '%s\n' '# .claude/skills/demo/SKILL.md .claude/agents/demo.md' > "$tmp/.claude/hooks/tests/test_paths.sh"
printf '%s\n' 'bash bin/example-tool.sh' > "$tmp/.claude/hooks/tests/test_tool.sh"
selector="$tmp/bin/select-affected-tests.sh"
assert_selection() {
  local paths=$1 expected=$2
  actual=$(printf '%s\n' "$paths" | /bin/bash "$selector")
  [ "$actual" = "$expected" ] || { echo "FAIL selection: $paths -> $actual (expected $expected)"; exit 1; }
}
assert_selection .claude/hooks/example.sh .claude/hooks/tests/test_example.sh
assert_selection .claude/hooks/tests/test_other.sh .claude/hooks/tests/test_other.sh
assert_selection .claude/skills/demo/SKILL.md .claude/hooks/tests/test_paths.sh
assert_selection .claude/agents/demo.md .claude/hooks/tests/test_paths.sh
assert_selection README.md ''
assert_selection bin/example-tool.sh .claude/hooks/tests/test_tool.sh
assert_selection .claude/hooks/tests/_helpers.sh ALL
assert_selection .claude/hooks/tests/fixtures/input.json ALL
for path in .claude/hooks/_lib-shared.sh .claude/settings.json .claude/project-config.defaults.json bin/run-hook-tests.sh bin/select-affected-tests.sh .github/workflows/tests.yml .githooks/pre-push; do
  assert_selection "$path" ALL
done
assert_selection $'.claude/hooks/example.sh\n.claude/hooks/example.sh' .claude/hooks/tests/test_example.sh
printf '%s\n' README.md docs/image.png | /bin/bash "$selector" --docs-only
for path in .claude/skills/demo/SKILL.md bin/example.sh; do
  if printf '%s\n' README.md "$path" | /bin/bash "$selector" --docs-only; then echo "FAIL docs-only: $path"; exit 1; fi
done
if printf '' | /bin/bash "$selector" --docs-only; then echo 'FAIL empty docs-only input'; exit 1; fi
# A rename out of .claude/ must not look docs-only: the old path must be listed.
rename_repo="$tmp/rename-repo"
git init -q "$rename_repo"
mkdir -p "$rename_repo/.claude/rules"
printf '%s\n' 'rule text that stays the same' > "$rename_repo/.claude/rules/foo.md"
git -C "$rename_repo" add .claude/rules/foo.md
git -C "$rename_repo" -c user.name=t -c user.email=t@example.invalid commit -q -m base
mkdir -p "$rename_repo/docs"
git -C "$rename_repo" mv .claude/rules/foo.md docs/foo.md
git -C "$rename_repo" -c user.name=t -c user.email=t@example.invalid commit -q -m move
git -C "$rename_repo" diff --name-only --no-renames HEAD~1...HEAD > "$tmp/renamed"
grep -Fxq .claude/rules/foo.md "$tmp/renamed" || { echo 'FAIL rename hides old path'; exit 1; }
if /bin/bash "$selector" --docs-only "$tmp/renamed"; then echo 'FAIL rename out of .claude/ counted as docs-only'; exit 1; fi
[ "$(grep -c 'git diff --name-only --no-renames' .github/workflows/tests.yml)" = 2 ] || { echo 'FAIL workflow diff calls must use --no-renames'; exit 1; }
# Explicit list execution, empty lists, and rejection use a tiny runner fixture.
cp bin/run-hook-tests.sh "$tmp/bin/"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$tmp/.claude/hooks/tests/test_other.sh"
printf '%s\n' '#!/bin/bash' 'exit 1' > "$tmp/.claude/hooks/tests/test_example.sh"
printf '%s\n' .claude/hooks/tests/test_other.sh > "$tmp/list"
/bin/bash "$tmp/bin/run-hook-tests.sh" --files "$tmp/list" > "$tmp/result"
grep -q 'PASS=1.*FAIL=0.*TOTAL=1' "$tmp/result"
: > "$tmp/list"
/bin/bash "$tmp/bin/run-hook-tests.sh" --files "$tmp/list" > "$tmp/result"
grep -q 'TOTAL=0' "$tmp/result"
echo missing.sh > "$tmp/list"
if /bin/bash "$tmp/bin/run-hook-tests.sh" --files "$tmp/list" > "$tmp/result" 2>&1; then echo 'FAIL invalid test accepted'; exit 1; fi
for workflow in tests conformance; do
  if command -v yq >/dev/null 2>&1; then
    yq -o=json '.' ".github/workflows/$workflow.yml" > "$tmp/$workflow.json"
  else
    python3 - ".github/workflows/$workflow.yml" > "$tmp/$workflow.json" <<'PY'
import json, sys, yaml
with open(sys.argv[1]) as source:
    print(json.dumps(yaml.load(source, Loader=yaml.BaseLoader)))
PY
  fi
done
node - "$tmp" "$root" <<'JS'
const fs = require('fs');
const assert = require('assert/strict');
const { spawnSync } = require('child_process');
const tmp = process.argv[2], root = process.argv[3];
const w = JSON.parse(fs.readFileSync(`${tmp}/tests.json`));
const conformance = JSON.parse(fs.readFileSync(`${tmp}/conformance.json`));
assert('workflow_call' in conformance.on);
assert.equal(w.jobs['hook-test-suite'].name, 'hook test suite');
assert.deepEqual(w.jobs['hook-test-suite'].needs, ['tier', 'hook-tests', 'conformance']);
assert.equal(w.jobs['hook-test-suite'].if, 'always()');
assert.deepEqual(w.on.push.branches, ['dev', 'main']);
assert.equal(w.on.schedule[0].cron, '17 3 * * *');
assert('workflow_dispatch' in w.on);
assert(w.jobs.tier.steps[0].with.ref.includes("'dev'"));
assert(w.jobs['hook-tests'].steps[0].with.ref.includes("'dev'"));
assert.equal(w.jobs.conformance.uses, './.github/workflows/conformance.yml');
assert.equal(w.jobs.conformance.secrets, 'inherit');
assert.equal(w.jobs.conformance.if, "needs.tier.outputs.tier == 'release' && vars.CONFORMANCE_ON_RELEASE == 'true'");
assert.deepEqual(w.jobs.conformance.permissions, { contents: 'write', actions: 'read' });
assert.deepEqual(w.jobs['nightly-failure'].permissions, { issues: 'write' });
assert.equal(w.permissions.contents, 'read');
const select = w.jobs.tier.steps.find(s => s.id === 'select').run;
function tier(event, paths, branch = '', title = '') {
  fs.writeFileSync(`${tmp}/output`, '');
  const result = spawnSync('bash', ['-c', 'git() { printf "%s\\n" "$CHANGED"; };\n' + select], {
    cwd: root, encoding: 'utf8', env: { ...process.env, EVENT: event, CHANGED: paths,
      HEAD_BRANCH: branch, PR_TITLE: title, BASE_SHA: 'base', HEAD_SHA: 'head',
      RUNNER_TEMP: tmp, GITHUB_OUTPUT: `${tmp}/output` }
  });
  assert.equal(result.status, 0, result.stderr);
  const output = fs.readFileSync(`${tmp}/output`, 'utf8').trim().split('\n');
  return { tier: output[0].slice(5), matrix: JSON.parse(output[1].slice(7)).include };
}
for (const event of ['push', 'schedule', 'workflow_dispatch']) {
  const r = tier(event, 'README.md');
  assert.equal(r.tier, 'heavy'); assert.equal(r.matrix.length, 6);
  assert.deepEqual(r.matrix.filter(m => m.shard).map(m => m.shard), ['1/4', '2/4', '3/4', '4/4']);
}
assert.equal(tier('pull_request', 'README.md\ndocs/image.png').tier, 'docs');
for (const path of ['.claude/skills/demo/SKILL.md', '.claude/hooks/example.sh']) {
  const r = tier('pull_request', path);
  assert.equal(r.tier, 'light'); assert.equal(r.matrix.length, 2);
  assert.equal(r.matrix[0].label, 'linux jq-1.7');
  assert.equal(r.matrix[1].os, 'macos-latest');
}
// A full selection on a regular PR runs the full suite on Linux only;
// the macOS suite waits for the merge push and the nightly run.
{
  const r = tier('pull_request', '.claude/hooks/_lib-tracker.sh');
  assert.equal(r.tier, 'light'); assert.equal(r.matrix.length, 1);
  assert.equal(r.matrix[0].label, 'linux jq-1.7');
}
for (const [branch, title] of [['release/v1.0', 'docs'], ['feature/example', 'release(1.0): ship']]) {
  const r = tier('pull_request', 'README.md', branch, title);
  assert.equal(r.tier, 'release'); assert.equal(r.matrix.length, 6);
}
const summary = w.jobs['hook-test-suite'].steps[0].run;
function check(tier, matrix, conform, tierResult = 'success', on = 'true') {
  return spawnSync('bash', ['-e', '-c', summary], { env: { ...process.env,
    TIER: tier, TIER_RESULT: tierResult, MATRIX_RESULT: matrix, CONFORMANCE_RESULT: conform,
    CONFORMANCE_ON_RELEASE: on } }).status;
}
// Without the variable, a release PR does not wait on conformance.
assert.equal(check('release', 'success', 'skipped', 'success', ''), 0);
assert.notEqual(check('release', 'failure', 'skipped', 'success', ''), 0);
assert.equal(check('docs', 'skipped', 'skipped'), 0);
assert.equal(check('light', 'success', 'skipped'), 0);
assert.equal(check('heavy', 'success', 'skipped'), 0);
assert.equal(check('release', 'success', 'success'), 0);
for (const args of [['light', 'failure', 'skipped'], ['heavy', 'cancelled', 'skipped'],
                    ['release', 'success', 'failure'], ['release', 'success', 'skipped'],
                    ['docs', 'skipped', 'skipped', 'failure']]) assert.notEqual(check(...args), 0);
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const notify = new AsyncFunction('github', 'context', w.jobs['nightly-failure'].steps[0].with.script);
(async () => {
  const issues = [], calls = [];
  const context = { repo: { owner: 'owner', repo: 'repo' }, serverUrl: 'https://github.com', runId: 123 };
  const github = {
    paginate: async () => issues,
    rest: { issues: {
      listForRepo: 'issues',
      create: async args => { calls.push('create'); issues.push({ ...args, number: 1 }); },
      update: async args => { calls.push('update'); Object.assign(issues[0], args); }
    } }
  };
  await notify(github, context);
  context.runId = 456;
  await notify(github, context);
  assert.deepEqual(calls, ['create', 'update']);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].title, 'Nightly CI failed');
  assert(issues[0].body.endsWith('/owner/repo/actions/runs/456'));
  console.log('PASS: selector (bash 3.2), docs-only, explicit lists, workflow tiers, summary, release conformance, nightly issue reuse');
})().catch(error => { console.error(error); process.exitCode = 1; });
JS
