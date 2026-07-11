'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

function readTestScript() {
  const packageJsonPath = path.join(__dirname, '..', 'package.json');
  const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
  return packageJson.scripts.test;
}

test('o script test inclui os testes de scripts/pressure', () => {
  const testScript = readTestScript();
  assert.match(testScript, /scripts\/pressure\/\*\.test\.js/);
});

test('o script test não depende de expansão bare "**"', () => {
  const testScript = readTestScript();
  const segments = testScript.split(/\s+/);
  assert.ok(!segments.includes('**'));
});
