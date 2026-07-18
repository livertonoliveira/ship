'use strict';

const fs = require('node:fs');
const path = require('node:path');

const KNOWN_ASSERTIONS = ['planSchema', 'noSpecIds', 'gateOutcome', 'gateSemantics'];
const KNOWN_GATES = ['PASS', 'WARN', 'FAIL'];
const KNOWN_GATE_ACTIONS = ['ask', 'fix', 'defer', 'pass', 'continue'];
const REQUIRED_ARMS = ['treatment', 'control'];

function loadCase(caseDir) {
  const absoluteCaseDir = path.resolve(caseDir);
  const caseFile = path.join(absoluteCaseDir, 'case.json');
  const raw = fs.readFileSync(caseFile, 'utf8');
  const parsed = JSON.parse(raw);

  if (typeof parsed.skill !== 'string' || parsed.skill.length === 0) {
    throw new Error(`case.json inválido: campo "skill" deve ser uma string não vazia`);
  }

  if (typeof parsed.input !== 'string' || parsed.input.length === 0) {
    throw new Error(`case.json inválido: campo "input" deve ser uma string não vazia`);
  }

  if (parsed.arms === null || typeof parsed.arms !== 'object') {
    throw new Error(`case.json inválido: campo "arms" deve ser um objeto contendo "treatment" e "control"`);
  }

  for (const arm of REQUIRED_ARMS) {
    if (!Object.prototype.hasOwnProperty.call(parsed.arms, arm)) {
      throw new Error(`case.json inválido: braço "${arm}" ausente em "arms"`);
    }
  }

  if (!Array.isArray(parsed.assertions)) {
    throw new Error(`case.json inválido: campo "assertions" deve ser um array`);
  }

  for (const assertion of parsed.assertions) {
    if (!KNOWN_ASSERTIONS.includes(assertion)) {
      throw new Error(`case.json inválido: "assertions" contém valor desconhecido "${assertion}"`);
    }
  }

  if (!Number.isInteger(parsed.reps) || parsed.reps < 1) {
    throw new Error(`case.json inválido: campo "reps" deve ser um inteiro maior ou igual a 1`);
  }

  const requiresGateOutcome = parsed.assertions.includes('gateOutcome');
  if (requiresGateOutcome && !KNOWN_GATES.includes(parsed.expectedGate)) {
    throw new Error(`case.json inválido: campo "expectedGate" deve ser um de PASS, WARN, FAIL`);
  }

  const requiresGateSemantics = parsed.assertions.includes('gateSemantics');
  if (requiresGateSemantics) {
    if (parsed.gateFixture === null || typeof parsed.gateFixture !== 'object') {
      throw new Error(`case.json inválido: campo "gateFixture" deve ser um objeto quando a assertion "gateSemantics" está presente`);
    }
    if (!Array.isArray(parsed.gateFixture.rows) || parsed.gateFixture.rows.length === 0) {
      throw new Error(`case.json inválido: campo "gateFixture.rows" deve ser um array não vazio`);
    }
    if (parsed.gateFixture.config === null || typeof parsed.gateFixture.config !== 'object') {
      throw new Error(`case.json inválido: campo "gateFixture.config" deve ser um objeto`);
    }
    if (!KNOWN_GATES.includes(parsed.expectedDecision)) {
      throw new Error(`case.json inválido: campo "expectedDecision" deve ser um de PASS, WARN, FAIL`);
    }
    if (!KNOWN_GATE_ACTIONS.includes(parsed.expectedAction)) {
      throw new Error(`case.json inválido: campo "expectedAction" deve ser um de ${KNOWN_GATE_ACTIONS.join(', ')}`);
    }
  }

  return {
    caseDir: absoluteCaseDir,
    skill: parsed.skill,
    input: parsed.input,
    arms: parsed.arms,
    assertions: parsed.assertions,
    reps: parsed.reps,
    expectedGate: requiresGateOutcome ? parsed.expectedGate : parsed.expectedGate ?? null,
    gateFixture: requiresGateSemantics ? parsed.gateFixture : parsed.gateFixture ?? null,
    expectedDecision: requiresGateSemantics ? parsed.expectedDecision : parsed.expectedDecision ?? null,
    expectedAction: requiresGateSemantics ? parsed.expectedAction : parsed.expectedAction ?? null,
  };
}

function listReps(caseDir, arm) {
  const armDir = path.join(path.resolve(caseDir), 'arms', arm);

  if (!fs.existsSync(armDir)) {
    return [];
  }

  return fs
    .readdirSync(armDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && /^rep-\d+$/.test(entry.name))
    .sort((a, b) => {
      const numA = Number.parseInt(a.name.slice('rep-'.length), 10);
      const numB = Number.parseInt(b.name.slice('rep-'.length), 10);
      return numA - numB;
    })
    .map((entry) => path.join(armDir, entry.name));
}

function repArtifacts(caseDir, arm, repId) {
  const repDir = path.join(path.resolve(caseDir), 'arms', arm, repId);

  return {
    planPath: path.join(repDir, 'plan.md'),
    codeDir: path.join(repDir, 'code'),
    phaseStatusPath: path.join(repDir, 'phase-status.md'),
  };
}

module.exports = { loadCase, listReps, repArtifacts };
