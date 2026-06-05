#!/usr/bin/env node

'use strict';

const fs = require('fs');
const path = require('path');

const PLUGIN_ROOT = path.resolve(__dirname, '..');
const REPO_ROOT = path.resolve(PLUGIN_ROOT, '..', '..');
const SOURCE_ROOT = path.join(REPO_ROOT, 'src');
const SOURCE_SKILLS = path.join(SOURCE_ROOT, 'skills');
const SOURCE_AGENTS = path.join(SOURCE_ROOT, 'agents');
const SOURCE_HOOKS = path.join(SOURCE_ROOT, 'hooks');
const OUTPUT_SKILLS = path.join(PLUGIN_ROOT, 'skills');
const OUTPUT_AGENTS = path.join(PLUGIN_ROOT, 'agents');
const OUTPUT_HOOKS = path.join(PLUGIN_ROOT, 'hooks');

const MAX_DEPTH = 10;
const HAS_REF = /@ship\/([^\s)]+\.md)/;
const REPLACE_REF = /@ship\/([^\s)]+\.md)/g;

const readCache = new Map();

function readFileCached(absPath) {
  if (!readCache.has(absPath)) {
    readCache.set(absPath, fs.readFileSync(absPath, 'utf8'));
  }
  return readCache.get(absPath);
}

function walkSkillFiles(dir, results = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walkSkillFiles(full, results);
    } else if (entry.name === 'SKILL.md') {
      results.push(full);
    }
  }
  return results;
}

function resolveRefs(content, skillRelPath) {
  let result = content;
  let depth = 0;

  while (true) {
    if (!HAS_REF.test(result)) break;

    if (depth >= MAX_DEPTH) {
      console.error(`Erro: possível referência circular em ${skillRelPath} (profundidade máxima ${MAX_DEPTH} atingida)`);
      process.exit(1);
    }

    result = result.replace(REPLACE_REF, (match, ref) => {
      const refPath = path.join(SOURCE_ROOT, ref);
      if (!fs.existsSync(refPath)) {
        console.error(`Erro: referência quebrada em ${skillRelPath}: @ship/${ref}`);
        process.exit(1);
      }
      console.log(`  ${skillRelPath} ← @ship/${ref}`);
      return readFileCached(refPath).trim();
    });

    depth++;
  }

  return result;
}

function walkAgentFiles(dir, results = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isFile() && entry.name.endsWith('.md')) {
      results.push(full);
    }
  }
  return results;
}

function buildSkills() {
  fs.rmSync(OUTPUT_SKILLS, { recursive: true, force: true });
  const skillFiles = walkSkillFiles(SOURCE_SKILLS);
  let count = 0;

  for (const skillPath of skillFiles) {
    const skillRelPath = path.relative(SOURCE_SKILLS, skillPath);
    const raw = fs.readFileSync(skillPath, 'utf8');
    const substituted = resolveRefs(raw, skillRelPath);
    const outPath = path.join(OUTPUT_SKILLS, skillRelPath);
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, substituted, 'utf8');
    console.log(`✓ skills/${skillRelPath}`);
    count++;
  }
  return count;
}

function buildAgents() {
  fs.rmSync(OUTPUT_AGENTS, { recursive: true, force: true });
  fs.mkdirSync(OUTPUT_AGENTS, { recursive: true });
  const agentFiles = walkAgentFiles(SOURCE_AGENTS);
  let count = 0;

  for (const agentPath of agentFiles) {
    const agentRelPath = path.relative(SOURCE_AGENTS, agentPath);
    const raw = fs.readFileSync(agentPath, 'utf8');
    const substituted = resolveRefs(raw, `agents/${agentRelPath}`);
    const outPath = path.join(OUTPUT_AGENTS, agentRelPath);
    fs.writeFileSync(outPath, substituted, 'utf8');
    console.log(`✓ agents/${agentRelPath}`);
    count++;
  }
  return count;
}

function buildHooks() {
  fs.rmSync(OUTPUT_HOOKS, { recursive: true, force: true });
  if (!fs.existsSync(SOURCE_HOOKS)) return 0;
  fs.mkdirSync(OUTPUT_HOOKS, { recursive: true });
  let count = 0;

  for (const entry of fs.readdirSync(SOURCE_HOOKS, { withFileTypes: true })) {
    if (!entry.isFile()) continue;
    const src = path.join(SOURCE_HOOKS, entry.name);
    const out = path.join(OUTPUT_HOOKS, entry.name);
    fs.copyFileSync(src, out);
    if (entry.name.endsWith('.sh')) fs.chmodSync(out, 0o755);
    console.log(`✓ hooks/${entry.name}`);
    count++;
  }
  return count;
}

function main() {
  const skillCount = buildSkills();
  const agentCount = buildAgents();
  const hookCount = buildHooks();
  console.log(`\nBuild concluído. ${skillCount} SKILL.md + ${agentCount} agents + ${hookCount} hooks gerados em ${path.relative(REPO_ROOT, PLUGIN_ROOT)}/.`);
}

main();
