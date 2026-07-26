'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { RUN_FOOTPRINT_FILES } = require('./run-footprint');
const { RUN_FOOTPRINT_BUDGET } = require('./budgets');

const SCRIPT_PATH = path.join(__dirname, 'run-footprint.js');

function makeFixtureRoot(wordsPerFile) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'run-footprint-'));
  const words = Array.from({ length: wordsPerFile }, (_, i) => `word${i}`).join(' ');
  for (const relPath of RUN_FOOTPRINT_FILES) {
    const absPath = path.join(root, relPath);
    fs.mkdirSync(path.dirname(absPath), { recursive: true });
    fs.writeFileSync(absPath, words, 'utf8');
  }
  return root;
}

function runScript(pluginRoot) {
  try {
    const stdout = execFileSync('node', [SCRIPT_PATH], {
      env: { ...process.env, RUN_FOOTPRINT_PLUGIN_ROOT: pluginRoot },
      encoding: 'utf8',
    });
    return { code: 0, stdout, stderr: '' };
  } catch (err) {
    return {
      code: err.status,
      stdout: err.stdout ? err.stdout.toString() : '',
      stderr: err.stderr ? err.stderr.toString() : '',
    };
  }
}

test('footprint lists every group with its files, totals and ceiling', () => {
  const stdout = execFileSync('node', [SCRIPT_PATH], { encoding: 'utf8' });
  const lines = stdout.trim().split('\n');
  for (const relPath of RUN_FOOTPRINT_FILES) {
    assert.ok(lines.some((line) => line.includes(relPath)), `expected output to list ${relPath}`);
  }
  // Three groups now, not one: spec and audit were previously bounded by no
  // aggregate at all, so raising the per-file ceiling would have left them
  // guarded by nothing.
  for (const group of ['run', 'spec', 'audit']) {
    assert.ok(lines.some((l) => l.trim() === `[${group}]`), `expected a [${group}] section`);
  }
  const totals = lines.filter((l) => l.startsWith('Total: '));
  assert.equal(totals.length, 3);
  assert.match(totals[0], new RegExp(`Total: \\d+ / ${RUN_FOOTPRINT_BUDGET}`));
});

test('a total above the ceiling fails with exit code 1 and the message reports the total, the ceiling and the overage', () => {
  const wordsPerFile = Math.ceil((RUN_FOOTPRINT_BUDGET + 1000) / RUN_FOOTPRINT_FILES.length);
  const root = makeFixtureRoot(wordsPerFile);
  const result = runScript(root);
  assert.equal(result.code, 1);
  assert.match(result.stderr, new RegExp(`excede o teto de ${RUN_FOOTPRINT_BUDGET}`));
  assert.match(result.stderr, /em \d+ palavras/);
});

test('a lazy file bundled alongside a skill and not referenced on the happy path does not change the total', () => {
  const root = makeFixtureRoot(10);
  const before = runScript(root);

  const lazyPath = path.join(root, 'skills', 'audit:frontend', 'methodology-nextjs.md');
  fs.mkdirSync(path.dirname(lazyPath), { recursive: true });
  fs.writeFileSync(lazyPath, 'lazy '.repeat(5000), 'utf8');

  const after = runScript(root);
  assert.equal(before.stdout, after.stdout);
});
