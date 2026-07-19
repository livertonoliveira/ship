#!/usr/bin/env node

'use strict';

// Session timing analyzer — turns a Claude Code session JSONL (plus any
// sub-agent transcripts) into per-transcript wall-clock, model breakdown, and
// assistant-turn counts. Use it to measure a real `/ship:run` or
// `/ship:audit:run` and see where wall-clock goes by nesting level, so
// decisions about flattening agent levels rest on data, not estimates.
//
//   node scripts/session-timing.js <session-id>.jsonl [more.jsonl ...]
//
// With no extra args it auto-discovers sub-agent transcripts under the sibling
// `<session-id>/subagents/*.jsonl` directory (Claude Code's layout).

const fs = require('fs');
const path = require('path');

function parseTranscript(text) {
  let start = null;
  let end = null;
  let turns = 0;
  const models = new Map();

  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line) continue;
    let rec;
    try {
      rec = JSON.parse(line);
    } catch {
      continue;
    }

    const ts = rec.timestamp ? Date.parse(rec.timestamp) : NaN;
    if (!Number.isNaN(ts)) {
      if (start === null || ts < start) start = ts;
      if (end === null || ts > end) end = ts;
    }

    const model = rec.message && rec.message.model;
    if (model) {
      turns += 1;
      models.set(model, (models.get(model) || 0) + 1);
    }
  }

  const durationMs = start !== null && end !== null ? end - start : 0;
  return { start, end, durationMs, turns, models };
}

function discoverTranscripts(inputs) {
  if (inputs.length !== 1) return inputs;
  const only = inputs[0];
  const dir = only.replace(/\.jsonl$/, '');
  const subDir = path.join(dir, 'subagents');
  const found = [only];
  if (fs.existsSync(subDir) && fs.statSync(subDir).isDirectory()) {
    for (const name of fs.readdirSync(subDir).sort()) {
      if (name.endsWith('.jsonl')) found.push(path.join(subDir, name));
    }
  }
  return found;
}

function analyze(files) {
  const rows = [];
  for (const file of files) {
    if (!fs.existsSync(file)) {
      process.stderr.write(`skip (not found): ${file}\n`);
      continue;
    }
    const t = parseTranscript(fs.readFileSync(file, 'utf8'));
    rows.push({ file, ...t });
  }
  return rows;
}

function modelsLabel(models) {
  if (models.size === 0) return '-';
  return [...models.entries()].map(([m, n]) => `${m}:${n}`).join(' ');
}

function main(argv) {
  const inputs = argv.slice(2);
  if (inputs.length === 0) {
    process.stderr.write('usage: session-timing.js <session>.jsonl [more.jsonl ...]\n');
    process.exit(1);
  }
  const files = discoverTranscripts(inputs);
  const rows = analyze(files);

  console.log('duration_s\tturns\tmodels\ttranscript');
  let wallStart = null;
  let wallEnd = null;
  let totalTurns = 0;
  for (const r of rows) {
    console.log(
      `${(r.durationMs / 1000).toFixed(1)}\t${r.turns}\t${modelsLabel(r.models)}\t${path.basename(r.file)}`
    );
    totalTurns += r.turns;
    if (r.start !== null && (wallStart === null || r.start < wallStart)) wallStart = r.start;
    if (r.end !== null && (wallEnd === null || r.end > wallEnd)) wallEnd = r.end;
  }
  const wallMs = wallStart !== null && wallEnd !== null ? wallEnd - wallStart : 0;
  console.log(`\nWall-clock (main + sub-agents overlap): ${(wallMs / 1000).toFixed(1)}s`);
  console.log(`Total assistant turns: ${totalTurns} across ${rows.length} transcript(s)`);
}

if (require.main === module) {
  main(process.argv);
}

module.exports = { parseTranscript, discoverTranscripts, analyze };
