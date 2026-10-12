#!/usr/bin/env bash
# Structural checks for the ready-PR pipeline. Requires yq v4 or Python PyYAML, plus Node.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"
workflow=.github/workflows/refresh-ready-prs.yml
cmp "$workflow" golden-paths/pipelines/refresh-ready-prs.yml
for file in "$workflow" golden-paths/pipelines/refresh-ready-prs.yml; do
  grep -Fq 'pr.head.repo.id === pr.base.repo?.id' "$file"
  [[ $(grep -Fc 'if (!sameRepo(pr)) {' "$file") -eq 2 ]]
  grep -Fq 'skipping fork or unavailable head repository.' "$file"
done
json=$(mktemp)
trap 'rm -f "$json"' EXIT
if command -v yq >/dev/null 2>&1; then
  yq -o=json '.' "$workflow" > "$json"
else
  python3 - "$workflow" > "$json" <<'PY'
import json, sys, yaml
# BaseLoader retains the GitHub Actions key "on" as a string.
with open(sys.argv[1]) as source:
    print(json.dumps(yaml.load(source, Loader=yaml.BaseLoader)))
PY
fi
node - "$json" <<'JS'
const fs = require('fs');
const assert = require('assert/strict');
const workflow = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
assert.deepEqual(workflow.permissions, { 'pull-requests': 'write', contents: 'read' });
assert.deepEqual(workflow.on.push.branches, ['dev', 'main']);
assert.deepEqual(workflow.on.pull_request.types, ['synchronize']);
assert.equal(workflow.env.INTEGRATION_BRANCHES, 'dev');
const step = workflow.jobs.refresh.steps[0];
assert.equal(step.with['github-token'], '${{ secrets.APEXYARD_BOT_TOKEN || github.token }}');
const script = step.with.script;
assert(script.includes("const label = 'ready-to-merge'"));
assert(script.includes('pr.draft'));
assert(!script.includes('${{'), 'No expression interpolation in JavaScript');
assert(script.includes('comparison.behind_by'));
assert(script.includes('expected_head_sha: pr.head.sha'));
assert(script.includes('apexyard-refresh-error:${pr.head.sha}'));
assert(script.includes('comments.some'));
assert(script.includes('removeLabel'));
assert(script.includes('head.parents.length === 2'));
assert(script.includes('context.payload.before'));
assert(!/gh\s+pr\s+merge|\/pulls\/[^\s'"`]+\/merge\b|pulls\.merge\s*\(|git\s+push|--force|force\s*:\s*true/i.test(script));
// Parse the embedded async JavaScript without performing API calls.
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const run = new AsyncFunction('github', 'context', 'core', script);
(async () => {
  process.env.INTEGRATION_BRANCHES = 'dev';
  const calls = [];
  const comments = [];
  const prs = [
    { number: 1, draft: true },
    { number: 2, labels: [] },
    { number: 3 }, { number: 4 }, { number: 5 }, { number: 6 },
    { number: 7, created_at: '2025-01-01T00:00:00Z', head: { sha: 'fork', repo: { id: 2 } } },
    { number: 8, created_at: '2025-01-02T00:00:00Z', head: { sha: 'deleted', repo: null } }
  ].map(pr => ({ draft: false, labels: [{ name: 'ready-to-merge' }], head: { sha: `sha${pr.number}`, repo: { id: 1 } }, created_at: `2026-01-${String(pr.number).padStart(2, '0')}T00:00:00Z`, base: { ref: 'dev', repo: { id: 1 } }, ...pr }));
  const github = {
    rest: {
      pulls: { list: 'pulls' },
      repos: {
        compareCommits: async args => {
          assert(!['fork', 'deleted'].includes(args.head), 'Skipped PRs receive no compare call');
          return { data: { behind_by: args.head === 'sha3' ? 0 : 1 } };
        },
        getCommit: async () => ({ data: { parents: [] } })
      },
      issues: {
        listComments: 'comments',
        createComment: async args => comments.push(args),
        removeLabel: async args => calls.push(['remove', args.issue_number])
      }
    },
    paginate: async (method) => method === 'pulls' ? [...prs].reverse() : comments,
    request: async (route, args) => {
      calls.push(['update', args.pull_number, args.expected_head_sha]);
      if (args.pull_number === 4) throw Object.assign(new Error('Merge conflict'), { status: 422 });
      if (args.pull_number === 5) throw Object.assign(new Error('Forbidden'), { status: 403 });
    }
  };
  const context = { repo: { owner: 'owner', repo: 'repo' }, eventName: 'push', ref: 'refs/heads/dev' };
  const logs = [];
  const core = { info(message) { logs.push(message); }, warning() {} };
  await run(github, context, core);
  assert.deepEqual(calls.map(c => c[1]), [4], 'Only the oldest behind PR is attempted, even on conflict');
  assert.equal(comments.length, 1);
  assert(comments.every(c => ![7, 8].includes(c.issue_number)));

  assert(logs.some(l => l.includes('PR #7: skipping')));
  assert(logs.some(l => l.includes('PR #8: skipping')));
  assert(comments[0].body.includes('Merge conflict'));
  await run(github, context, core);
  assert.equal(comments.length, 1, 'Failure comments repeat only for a new head');
  github.request = async (route, args) => calls.push(['update', args.pull_number, args.expected_head_sha]);
  await run(github, context, core);
  assert.deepEqual(calls.at(-1), ['update', 4, 'sha4'], 'Only the oldest behind PR updates on success');
  context.eventName = 'pull_request';
  context.payload = { before: 'old', pull_request: prs[5] };
  await run(github, context, core);
  assert.deepEqual(calls.at(-1), ['remove', 6]);
  github.rest.repos.getCommit = async () => ({ data: { parents: [{ sha: 'old' }, { sha: 'base' }] } });
  github.rest.repos.compareCommits = async () => ({ data: { status: 'ahead' } });
  const before = calls.length;
  await run(github, context, core);
  assert.equal(calls.length, before, 'Base merge retains readiness');
  for (const pr of prs.slice(6)) {
    context.payload.pull_request = pr;
    const noCalls = new Proxy({}, { get() { throw new Error('Skipped PR received an API call'); } });
    await run(noCalls, context, core);
  }
  assert.equal(calls.length, before, 'Skipped synchronize events never remove labels');
  assert.equal(comments.length, 1, 'Skipped PRs never receive comments');
  console.log('PASS: oldest behind selection, conflict stops, comment deduplication, and synchronize labels');
})().catch(error => { console.error(error); process.exitCode = 1; });
console.log('PASS: workflow YAML, permissions, guards, API safety, and copy parity');
JS
