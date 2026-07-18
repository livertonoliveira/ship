'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PIPELINE = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'pipeline.sh');

function sh(cwd, cmd, args) {
  return spawnSync(cmd, args, { cwd, encoding: 'utf8' });
}

function makeScratch() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'pipeline-gate-'));
}

function writePhaseStatus(scratchDir, rows) {
  const header =
    '# Phase Status\n\n| Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |\n' +
    '|-------|-----|-----------|-------|------|----------|------|--------|-----|-------|\n';
  fs.writeFileSync(path.join(scratchDir, 'phase-status.md'), header + rows.join('\n') + '\n');
}

function phaseRow(phase, critical, high, medium, low) {
  return `| ${phase} | #1 | 2026-07-17T10:00:00Z | 3 | pass | ${critical} | ${high} | ${medium} | ${low} | |`;
}

function writeConfig(configPath, { overrides = [], onFail = 'ask', onWarn = 'ask' } = {}) {
  const lines = ['# Config', ''];
  if (overrides.length > 0) {
    lines.push('## Severity Overrides');
    for (const o of overrides) lines.push(`- ${o}`);
    lines.push('');
  }
  lines.push('## Gate Behavior');
  lines.push(`- on_fail: ${onFail}`);
  lines.push(`- on_warn: ${onWarn}`);
  lines.push('');
  fs.writeFileSync(configPath, lines.join('\n'));
}

function runGate(scratchDir, configPath) {
  return sh(process.cwd(), 'bash', [PIPELINE, 'gate', scratchDir, '--config', configPath]);
}

function runGateWithLocale(scratchDir, configPath, locale) {
  return spawnSync('bash', [PIPELINE, 'gate', scratchDir, '--config', configPath], {
    cwd: process.cwd(),
    encoding: 'utf8',
    env: { ...process.env, LC_ALL: locale, LANG: locale },
  });
}

test('apenas findings low resulta em PASS e continue', () => {
  const dir = makeScratch();
  writePhaseStatus(dir, [phaseRow('dev', 0, 0, 0, 5)]);
  const configPath = path.join(dir, 'config.md');
  writeConfig(configPath, { onFail: 'fix', onWarn: 'defer' });

  const res = runGate(dir, configPath);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /decision=PASS/);
  assert.match(res.stdout, /action=continue/);
});

test('matriz de severidades: high sem override, on_fail=fix -> FAIL/fix', () => {
  const dir = makeScratch();
  writePhaseStatus(dir, [phaseRow('review', 0, 1, 0, 0)]);
  const configPath = path.join(dir, 'config.md');
  writeConfig(configPath, { onFail: 'fix', onWarn: 'ask' });

  const res = runGate(dir, configPath);
  assert.equal(res.status, 2);
  assert.match(res.stdout, /decision=FAIL/);
  assert.match(res.stdout, /action=fix/);
});

test('matriz de severidades: critical sem override, on_fail=ask -> FAIL/ask', () => {
  const dir = makeScratch();
  writePhaseStatus(dir, [phaseRow('security', 1, 0, 0, 0)]);
  const configPath = path.join(dir, 'config.md');
  writeConfig(configPath, { onFail: 'ask', onWarn: 'ask' });

  const res = runGate(dir, configPath);
  assert.equal(res.status, 2);
  assert.match(res.stdout, /decision=FAIL/);
  assert.match(res.stdout, /action=ask/);
});

test('matriz de severidades: medium sem override, on_warn=fix -> WARN/fix', () => {
  const dir = makeScratch();
  writePhaseStatus(dir, [phaseRow('perf', 0, 0, 2, 0)]);
  const configPath = path.join(dir, 'config.md');
  writeConfig(configPath, { onFail: 'fix', onWarn: 'fix' });

  const res = runGate(dir, configPath);
  assert.equal(res.status, 1);
  assert.match(res.stdout, /decision=WARN/);
  assert.match(res.stdout, /action=fix/);
});

test('matriz de severidades: security high->warn override rebaixa FAIL para WARN', () => {
  const dir = makeScratch();
  writePhaseStatus(dir, [phaseRow('security', 0, 1, 0, 0)]);
  const configPath = path.join(dir, 'config.md');
  writeConfig(configPath, {
    overrides: ['security: high→warn'],
    onFail: 'fix',
    onWarn: 'pass',
  });

  const res = runGate(dir, configPath);
  assert.equal(res.status, 1);
  assert.match(res.stdout, /decision=WARN/);
  assert.match(res.stdout, /action=pass/);
});

