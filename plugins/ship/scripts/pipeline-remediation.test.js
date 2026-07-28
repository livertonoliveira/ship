'use strict';

// Guards the single-batch remediation path in pipeline.sh `next`. Every detector
// reports into one consolidated gate; when that gate is red the pipeline builds
// remediation.md ONCE — the complete list of adjustments the round requires —
// and hands it to exactly one fix agent. There is no cap, no findings ledger and
// no churn guard, because the confirmation pass that follows scores a closed set
// and therefore cannot mint a finding that was not already in the batch.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PIPELINE = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'pipeline.sh');
const TASK_ID = 'remediation-task';

function git(cwd, args) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
  assert.equal(r.status, 0, `git ${args.join(' ')} failed: ${r.stderr}`);
  return r;
}

const HEADER =
  '# Phase Status\n\n| Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |\n' +
  '|-------|-----|-----------|-------|------|----------|------|--------|-----|-------|\n';

// A scratch dir pre-seeded so `next --mode check` skips straight to the gate:
// dev/test/homolog disabled, a single WARN (medium) review row plus the matching
// review-findings.md, everything the state machine gates on already resolved.
function setup() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'remediation-'));
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
  w('review-findings.md', '### [MEDIUM] Some warn\n- **File:** src/x.ts:1\n');
  w('phase-status.md', HEADER + '| review | #1 | 2026-07-22T10:00:00Z | 3 | warn | 0 | 0 | 1 | 0 | |\n');

  return { dir, config, scratch };
}

function runNext(dir, config, extra = []) {
  return spawnSync('bash', [PIPELINE, 'next', TASK_ID, '--mode', 'check', '--config', config, ...extra], {
    cwd: dir,
    encoding: 'utf8',
  });
}

test('a red gate builds one batch and dispatches exactly one fix agent', () => {
  const { dir, config, scratch } = setup();

  const res = runNext(dir, config);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /state=remediation-fix/);
  assert.match(res.stdout, /action=dispatch/);
  // One agent for the whole batch — not one per phase, not one per finding.
  assert.equal((res.stdout.match(/subagent_type=/g) || []).length, 1);
  assert.match(fs.readFileSync(path.join(scratch, 'remediation.md'), 'utf8'), /^### R1 /m);
  assert.ok(fs.existsSync(path.join(scratch, 'remediation-fix-inflight.txt')));
});

test('a medium-only gate (WARN) is remediated, not deferred', () => {
  const { dir, config, scratch } = setup();

  const res = runNext(dir, config);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /state=remediation-fix/);
  const items = fs.readFileSync(path.join(scratch, 'remediation-items.txt'), 'utf8');
  assert.match(items, /^R1\|finding\|review\|medium\|/m);
});

test('deterministic failures and findings land in the SAME batch', () => {
  const { dir, config, scratch } = setup();
  // A red typecheck no longer halts the pipeline ahead of the fan-out, so its
  // failure reaches the gate alongside the review finding.
  fs.writeFileSync(
    path.join(scratch, 'phase-status-static.md'),
    '| static | #1 | 2026-07-22T10:00:00Z | - | fail | 0 | 0 | 0 | 0 | |\n'
  );
  fs.writeFileSync(path.join(scratch, 'static-failures.md'), '# Static Failures\n\nTS2304\n');
  fs.writeFileSync(
    path.join(scratch, 'phase-status.md'),
    HEADER +
      '| static | #1 | 2026-07-22T10:00:00Z | - | fail | 0 | 0 | 0 | 0 | |\n' +
      '| review | #1 | 2026-07-22T10:00:00Z | 3 | warn | 0 | 0 | 1 | 0 | |\n'
  );

  const res = runNext(dir, config);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /state=remediation-fix/);
  assert.equal((res.stdout.match(/subagent_type=/g) || []).length, 1);
  const batch = fs.readFileSync(path.join(scratch, 'remediation.md'), 'utf8');
  assert.match(batch, /typecheck\/lint/);
  assert.match(batch, /some-warn/);
  assert.equal((batch.match(/^### R\d+ /gm) || []).length, 2);
});

test('a phase row reporting fail with no severity counts still fails the gate', () => {
  const { dir, config, scratch } = setup();
  // Static/test rows carry 0/0/0/0; without the gate-column check a broken build
  // would score PASS now that those phases no longer block the pipeline.
  fs.writeFileSync(
    path.join(scratch, 'phase-status.md'),
    HEADER + '| static | #1 | 2026-07-22T10:00:00Z | - | fail | 0 | 0 | 0 | 0 | |\n'
  );

  const res = spawnSync('bash', [PIPELINE, 'gate', scratch, '--config', config], {
    cwd: dir,
    encoding: 'utf8',
  });
  assert.equal(res.status, 2);
  assert.match(res.stdout, /decision=FAIL/);
});

test('the remediation round is not repeated automatically — residue asks the user', () => {
  const { dir, config, scratch } = setup();
  // The round has been spent and the confirmation pass left an item open.
  fs.writeFileSync(path.join(scratch, 'remediation-done.txt'), 'spent\n');
  fs.writeFileSync(path.join(scratch, 'remediation-verdict.txt'), 'resolved=0\nunresolved=1\nunresolved_ids=R1\n');

  const res = runNext(dir, config);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /action=ask/);
  assert.match(res.stdout, /R1/);
  assert.doesNotMatch(res.stdout, /state=remediation-fix/);
  assert.equal(fs.existsSync(path.join(scratch, 'remediation-fix-inflight.txt')), false);
});

test('the user can still ask for another round explicitly', () => {
  const { dir, config, scratch } = setup();
  fs.writeFileSync(path.join(scratch, 'remediation-done.txt'), 'spent\n');

  const res = runNext(dir, config, ['--answer', 'fix']);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /state=remediation-fix/);
});
