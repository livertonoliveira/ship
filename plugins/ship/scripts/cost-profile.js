#!/usr/bin/env node

'use strict';

// Cost profile of Ship runs, read from Claude Code transcripts.
//
//   node scripts/cost-profile.js [--json] [--since ISO] <project-dir | session.jsonl> ...
//   node scripts/cost-profile.js --prefix api-astros-MOB-        # every node dir under ~/.claude/projects
//
// A "node" is one project dir under ~/.claude/projects (one workspace = one
// task). Each session.jsonl in it is the orchestrating session; its
// `<session-id>/subagents/*.jsonl` are the workers, categorised by the
// agentType in the sibling `.meta.json`.
//
// Cost = input + cache writes (5m 1.25x, 1h 2x input price) + cache reads +
// output, at Anthropic list prices. Usage is deduped per (message.id,
// requestId): streaming repeats the same usage on every chunk of a message.

const fs = require('fs');
const os = require('os');
const path = require('path');

const PRICES = {
  'claude-fable-5-1': { in: 10, out: 50, read: 0.25 },
  'claude-fable-5': { in: 10, out: 50, read: 1.0 },
  'claude-opus-5-5': { in: 4, out: 20, read: 0.2 },
  'claude-opus-5': { in: 5, out: 25, read: 0.5 },
  'claude-opus-4-8': { in: 5, out: 25, read: 0.5 },
  'claude-opus-4-7': { in: 5, out: 25, read: 0.5 },
  'claude-opus-4-6': { in: 5, out: 25, read: 0.5 },
  'claude-sonnet-5-5': { in: 2, out: 10, read: 0.2 },
  'claude-sonnet-5': { in: 2, out: 10, read: 0.2 },
  'claude-sonnet-4-6': { in: 3, out: 15, read: 0.3 },
  'claude-haiku-5-5': { in: 0.1, out: 0.5, read: 0.01 },
  'claude-haiku-4-5': { in: 1, out: 5, read: 0.1 },
};
const ALIASES = { sonnet: 'claude-sonnet-5-5', opus: 'claude-opus-5-5', haiku: 'claude-haiku-5-5' };

function priceOf(model) {
  if (!model) return null;
  if (PRICES[model]) return PRICES[model];
  if (ALIASES[model]) return PRICES[ALIASES[model]];
  const m = /^claude-(fable|opus|sonnet|haiku)-(\d+)(?:-(\d+))?/.exec(model);
  if (m) {
    const key = `claude-${m[1]}-${m[2]}${m[3] ? '-' + m[3] : ''}`;
    if (PRICES[key]) return PRICES[key];
  }
  return null;
}

function emptyBucket() {
  return {
    cost: 0, turns: 0, input: 0, cacheWrite: 0, cacheRead: 0, output: 0,
    tools: {}, models: {}, unknownModels: {}, maxContext: 0, start: null, end: null,
  };
}

function addTurn(bucket, rec, usage, model) {
  const p = priceOf(model);
  const input = usage.input_tokens || 0;
  const output = usage.output_tokens || 0;
  const read = usage.cache_read_input_tokens || 0;
  const cc = usage.cache_creation || {};
  const w5 = cc.ephemeral_5m_input_tokens;
  const w1 = cc.ephemeral_1h_input_tokens;
  const writeTotal = usage.cache_creation_input_tokens || 0;
  const w5m = w5 == null && w1 == null ? writeTotal : (w5 || 0);
  const w1h = w1 || 0;
  bucket.turns += 1;
  bucket.input += input;
  bucket.cacheWrite += w5m + w1h;
  bucket.cacheRead += read;
  bucket.output += output;
  bucket.maxContext = Math.max(bucket.maxContext, input + read + w5m + w1h);
  bucket.models[model] = (bucket.models[model] || 0) + 1;
  if (p) {
    bucket.cost += (input * p.in + w5m * p.in * 1.25 + w1h * p.in * 2 + read * p.read + output * p.out) / 1e6;
  } else {
    bucket.unknownModels[model] = (bucket.unknownModels[model] || 0) + 1;
  }
  const ts = rec.timestamp ? Date.parse(rec.timestamp) : NaN;
  if (!Number.isNaN(ts)) {
    if (bucket.start === null || ts < bucket.start) bucket.start = ts;
    if (bucket.end === null || ts > bucket.end) bucket.end = ts;
  }
}

