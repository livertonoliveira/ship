'use strict';

const fs = require('node:fs');
const path = require('node:path');

const KNOWN_ASSERTIONS = ['planSchema', 'noSpecIds', 'gateOutcome'];
const KNOWN_GATES = ['PASS', 'WARN', 'FAIL'];
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

  return {
    caseDir: absoluteCaseDir,
    skill: parsed.skill,
    input: parsed.input,
    arms: parsed.arms,
    assertions: parsed.assertions,
    reps: parsed.reps,
    expectedGate: requiresGateOutcome ? parsed.expectedGate : parsed.expectedGate ?? null,
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
