'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const HOOK = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'analyze-correlate.sh');

const id = (kind, n) => `${kind}-0${n}`;
const REQ = (n) => id('REQ', n);
const AC = (n) => id('AC', n);
const SC = (n) => id('SC', n);

const SPEC = `# Spec — Auth Feature

### ${REQ(1)}: auth login endpoint
Some prose.

- ${AC(1)}: auth login returns token

### ${REQ(2)}: billing invoice generation
- ${AC(2)}: invoice generation downloads csv

### ${REQ(3)}: user session refresh token rotation
### ${REQ(4)}: user session refresh token rotation

## Scenarios

@${SC(1)} @${AC(1)} @unit
Scenario: auth login token
  Given a registered user
  When the user submits auth login
  Then a token is returned

@${SC(2)} @${AC(2)} @integration
Scenario: invoice generation csv
  When the invoice generation runs
  Then a csv downloads
`;

const DIFF = `diff --git a/src/auth/login.ts b/src/auth/login.ts
--- a/src/auth/login.ts
+++ b/src/auth/login.ts
@@ -0,0 +1,2 @@
+export function authLogin(token) {
+  return token
diff --git a/src/zorp/quux.ts b/src/zorp/quux.ts
--- a/src/zorp/quux.ts
+++ b/src/zorp/quux.ts
@@ -0,0 +1,1 @@
+const zorp = quux
`;

function setup() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'analyze-correlate-'));
  fs.writeFileSync(path.join(dir, 'spec.md'), SPEC);
  fs.writeFileSync(path.join(dir, 'diff.md'), DIFF);
  fs.mkdirSync(path.join(dir, 'src', 'auth'), { recursive: true });
  fs.writeFileSync(
    path.join(dir, 'src', 'auth', 'login.test.ts'),
    "it('auth login returns token', () => {})\n"
  );
  fs.writeFileSync(
    path.join(dir, 'src', 'auth', 'billing.integration.test.ts'),
    "it('invoice generation downloads csv', () => {})\n"
  );
  return dir;
}

function run(dir, extraArgs = []) {
  const res = spawnSync(
    'bash',
    [
      HOOK,
      path.join(dir, 'spec.md'),
      path.join(dir, 'diff.md'),
      '--repo-root',
      dir,
      ...extraArgs,
    ],
    { encoding: 'utf8' }
  );
  assert.equal(res.status, 0, `hook failed: ${res.stderr}`);
  return JSON.parse(res.stdout);
}

test('extracts requirements, criteria, and scenarios from the spec', () => {
  const dir = setup();
  const out = run(dir);
  assert.equal(out.summary.requirements.total, 4);
  assert.equal(out.summary.criteria.total, 2);
  assert.equal(out.summary.scenarios.total, 2);
  const ids = out.requirements.map((r) => r.id);
  assert.deepEqual(ids, [REQ(1), REQ(2), REQ(3), REQ(4)]);
  const firstCriterion = out.criteria.find((c) => c.id === AC(1));
  assert.equal(firstCriterion.req, REQ(1));
});

test('maps implemented requirements to files and flags unimplemented ones', () => {
  const dir = setup();
  const out = run(dir);
  const implemented = out.requirements.find((r) => r.id === REQ(1));
  assert.ok(implemented.confidence > 0, 'login requirement should match src/auth/login.ts');
  assert.equal(implemented.file, 'src/auth/login.ts');
  const missing = out.requirements.find((r) => r.id === REQ(2));
  assert.equal(missing.confidence, 0, 'billing requirement has no implementation in the diff');
});

test('maps criteria and unit scenarios to test files', () => {
  const dir = setup();
  const out = run(dir);
  const loginCriterion = out.criteria.find((c) => c.id === AC(1));
  assert.ok(loginCriterion.confidence >= 0.5, `login criterion confidence ${loginCriterion.confidence}`);
  assert.equal(loginCriterion.file, 'src/auth/login.test.ts');
  assert.equal(loginCriterion.layer, 'unit');
  const loginScenario = out.scenarios.find((s) => s.id === SC(1));
  assert.ok(loginScenario.confidence > 0);
  assert.equal(loginScenario.ac, AC(1));
  assert.equal(loginScenario.layer, 'unit');
});