function parseTranscript(file, bucket) {
  const seen = new Map();
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return; }
  for (const raw of text.split('\n')) {
    if (!raw.trim()) continue;
    let rec;
    try { rec = JSON.parse(raw); } catch { continue; }
    if (rec.type !== 'assistant' || !rec.message) continue;
    const msg = rec.message;
    for (const block of msg.content || []) {
      if (block && block.type === 'tool_use') {
        const key = `${msg.id}|${block.id}`;
        if (!seen.has(key)) {
          seen.set(key, true);
          bucket.tools[block.name] = (bucket.tools[block.name] || 0) + 1;
        }
      }
    }
    if (!msg.usage) continue;
    const key = `${msg.id}|${rec.requestId || ''}`;
    seen.set(key, { rec, usage: msg.usage, model: msg.model });
  }
  for (const [key, v] of seen) {
    if (v === true || key.indexOf('|toolu_') > 0) continue;
    addTurn(bucket, v.rec, v.usage, v.model);
  }
}

// A forked skill (`context: fork`) is recorded as a general-purpose agent with
// no description; its first user turn opens with the skill's base directory.
function forkedSkill(file) {
  let fd;
  try { fd = fs.openSync(file, 'r'); } catch { return null; }
  const buf = Buffer.alloc(64 * 1024);
  const n = fs.readSync(fd, buf, 0, buf.length, 0);
  fs.closeSync(fd);
  const m = /Base directory for this skill: [^\n"]*\/skills\/([a-z:-]+)/.exec(buf.toString('utf8', 0, n));
  return m ? m[1] : null;
}

function categoryOf(meta, file) {
  let t = (meta && (meta.agentType || meta.description)) || 'unknown';
  if (t === 'general-purpose' && file) t = forkedSkill(file) || t;
  if (/test-(unit|integration|e2e)/.test(t)) return 'tests';
  if (/ship-(perf|security|review)/.test(t)) return 'quality';
  if (/remediation/.test(t)) return 'remediation';
  if (/audit/.test(t)) return 'audit';
  return t;
}

function profileSession(file, node, since) {
  const dir = file.replace(/\.jsonl$/, '');
  const stat = fs.statSync(file);
  if (since && stat.mtimeMs < since) return;
  node.sessions += 1;
  parseTranscript(file, node.categories.orchestration);
  const subDir = path.join(dir, 'subagents');
  if (!fs.existsSync(subDir)) return;
  for (const name of fs.readdirSync(subDir)) {
    if (!name.endsWith('.jsonl')) continue;
    let meta = null;
    try { meta = JSON.parse(fs.readFileSync(path.join(subDir, name.replace(/\.jsonl$/, '.meta.json')), 'utf8')); } catch { /* no meta */ }
    const cat = categoryOf(meta, path.join(subDir, name));
    if (!node.categories[cat]) node.categories[cat] = emptyBucket();
    parseTranscript(path.join(subDir, name), node.categories[cat]);
  }
}

function profileNode(input, since) {
  const node = { name: path.basename(input).replace(/\.jsonl$/, ''), sessions: 0, categories: { orchestration: emptyBucket() } };
  if (input.endsWith('.jsonl')) {
    profileSession(input, node, since);
  } else {
    for (const name of fs.readdirSync(input).sort()) {
      if (name.endsWith('.jsonl')) profileSession(path.join(input, name), node, since);
    }
  }
  node.total = Object.values(node.categories).reduce((s, b) => s + b.cost, 0);
  return node;
}

function fmt(n, d = 2) { return n.toFixed(d); }
function pad(s, w) { s = String(s); return s.length >= w ? s : s + ' '.repeat(w - s.length); }
function lpad(s, w) { s = String(s); return s.length >= w ? s : ' '.repeat(w - s.length) + s; }

function render(nodes) {
  const lines = [];
  const grand = nodes.reduce((s, n) => s + n.total, 0);
  lines.push(`${nodes.length} node(s), total $${fmt(grand)}, mean $${fmt(nodes.length ? grand / nodes.length : 0)}/node`);
  lines.push('');
  lines.push(`${pad('node', 44)} ${lpad('$', 8)} ${lpad('orch%', 6)} ${lpad('turns', 6)} ${lpad('ctx-max', 8)} ${lpad('linear', 6)} ${lpad('agents', 6)}`);
  for (const n of nodes) {
    const o = n.categories.orchestration;
    const linear = Object.entries(o.tools).filter(([k]) => k.startsWith('mcp__linear')).reduce((s, [, v]) => s + v, 0);
    const agents = Object.keys(n.categories).length - 1;
    lines.push(`${pad(n.name, 44)} ${lpad(fmt(n.total), 8)} ${lpad(n.total ? fmt(100 * o.cost / n.total, 0) : '-', 6)} ${lpad(o.turns, 6)} ${lpad(Math.round(o.maxContext / 1000) + 'k', 8)} ${lpad(linear, 6)} ${lpad(agents, 6)}`);
  }
  lines.push('');
  const cats = {};
  for (const n of nodes) for (const [c, b] of Object.entries(n.categories)) cats[c] = (cats[c] || 0) + b.cost;
  lines.push(`${pad('category', 28)} ${lpad('$', 10)} ${lpad('share', 6)}`);
  for (const [c, v] of Object.entries(cats).sort((a, b) => b[1] - a[1])) {
    lines.push(`${pad(c, 28)} ${lpad(fmt(v), 10)} ${lpad(grand ? fmt(100 * v / grand, 0) + '%' : '-', 6)}`);
  }
  const tools = {};
  const unknown = {};
  for (const n of nodes) {
    for (const [k, v] of Object.entries(n.categories.orchestration.tools)) tools[k] = (tools[k] || 0) + v;
    for (const b of Object.values(n.categories)) for (const [k, v] of Object.entries(b.unknownModels)) unknown[k] = (unknown[k] || 0) + v;
  }
  lines.push('');
  lines.push('orchestration tool calls (all nodes):');
  for (const [k, v] of Object.entries(tools).sort((a, b) => b[1] - a[1]).slice(0, 15)) lines.push(`  ${pad(k, 40)} ${lpad(v, 6)}`);
  if (Object.keys(unknown).length) {
    lines.push('');
    lines.push(`unpriced models (cost counted as 0): ${JSON.stringify(unknown)}`);
  }
  return lines.join('\n');
}

function main(argv) {
  const args = argv.slice(2);
  let json = false;
  let since = null;
  let prefix = null;
  const inputs = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--json') json = true;
    else if (a === '--since') since = Date.parse(args[++i]);
    else if (a === '--prefix') prefix = args[++i];
    else inputs.push(a);
  }
  if (prefix) {
    const root = path.join(os.homedir(), '.claude', 'projects');
    for (const name of fs.readdirSync(root).sort()) {
      if (name.includes(prefix)) inputs.push(path.join(root, name));
    }
  }
  if (!inputs.length) {
    process.stderr.write('usage: cost-profile.js [--json] [--since ISO] [--prefix <project-dir-substring>] <project-dir|session.jsonl> ...\n');
    process.exit(2);
  }
  const nodes = inputs.filter((p) => fs.existsSync(p)).map((p) => profileNode(p, since)).filter((n) => n.sessions > 0);
  if (json) {
    process.stdout.write(JSON.stringify(nodes, null, 2) + '\n');
  } else {
    process.stdout.write(render(nodes) + '\n');
  }
}

if (require.main === module) main(process.argv);

module.exports = { parseTranscript, profileNode, priceOf, emptyBucket, categoryOf };
