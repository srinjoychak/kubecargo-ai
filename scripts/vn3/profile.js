// scripts/vn3/profile.js
// Recomputes specialization-profile/<agent>.json from skill-registry.json
// Implements: weighted_success_rate = (raw + recovery + confirmed×3) / (samples + confirmed×3)

import { readFileSync, writeFileSync, existsSync, readdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { execSync } from 'child_process';
import { readEntries } from './registry.js';

const ROOT = process.cwd();
const PROFILES_DIR = join(ROOT, '.vn-squad', 'specialization-profile');
const TRAJECTORIES_DIR = join(ROOT, '.vn-squad', 'trajectories');

const AGENTS = ['gemini-worker', 'codex-worker', 'claude-subagent'];
const TASK_TYPES = ['code', 'test', 'research', 'docs', 'debug', 'refactor', 'review'];

function countTrajectories(agent, taskType, prefix) {
  if (!existsSync(TRAJECTORIES_DIR)) return 0;
  return readdirSync(TRAJECTORIES_DIR)
    .filter(f => f.startsWith(prefix))
    .filter(f => {
      try {
        const t = JSON.parse(readFileSync(join(TRAJECTORIES_DIR, f), 'utf8'));
        return t.agent === agent && t.task_type === taskType;
      } catch { return false; }
    }).length;
}

export function recomputeProfiles() {
  const entries = readEntries(); // active entries (last 6 months)

  for (const agent of AGENTS) {
    const profilePath = join(PROFILES_DIR, `${agent}.json`);
    const existing = existsSync(profilePath)
      ? JSON.parse(readFileSync(profilePath, 'utf8')) : {};

    const strengths = [];
    const weaknesses = [];
    const failureModes = {};

    for (const taskType of TASK_TYPES) {
      const agentEntries = entries.filter(e => e.agent === agent && e.task_type === taskType);
      if (agentEntries.length === 0) continue;

      const totalSamples = agentEntries.length;
      const rawSuccesses = agentEntries.filter(e => e.failure_code === 'none' && e.quality_signals?.review_verdict === 'APPROVE').length;
      const recoveryCount = countTrajectories(agent, taskType, 'recovery-');
      const patternConfirmedCount = countTrajectories(agent, taskType, 'pattern-confirmed-');

      const weightedRate = (rawSuccesses + recoveryCount + patternConfirmedCount * 3)
        / Math.max(1, totalSamples + patternConfirmedCount * 3);

      const dataLabel = totalSamples >= 10 ? 'stable' : totalSamples >= 3 ? 'preliminary' : 'insufficient';

      // Aggregate failure codes
      agentEntries
        .filter(e => e.failure_code && e.failure_code !== 'none')
        .forEach(e => { failureModes[e.failure_code] = (failureModes[e.failure_code] || 0) + 1; });

      const stat = { task_type: taskType, weighted_success_rate: +weightedRate.toFixed(3), sample_size: totalSamples, data_label: dataLabel };

      if (weightedRate >= 0.7 && totalSamples >= 3) strengths.push(stat);
      else if (weightedRate < 0.5 && totalSamples >= 3) weaknesses.push(stat);
    }

    const profile = {
      agent,
      last_recomputed_at: new Date().toISOString(),
      registry_entry_count_at_recompute: entries.filter(e => e.agent === agent).length,
      strengths,
      weaknesses,
      failure_modes: failureModes,
      constraints: existing.constraints || []
    };

    const tmp = join(tmpdir(), `profile-${agent}-${Date.now()}.json`);
    writeFileSync(tmp, JSON.stringify(profile, null, 2) + '\n');
    execSync(`mv "${tmp}" "${profilePath}"`);
    console.log(`✓ ${agent}: ${strengths.length} strengths, ${weaknesses.length} weaknesses`);
  }
}

if (process.argv[2] === '--recompute') recomputeProfiles();
