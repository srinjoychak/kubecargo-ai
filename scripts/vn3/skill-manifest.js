#!/usr/bin/env node
// scripts/vn3/skill-manifest.js
// Scans .claude/commands/ and writes .vn-squad/skill-manifest.json
// Safe to run any time — fully idempotent.

import { readdirSync, readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join, basename } from 'path';
import { tmpdir } from 'os';
import { execSync } from 'child_process';

const ROOT = process.cwd();
const COMMANDS_DIR = join(ROOT, '.claude', 'commands');
const VN3_DIR = join(ROOT, '.vn-squad');
const MANIFEST_PATH = join(VN3_DIR, 'skill-manifest.json');

if (!existsSync(VN3_DIR)) mkdirSync(VN3_DIR, { recursive: true });

const CATEGORY_MAP = {
  argue: 'design', dispatch: 'orchestration', finish: 'lifecycle',
  gemini: 'execution', plan: 'planning', review: 'quality',
  verify: 'quality', worktrees: 'orchestration',
  scaffold: 'planning', 'vn3-status': 'observability'
};

const TAG_MAP = {
  argue: ['design', 'debate', 'codex'], dispatch: ['parallel', 'agents', 'orchestration'],
  finish: ['merge', 'pr', 'lifecycle'], gemini: ['gemini', 'research', 'large-context'],
  plan: ['tdd', 'planning', 'decompose'], review: ['review', 'quality'],
  verify: ['verify', 'gate', 'green'], worktrees: ['git', 'isolation'],
  scaffold: ['curriculum', 'tiered', 'planning'], 'vn3-status': ['v3', 'status', 'observability']
};

function extractDescription(content) {
  const lines = content.split('\n');
  for (const line of lines) {
    const h1 = line.match(/^#\s+(.+)/);
    if (h1) return h1[1].trim();
  }
  return 'No description';
}

const files = readdirSync(COMMANDS_DIR).filter(f => f.endsWith('.md'));
const skills = files.map(f => {
  const name = basename(f, '.md');
  const content = readFileSync(join(COMMANDS_DIR, f), 'utf8');
  return {
    name,
    file: `.claude/commands/${f}`,
    description: extractDescription(content),
    category: CATEGORY_MAP[name] || 'general',
    tags: TAG_MAP[name] || [name]
  };
});

const manifest = {
  schema_version: 1,
  generated_at: new Date().toISOString(),
  skills
};

const tmp = join(tmpdir(), `skill-manifest-${Date.now()}.json`);
writeFileSync(tmp, JSON.stringify(manifest, null, 2) + '\n');
execSync(`mv "${tmp}" "${MANIFEST_PATH}"`);

console.log(`✓ skill-manifest.json — ${skills.length} skills indexed`);
skills.forEach(s => console.log(`  ${s.name.padEnd(16)} [${s.category}]  ${s.description.slice(0, 60)}`));
