'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const AGENT_PATH = path.join(__dirname, '..', 'agents', 'ship-analyze.md');
const VAGUE_TERMS_PATH = path.join(__dirname, '..', '..', '..', 'src', 'patterns', 'vague-terms.md');

function readAgent() {
  return fs.readFileSync(AGENT_PATH, 'utf8');
}

function section(content, heading, nextHeadingPattern) {
  const start = content.indexOf(heading);
  assert.notEqual(start, -1, `heading "${heading}" not found in ship-analyze.md`);
  const rest = content.slice(start + heading.length);
  const nextMatch = rest.match(nextHeadingPattern);
  return nextMatch ? rest.slice(0, nextMatch.index) : rest;
}

test('AMBIG rubric asks whether the item has a qualitative attribute with no measurable threshold, and names the offending item', () => {
  const content = readAgent();
  const ambig = section(content, '### 6.10 Ambiguity pass (AMBIG)', /\n### 6\.11/);
  assert.match(
    ambig,
    /does the item contain a qualitative attribute with no measurable threshold\?/
  );
  assert.match(ambig, /naming the item \(REQ-XX or AC-XX\)/);
});

test('SUBSPEC rubric checks for REQ-XX without AC or AC without a verifiable pass/fail condition', () => {
  const content = readAgent();
  const subspec = section(content, '### 6.11 Underspecification pass (SUBSPEC)', /\n### 6\.12/);
  assert.match(
    subspec,
    /does this requirement have a testable acceptance criterion\? does each of its acceptance criteria have a verifiable pass\/fail condition\?/
  );
  assert.match(subspec, /zero linked AC-XX/);
});

test('PRINCIPLE rubric checks adherence to declared conventions', () => {
  const content = readAgent();
  const principle = section(content, '### 6.12 Principle-violation pass (PRINCIPLE)', /\n---/);
  assert.match(
    principle,
    /fixed rubric checking adherence of each REQ-XX\/AC-XX to the declared conventions/
  );
});

test('AMBIG pre-filter states a vague-terms dictionary hit selects the item as an LLM candidate', () => {
  const content = readAgent();
  const ambig = section(content, '### 6.10 Ambiguity pass (AMBIG)', /\n### 6\.11/);
  assert.match(ambig, /A term match selects the item as a candidate for LLM confirmation/);
  assert.match(ambig, /No dictionary hit → no candidate, skip the item entirely/);
});

test('vague-terms.md lists specific vague terms for pt-BR, including "escalável"', () => {
  const vagueTerms = fs.readFileSync(VAGUE_TERMS_PATH, 'utf8');
  assert.match(vagueTerms, /## pt-BR/);
  assert.match(vagueTerms, /escalável \/ escalabilidade/);
});

test('AMBIG rubric explicitly states a measurable threshold suppresses the finding', () => {
  const content = readAgent();
  const ambig = section(content, '### 6.10 Ambiguity pass (AMBIG)', /\n### 6\.11/);
  assert.match(
    ambig,
    /if a threshold is present, the sub-agent must return a negative confirmation \(not ambiguous\)/
  );
});

test('AMBIG, SUBSPEC, and PRINCIPLE each state the no-findings → no-section rule', () => {
  const content = readAgent();
  const ambig = section(content, '### 6.10 Ambiguity pass (AMBIG)', /\n### 6\.11/);
  const subspec = section(content, '### 6.11 Underspecification pass (SUBSPEC)', /\n### 6\.12/);
  const principle = section(content, '### 6.12 Principle-violation pass (PRINCIPLE)', /\n---/);

  assert.match(
    ambig,
    /no `AMBIG` findings; the `## Gaps` entries for `AMBIG` are simply absent \(mirrors §6\.7's empty-result rule\)/
  );
  assert.match(
    subspec,
    /no `SUBSPEC` findings; the `## Gaps` entries for `SUBSPEC` are simply absent \(mirrors §6\.7's empty-result rule\)/
  );
  assert.match(
    principle,
    /no `PRINCIPLE` findings; the `## Gaps` entries for `PRINCIPLE` are simply absent \(mirrors §6\.7's empty-result rule\)/
  );
});

test('the Trigger conditions reference documents all seven passes inline', () => {
  const content = readAgent();
  assert.match(content, /### Trigger conditions — quick reference \(all seven passes\)/);
  const table = section(
    content,
    '### Trigger conditions — quick reference (all seven passes)',
    /\n### 6\.7/
  );
  for (let n = 1; n <= 7; n += 1) {
    assert.match(table, new RegExp(`\\| ${n} \\|`), `row ${n} missing from trigger conditions table`);
  }
  assert.match(table, /Ambiguity \(AMBIG\)/);
  assert.match(table, /Underspecification \(SUBSPEC\)/);
  assert.match(table, /Principle violation \(PRINCIPLE\)/);
});

test('AMBIG and SUBSPEC each document an explicit batch cap of 20 sub-agent dispatches per run', () => {
  const content = readAgent();
  const ambig = section(content, '### 6.10 Ambiguity pass (AMBIG)', /\n### 6\.11/);
  const subspec = section(content, '### 6.11 Underspecification pass (SUBSPEC)', /\n### 6\.12/);

  assert.match(ambig, /dispatch at most 20 AMBIG sub-agents per `\/ship:analyze` run/);
  assert.match(subspec, /dispatch at most 20 SUBSPEC sub-agents per `\/ship:analyze` run/);
});