test('matriz de severidades: perf medium->low override rebaixa WARN para PASS', () => {
  const dir = makeScratch();
  writePhaseStatus(dir, [phaseRow('perf', 0, 0, 1, 0)]);
  const configPath = path.join(dir, 'config.md');
  writeConfig(configPath, {
    overrides: ['perf: medium→low'],
    onFail: 'ask',
    onWarn: 'ask',
  });

  const res = runGate(dir, configPath);
  assert.equal(res.status, 0);
  assert.match(res.stdout, /decision=PASS/);
  assert.match(res.stdout, /action=continue/);
});

test('matriz de severidades: security critical->medium override rebaixa FAIL para WARN', () => {
  const dir = makeScratch();
  writePhaseStatus(dir, [phaseRow('security', 1, 0, 0, 0)]);
  const configPath = path.join(dir, 'config.md');
  writeConfig(configPath, {
    overrides: ['security: critical→medium'],
    onFail: 'fix',
    onWarn: 'ask',
  });

  const res = runGate(dir, configPath);
  assert.equal(res.status, 1);
  assert.match(res.stdout, /decision=WARN/);
  assert.match(res.stdout, /action=ask/);
});

test('duas overrides encadeadas na mesma fase falham rapido em vez de zerar critical', () => {
  const dir = makeScratch();
  writePhaseStatus(dir, [phaseRow('security', 1, 0, 0, 0)]);
  const configPath = path.join(dir, 'config.md');
  writeConfig(configPath, {
    overrides: ['security: critical→medium', 'security: medium→low'],
    onFail: 'fix',
    onWarn: 'ask',
  });

  const res = runGate(dir, configPath);
  assert.notEqual(res.status, 0);
  assert.doesNotMatch(res.stdout, /decision=PASS/);
  assert.match(res.stderr, /Severity override refers to phase already overridden: security/);
});

test('override com nivel de severidade desconhecido falha rapido', () => {
  const dir = makeScratch();
  writePhaseStatus(dir, [phaseRow('review', 0, 0, 0, 0)]);
  const configPath = path.join(dir, 'config.md');
  writeConfig(configPath, { overrides: ['review: critical→bogus'] });

  const res = runGate(dir, configPath);
  assert.notEqual(res.status, 0);
  assert.match(res.stderr, /Severity override refers to unknown severity level: bogus/);
});

test('phase-status.md ausente sai com erro claro', () => {
  const dir = makeScratch();
  const configPath = path.join(dir, 'config.md');
  writeConfig(configPath);

  const res = runGate(dir, configPath);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /phase-status\.md/);
  assert.match(res.stderr, /not found/);
});

test('phase-status.md apenas com cabecalho sai com erro claro', () => {
  const dir = makeScratch();
  writePhaseStatus(dir, []);
  const configPath = path.join(dir, 'config.md');
  writeConfig(configPath);

  const res = runGate(dir, configPath);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /phase-status\.md/);
  assert.match(res.stderr, /no phase rows/);
});

test('override com separador unicode e parseado corretamente sob locale C', () => {
  const dir = makeScratch();
  writePhaseStatus(dir, [phaseRow('security', 0, 1, 0, 0)]);
  const configPath = path.join(dir, 'config.md');
  writeConfig(configPath, {
    overrides: ['security: high→warn'],
    onFail: 'fix',
    onWarn: 'pass',
  });

  const res = runGateWithLocale(dir, configPath, 'C');
  assert.equal(res.status, 1, res.stderr);
  assert.match(res.stdout, /decision=WARN/);
  assert.match(res.stdout, /action=pass/);
});

test('override apontando para fase desconhecida falha rapido', () => {
  const dir = makeScratch();
  writePhaseStatus(dir, [phaseRow('review', 0, 0, 0, 0)]);
  const configPath = path.join(dir, 'config.md');
  writeConfig(configPath, { overrides: ['bogus: high→warn'] });

  const res = runGate(dir, configPath);
  assert.notEqual(res.status, 0);
  assert.match(res.stderr, /Severity override refers to unknown phase: bogus/);
});
