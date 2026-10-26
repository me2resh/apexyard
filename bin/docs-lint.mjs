#!/usr/bin/env node
// Check document text with the shared rules.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Word boundaries that keep "just" out of "adjust" and "just-in-time".
function wordRegex(term) {
  const pre = /^[\w']/.test(term) ? "(?<![\\w'-])" : '';
  const post = /[\w']$/.test(term) ? "(?![\\w'-])" : '';
  return new RegExp(pre + esc(term).replace(/\s+/g, '\\s+') + post, 'gi');
}

export function compileRules(raw) {
  for (const key of ['sentenceLength', 'passive', 'banned', 'emDash']) {
    if (!raw[key]) throw new Error(`the rules file has no "${key}" key`);
  }
  const p = raw.passive;
  const aux = p.auxiliaries.map(esc).join('|');
  const adv = p.adverbs.map(esc).join('|');
  const irregular = p.irregular.map(esc).join('|');
  const minStem = Math.max(1, (p.regularMinLength || 4) - p.regularSuffix.length);
  const passive = new RegExp(`\\b(?:${aux})\\s+(?:(?:${adv})\\s+)?((?:[A-Za-z]{${minStem},}${esc(p.regularSuffix)})|(?:${irregular}))(?![\\w'-])`, 'gi');
  return {
    stepMax: raw.sentenceLength.step,
    descMax: raw.sentenceLength.description,
    passive,
    passiveExclude: new Set(p.regularExclude.map((w) => w.toLowerCase())),
    approved: ((raw.approved && raw.approved.terms) || []).map(wordRegex),
    banned: raw.banned.entries.map(([kind, term, use]) => ({ kind, term, use, re: wordRegex(term) })),
    emDash: raw.emDash.characters.map((c) => ({ c, re: new RegExp(esc(c), 'g') })),
    emDashUse: raw.emDash.use,
  };
}

// ---------------------------------------------------------------- markdown

const FENCE = /^\s{0,3}(`{3,}|~{3,})/;

function fenceMask(lines) {
  const mask = new Array(lines.length).fill(false);
  let open = null;
  lines.forEach((line, i) => {
    if (open) {
      mask[i] = true;
      const close = line.match(/^\s{0,3}(`{3,}|~{3,})\s*$/);
      if (close && close[1][0] === open[0] && close[1].length >= open.length) open = null;
    } else {
      const m = line.match(FENCE);
      if (m) {
        mask[i] = true;
        open = m[1];
      }
    }
  });
  return mask;
}

// Remove Markdown and HTML syntax, and keep the words a reader sees.
export function cleanInline(s) {
  return s
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/`+[^`]*`+/g, 'CODE')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\[([^\]]*)\]\[[^\]]*\]/g, '$1')
    .replace(/<https?:[^>]*>/g, 'URL')
    .replace(/https?:\/\/\S+/g, 'URL')
    .replace(/<[^>]+>/g, '')
    .replace(/\\([|*_`#[\]()])/g, '$1')
    .replace(/\*\*|__|\*/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

const STEP = /^\s*\d+[.)]\s+/;
const BULLET = /^\s*[-*+]\s+(?:\[[ xX]\]\s+)?/;

