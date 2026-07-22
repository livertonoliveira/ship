'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const PLUGIN_ROOT = path.resolve(__dirname, '..');
const HOOK_SIBLING_REF = /\$HOOK_DIR\/([A-Za-z0-9_-]+\.sh)/g;

function findHookScripts(dir, results = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      findHookScripts(full, results);
    } else if (entry.name.endsWith('.sh')) {
      results.push(full);
    }
  }
  return results;
}

test('every bundled hook has its HOOK_DIR siblings alongside it', () => {
  const scripts = findHookScripts(path.join(PLUGIN_ROOT, 'skills'))
    .concat(findHookScripts(path.join(PLUGIN_ROOT, 'hooks')));

  const missing = [];
  for (const script of scripts) {
    const content = fs.readFileSync(script, 'utf8');
    const dir = path.dirname(script);
    for (const [, name] of content.matchAll(HOOK_SIBLING_REF)) {
      if (!fs.existsSync(path.join(dir, name))) {
        missing.push(`${path.relative(PLUGIN_ROOT, script)} -> $HOOK_DIR/${name}`);
      }
    }
  }

  assert.deepEqual(missing, [], `bundled hooks reference siblings that are not bundled:\n${missing.join('\n')}`);
});

test('pipeline required hooks are bundled wherever pipeline is bundled', () => {
  const required = fs.readFileSync(path.join(PLUGIN_ROOT, 'hooks', 'pipeline.sh'), 'utf8')
    .match(/REQUIRED_HOOKS="([^"]+)"/)[1]
    .trim()
    .split(/\s+/);
  assert.ok(required.length > 0, 'expected pipeline.sh to declare REQUIRED_HOOKS');

  const pipelines = findHookScripts(path.join(PLUGIN_ROOT, 'skills'))
    .filter((p) => path.basename(p) === 'pipeline.sh');
  assert.ok(pipelines.length > 0, 'expected at least one skill to bundle pipeline.sh');

  for (const pipeline of pipelines) {
    const dir = path.dirname(pipeline);
    for (const hook of required) {
      assert.ok(
        fs.existsSync(path.join(dir, hook)),
        `${path.relative(PLUGIN_ROOT, dir)} bundles pipeline.sh but is missing required hook ${hook}`,
      );
    }
  }
});
