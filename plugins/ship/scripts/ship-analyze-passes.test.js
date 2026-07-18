'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const AGENT_PATH = path.join(__dirname, '..', 'agents', 'ship-analyze.md');
const SPEC_QUALITY_PATH = path.join(__dirname, '..', '..', '..', 'src', 'patterns', 'spec-quality.md');
const VAGUE_TERMS_PATH = path.join(__dirname, '..', '..', '..', 'src', 'patterns', 'vague-terms.md');
const SPEC_SKILL_PATH = path.join(__dirname, '..', '..', '..', 'src', 'skills', 'spec', 'SKILL.md');

const readAgent = () => fs.readFileSync(AGENT_PATH, 'utf8');
const readSpecQuality = () => fs.readFileSync(SPEC_QUALITY_PATH, 'utf8');

test('semantic passes live in the spec quality gate with their fixed rubrics', () => {
  const content = readSpecQuality();
  assert.match(
    content,
    /does the item contain a qualitative attribute with no measurable threshold\?/
  );
  assert.match(
    content,
    /does this requirement have a testable acceptance criterion\? does each of its acceptance criteria have a verifiable pass\/fail condition\?/
  );
  assert.match(
    content,
    /check adherence of each REQ-XX\/AC-XX to the declared conventions/
  );
});

test('spec quality gate dispatches exactly one batched sub-agent, never one per item', () => {
  const content = readSpecQuality();
  assert.match(content, /dispatch \*\*exactly one\*\* sub-agent/);
  assert.match(content, /ALL candidates in a single prompt/);
  assert.match(content, /never one dispatch per item/);
});

test('AMBIG pre-filter selects dictionary hits and suppresses items with measurable thresholds', () => {
  const content = readSpecQuality();
  assert.match(content, /A term match selects the item as a candidate for LLM confirmation/);
  assert.match(content, /No dictionary hit → no candidate, skip the item entirely/);
  assert.match(content, /must not be selected/);
});

test('SUBSPEC pre-filter resolves measurable REQs locally without sub-agent dispatch', () => {
  const content = readSpecQuality();
  assert.match(content, /zero linked AC-XX/);
  assert.match(content, /resolved locally as "not underspecified" and skipped/);
});

test('spec quality passes are excluded from the pipeline by contract', () => {
  const content = readSpecQuality();
  assert.match(content, /never run inside the development pipeline/);
  const skill = fs.readFileSync(SPEC_SKILL_PATH, 'utf8');
  assert.match(skill, /spec-quality\.md/);
  assert.match(skill, /never inside the pipeline/);
});

test('vague-terms.md lists specific vague terms for pt-BR, including "escalável"', () => {
  const vagueTerms = fs.readFileSync(VAGUE_TERMS_PATH, 'utf8');
  assert.match(vagueTerms, /## pt-BR/);
  assert.match(vagueTerms, /escalável \/ escalabilidade/);
});

test('ship-analyze no longer dispatches semantic sub-agents nor extraction sub-agents', () => {
  const content = readAgent();
  assert.doesNotMatch(content, /### 6\.10|### 6\.11|### 6\.12/);
  assert.doesNotMatch(content, /dispatch a sub-agent/);
  assert.doesNotMatch(content, /extraction agents/i);
  assert.doesNotMatch(content, /dispatch sub-agent/i);
  assert.match(content, /AMBIG\/SUBSPEC\/PRINCIPLE n\/a here.*owned by/);
});

test('ship-analyze delegates extraction and correlation to the deterministic engine', () => {
  const content = readAgent();
  assert.match(content, /script-path/);
  assert.match(content, /--test-scope/);
  assert.match(content, /Jaccard/);
  assert.match(content, /never recompute in-context/i);
});
