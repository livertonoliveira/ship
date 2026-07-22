'use strict';

// Guards the gate fix-loop convergence check in pipeline.sh `next`: when a fix
// cycle leaves the gate's inputs (per-phase severity counts) unchanged, another
// fix is a fixpoint (e.g. cross-language orphans a code change cannot move), so
// the loop must surface to the user instead of re-dispatching.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PIPELINE = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'pipeline.sh');
const TASK_ID = 'conv-task';

// last_rows_by_phase emits "phase\tcrit\thigh\tmed\tlow\n" per phase — the exact
// fingerprint the guard compares across fix cycles.
const ROWS_FINGERPRINT = 'review\t0\t0\t1\t0\n';

function git(cwd, args) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
  assert.equal(r.status, 0, `git ${args.join(' ')} failed: ${r.stderr}`);
  return r;
}

// A scratch dir pre-seeded so `next --mode check` skips straight to the gate:
// dev/test/homolog disabled, a single WARN (medium) review row, everything the
// state machine gates on already marked resolved on disk.
function setup() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gate-converge-'));
  git(dir, ['init', '-q']);
  git(dir, ['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'base']);
  git(dir, ['update-ref', 'refs/remotes/origin/main', 'HEAD']);

  const config = path.join(dir, 'config.md');
  fs.writeFileSync(
    config,
    [
      '# Config',
      '',
      '## Pipeline Phases',
      '- dev: disabled',
      '- test: disabled',
      '- homolog: disabled',
      '',
      '## Gate Behavior',
      '- on_fail: fix',
      '- on_warn: fix',
      '',
    ].join('\n')
  );

  const scratch = path.join(dir, '.context', 'ship-run', TASK_ID);
  fs.mkdirSync(scratch, { recursive: true });
  const w = (name, body) => fs.writeFileSync(path.join(scratch, name), body);

  w('diff-class.txt', 'normal\n');
  w('spec.md', '# Spec\n\n### Requirement: something\n');
  w('diff.md', 'diff --git a/src/x.ts b/src/x.ts\n+const x = 1\n');
  w('plan-decision.txt', 'skip:dev-disabled\n');
  w('dev-skipped.txt', '');
  w('post-develop-done.txt', '');
  w('verify-a.txt', 'quality=review\ndepth=flat\nlayers=\n');
  w('pending.txt', '');
  w('test-exec-done.txt', '');
  w('analyze-decided.txt', 'skip\n');
  w(
    'phase-status.md',
    '# Phase Status\n\n| Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |\n' +
      '|-------|-----|-----------|-------|------|----------|------|--------|-----|-------|\n' +
      '| review | #1 | 2026-07-22T10:00:00Z | 3 | warn | 0 | 0 | 1 | 0 | |\n'
  );

  return { dir, config, scratch };
}

function runNext(dir, config) {
  return spawnSync('bash', [PIPELINE, 'next', TASK_ID, '--mode', 'check', '--config', config], {
    cwd: dir,
    encoding: 'utf8',
  });
}

test('fingerprint unchanged after a fix cycle → gate surfaces (ask), no re-dispatch', () => {
  const { dir, config, scratch } = setup();
  // Prior fix cycle already recorded this exact fingerprint; the gate inputs
  // have not moved since, so a further fix is futile.
  fs.writeFileSync(path.join(scratch, 'gate-fix-fingerprint.txt'), ROWS_FINGERPRINT);

  const res = runNext(dir, config);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /action=ask/);
  assert.match(res.stdout, /fix converged/);
  assert.doesNotMatch(res.stdout, /dispatching fix agent/);
  // The loop stopped: no fix iteration was consumed and no fix agent dispatched.
  assert.equal(fs.existsSync(path.join(scratch, 'iteration-fix.txt')), false);
  assert.equal(fs.existsSync(path.join(scratch, 'gate-fix-inflight.txt')), false);
});

test('first WARN (no prior fingerprint) → records fingerprint and dispatches the fix', () => {
  const { dir, config, scratch } = setup();

  const res = runNext(dir, config);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /action=dispatch/);
  assert.match(res.stdout, /dispatching fix agent/);
  // The current gate inputs are fingerprinted so the next cycle can detect a fixpoint.
  const fp = fs.readFileSync(path.join(scratch, 'gate-fix-fingerprint.txt'), 'utf8');
  assert.equal(fp, ROWS_FINGERPRINT);
  assert.ok(fs.existsSync(path.join(scratch, 'gate-fix-inflight.txt')));
});
