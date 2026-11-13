#!/usr/bin/env node
'use strict';
// Install the pinned CLI from the bundled release archive, then run
// `apexyard init`. This package never downloads code. The release workflow
// stamps the tag and the archive SHA-256 into package.json, the same values
// as the Homebrew formula (AgDR-0300).
const { spawnSync } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.join(__dirname, '..');
const pin = require(path.join(root, 'package.json')).apexyard || {};
const args = process.argv.slice(2);

function fail(message, status = 1) {
  console.error(`create-apexyard: ${message}`);
  process.exit(status);
}

function finish(result, label) {
  if (result.error) console.error(`create-apexyard: ${label}: ${result.error.message}`);
  else if (result.signal) console.error(`create-apexyard: ${label} stopped by ${result.signal}`);
  process.exit(result.status === null ? 1 : result.status);
}

// Read the bundled archive and refuse it unless it matches the stamped hash.
function verifiedArchive() {
  const tag = typeof pin.tag === 'string' ? pin.tag : '';
  const sha256 = typeof pin.sha256 === 'string' ? pin.sha256.toLowerCase() : '';
  if (!/^[0-9A-Za-z][0-9A-Za-z._-]*$/.test(tag) || !/^[0-9a-f]{64}$/.test(sha256)) {
    fail('this copy has no stamped release. Install a published version from npm.');
  }
  const archive = path.join(root, `apexyard-${tag}.tar.gz`);
  let data;
  try {
    data = fs.readFileSync(archive);
  } catch {
    fail(`the bundled archive is missing: ${path.basename(archive)}`);
  }
  const actual = crypto.createHash('sha256').update(data).digest('hex');
  if (actual !== sha256) fail('checksum mismatch. The bundled archive does not match the stamped SHA-256.');
  return { data, tag };
}

// Extract the verified bytes into dir. tar reads them from stdin, so it
// never reads the file again after the hash check.
// Return the path of the extracted release folder.
function extract(data, tag, dir) {
  const result = spawnSync('tar', ['-xzf', '-', '-C', dir], { input: data, stdio: ['pipe', 'inherit', 'inherit'] });
  if (result.error || result.status !== 0) finish(result, 'archive extraction failed');
  const release = path.join(dir, `apexyard-${tag}`);
  if (!fs.existsSync(path.join(release, 'bin', 'apexyard'))) fail('the CLI is missing from the archive.');
  return release;
}

const has = (...names) => args.some((arg) => names.includes(arg));

if (has('-h', '--help')) {
  console.log('Usage: npx create-apexyard [options]');
  console.log('Installs the pinned apexyard CLI, then runs apexyard init with these options.\n');
  const { data, tag } = verifiedArchive();
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'create-apexyard-'));
  let result;
  try {
    const release = extract(data, tag, work);
    result = spawnSync('bash', [path.join(release, 'bin', 'apexyard'), 'init', '--help'], { stdio: 'inherit' });
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
  finish(result, 'init');
}

// No terminal and no --yes: never ask and never guess (same rule as init, #2060).
if (!process.stdin.isTTY && !has('-y', '--yes', '-i', '--interactive')) {
  const missing = ['--org', '--name'].filter((flag) => !args.includes(flag));
  if (missing.length > 0) {
    fail(`no terminal, so it cannot ask. Missing flags: ${missing.join(' ')}. Pass each flag, or add --yes to accept the defaults.`, 2);
  }
}

const { data, tag } = verifiedArchive();
const prefix = path.resolve(process.env.APEXYARD_PREFIX || path.join(os.homedir(), '.local'));
const share = path.join(prefix, 'share', 'apexyard');
const dest = path.join(share, tag);
const cli = path.join(dest, 'bin', 'apexyard');
if (!fs.existsSync(cli)) {
  if (fs.existsSync(dest)) fail(`the install directory exists without the CLI: ${dest}. Remove it, then try again.`);
  fs.mkdirSync(share, { recursive: true });
  const work = fs.mkdtempSync(path.join(share, '.create-apexyard-'));
  try {
    fs.renameSync(extract(data, tag, work), dest);
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
  console.error(`create-apexyard: installed apexyard ${tag} in ${dest}`);
}

// Replace a symlink, as install.sh does. Never replace a regular file.
const link = path.join(prefix, 'bin', 'apexyard');
fs.mkdirSync(path.dirname(link), { recursive: true });
let current = null;
try {
  current = fs.lstatSync(link);
} catch {
  current = null;
}
if (current === null || current.isSymbolicLink()) {
  if (current !== null) fs.unlinkSync(link);
  fs.symlinkSync(cli, link);
} else {
  console.error(`create-apexyard: ${link} is not a symlink. It was not changed.`);
}

// Exit 1 is a warning (for example gh missing). Only exit 2 stops init.
const check = spawnSync('bash', [path.join(dest, '.claude', 'skills', 'preflight', 'preflight.sh'), '--dependencies'], { stdio: 'inherit' });
if (check.error || (check.status !== 0 && check.status !== 1)) finish(check, 'dependency check');

// Clone the framework at the release tag of this package, not at main.
// git clone fails when the tag is missing, and init then removes the folder.
// An explicit --ref from the caller wins.
const ref = args.includes('--ref') ? [] : ['--ref', tag];
const init = spawnSync('bash', [cli, 'init', ...ref, ...args], { stdio: 'inherit' });
const bin = path.join(prefix, 'bin');
if (!(process.env.PATH || '').split(path.delimiter).includes(bin)) {
  console.error(`create-apexyard: add this directory to PATH to run apexyard later: ${bin}`);
}
finish(init, 'init');
