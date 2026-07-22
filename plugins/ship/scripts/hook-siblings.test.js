'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const PLUGIN_ROOT = path.resolve(__dirname, '..');
const REPO_ROOT = path.resolve(PLUGIN_ROOT, '..', '..');
const SRC_HOOKS = path.join(REPO_ROOT, 'src', 'hooks');
const SKILLS_DIR = path.join(PLUGIN_ROOT, 'skills');

function shFiles(dir) {
  return fs
    .readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isFile() && e.name.endsWith('.sh'))
    .map((e) => e.name)
    .sort();
}

function skillHookDirs(dir, results = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const full = path.join(dir, entry.name);
    if (entry.name === 'hooks') {
      results.push(full);
    } else {
      skillHookDirs(full, results);
    }
  }
  return results;
}

test('every compiled skill that bundles a hook carries the full sibling set', () => {
  const expected = shFiles(SRC_HOOKS);
  assert.ok(expected.length > 0, 'src/hooks has no .sh files');

  const hookDirs = skillHookDirs(SKILLS_DIR);
  assert.ok(hookDirs.length > 0, 'no compiled skill bundles hooks — did the build run?');

  for (const dir of hookDirs) {
    const bundled = shFiles(dir);
    const missing = expected.filter((name) => !bundled.includes(name));
    assert.deepEqual(
      missing,
      [],
      `${path.relative(REPO_ROOT, dir)} is missing sibling hook(s): ${missing.join(', ')} — ` +
        'hooks resolve siblings via $HOOK_DIR at runtime, so a partial bundle ships a broken install'
    );
  }
});