test('disabled layers are excluded from matching and reported as informational', () => {
  const dir = setup();
  const out = run(dir, ['--test-scope', 'unit=enabled,integration=disabled,e2e=disabled']);
  assert.equal(out.scenarios.some((s) => s.id === SC(2)), false);
  assert.ok(out.disabled_layers.integration.includes(SC(2)));
  assert.ok(out.disabled_layers.integration.includes(AC(1)));
  assert.equal(out.summary.scenarios.skipped_disabled, 1);
  const invoiceCriterion = out.criteria.find((c) => c.id === AC(2));
  assert.equal(
    invoiceCriterion.confidence,
    0,
    'integration test file must not be matched when the layer is disabled'
  );
});

test('detects orphan changed files with zero match against every requirement', () => {
  const dir = setup();
  const out = run(dir);
  assert.deepEqual(out.orphans.map((o) => o.file), ['src/zorp/quux.ts']);
});

test('changed test files are never flagged as requirement orphans', () => {
  const dir = setup();
  const diffWithTests = `${DIFF}diff --git a/src/xoxo/xoxo.test.ts b/src/xoxo/xoxo.test.ts
--- a/src/xoxo/xoxo.test.ts
+++ b/src/xoxo/xoxo.test.ts
@@ -0,0 +1,1 @@
+it('xoxo mock', () => { const searchPublic = jest.fn() })
diff --git a/src/wibble/__tests__/wibble.ts b/src/wibble/__tests__/wibble.ts
--- a/src/wibble/__tests__/wibble.ts
+++ b/src/wibble/__tests__/wibble.ts
@@ -0,0 +1,1 @@
+const wibble = mock
diff --git a/e2e/flow.e2e-spec.ts b/e2e/flow.e2e-spec.ts
--- a/e2e/flow.e2e-spec.ts
+++ b/e2e/flow.e2e-spec.ts
@@ -0,0 +1,1 @@
+const flow = wobble
`;
  fs.writeFileSync(path.join(dir, 'diff.md'), diffWithTests);
  const out = run(dir);
  // Only the non-test orphan survives; the three changed test files are excluded.
  assert.deepEqual(out.orphans.map((o) => o.file), ['src/zorp/quux.ts']);
});

test('detects duplicate requirement pairs at similarity >= 0.8', () => {
  const dir = setup();
  const out = run(dir);
  assert.equal(out.duplicates.length, 1);
  assert.equal(out.duplicates[0].a, REQ(3));
  assert.equal(out.duplicates[0].b, REQ(4));
  assert.ok(out.duplicates[0].score >= 0.8);
});

test('cache: identical inputs reuse jaccard.json, changed diff invalidates it', () => {
  const dir = setup();
  const scratch = path.join(dir, 'scratch');
  const first = run(dir, ['--scratch', scratch]);
  assert.ok(fs.existsSync(path.join(scratch, 'jaccard.json')));
  const second = run(dir, ['--scratch', scratch]);
  assert.deepEqual(second, first);
  fs.appendFileSync(path.join(dir, 'diff.md'), '+const another = change\n');
  const third = run(dir, ['--scratch', scratch]);
  assert.notEqual(third.diff_hash, first.diff_hash);
});

test('scope-index entries (em-dash form) never enter the correlation matrix', () => {
  const dir = setup();
  fs.appendFileSync(
    path.join(dir, 'spec.md'),
    `\n## Scope index\n- ${id('REQ', 9)} — payment gateway — covered by another issue\n`
  );
  const out = run(dir);
  assert.equal(out.requirements.some((r) => r.id === id('REQ', 9)), false);
  assert.equal(out.summary.requirements.total, 4);
});

test('empty diff yields zero-confidence requirements and no orphans', () => {
  const dir = setup();
  fs.writeFileSync(path.join(dir, 'diff.md'), '');
  const out = run(dir);
  assert.equal(out.summary.changed_files, 0);
  assert.equal(out.orphans.length, 0);
  assert.ok(out.requirements.every((r) => r.confidence === 0));
});
