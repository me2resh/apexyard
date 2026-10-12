#!/bin/bash
# Execute the workflow script with mocked GitHub responses; no network.
set -eu
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
node - "$ROOT/.github/workflows/pr-title-check.yml" <<'JS'
const fs = require('fs');
const assert = require('assert');
const source = fs.readFileSync(process.argv[2], 'utf8').split('          script: |\n')[1]
  .split('\n      - name:')[0].split('\n').map(line => line.slice(12)).join('\n');
const run = new Function('context', 'github', 'core', `return (async () => {${source}})()`);
async function check(label, overrides, expected) {
  const options = { branch: 'orbit/demo-widget-cycle', title: 'docs(orbit/demo-widget): records',
    body: 'Initiative: plan-demo-widget', ids: ['plan-demo', 'plan-demo-widget'], outside: false, ...overrides };
  let failed = false;
  const context = { repo: { owner: 'test', repo: 'test' }, payload: { pull_request: {
    number: 1, title: options.title, body: options.body,
    head: { ref: options.branch, sha: 'head-sha', repo: { owner: { login: 'test' }, name: 'test' } }
  } } };
  const github = { rest: { pulls: { listFiles() {} }, repos: { getContent: async params => {
    assert.equal(params.ref, 'head-sha');
    return { data: params.path === 'docs/orbit/plans' ? options.ids.map((id, i) =>
      ({ type: 'file', name: `${i}.json`, path: `${i}.json` })) :
      { content: Buffer.from(JSON.stringify({ id: options.ids[Number(params.path.split('.')[0])] })).toString('base64') } };
  } } }, paginate: async () => [{ filename: options.outside ? 'src/app.sh' : 'docs/orbit/plans/demo.json' }] };
  await run(context, github, { setFailed() { failed = true; }, setOutput() {} });
  assert.equal(!failed, expected, label);
  console.log(`PASS ${label}`);
}
(async () => {
  await check('matching initiative and longest prefix', {}, true);
  await check('shorter title ID', { title: 'docs(orbit/demo): records' }, false);
  await check('unknown initiative', { ids: ['plan-other'] }, false);
  await check('missing Initiative', { body: 'Refs #1' }, false);
  await check('wrong Initiative', { body: 'Initiative: plan-other' }, false);
  await check('outside records', { outside: true }, false);
  await check('legacy title', { title: 'docs(orbit): records' }, false);
})().catch(error => { console.error(error); process.exitCode = 1; });
JS
