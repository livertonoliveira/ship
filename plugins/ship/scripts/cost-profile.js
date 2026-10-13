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

function profileSession(file, node, since, timings) {
  const dir = file.replace(/\.jsonl$/, '');
  const stat = fs.statSync(file);
  if (since && stat.mtimeMs < since) return;
  node.sessions += 1;
  parseTranscript(file, node.categories.orchestration);
  chargeTurnsToPhases(file, timings, node.orchestrationByPhase);
  const subDir = path.join(dir, 'subagents');
  if (!fs.existsSync(subDir)) return;
  for (const name of fs.readdirSync(subDir)) {
    if (!name.endsWith('.jsonl')) continue;
    let meta = null;
    try { meta = JSON.parse(fs.readFileSync(path.join(subDir, name.replace(/\.jsonl$/, '.meta.json')), 'utf8')); } catch { /* no meta */ }
    const sub = path.join(subDir, name);
    const cat = categoryOf(meta, sub);
    if (!node.categories[cat]) node.categories[cat] = emptyBucket();
    parseTranscript(sub, node.categories[cat]);
    // A standalone /ship:run is a fork: the pipeline's orchestrating turns are
    // in that subagent, not in the session that launched it.
    if (cat === 'run') chargeTurnsToPhases(sub, timings, node.orchestrationByPhase);
  }
}

// A node's `timings.tsv` (epoch, phase, tool, name — one row per dispatch) is
// the only record of which phase the orchestrating session was in at a given
// moment. Each orchestration turn is charged to the phase dispatched last
// before it; turns before the first dispatch are `init`.
function readTimings(file) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return []; }
  return text.split('\n').map((l) => l.split('\t')).filter((c) => c.length >= 2 && /^\d+$/.test(c[0]))
    .map((c) => ({ at: Number(c[0]) * 1000, phase: c[1] })).sort((a, b) => a.at - b.at);
}

function phaseAt(timings, ts) {
  let phase = 'init';
  for (const t of timings) {
    if (t.at <= ts) phase = t.phase; else break;
  }
  return phase;
}

// The node's task id is the tail of its workspace name (`...-MOB-5670`,
// `...-MOB-5655-2`). A workspace named otherwise (a smoke test's temp dir) is
// matched when the artifacts dir holds exactly one task.
function timingsFor(nodeName, artifactsDirs) {
  const m = /([A-Z]+-\d+)(?:-\d+)?$/.exec(nodeName);
  for (const dir of artifactsDirs) {
    if (m) {
      const f = path.join(dir, m[1], 'timings.tsv');
      if (fs.existsSync(f)) return readTimings(f);
      continue;
    }
    let tasks = [];
    try { tasks = fs.readdirSync(dir).filter((t) => fs.existsSync(path.join(dir, t, 'timings.tsv'))); } catch { /* not a dir */ }
    if (tasks.length === 1) return readTimings(path.join(dir, tasks[0], 'timings.tsv'));
  }
  return [];
}

function chargeTurnsToPhases(file, timings, byPhase) {
  if (!timings.length) return;
  const seen = new Set();
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return; }
  for (const raw of text.split('\n')) {
    if (!raw.trim()) continue;
    let rec;
    try { rec = JSON.parse(raw); } catch { continue; }
    if (rec.type !== 'assistant' || !rec.message || !rec.message.usage) continue;
    const key = `${rec.message.id}|${rec.requestId || ''}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const ts = Date.parse(rec.timestamp);
    if (Number.isNaN(ts)) continue;
    const phase = phaseAt(timings, ts);
    if (!byPhase[phase]) byPhase[phase] = emptyBucket();
    addTurn(byPhase[phase], rec, rec.message.usage, rec.message.model);
  }
}

function profileNode(input, since, artifactsDirs) {
  const node = { name: path.basename(input).replace(/\.jsonl$/, ''), sessions: 0, categories: { orchestration: emptyBucket() }, orchestrationByPhase: {} };
  const timings = artifactsDirs && artifactsDirs.length ? timingsFor(node.name, artifactsDirs) : [];
  const sessions = input.endsWith('.jsonl') ? [input]
    : fs.readdirSync(input).sort().filter((n) => n.endsWith('.jsonl')).map((n) => path.join(input, n));
  for (const s of sessions) profileSession(s, node, since, timings);
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
  const phases = {};
  let phasedNodes = 0;
  for (const n of nodes) {
    const entries = Object.entries(n.orchestrationByPhase || {});
    if (!entries.length) continue;
    phasedNodes += 1;
    for (const [p, b] of entries) {
      if (!phases[p]) phases[p] = { cost: 0, turns: 0, output: 0 };
      phases[p].cost += b.cost; phases[p].turns += b.turns; phases[p].output += b.output;
    }
  }
  if (phasedNodes) {
    const orchTotal = Object.values(phases).reduce((s, p) => s + p.cost, 0);
    lines.push('');
    lines.push(`orchestration turns by pipeline phase (${phasedNodes} node(s) with timings; a phase owns the turns between its dispatch and the next one, 'init' the turns before the first):`);
    lines.push(`  ${pad('phase', 20)} ${lpad('$', 8)} ${lpad('share', 6)} ${lpad('turns', 6)} ${lpad('turns/node', 10)} ${lpad('out-tok', 8)}`);
    for (const [p, v] of Object.entries(phases).sort((a, b) => b[1].cost - a[1].cost)) {
      lines.push(`  ${pad(p, 20)} ${lpad(fmt(v.cost), 8)} ${lpad(orchTotal ? fmt(100 * v.cost / orchTotal, 0) + '%' : '-', 6)} ${lpad(v.turns, 6)} ${lpad(fmt(v.turns / phasedNodes, 1), 10)} ${lpad(v.output, 8)}`);
    }
  }
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
  const artifacts = [];
  const inputs = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--json') json = true;
    else if (a === '--since') since = Date.parse(args[++i]);
    else if (a === '--prefix') prefix = args[++i];
    else if (a === '--artifacts') artifacts.push(args[++i]);
    else inputs.push(a);
  }
  if (prefix) {
    const root = path.join(os.homedir(), '.claude', 'projects');
    for (const name of fs.readdirSync(root).sort()) {
      if (name.includes(prefix)) inputs.push(path.join(root, name));
    }
  }
  if (!inputs.length) {
    process.stderr.write('usage: cost-profile.js [--json] [--since ISO] [--prefix <project-dir-substring>] [--artifacts <dir-with-<task>/timings.tsv>]... <project-dir|session.jsonl> ...\n');
    process.exit(2);
  }
  const nodes = inputs.filter((p) => fs.existsSync(p)).map((p) => profileNode(p, since, artifacts)).filter((n) => n.sessions > 0);
  if (json) {
    process.stdout.write(JSON.stringify(nodes, null, 2) + '\n');
  } else {
    process.stdout.write(render(nodes) + '\n');
  }
}

if (require.main === module) main(process.argv);

module.exports = { parseTranscript, profileNode, priceOf, emptyBucket, categoryOf };
