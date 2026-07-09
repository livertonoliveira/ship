'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function findRepoRoot(startDir) {
  let current = startDir;
  while (true) {
    const hasSrc = fs.existsSync(path.join(current, 'src'));
    const hasPlugins = fs.existsSync(path.join(current, 'plugins'));
    if (hasSrc && hasPlugins) {
      return current;
    }
    const parent = path.dirname(current);
    if (parent === current) {
      throw new Error('repo root não encontrado a partir de ' + startDir);
    }
    current = parent;
  }
}

function runHook(relativePath, args) {
  const repoRoot = findRepoRoot(__dirname);
  const scriptPath = path.join(repoRoot, 'src', 'hooks', relativePath);
  return spawnSync('bash', [scriptPath, ...args], { encoding: 'utf8' });
}

function planSchema(artifacts) {
  const result = runHook('plan-validate.sh', [artifacts.planPath]);
  const observed = result.status;
  return {
    assertion: 'planSchema',
    pass: observed === 0,
    observed,
    expected: 0,
  };
}

function noSpecIds(artifacts) {
  const result = runHook('hygiene-scan.sh', ['--dir', artifacts.codeDir]);
  const lines = (result.stdout || '').split('\n');
  const observed = lines
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && line.includes(':') && line !== 'Ship hygiene — clean.')
    .filter((line) => !line.startsWith('Ship hygiene —'));
  return {
    assertion: 'noSpecIds',
    pass: observed.length === 0,
    observed,
    expected: 0,
  };
}

function parseGateFromPhaseStatus(phaseStatusPath) {
  const content = fs.readFileSync(phaseStatusPath, 'utf8');
  const lines = content.split('\n').filter((line) => line.trim().startsWith('|'));

  const headerIndex = lines.findIndex((line) => {
    const cells = line.split('|').map((cell) => cell.trim());
    return cells[1] === 'Phase';
  });

  if (headerIndex === -1) {
    return null;
  }

  const headerCells = lines[headerIndex].split('|').map((cell) => cell.trim());
  const gateIndex = headerCells.findIndex((cell) => cell === 'Gate');
  if (gateIndex === -1) {
    return null;
  }

  const dataRows = lines.slice(headerIndex + 1).filter((line) => {
    const cells = line.split('|').map((cell) => cell.trim());
    return !/^-+$/.test(cells[1] ?? '');
  });

  if (dataRows.length === 0) {
    return null;
  }

  const lastRowCells = dataRows[dataRows.length - 1].split('|').map((cell) => cell.trim());
  return lastRowCells[gateIndex] ?? null;
}

function gateOutcome(artifacts, caseMeta) {
  const observed = parseGateFromPhaseStatus(artifacts.phaseStatusPath);
  const expected = caseMeta.expectedGate;
  const pass = typeof observed === 'string' && observed.toUpperCase() === String(expected).toUpperCase();
  return {
    assertion: 'gateOutcome',
    pass,
    observed,
    expected,
  };
}

function runAssertion(name, repArtifacts, caseMeta) {
  switch (name) {
    case 'planSchema':
      return planSchema(repArtifacts);
    case 'noSpecIds':
      return noSpecIds(repArtifacts);
    case 'gateOutcome':
      return gateOutcome(repArtifacts, caseMeta);
    default:
      throw new Error(`assertion desconhecida: ${name}`);
  }
}

module.exports = { runAssertion, planSchema, noSpecIds, gateOutcome };
