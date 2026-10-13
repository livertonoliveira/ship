'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { parseTranscript, profileNode, priceOf, emptyBucket, categoryOf } = require('./cost-profile');

function line(obj) {
  return JSON.stringify(obj);
}

function assistant(id, requestId, usage, model, content, timestamp) {
  return line({
    type: 'assistant', requestId, timestamp,
    message: { id, model, role: 'assistant', content: content || [], usage },
  });
}

function tmpFile(name, text) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cost-profile-'));
  const file = path.join(dir, name);
  fs.writeFileSync(file, text);
  return file;
}

test('dedupes streamed repeats of one message and prices each cache tier', () => {
  const usage = {
    input_tokens: 100, output_tokens: 10, cache_read_input_tokens: 1000,
    cache_creation_input_tokens: 500,
    cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 500 },
  };
  const file = tmpFile('s.jsonl', [
    assistant('msg_1', 'req_1', usage, 'claude-sonnet-5-5', [], '2026-10-13T10:00:00Z'),
    assistant('msg_1', 'req_1', usage, 'claude-sonnet-5-5', [], '2026-10-13T10:00:01Z'),
  ].join('\n'));
  const b = emptyBucket();
  parseTranscript(file, b);
  assert.equal(b.turns, 1);
  const p = priceOf('claude-sonnet-5-5');
  const expected = (100 * p.in + 500 * p.in * 2 + 1000 * p.read + 10 * p.out) / 1e6;
  assert.ok(Math.abs(b.cost - expected) < 1e-9);
  assert.equal(b.maxContext, 1600);
});

test('counts tool calls once and flags unpriced models instead of guessing', () => {
  const content = [{ type: 'tool_use', id: 'toolu_1', name: 'mcp__linear-server__save_issue', input: {} }];
  const usage = { input_tokens: 1, output_tokens: 1 };
  const file = tmpFile('s.jsonl', [
    assistant('msg_1', 'req_1', usage, 'mystery-model', content),
    assistant('msg_1', 'req_1', usage, 'mystery-model', content),
  ].join('\n'));
  const b = emptyBucket();
  parseTranscript(file, b);
  assert.equal(b.tools['mcp__linear-server__save_issue'], 1);
  assert.equal(b.cost, 0);
  assert.equal(b.unknownModels['mystery-model'], 1);
});

test('bare model aliases resolve to the current generation', () => {
  assert.equal(priceOf('sonnet'), priceOf('claude-sonnet-5-5'));
  assert.equal(priceOf('claude-opus-5-5-20260401'), priceOf('claude-opus-5-5'));
});

test('a forked skill is categorised by the skill its first turn loads', () => {
  const file = tmpFile('agent-x.jsonl', line({
    type: 'user',
    message: { role: 'user', content: 'Base directory for this skill: /x/ship/4.43.1/skills/develop\n\n# Ship Develop' },
  }));
  assert.equal(categoryOf({ agentType: 'general-purpose' }, file), 'develop');
  assert.equal(categoryOf({ agentType: 'ship:ship-test-unit' }), 'tests');
  assert.equal(categoryOf({ agentType: 'ship:ship-remediation-fix' }), 'remediation');
  assert.equal(categoryOf({ agentType: 'ship:ship-review' }), 'quality');
});

test('a node sums its orchestrating session and the subagents beside it', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cost-profile-node-'));
  const usage = { input_tokens: 1000, output_tokens: 100 };
  fs.writeFileSync(path.join(dir, 'sess.jsonl'), assistant('m1', 'r1', usage, 'claude-sonnet-5-5'));
  const sub = path.join(dir, 'sess', 'subagents');
  fs.mkdirSync(sub, { recursive: true });
  fs.writeFileSync(path.join(sub, 'agent-1.jsonl'), assistant('m2', 'r2', usage, 'claude-sonnet-5-5'));
  fs.writeFileSync(path.join(sub, 'agent-1.meta.json'), JSON.stringify({ agentType: 'ship:ship-perf' }));
  const node = profileNode(dir, null);
  assert.equal(node.sessions, 1);
  assert.equal(node.categories.orchestration.turns, 1);
  assert.equal(node.categories.quality.turns, 1);
  assert.ok(Math.abs(node.total - 2 * node.categories.quality.cost) < 1e-12);
});
