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

// A hook points the orchestrator at a pattern the same way it shells out to a
// sibling hook: `$HOOK_DIR/../patterns/<name>.md`. Bundling the hooks without
// those patterns ships paths that resolve to nothing, and the failure only
// surfaces when a run reaches the instruction that names one.
test('every hook-bundling skill also carries the patterns its hooks reference', () => {
  const pluginRoot = path.resolve(__dirname, '..');
  const srcHooks = path.resolve(pluginRoot, '..', '..', 'src', 'hooks');

  const referenced = new Set();
  for (const name of fs.readdirSync(srcHooks)) {
    if (!name.endsWith('.sh')) continue;
    const body = fs.readFileSync(path.join(srcHooks, name), 'utf8');
    for (const m of body.matchAll(/patterns\/([a-z0-9-]+\.md)/g)) referenced.add(m[1]);
  }
  assert.ok(referenced.size > 0, 'expected hooks to reference at least one pattern');

  const skillsDir = path.join(pluginRoot, 'skills');
  const bundlers = fs
    .readdirSync(skillsDir)
    .filter((s) => fs.existsSync(path.join(skillsDir, s, 'hooks')));
  assert.ok(bundlers.length > 0, 'expected at least one hook-bundling skill');

  for (const skill of bundlers) {
    for (const pattern of referenced) {
      const p = path.join(skillsDir, skill, 'patterns', pattern);
      assert.ok(fs.existsSync(p), `skills/${skill} bundles hooks but is missing patterns/${pattern}`);
    }
  }
});