// Split a Markdown file into text segments. Each segment is one heading, one
// table cell, one list item or one paragraph, with the line of each part.
export function segments(text) {
  const lines = text.split('\n');
  const mask = fenceMask(lines);
  const out = [];
  let cur = null;
  const close = () => (cur = null);
  const push = (kind, line, t) => {
    const s = cleanInline(t);
    cur = { kind, parts: [] };
    out.push(cur);
    if (s) cur.parts.push({ line, text: s });
  };

  let start = 0;
  if (lines[0] === '---') {
    const end = lines.indexOf('---', 1);
    if (end > 0) {
      for (let i = 1; i < end; i++) {
        const m = lines[i].match(/^(title|description):\s*(.*)$/);
        if (!m) continue;
        let v = m[2].trim();
        try {
          if (v.startsWith('"')) v = JSON.parse(v);
        } catch {
          // Keep the raw value.
        }
        v = v.replace(/^'(.*)'$/, '$1');
        push(m[1] === 'title' ? 'title' : 'text', i + 1, v);
        close();
      }
      start = end + 1;
    }
  }

  for (let i = start; i < lines.length; i++) {
    let line = lines[i];
    const n = i + 1;
    if (mask[i]) {
      close();
      continue;
    }
    line = line.replace(/^(\s*>)+\s?/, '');
    if (!line.trim() || /^\s*</.test(line) || /^\s*(\*\s*){3,}$|^\s*(-\s*){3,}$/.test(line)) {
      close();
      continue;
    }
    if (/^\s*#{1,6}\s/.test(line)) {
      push('title', n, line.replace(/^\s*#{1,6}\s+/, '').replace(/\s#+\s*$/, ''));
      close();
      continue;
    }
    if (/^\s*\|/.test(line)) {
      close();
      if (/^\s*\|?\s*:?-{2,}/.test(line)) continue;
      const cells = line.trim().replace(/^\||\|$/g, '').split(/(?<!\\)\|/);
      for (const c of cells) {
        push('text', n, c);
        close();
      }
      continue;
    }
    if (STEP.test(line)) {
      push('step', n, line.replace(STEP, ''));
      continue;
    }
    if (BULLET.test(line)) {
      push('text', n, line.replace(BULLET, ''));
      continue;
    }
    if (cur) {
      const s = cleanInline(line);
      if (s) cur.parts.push({ line: n, text: s });
    } else push('text', n, line);
  }
  return out.filter((s) => s.parts.length);
}

// ---------------------------------------------------------------- checks

const ABBREV = /\b(e\.g|i\.e|vs|etc|cf|approx)\./gi;

function joinParts(seg) {
  let text = '';
  const starts = [];
  for (const p of seg.parts) {
    if (text) text += ' ';
    starts.push({ at: text.length, line: p.line });
    text += p.text;
  }
  const lineAt = (off) => {
    let line = starts[0].line;
    for (const s of starts) if (s.at <= off) line = s.line;
    return line;
  };
  return { text, lineAt };
}

export function sentences(text) {
  const masked = text.replace(ABBREV, (m) => m.slice(0, -1) + '\u0000');
  const out = [];
  let at = 0;
  // Split at a period, ! or ? that a space or the end follows.
  const ends = [];
  for (let i = 0; i < masked.length; i++) {
    if (/[.!?]/.test(masked[i]) && (i + 1 === masked.length || /\s/.test(masked[i + 1]))) ends.push(i + 1);
  }
  for (const e of ends) {
    out.push({ at, text: text.slice(at, e) });
    at = e;
  }
  if (at < text.length) out.push({ at, text: text.slice(at) });
  return out.filter((s) => s.text.trim());
}

const WORD = /[A-Za-z0-9][A-Za-z0-9'_./-]*/g;
export const countWords = (s) => (s.match(WORD) || []).length;

function overlapsApproved(rules, text, start, end) {
  for (const re of rules.approved) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(text))) {
      if (m.index < end && m.index + m[0].length > start) return true;
    }
  }
  return false;
}

