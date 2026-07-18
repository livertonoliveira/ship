'use strict';

const fs = require('node:fs');
const os = require('node:os');
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

function buildGatePhaseStatus(scratchDir, rows) {
  const header =
    '# Phase Status\n\n| Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |\n' +
    '|-------|-----|-----------|-------|------|----------|------|--------|-----|-------|\n';
  const dataRows = rows.map(
    (row) =>
      `| ${row.phase} | #1 | 2026-07-17T10:00:00Z | 3 | pass | ${row.critical} | ${row.high} | ${row.medium} | ${row.low} | |`
  );
  fs.writeFileSync(path.join(scratchDir, 'phase-status.md'), header + dataRows.join('\n') + '\n');
}

function buildGateConfig(scratchDir, config) {
  const configPath = path.join(scratchDir, 'config.md');
  const overrides = config.overrides ?? [];
  const onFail = config.onFail ?? 'ask';
  const onWarn = config.onWarn ?? 'ask';
  const lines = ['# Config', ''];
  if (overrides.length > 0) {
    lines.push('## Severity Overrides');
    for (const override of overrides) {
      lines.push(`- ${override}`);
    }
    lines.push('');
  }
  lines.push('## Gate Behavior');
  lines.push(`- on_fail: ${onFail}`);
  lines.push(`- on_warn: ${onWarn}`);
  lines.push('');
  fs.writeFileSync(configPath, lines.join('\n'));
  return configPath;
}

function parseGateStdout(stdout) {
  const decisionMatch = stdout.match(/decision=(\w+)/);
  const actionMatch = stdout.match(/action=(\w+)/);
  return {
    decision: decisionMatch ? decisionMatch[1] : null,
    action: actionMatch ? actionMatch[1] : null,
  };
}

function gateSemantics(artifacts, caseMeta) {
  const repoRoot = findRepoRoot(__dirname);
  const pipelinePath = path.join(repoRoot, 'src', 'hooks', 'pipeline.sh');
  const scratchDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ship-pressure-gate-'));

  try {
    buildGatePhaseStatus(scratchDir, caseMeta.gateFixture.rows);
    const configPath = buildGateConfig(scratchDir, caseMeta.gateFixture.config);
    const result = spawnSync('bash', [pipelinePath, 'gate', scratchDir, '--config', configPath], { encoding: 'utf8' });
    const { decision, action } = parseGateStdout(result.stdout || '');
    const expected = { decision: caseMeta.expectedDecision, action: caseMeta.expectedAction };
    const observed = { decision, action };
    const pass = decision === expected.decision && action === expected.action;
    return {
      assertion: 'gateSemantics',
      pass,
      observed,
      expected,
    };
  } finally {
    fs.rmSync(scratchDir, { recursive: true, force: true });
  }
}

function runAssertion(name, repArtifacts, caseMeta) {
  switch (name) {
    case 'planSchema':
      return planSchema(repArtifacts);
    case 'noSpecIds':
      return noSpecIds(repArtifacts);
    case 'gateOutcome':
      return gateOutcome(repArtifacts, caseMeta);
    case 'gateSemantics':
      return gateSemantics(repArtifacts, caseMeta);
    default:
      throw new Error(`assertion desconhecida: ${name}`);
  }
}

module.exports = { runAssertion, planSchema, noSpecIds, gateOutcome, gateSemantics };
