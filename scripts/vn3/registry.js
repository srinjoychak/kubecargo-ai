// scripts/vn3/registry.js
// Atomic append to .vn-squad/skill-registry.json

import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { execSync } from 'child_process';
import { randomUUID } from 'crypto';

const ROOT = process.cwd();
const REGISTRY_PATH = join(ROOT, '.vn-squad', 'skill-registry.json');

const VALID_TASK_TYPES = new Set(['code','test','research','docs','debug','refactor','review']);
const VALID_FAILURE_CODES = new Set(['EmptyDiff','CompileRed','TestFail','StaleBranch','PromptMisdelivery','ProviderFailure','none']);

function getCurrentBranch() {
  try { return execSync('git rev-parse --abbrev-ref HEAD', { encoding: 'utf8' }).trim(); }
  catch { return 'unknown'; }
}

function getHeadCommit() {
  try { return execSync('git rev-parse HEAD', { encoding: 'utf8' }).trim(); }
  catch { return 'unknown'; }
}

function readRegistry() {
  if (!existsSync(REGISTRY_PATH)) return { schema_version: 1, entries: [] };
  try {
    const data = JSON.parse(readFileSync(REGISTRY_PATH, 'utf8'));
    if (data.schema_version !== 1) throw new Error('schema_version mismatch');
    return data;
  } catch (e) {
    execSync(`mv "${REGISTRY_PATH}" "${REGISTRY_PATH}.bak"`);
    console.warn(`⚠ skill-registry.json corrupted — renamed to .bak, reinitializing`);
    return { schema_version: 1, entries: [] };
  }
}

export function appendEntry(entry) {
  const task_type = entry.task_type;
  const failure_code = entry.failure_code || 'none';

  if (!VALID_TASK_TYPES.has(task_type)) {
    throw new Error(`Invalid task_type: ${task_type}. Must be one of: ${[...VALID_TASK_TYPES].join(', ')}`);
  }

  const registry = readRegistry();
  const fullEntry = {
    id: randomUUID(),
    timestamp: new Date().toISOString(),
    branch: getCurrentBranch(),
    head_commit: getHeadCommit(),
    skill: entry.skill || '/dispatch',
    agent: entry.agent,
    model: entry.model || null,
    task_type,
    outcome: entry.outcome,
    failure_code: VALID_FAILURE_CODES.has(failure_code) ? failure_code : 'none',
    recovery_used: entry.recovery_used || null,
    recovery_outcome: entry.recovery_outcome || null,
    quality_signals: {
      review_verdict: entry.quality_signals?.review_verdict || null,
      files_changed: entry.quality_signals?.files_changed ?? null,
      test_coverage: entry.quality_signals?.test_coverage || null
    }
  };

  registry.entries.push(fullEntry);

  const tmp = join(tmpdir(), `skill-registry-${Date.now()}.json`);
  writeFileSync(tmp, JSON.stringify(registry, null, 2) + '\n');
  execSync(`mv "${tmp}" "${REGISTRY_PATH}"`);

  return fullEntry;
}

export function readEntries(allEntries = false) {
  const registry = readRegistry();
  if (allEntries) return registry.entries;
  const cutoff = new Date();
  cutoff.setMonth(cutoff.getMonth() - 6);
  return registry.entries.filter(e => new Date(e.timestamp) >= cutoff);
}

// CLI
if (process.argv[2] === '--append') {
  const entry = JSON.parse(process.argv[3]);
  const result = appendEntry(entry);
  console.log('✓ appended:', result.id);
} else if (process.argv[2] === '--list') {
  const entries = readEntries();
  console.log(`${entries.length} active entries (last 6 months)`);
  entries.slice(-5).forEach(e => console.log(`  ${e.timestamp.slice(0,10)} ${e.agent} ${e.task_type} → ${e.outcome}`));
}