export function lintText(text, rules) {
  const findings = [];
  for (const seg of segments(text)) {
    const { text: t, lineAt } = joinParts(seg);
    if (seg.kind !== 'title') {
      const max = seg.kind === 'step' ? rules.stepMax : rules.descMax;
      const rule = seg.kind === 'step' ? 'sentence-length-step' : 'sentence-length';
      for (const s of sentences(t)) {
        const n = countWords(s.text);
        if (n > max) {
          const off = s.at + (s.text.length - s.text.trimStart().length);
          findings.push({ line: lineAt(off), rule, detail: `${n} words (max ${max}): "${s.text.trim().slice(0, 60)}..."` });
        }
      }
    }
    rules.passive.lastIndex = 0;
    let m;
    while ((m = rules.passive.exec(t))) {
      const part = m[1].toLowerCase();
      if (rules.passiveExclude.has(part) || part.endsWith('eed')) continue;
      if (overlapsApproved(rules, t, m.index, m.index + m[0].length)) continue;
      findings.push({ line: lineAt(m.index), rule: 'passive-voice', detail: `"${m[0]}"` });
    }
    for (const b of rules.banned) {
      b.re.lastIndex = 0;
      while ((m = b.re.exec(t))) {
        if (overlapsApproved(rules, t, m.index, m.index + m[0].length)) continue;
        findings.push({ line: lineAt(m.index), rule: 'banned-word', detail: `${b.kind} "${m[0]}", use: ${b.use}` });
      }
    }
    for (const d of rules.emDash) {
      d.re.lastIndex = 0;
      while ((m = d.re.exec(t))) findings.push({ line: lineAt(m.index), rule: 'em-dash', detail: `use ${rules.emDashUse}` });
    }
  }
  return findings.sort((a, b) => a.line - b.line);
}

// Match the ownership manifest glob syntax.
export function globRegex(glob) {
  let re = '^';
  for (let i = 0; i < glob.length; i++) {
    if (glob.slice(i, i + 4) === '/**/') { re += '/(?:.*/)?'; i += 3; }
    else if (i === 0 && glob.startsWith('**/')) { re += '(?:.*/)?'; i += 2; }
    else if (glob.slice(i) === '/**') { re += '/.+'; i += 2; }
    else if (glob.slice(i, i + 2) === '**') { re += '.*'; i++; }
    else if (glob[i] === '*') re += '[^/]*';
    else if (glob[i] === '?') re += '[^/]';
    else re += esc(glob[i]);
  }
  return new RegExp(re + '$');
}

export function parseChanged(text) {
  const map = new Map();
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const m = line.match(/^(.*):(\d+)(?:-(\d+))?$/);
    if (!m || !m[1] || +m[2] < 1 || +(m[3] || m[2]) < +m[2]) {
      throw new Error('Use path:line or path:start-end in the changed file.');
    }
    const file = m[1].replace(/^(\.\/)+/, '');
    if (!map.has(file)) map.set(file, []);
    map.get(file).push([+m[2], +(m[3] || m[2])]);
  }
  return map;
}

export function parseDiff(text) {
  const map = new Map();
  let file;
  for (const line of text.split('\n')) {
    if (line.startsWith('+++ b/')) {
      file = line.slice(6);
      if (!map.has(file)) map.set(file, []);
    } else if (line.startsWith('+++ ')) file = null;
    const h = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/);
    if (h && file) {
      const count = h[2] === undefined ? 1 : +h[2];
      if (count) map.get(file).push([+h[1], +h[1] + count - 1]);
    }
  }
  return map;
}

export function frontmatterText(text) {
  const lines = text.split('\n');
  const end = lines[0] === '---' ? lines.indexOf('---', 1) : -1;
  return end > 0 ? lines.slice(0, end + 1).join('\n') : '';
}

export function parseArgs(argv) {
  const opts = { root: path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..'), files: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (['--root', '--rules', '--scope', '--base', '--changed'].includes(a)) {
      if (!argv[i + 1] || argv[i + 1].startsWith('--')) throw new Error(`${a} needs a value.`);
      opts[a.slice(2)] = argv[++i];
    } else if (a === '--strict' || a === '--summary') opts[a.slice(2)] = true;
    else if (a.startsWith('-')) throw new Error(`Unknown option ${a}.`);
    else opts.files.push(a);
  }
  opts.root = path.resolve(opts.root);
  if (opts.base && opts.changed) throw new Error('Use --base or --changed, not both.');
  if (opts.strict && !opts.base && !opts.changed) throw new Error('--strict needs --base or --changed.');
  return opts;
}

