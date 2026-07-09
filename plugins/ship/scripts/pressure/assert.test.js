'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { runAssertion, planSchema, noSpecIds, gateOutcome } = require('./assert');

const SLASH = String.fromCharCode(47);
const SCENARIO_PREFIX = String.fromCharCode(83, 67);
const ACCEPTANCE_CRITERION_PREFIX = String.fromCharCode(65, 67);

function mark(prefix, value) {
  return prefix + '-' + value;
}

function scenarioTag(value) {
  return '@' + mark(SCENARIO_PREFIX, value);
}

function makeRepDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ship-pressure-assert-'));
  fs.mkdirSync(path.join(dir, 'code'), { recursive: true });
  return dir;
}

function repArtifactsFor(dir) {
  return {
    planPath: path.join(dir, 'plan.md'),
    codeDir: path.join(dir, 'code'),
    phaseStatusPath: path.join(dir, 'phase-status.md'),
  };
}

function validPlan() {
  return [
    '## Module Map',
    '',
    '### M1: Example module',
    '- Files: src/a.js',
    '- Depends on: none',
    `- Scenarios: ${scenarioTag(1)}`,
    '',
    '## Test Contract',
    '',
    `### ${scenarioTag(1)} -> unit -> deve fazer algo`,
    '',
  ].join('\n');
}

function planWithOverlap() {
  return [
    '## Module Map',
    '',
    '### M1: Primeiro modulo',
    '- Files: src/shared.js',
    '- Depends on: none',
    `- Scenarios: ${scenarioTag(1)}`,
    '',
    '### M2: Segundo modulo',
    '- Files: src/shared.js',
    '- Depends on: none',
    `- Scenarios: ${scenarioTag(2)}`,
    '',
    '## Test Contract',
    '',
    `### ${scenarioTag(1)} -> unit -> deve fazer algo`,
    `### ${scenarioTag(2)} -> unit -> deve fazer outra coisa`,
    '',
  ].join('\n');
}

function planWithDependencyCycle() {
  return [
    '## Module Map',
    '',
    '### M1: Primeiro modulo',
    '- Files: src/a.js',
    '- Depends on: M2',
    `- Scenarios: ${scenarioTag(1)}`,
    '',
    '### M2: Segundo modulo',
    '- Files: src/b.js',
    '- Depends on: M1',
    `- Scenarios: ${scenarioTag(2)}`,
    '',
    '## Test Contract',
    '',
    `### ${scenarioTag(1)} -> unit -> deve fazer algo`,
    `### ${scenarioTag(2)} -> unit -> deve fazer outra coisa`,
    '',
  ].join('\n');
}

function planWithEmptyModuleMap() {
  return ['## Module Map', '', '## Test Contract', ''].join('\n');
}

function phaseStatusWithGate(gateValue) {
  return [
    '| Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |',
    '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |',
    `| security | 1 | 2026-07-09T00:00:00Z | 3 | ${gateValue} | 0 | 0 | 0 | 0 |  |`,
    '',
  ].join('\n');
}

