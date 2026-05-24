#!/usr/bin/env node

'use strict';

const fs = require('fs');
const path = require('path');

const PLUGIN_ROOT = path.resolve(__dirname, '..');
const REPO_ROOT = path.resolve(PLUGIN_ROOT, '..', '..');
const SOURCE_ROOT = path.join(REPO_ROOT, 'src');
const SOURCE_SKILLS = path.join(SOURCE_ROOT, 'skills');
const OUTPUT_SKILLS = path.join(PLUGIN_ROOT, 'skills');

const MAX_DEPTH = 10;

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
    const refRe = /@ship\/([^\s)]+\.md)/g;
    if (!refRe.test(result)) break;

    if (depth >= MAX_DEPTH) {
      console.error(`Erro: possível referência circular em ${skillRelPath} (profundidade máxima ${MAX_DEPTH} atingida)`);
      process.exit(1);
    }

    result = result.replace(/@ship\/([^\s)]+\.md)/g, (match, ref) => {
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

function main() {
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
    console.log(`✓ ${skillRelPath}`);
    count++;
  }

  console.log(`\nBuild concluído. ${count} SKILL.md gerados em ${path.relative(REPO_ROOT, OUTPUT_SKILLS)}/.`);
}

main();
