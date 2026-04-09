// scripts/vn3/routing.js
// Routing decision algorithm: suggest agent override based on specialization profiles.
// Reads specialization-profile/, compares weighted_success_rate vs AGENTS.md static table.

import { readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { appendDecision } from './decisions.js';

const ROOT = process.cwd();
const PROFILES_DIR = join(ROOT, '.vn-squad', 'specialization-profile');

// Static routing table from AGENTS.md (default assignments)
const STATIC_ROUTING = {
  code: 'claude-subagent',
  test: 'claude-subagent',
  research: 'gemini-worker',
  docs: 'gemini-worker',
  debug: 'claude-subagent',
  refactor: 'claude-subagent',
  review: 'codex-worker'
};

function loadProfile(agent) {
  const p = join(PROFILES_DIR, `${agent}.json`);
  return existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : null;
}

/**
 * Get routing suggestion for a task type.
 * Returns { suggested_agent, reason, confidence, data_label } or null if no override.
 */
export function getRoutingSuggestion(taskType) {
  const agents = ['gemini-worker', 'codex-worker', 'claude-subagent'];
  const candidates = [];

  for (const agent of agents) {
    const profile = loadProfile(agent);
    if (!profile) continue;

    const all = [...(profile.strengths || []), ...(profile.weaknesses || [])];
    const stat = all.find(s => s.task_type === taskType);
    if (!stat || stat.sample_size < 3) continue; // insufficient data

    candidates.push({ agent, ...stat });
  }

  if (candidates.length === 0) return null;

  // Sort by weighted_success_rate desc
  candidates.sort((a, b) => b.weighted_success_rate - a.weighted_success_rate);
  const best = candidates[0];
  const defaultAgent = STATIC_ROUTING[taskType];

  // Suggest override if:
  // 1. Best candidate is different from AGENTS.md default
  // 2. Best has rate >= 0.7
  // 3. Default (if measured) has rate < 0.5
  const defaultStat = candidates.find(c => c.agent === defaultAgent);
  const defaultRate = defaultStat?.weighted_success_rate ?? null;

  if (best.agent !== defaultAgent && best.weighted_success_rate >= 0.7
      && (defaultRate === null || defaultRate < 0.5)) {
    return {
      suggested_agent: best.agent,
      default_agent: defaultAgent,
      suggested_rate: best.weighted_success_rate,
      default_rate: defaultRate,
      sample_size: best.sample_size,
      data_label: best.data_label,
      reason: `${best.agent} outperforms ${defaultAgent} on ${taskType} (rate: ${best.weighted_success_rate.toFixed(2)} vs ${defaultRate?.toFixed(2) ?? 'no data'})`
    };
  }

  return null;
}

/**
 * Print routing calibration report for all task types.
 */
export function printRoutingStatus() {
  console.log('\n── VN-Squad v3 Routing Status ──\n');
  const taskTypes = ['code', 'test', 'research', 'docs', 'debug', 'refactor', 'review'];

  for (const tt of taskTypes) {
    const suggestion = getRoutingSuggestion(tt);
    const def = STATIC_ROUTING[tt];
    if (suggestion) {
      console.log(`[OVERRIDE] ${tt.padEnd(10)} → ${suggestion.suggested_agent} (${suggestion.data_label}, n=${suggestion.sample_size}, rate=${suggestion.suggested_rate.toFixed(2)})`);
      console.log(`           default: ${def} (rate=${suggestion.default_rate?.toFixed(2) ?? 'no data'})`);
    } else {
      console.log(`[default]  ${tt.padEnd(10)} → ${def}`);
    }
  }

  // Plateau check
  console.log('\n── Plateau Milestone ──');
  console.log('(Track in decisions.json: need >=3 distinct task_type routing_override_accepted with outcome==success)');
}

if (process.argv[2] === '--status') printRoutingStatus();