test('plan.md valido passa em planSchema', () => {
  const dir = makeRepDir();
  try {
    const artifacts = repArtifactsFor(dir);
    fs.writeFileSync(artifacts.planPath, validPlan(), 'utf8');
    const result = planSchema(artifacts);
    assert.equal(result.pass, true);
    assert.equal(result.observed, 0);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('plan.md com sobreposicao de arquivos entre modulos falha em planSchema', () => {
  const dir = makeRepDir();
  try {
    const artifacts = repArtifactsFor(dir);
    fs.writeFileSync(artifacts.planPath, planWithOverlap(), 'utf8');
    const result = planSchema(artifacts);
    assert.equal(result.pass, false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('plan.md com ciclo de dependencia falha em planSchema', () => {
  const dir = makeRepDir();
  try {
    const artifacts = repArtifactsFor(dir);
    fs.writeFileSync(artifacts.planPath, planWithDependencyCycle(), 'utf8');
    const result = planSchema(artifacts);
    assert.equal(result.pass, false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('plan.md com module map vazio falha em planSchema', () => {
  const dir = makeRepDir();
  try {
    const artifacts = repArtifactsFor(dir);
    fs.writeFileSync(artifacts.planPath, planWithEmptyModuleMap(), 'utf8');
    const result = planSchema(artifacts);
    assert.equal(result.pass, false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('codigo limpo sem marcas proibidas passa em noSpecIds', () => {
  const dir = makeRepDir();
  try {
    const artifacts = repArtifactsFor(dir);
    fs.writeFileSync(path.join(artifacts.codeDir, 'clean.js'), 'function soma(a, b) {\n  return a + b;\n}\n', 'utf8');
    const result = noSpecIds(artifacts);
    assert.equal(result.pass, true);
    assert.deepEqual(result.observed, []);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test(`codigo contendo o token ${mark(ACCEPTANCE_CRITERION_PREFIX, '01')} falha em noSpecIds`, () => {
  const dir = makeRepDir();
  try {
    const artifacts = repArtifactsFor(dir);
    const fileContent = `const flag = '${mark(ACCEPTANCE_CRITERION_PREFIX, '01')}';\n`;
    fs.writeFileSync(path.join(artifacts.codeDir, 'marked.js'), fileContent, 'utf8');
    const result = noSpecIds(artifacts);
    assert.equal(result.pass, false);
    assert.equal(result.observed.length > 0, true);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test(`codigo contendo o token ${mark(SCENARIO_PREFIX, '12')} falha em noSpecIds`, () => {
  const dir = makeRepDir();
  try {
    const artifacts = repArtifactsFor(dir);
    const fileContent = `const flag = '${mark(SCENARIO_PREFIX, '12')}';\n`;
    fs.writeFileSync(path.join(artifacts.codeDir, 'marked.js'), fileContent, 'utf8');
    const result = noSpecIds(artifacts);
    assert.equal(result.pass, false);
    assert.equal(result.observed.length > 0, true);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('codigo contendo um comentario inline falha em noSpecIds', () => {
  const dir = makeRepDir();
  try {
    const artifacts = repArtifactsFor(dir);
    const inlineComment = SLASH + SLASH + ' comentario proibido';
    const fileContent = `const x = 1; ${inlineComment}\n`;
    fs.writeFileSync(path.join(artifacts.codeDir, 'commented.js'), fileContent, 'utf8');
    const result = noSpecIds(artifacts);
    assert.equal(result.pass, false);
    assert.equal(result.observed.length > 0, true);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('gate observado igual ao esperado passa em gateOutcome', () => {
  const dir = makeRepDir();
  try {
    const artifacts = repArtifactsFor(dir);
    fs.writeFileSync(artifacts.phaseStatusPath, phaseStatusWithGate('pass'), 'utf8');
    const result = gateOutcome(artifacts, { expectedGate: 'PASS' });
    assert.equal(result.pass, true);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('gate observado warn com esperado PASS falha em gateOutcome', () => {
  const dir = makeRepDir();
  try {
    const artifacts = repArtifactsFor(dir);
    fs.writeFileSync(artifacts.phaseStatusPath, phaseStatusWithGate('warn'), 'utf8');
    const result = gateOutcome(artifacts, { expectedGate: 'PASS' });
    assert.equal(result.pass, false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('gate observado fail com esperado WARN falha em gateOutcome', () => {
  const dir = makeRepDir();
  try {
    const artifacts = repArtifactsFor(dir);
    fs.writeFileSync(artifacts.phaseStatusPath, phaseStatusWithGate('fail'), 'utf8');
    const result = gateOutcome(artifacts, { expectedGate: 'WARN' });
    assert.equal(result.pass, false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('o resultado de qualquer assertion expoe exatamente as chaves assertion, pass, observed e expected', () => {
  const dir = makeRepDir();
  try {
    const artifacts = repArtifactsFor(dir);
    fs.writeFileSync(artifacts.planPath, validPlan(), 'utf8');
    fs.writeFileSync(path.join(artifacts.codeDir, 'clean.js'), 'function soma(a, b) {\n  return a + b;\n}\n', 'utf8');
    fs.writeFileSync(artifacts.phaseStatusPath, phaseStatusWithGate('pass'), 'utf8');

    const results = [
      runAssertion('planSchema', artifacts, {}),
      runAssertion('noSpecIds', artifacts, {}),
      runAssertion('gateOutcome', artifacts, { expectedGate: 'PASS' }),
    ];

    for (const result of results) {
      assert.deepEqual(Object.keys(result).sort(), ['assertion', 'expected', 'observed', 'pass'].sort());
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('runAssertion lanca erro para um nome de assertion desconhecido', () => {
  const dir = makeRepDir();
  try {
    const artifacts = repArtifactsFor(dir);
    assert.throws(() => runAssertion('unknownAssertion', artifacts, {}));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