export function main(argv = process.argv.slice(2)) {
  const opts = parseArgs(argv);
  const read = (file) => fs.readFileSync(file, 'utf8');
  const raw = JSON.parse(read(opts.rules || path.join(opts.root, 'docs/docs-lint-rules.json')));
  if (raw.version !== 1) throw new Error('Use rules version 1.');
  const rules = compileRules(raw);
  const scope = JSON.parse(read(opts.scope || path.join(opts.root, 'docs/docs-lint-scope.json')));
  if (scope.version !== 1 || !Array.isArray(scope.include) || !Array.isArray(scope.exclude)) {
    throw new Error('Use scope version 1 with include and exclude lists.');
  }
  const includes = scope.include.map((entry) => ({ ...entry, re: globRegex(entry.glob) }));
  const excludes = scope.exclude.map(globRegex);
  const git = (args) => execFileSync('git', ['-c', 'core.quotePath=false', '-C', opts.root, ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const tracked = git(['ls-files', '-z']).split('\0').filter(Boolean);
  const selected = new Map();
  for (const file of tracked) {
    const entry = includes.find((e) => e.re.test(file));
    if (entry && !excludes.some((re) => re.test(file))) selected.set(file, entry);
  }
  let files = [...selected.keys()];
  if (opts.files.length) {
    files = [...new Set(opts.files.map((file) => path.relative(opts.root, path.resolve(opts.root, file))))];
    for (const file of files) {
      if (!fs.statSync(path.join(opts.root, file)).isFile()) throw new Error(`Cannot read ${file}.`);
    }
    files = files.filter((file) => {
      const entry = includes.find((e) => e.re.test(file));
      if (!entry || excludes.some((re) => re.test(file))) return false;
      selected.set(file, entry);
      return true;
    });
  }
  let changed = null;
  if (opts.changed) changed = parseChanged(read(opts.changed));
  if (opts.base) {
    if (opts.base.startsWith('-')) throw new Error('Use a valid base reference.');
    changed = files.length ? parseDiff(git(['diff', '-U0', '--no-color', '--no-ext-diff', '--no-renames', `${opts.base}...HEAD`, '--', ...files])) : new Map();
  }
  const byRule = {};
  const byFile = {};
  let total = 0;
  let unchanged = 0;
  for (const file of files) {
    let text = read(path.join(opts.root, file));
    if (selected.get(file).frontmatterOnly) text = frontmatterText(text);
    for (const f of lintText(text, rules)) {
      if (changed && !(changed.get(file) || []).some(([a, b]) => f.line >= a && f.line <= b)) {
        unchanged++;
        continue;
      }
      total++;
      byRule[f.rule] = (byRule[f.rule] || 0) + 1;
      byFile[file] = (byFile[file] || 0) + 1;
      if (!opts.summary) console.log(`${file}:${f.line}: ${f.rule}: ${f.detail}`);
    }
  }
  console.log('Counts by rule:');
  for (const [rule, n] of Object.entries(byRule).sort()) console.log(`  ${rule}: ${n}`);
  console.log(opts.summary ? 'Counts by file (top 10):' : 'Counts by file:');
  const counts = Object.entries(byFile).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  for (const [file, n] of opts.summary ? counts.slice(0, 10) : counts) console.log(`  ${file}: ${n}`);
  console.log(`Total: ${total} findings`);
  if (changed) console.log(`${unchanged} findings on unchanged lines, not checked`);
  console.log(`Mode: ${opts.strict ? 'strict' : 'report only'}, ${changed ? 'changed lines' : 'all selected lines'}`);
  return opts.strict && total ? 1 : 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.exitCode = main(); }
  catch (error) { console.error(`docs-lint: ${error.message}`); process.exitCode = 2; }
}
