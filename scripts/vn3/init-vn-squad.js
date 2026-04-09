#!/usr/bin/env node
// scripts/vn3/init-vn-squad.js
// Idempotent bootstrap: creates .vn-squad/ and all v3 JSON artifacts if missing.

import { existsSync, mkdirSync, writeFileSync } from 'fs';
import { join } from 'path';
import { randomUUID } from 'crypto';
import { execSync } from 'child_process';

const ROOT = process.cwd();
const VN3 = join(ROOT, '.vn-squad');
const ARCHIVE = join(VN3, 'skill-registry-archive');
const TRAJECTORIES = join(VN3, 'trajectories');
const SKILLS = join(VN3, 'skills');
const PROFILES = join(VN3, 'specialization-profile');

function ensureDir(p) {
  if (!existsSync(p)) { mkdirSync(p, { recursive: true }); console.log(`created ${p}`); }
}

function writeIfMissing(p, data) {
  if (!existsSync(p)) {
    writeFileSync(p, JSON.stringify(data, null, 2) + '\n');
    console.log(`created ${p}`);
  } else {
    console.log(`exists  ${p}`);
  }
}

function getBranch() {
  try { return execSync('git rev-parse --abbrev-ref HEAD', { encoding: 'utf8' }).trim(); }
  catch { return 'unknown'; }
}

// Ensure directories
[VN3, ARCHIVE, TRAJECTORIES, SKILLS, PROFILES].forEach(ensureDir);

const now = new Date().toISOString();

writeIfMissing(join(VN3, 'skill-registry.json'), { schema_version: 1, entries: [] });
writeIfMissing(join(VN3, 'decisions.json'), { schema_version: 1, entries: [] });
writeIfMissing(join(VN3, 'session-context.json'), {
  schema_version: 1, session_id: randomUUID(), branch: getBranch(),
  created_at: now, seeded_from_trajectory: null, conventions: {},
  rejected_keys: [], pending_proposals: [], completed_tasks: []
});
writeIfMissing(join(VN3, 'prompt-patches.json'), { schema_version: 1, patches: [] });

for (const agent of ['gemini-worker', 'codex-worker', 'claude-subagent']) {
  writeIfMissing(join(PROFILES, `${agent}.json`), {
    agent, last_recomputed_at: now, registry_entry_count_at_recompute: 0,
    strengths: [], weaknesses: [], constraints: []
  });
}

console.log('\n✓ .vn-squad/ initialized');
