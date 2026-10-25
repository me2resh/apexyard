#!/usr/bin/env node
'use strict';
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const os = require('node:os');
const args = process.argv.slice(2);
function run(command, argv) {
  return spawnSync(command, argv, { stdio: 'inherit' });
}
function finish(result, label) {
  if (result.error) console.error(`create-apexyard: ${label}: ${result.error.message}`);
  else if (result.signal) console.error(`create-apexyard: ${label} stopped by ${result.signal}`);
  process.exit(result.status === null ? 1 : result.status);
}
let result = run('apexyard', ['init', ...args]);
if (!result.error || result.error.code !== 'ENOENT') finish(result, 'init');
console.error('create-apexyard: Install the CLI before repository creation.');
const installer = path.join(__dirname, '..', 'install.sh');
result = run('sh', [installer]); // The installer prints its plan and needs no prompt.
if (result.error || result.status !== 0) finish(result, 'CLI installation failed. Set APEXYARD_VERSION if required');
const prefix = process.env.APEXYARD_PREFIX || path.join(os.homedir(), '.local');
finish(run(path.resolve(prefix, 'bin', 'apexyard'), ['init', ...args]), 'init');
