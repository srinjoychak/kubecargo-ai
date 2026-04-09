// scripts/vn3/patches.js
// prompt-patches lifecycle: add, expire (10 type-matched samples with 0 successes), graduate (>=5 successes).

import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { execSync } from 'child_process';
import { randomUUID } from 'crypto';
import { appendDecision } from './decisions.js';

const ROOT = process.cwd();
const PATCHES_PATH = join(ROOT, '.vn-squad', 'prompt-patches.json');
const MAX_PER_AGENT_CATEGORY = 5;

function read() {
  if (!existsSync(PATCHES_PATH)) return { schema_version: 1, patches: [] };
  return JSON.parse(readFileSync(PATCHES_PATH, 'utf8'));
}

function write(data) {
  const tmp = join(tmpdir(), `patches-${Date.now()}.json`);
  writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n');
  execSync(`mv "${tmp}" "${PATCHES_PATH}"`);
}

export function addPatch(patch) {
  const data = read();
  const activeInCategory = data.patches.filter(
    p => p.agent === patch.agent && p.category === patch.category && p.status === 'active'
  );

  if (activeInCategory.length >= MAX_PER_AGENT_CATEGORY) {
    // Find lowest-validated to surface conflict
    const lowest = activeInCategory.sort((a, b) => a.validated_successes - b.validated_successes)[0];
    const newPatch = { id: randomUUID(), ...patch, status: 'pending-conflict', samples_seen: 0, validated_successes: 0, added: new Date().toISOString(), conflict_with: lowest.id };
    data.patches.push(newPatch);
    write(data);
    console.warn(`⚠ CONFLICT: ${patch.agent}/${patch.category} at max (${MAX_PER_AGENT_CATEGORY}). Patch pending-conflict vs "${lowest.constraint.slice(0,40)}..." (${lowest.validated_successes} successes)`);
    return newPatch;
  }

  const newPatch = { id: randomUUID(), ...patch, status: 'active', samples_seen: 0, validated_successes: 0, added: new Date().toISOString() };
  data.patches.push(newPatch);
  write(data);
  appendDecision({ type: 'patch_added', agent: patch.agent, task_type: patch.target_task_types?.join(','), reason: patch.rationale });
  console.log(`✓ patch added: ${patch.agent}/${patch.category} — "${patch.constraint.slice(0, 60)}..."`);
  return newPatch;
}

export function recordDispatch(agent, taskType, wasSuccess) {
  const data = read();
  let changed = false;
  const graduated = [];

  data.patches = data.patches.map(p => {
    if (p.status !== 'active') return p;
    if (p.agent !== agent || !p.target_task_types?.includes(taskType)) return p;

    p.samples_seen = (p.samples_seen || 0) + 1;
    if (wasSuccess) p.validated_successes = (p.validated_successes || 0) + 1;
    changed = true;

    // Expiry: 10 type-matched samples with 0 successes
    if (p.samples_seen >= 10 && p.validated_successes === 0) {
      p.status = 'expired';
      appendDecision({ type: 'patch_expired', agent, task_type: taskType, reason: `0 successes after ${p.samples_seen} samples` });
      console.log(`✓ patch expired: ${p.id}`);
    }

    // Graduation: >= 5 validated_successes
    if (p.validated_successes >= 5 && p.status === 'active') {
      p.status = 'graduated';
      graduated.push(p);
      appendDecision({ type: 'patch_graduated', agent, task_type: taskType, reason: `${p.validated_successes} validated successes` });
      console.log(`★ patch graduated (promote to AGENTS.md): "${p.constraint.slice(0, 60)}..."`);
    }

    return p;
  });

  if (changed) write(data);
  return graduated;
}

export function getActivePatches(agent) {
  return read().patches.filter(p => p.agent === agent && p.status === 'active');
}

if (process.argv[2] === '--list') {
  const data = read();
  if (data.patches.length === 0) { console.log('No patches yet'); process.exit(0); }
  data.patches.forEach(p => console.log(`${p.status.padEnd(16)} ${p.agent} [${p.category}] samples=${p.samples_seen} successes=${p.validated_successes}`));
}
