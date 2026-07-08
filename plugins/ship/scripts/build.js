#!/usr/bin/env node

'use strict';

const fs = require('fs');
const path = require('path');
const { WORD_BUDGETS, DEFAULT_BUDGET } = require('./budgets');

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
const HAS_REF = /@ship\/[^\s)]+\.md(?:#[A-Za-z0-9_-]+)?/;
const REPLACE_REF = /@ship\/([^\s)]+\.md)(?:#([A-Za-z0-9_-]+))?/g;

const REPLACE_LAZY = /@@ship\/([^\s)]+\.(?:md|sh))(#[A-Za-z0-9_-]+)?/g;

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

function extractSection(content, anchor, refLabel, skillRelPath) {
  const lines = content.split('\n');
  const headingRe = /^(#{1,6})\s/;
  const markerRe = new RegExp('\\{#' + anchor.replace(/[-/\\^$*+?.()|[\]{}]/g, '\\$&') + '\\}');

  let start = -1;
  let level = 0;
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(headingRe);
    if (m && markerRe.test(lines[i])) {
      start = i;
      level = m[1].length;
      break;
    }
  }
  if (start === -1) {
    console.error(`Erro: âncora não encontrada em ${skillRelPath}: @ship/${refLabel}`);
    process.exit(1);
  }

  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    const m = lines[i].match(headingRe);
    if (m && m[1].length <= level) {
      end = i;
      break;
    }
  }

  return lines.slice(start, end).join('\n').trim();
}

function titleCase(slug) {
  return slug
    .split('-')
    .filter(Boolean)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(' ');
}

function pointerFor(ref, anchor) {
  if (anchor) {
    return `the ${titleCase(anchor)} section (included above)`;
  }
  return `the ${path.basename(ref)} pattern (included above)`;
}

function resolveRefs(content, skillRelPath) {
  const seen = new Set();

  function expand(text, depth) {
    if (depth >= MAX_DEPTH) {
      console.error(`Erro: possível referência circular em ${skillRelPath} (profundidade máxima ${MAX_DEPTH} atingida)`);
      process.exit(1);
    }

    return text.replace(REPLACE_REF, (match, ref, anchor) => {
      const refKey = anchor ? `${ref}#${anchor}` : ref;

      if (seen.has(refKey)) {
        return pointerFor(ref, anchor);
      }
      seen.add(refKey);

      const refPath = path.join(SOURCE_ROOT, ref);
      if (!fs.existsSync(refPath)) {
        console.error(`Erro: referência quebrada em ${skillRelPath}: @ship/${ref}`);
        process.exit(1);
      }
      const fileContent = readFileCached(refPath).trim();
      console.log(`  ${skillRelPath} ← @ship/${refKey}`);
      const body = anchor ? extractSection(fileContent, anchor, refKey, skillRelPath) : fileContent;
      return expand(body, depth + 1);
    });
  }

  return expand(content, 0);
}

function processLazyRefs(content, skillRelPath, skillOutDir) {
  return content.replace(REPLACE_LAZY, (match, ref, anchor) => {
    if (anchor) {
      console.error(`Erro: lazy ref com âncora não é suportado em ${skillRelPath}: @@ship/${ref}${anchor} (lazy é whole-file; remova a âncora ou use @ship inline)`);
      process.exit(1);
    }
    const srcPath = path.join(SOURCE_ROOT, ref);
    if (!fs.existsSync(srcPath)) {
      console.error(`Erro: lazy ref quebrada em ${skillRelPath}: @@ship/${ref}`);
      process.exit(1);
    }
    const destPath = path.join(skillOutDir, ref);
    fs.mkdirSync(path.dirname(destPath), { recursive: true });
    if (ref.endsWith('.sh')) {
      fs.copyFileSync(srcPath, destPath);
      fs.chmodSync(destPath, 0o755);
    } else {
      const resolved = resolveRefs(readFileCached(srcPath), `${skillRelPath} → ${ref}`);
      fs.writeFileSync(destPath, resolved, 'utf8');
    }
    console.log(`  ${skillRelPath} ⇢ @@ship/${ref} (bundled, lazy)`);
    return '${CLAUDE_SKILL_DIR}/' + ref;
  });
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

function countWords(content) {
  return content.trim().split(/\s+/).filter(Boolean).length;
}

function checkBudget(skillKey, wordCount, budgets) {
  const limit = Object.prototype.hasOwnProperty.call(budgets, skillKey)
    ? budgets[skillKey]
    : DEFAULT_BUDGET;
  if (wordCount > limit) {
    return { skillKey, wordCount, limit };
  }
  return null;
}

function skillKeyFromRelPath(skillRelPath) {
  return skillRelPath.split(path.sep).join('/').replace(/\/SKILL\.md$/, '');
}

function buildSkills() {
  fs.rmSync(OUTPUT_SKILLS, { recursive: true, force: true });
  const skillFiles = walkSkillFiles(SOURCE_SKILLS);
  let count = 0;
  const entries = [];

  for (const skillPath of skillFiles) {
    const skillRelPath = path.relative(SOURCE_SKILLS, skillPath);
    const raw = fs.readFileSync(skillPath, 'utf8');
    const outPath = path.join(OUTPUT_SKILLS, skillRelPath);
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    const lazyResolved = processLazyRefs(raw, skillRelPath, path.dirname(outPath));
    const substituted = resolveRefs(lazyResolved, skillRelPath);
    fs.writeFileSync(outPath, substituted, 'utf8');
    console.log(`✓ skills/${skillRelPath}`);
    entries.push({ skillKey: skillKeyFromRelPath(skillRelPath), wordCount: countWords(substituted) });
    count++;
  }
  return { count, entries };
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
  const { count: skillCount, entries } = buildSkills();
  const agentCount = buildAgents();
  const hookCount = buildHooks();

  for (const { skillKey, wordCount } of entries) {
    const violation = checkBudget(skillKey, wordCount, WORD_BUDGETS);
    if (violation) {
      console.error(`Erro: ${violation.skillKey} tem ${violation.wordCount} palavras, excede o teto de ${violation.limit}`);
      process.exit(1);
    }
  }

  console.log(`\nBuild concluído. ${skillCount} SKILL.md + ${agentCount} agents + ${hookCount} hooks gerados em ${path.relative(REPO_ROOT, PLUGIN_ROOT)}/.`);
}

if (require.main === module) {
  main();
}

module.exports = { countWords, checkBudget, skillKeyFromRelPath, WORD_BUDGETS, DEFAULT_BUDGET };
