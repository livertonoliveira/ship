'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SKILLS_DIR = path.resolve(__dirname, '..', 'skills');

function split(file) {
  const raw = fs.readFileSync(path.join(SKILLS_DIR, file), 'utf8');
  const m = raw.match(/^---\n([\s\S]*?)\n---\n/);
  return { front: m[1], body: raw.slice(m[0].length) };
}

test('ship:pr-node ships the exact body of ship:pr, so the two flows never drift', () => {
  assert.equal(split('pr-node/SKILL.md').body, split('pr/SKILL.md').body);
});

test('ship:pr-node forks and waits, ship:pr stays inline for the interactive flow', () => {
  const node = split('pr-node/SKILL.md').front;
  const pr = split('pr/SKILL.md').front;
  assert.match(node, /^context: fork$/m);
  assert.match(node, /^background: false$/m);
  assert.match(node, /^user-invocable: false$/m);
  assert.doesNotMatch(pr, /^context: fork$/m);
});

test('ship:pr-node bundles the same hooks as ship:pr', () => {
  const hooks = (dir) => fs.readdirSync(path.join(SKILLS_DIR, dir, 'hooks')).sort();
  assert.deepEqual(hooks('pr-node'), hooks('pr'));
});
