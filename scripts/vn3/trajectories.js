// scripts/vn3/trajectories.js
// Classify and capture trajectory types:
//   success-<uuid>.json        — task-level success + APPROVE verdict
//   recovery-<uuid>.json       — 1st/2nd recovery chain (failure→success)
//   pattern-confirmed-<uuid>.json — 3rd+ occurrence of same (failure_code × task_type)

import { readFileSync, writeFileSync, existsSync, readdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { execSync } from 'child_process';
import { randomUUID } from 'crypto';

const ROOT = process.cwd();
const TRAJ_DIR = join(ROOT, '.vn-squad', 'trajectories');

function countPattern(failureCode, taskType) {
  if (!existsSync(TRAJ_DIR)) return 0;
  return readdirSync(TRAJ_DIR)
    .filter(f => f.startsWith('recovery-') || f.startsWith('pattern-confirmed-'))
    .filter(f => {
      try {
        const t = JSON.parse(readFileSync(join(TRAJ_DIR, f), 'utf8'));
        return t.failure_code === failureCode && t.task_type === taskType;
      } catch { return false; }
    }).length;
}

function saveTrajectory(prefix, data) {
  if (!existsSync(TRAJ_DIR)) execSync(`mkdir -p "${TRAJ_DIR}"`);
  const id = randomUUID();
  const path = join(TRAJ_DIR, `${prefix}${id}.json`);
  const tmp = join(tmpdir(), `traj-${Date.now()}.json`);
  writeFileSync(tmp, JSON.stringify({ id, ...data, timestamp: new Date().toISOString() }, null, 2) + '\n');
  execSync(`mv "${tmp}" "${path}"`);
  console.log(`✓ trajectory saved: ${prefix}${id}`);
  return id;
}

/**
 * Classify and save a trajectory based on the dispatch outcome.
 * @param {object} outcome - Outcome fields from registry entry
 * @param {string} type - 'success' | 'recovery' | 'no_recovery' | 'skip'
 */
export function captureTrajectory(outcome, type) {
  if (type === 'success' && outcome.quality_signals?.review_verdict === 'APPROVE') {
    return saveTrajectory('success-', outcome);
  }

  if (type === 'recovery' && outcome.recovery_outcome === 'success') {
    const existingCount = countPattern(outcome.failure_code, outcome.task_type);
    const prefix = existingCount >= 2 ? 'pattern-confirmed-' : 'recovery-';
    return saveTrajectory(prefix, outcome);
  }

  // Skip: failure with no recovery, duplicate failure (no recovery), borderline quality
  return null;
}

if (process.argv[2] === '--list') {
  if (!existsSync(TRAJ_DIR)) { console.log('No trajectories yet'); process.exit(0); }
  const files = readdirSync(TRAJ_DIR);
  const counts = { 'success-': 0, 'recovery-': 0, 'pattern-confirmed-': 0 };
  files.forEach(f => { for (const p of Object.keys(counts)) if (f.startsWith(p)) counts[p]++; });
  console.log(`Trajectories: success=${counts['success-']} recovery=${counts['recovery-']} pattern-confirmed=${counts['pattern-confirmed-']}`);
}
