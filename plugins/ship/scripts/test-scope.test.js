'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const SCOPE = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'test-scope.sh');

function run(config) {
  return spawnSync('bash', [SCOPE, '--config', config], { encoding: 'utf8' });
}

function parse(stdout) {
  const out = {};
  for (const line of stdout.split('\n')) {
    const i = line.indexOf('=');
    if (i > 0) out[line.slice(0, i)] = line.slice(i + 1);
  }
  return out;
}

function writeConfig(body) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'test-scope-'));
  const p = path.join(dir, 'config.md');
  fs.writeFileSync(p, body);
  return p;
}

test('missing config defaults every layer to enabled', () => {
  const o = parse(run('/nonexistent').stdout);
  assert.equal(o.run, 'unit integration e2e');
  assert.equal(o.skip, '');
});

test('config with no Test Scope section defaults every layer to enabled', () => {
  const config = writeConfig('## Stack\n- Runtime: Node 20\n');
  const o = parse(run(config).stdout);
  assert.equal(o.run, 'unit integration e2e');
  assert.equal(o.skip, '');
});

test('a layer disabled in Test Scope is excluded from run=', () => {
  const config = writeConfig([
    '## Test Scope',
    '- unit: enabled',
    '- integration: disabled',
    '- e2e: disabled',
  ].join('\n'));
  const o = parse(run(config).stdout);
  assert.equal(o.run, 'unit');
  assert.equal(o.skip, 'integration e2e');
});

test('a layer with no explicit entry in an otherwise-present Test Scope section defaults to enabled', () => {
  const config = writeConfig([
    '## Test Scope',
    '- integration: disabled',
  ].join('\n'));
  const o = parse(run(config).stdout);
  assert.equal(o.run, 'unit e2e');
  assert.equal(o.skip, 'integration');
});

test('all layers disabled yields an empty run= and full skip=', () => {
  const config = writeConfig([
    '## Test Scope',
    '- unit: disabled',
    '- integration: disabled',
    '- e2e: disabled',
  ].join('\n'));
  const o = parse(run(config).stdout);
  assert.equal(o.run, '');
  assert.equal(o.skip, 'unit integration e2e');
});
