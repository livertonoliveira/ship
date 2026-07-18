'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { loadCase, listReps, repArtifacts } = require('./cases');

function makeCaseDir(caseJson) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ship-pressure-case-'));
  if (caseJson !== undefined) {
    fs.writeFileSync(path.join(dir, 'case.json'), JSON.stringify(caseJson), 'utf8');
  }
  return dir;
}

function baseCase(overrides = {}) {
  return {
    skill: 'audit/backend',
    input: 'input.md',
    arms: { treatment: {}, control: {} },
    assertions: ['planSchema', 'noSpecIds', 'gateOutcome'],
    reps: 3,
    expectedGate: 'PASS',
    ...overrides,
  };
}

test('loadCase carrega e normaliza um case.json bem-formado', () => {
  const dir = makeCaseDir(baseCase());
  try {
    const result = loadCase(dir);
    assert.equal(result.skill, 'audit/backend');
    assert.equal(result.input, 'input.md');
    assert.deepEqual(result.arms, { treatment: {}, control: {} });
    assert.deepEqual(result.assertions, ['planSchema', 'noSpecIds', 'gateOutcome']);
    assert.equal(result.reps, 3);
    assert.equal(result.expectedGate, 'PASS');
    assert.equal(result.caseDir, path.resolve(dir));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('loadCase lança erro mencionando "skill" quando o campo está ausente', () => {
  const caseJson = baseCase();
  delete caseJson.skill;
  const dir = makeCaseDir(caseJson);
  try {
    assert.throws(() => loadCase(dir), /skill/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('loadCase lança erro mencionando "control" quando apenas treatment está presente', () => {
  const caseJson = baseCase({ arms: { treatment: {} } });
  const dir = makeCaseDir(caseJson);
  try {
    assert.throws(() => loadCase(dir), /control/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('loadCase lança erro mencionando "reps" quando o campo está ausente', () => {
  const caseJson = baseCase();
  delete caseJson.reps;
  const dir = makeCaseDir(caseJson);
  try {
    assert.throws(() => loadCase(dir), /reps/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('loadCase lança erro mencionando "assertions" quando há um nome de assertion desconhecido', () => {
  const caseJson = baseCase({ assertions: ['planSchema', 'unknownAssertion'] });
  const dir = makeCaseDir(caseJson);
  try {
    assert.throws(() => loadCase(dir), /assertions/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('loadCase carrega gateFixture, expectedDecision e expectedAction quando gateSemantics esta presente', () => {
  const caseJson = baseCase({
    assertions: ['gateSemantics'],
    gateFixture: {
      rows: [{ phase: 'security', critical: 0, high: 1, medium: 0, low: 0 }],
      config: { onFail: 'ask', onWarn: 'ask' },
    },
    expectedDecision: 'FAIL',
    expectedAction: 'ask',
  });
  const dir = makeCaseDir(caseJson);
  try {
    const result = loadCase(dir);
    assert.deepEqual(result.gateFixture, caseJson.gateFixture);
    assert.equal(result.expectedDecision, 'FAIL');
    assert.equal(result.expectedAction, 'ask');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('loadCase aceita expectedAction "defer" e "pass" como valores validos do contrato de gate', () => {
  const deferCase = baseCase({
    assertions: ['gateSemantics'],
    gateFixture: {
      rows: [{ phase: 'security', critical: 0, high: 1, medium: 0, low: 0 }],
      config: { onFail: 'defer', onWarn: 'ask' },
    },
    expectedDecision: 'FAIL',
    expectedAction: 'defer',
  });
  const deferDir = makeCaseDir(deferCase);
  const passCase = baseCase({
    assertions: ['gateSemantics'],
    gateFixture: {
      rows: [{ phase: 'perf', critical: 0, high: 0, medium: 1, low: 0 }],
      config: { onFail: 'ask', onWarn: 'pass' },
    },
    expectedDecision: 'WARN',
    expectedAction: 'pass',
  });
  const passDir = makeCaseDir(passCase);
  try {
    assert.equal(loadCase(deferDir).expectedAction, 'defer');
    assert.equal(loadCase(passDir).expectedAction, 'pass');
  } finally {
    fs.rmSync(deferDir, { recursive: true, force: true });
    fs.rmSync(passDir, { recursive: true, force: true });
  }
});

test('loadCase lança erro mencionando "gateFixture" quando gateSemantics esta presente sem o campo', () => {
  const caseJson = baseCase({
    assertions: ['gateSemantics'],
    expectedDecision: 'FAIL',
    expectedAction: 'ask',
  });
  const dir = makeCaseDir(caseJson);
  try {
    assert.throws(() => loadCase(dir), /gateFixture/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('loadCase lança erro mencionando "expectedDecision" quando o valor e invalido', () => {
  const caseJson = baseCase({
    assertions: ['gateSemantics'],
    gateFixture: {
      rows: [{ phase: 'security', critical: 0, high: 1, medium: 0, low: 0 }],
      config: { onFail: 'ask', onWarn: 'ask' },
    },
    expectedDecision: 'BOGUS',
    expectedAction: 'ask',
  });
  const dir = makeCaseDir(caseJson);
  try {
    assert.throws(() => loadCase(dir), /expectedDecision/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('loadCase lança erro mencionando "expectedAction" quando o valor e invalido', () => {
  const caseJson = baseCase({
    assertions: ['gateSemantics'],
    gateFixture: {
      rows: [{ phase: 'security', critical: 0, high: 1, medium: 0, low: 0 }],
      config: { onFail: 'ask', onWarn: 'ask' },
    },
    expectedDecision: 'FAIL',
    expectedAction: 'bogus',
  });
  const dir = makeCaseDir(caseJson);
  try {
    assert.throws(() => loadCase(dir), /expectedAction/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('listReps enumera os diretórios de reps de um braço em ordem ascendente', () => {
  const dir = makeCaseDir(baseCase());
  try {
    const armDir = path.join(dir, 'arms', 'treatment');
    fs.mkdirSync(path.join(armDir, 'rep-03'), { recursive: true });
    fs.mkdirSync(path.join(armDir, 'rep-01'), { recursive: true });
    fs.mkdirSync(path.join(armDir, 'rep-02'), { recursive: true });

    const reps = listReps(dir, 'treatment');
    assert.deepEqual(reps, [
      path.join(armDir, 'rep-01'),
      path.join(armDir, 'rep-02'),
      path.join(armDir, 'rep-03'),
    ]);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('repArtifacts resolve os caminhos de plan.md, code/ e phase-status.md sem chamada externa', () => {
  const dir = makeCaseDir(baseCase());
  try {
    const repDir = path.join(dir, 'arms', 'treatment', 'rep-01');
    fs.mkdirSync(path.join(repDir, 'code'), { recursive: true });
    fs.writeFileSync(path.join(repDir, 'plan.md'), '# plan', 'utf8');
    fs.writeFileSync(path.join(repDir, 'phase-status.md'), '# status', 'utf8');

    const artifacts = repArtifacts(dir, 'treatment', 'rep-01');
    assert.equal(artifacts.planPath, path.join(repDir, 'plan.md'));
    assert.equal(artifacts.codeDir, path.join(repDir, 'code'));
    assert.equal(artifacts.phaseStatusPath, path.join(repDir, 'phase-status.md'));
    assert.equal(fs.readFileSync(artifacts.planPath, 'utf8'), '# plan');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
