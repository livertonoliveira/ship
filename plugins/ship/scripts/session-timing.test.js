'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { parseTranscript } = require('./session-timing');

function line(obj) {
  return JSON.stringify(obj);
}

test('computes duration from min/max timestamps and counts assistant turns', () => {
  const text = [
    line({ timestamp: '2026-07-18T10:00:00.000Z', message: { role: 'user' } }),
    line({ timestamp: '2026-07-18T10:00:05.000Z', message: { role: 'assistant', model: 'claude-sonnet-5' } }),
    line({ timestamp: '2026-07-18T10:00:20.000Z', message: { role: 'assistant', model: 'claude-sonnet-5' } }),
  ].join('\n');
  const t = parseTranscript(text);
  assert.equal(t.durationMs, 20000);
  assert.equal(t.turns, 2);
  assert.equal(t.models.get('claude-sonnet-5'), 2);
});

test('ignores malformed lines and records without timestamps', () => {
  const text = [
    'not json',
    line({ message: { role: 'assistant', model: 'claude-opus-4-8' } }),
    line({ timestamp: '2026-07-18T10:00:00.000Z', message: { role: 'assistant', model: 'claude-opus-4-8' } }),
    '',
  ].join('\n');
  const t = parseTranscript(text);
  assert.equal(t.turns, 2);
  assert.equal(t.models.get('claude-opus-4-8'), 2);
  assert.equal(t.durationMs, 0);
});

test('flags a mixed-model transcript (would surface a routing/latency anomaly)', () => {
  const text = [
    line({ timestamp: '2026-07-18T10:00:00.000Z', message: { role: 'assistant', model: 'claude-sonnet-5' } }),
    line({ timestamp: '2026-07-18T10:00:03.000Z', message: { role: 'assistant', model: 'claude-haiku-4-5' } }),
  ].join('\n');
  const t = parseTranscript(text);
  assert.equal(t.models.size, 2);
  assert.ok(t.models.has('claude-haiku-4-5'));
});

test('empty transcript yields zero duration and zero turns', () => {
  const t = parseTranscript('');
  assert.equal(t.durationMs, 0);
  assert.equal(t.turns, 0);
  assert.equal(t.models.size, 0);
});
