// scripts/vn3/session-context.js
// Manages session-context.json: seed/reset, CONTEXT_PROPOSAL processing, task tracking.

import { readFileSync, writeFileSync, existsSync, readdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { execSync } from 'child_process';
import { randomUUID } from 'crypto';

const ROOT = process.cwd();
const CTX_PATH = join(ROOT, '.vn-squad', 'session-context.json');
const TRAJECTORIES_DIR = join(ROOT, '.vn-squad', 'trajectories');

function getBranch() {
  try { return execSync('git rev-parse --abbrev-ref HEAD', { encoding: 'utf8' }).trim(); }
  catch { return 'unknown'; }
}

function atomicWrite(path, data) {
  const tmp = join(tmpdir(), `ctx-${Date.now()}.json`);
  writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n');
  execSync(`mv "${tmp}" "${path}"`);
}

function findLastSuccessConventions(branch) {
  if (!existsSync(TRAJECTORIES_DIR)) return {};
  const successes = readdirSync(TRAJECTORIES_DIR)
    .filter(f => f.startsWith('success-'))
    .map(f => {
      try { return JSON.parse(readFileSync(join(TRAJECTORIES_DIR, f), 'utf8')); }
      catch { return null; }
    })
    .filter(t => t && t.branch === branch)
    .sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));
  return successes[0]?.conventions || {};
}

export function resetSession() {
  const branch = getBranch();
  const seededConventions = findLastSuccessConventions(branch);
  const ctx = {
    schema_version: 1,
    session_id: randomUUID(),
    branch,
    created_at: new Date().toISOString(),
    seeded_from_trajectory: null,
    conventions: seededConventions,
    rejected_keys: [],
    pending_proposals: [],
    completed_tasks: []
  };
  atomicWrite(CTX_PATH, ctx);
  console.log(`✓ session-context.json reset (session: ${ctx.session_id})`);
  if (Object.keys(seededConventions).length > 0) {
    console.log(`  seeded conventions from last success: ${Object.keys(seededConventions).join(', ')}`);
  }
  return ctx;
}

export function readContext() {
  if (!existsSync(CTX_PATH)) return resetSession();
  return JSON.parse(readFileSync(CTX_PATH, 'utf8'));
}

/** Process a CONTEXT_PROPOSAL from an agent. Returns 'pending' — Tech Lead must accept/reject. */
export function addProposal(proposal) {
  const ctx = readContext();
  const alreadyRejected = ctx.rejected_keys.find(r => r.key === proposal.key);
  if (alreadyRejected) {
    console.warn(`⚠ Proposal for key "${proposal.key}" was previously rejected: ${alreadyRejected.reason}`);
  }
  if (ctx.pending_proposals.length >= 3) {
    console.warn(`⚠ Max 3 pending proposals — proposal deferred to next session`);
    return false;
  }
  ctx.pending_proposals.push({ id: randomUUID(), ...proposal, proposed_at: new Date().toISOString(), dispatch_cycles_pending: 0 });
  atomicWrite(CTX_PATH, ctx);
  console.log(`✓ proposal queued: ${proposal.key}`);
  return true;
}

/** Accept a pending proposal — merges into conventions. */
export function acceptProposal(proposalId) {
  const ctx = readContext();
  const idx = ctx.pending_proposals.findIndex(p => p.id === proposalId);
  if (idx === -1) throw new Error(`Proposal ${proposalId} not found`);
  const [proposal] = ctx.pending_proposals.splice(idx, 1);
  const keyParts = proposal.key.split('.');
  const ns = keyParts[0]; const k = keyParts[1];
  if (!ctx.conventions[ns]) ctx.conventions[ns] = {};
  ctx.conventions[ns][k] = proposal.value;
  atomicWrite(CTX_PATH, ctx);
  console.log(`✓ accepted: ${proposal.key} = ${proposal.value}`);
  return proposal;
}

/** Reject a pending proposal — logs to rejected_keys. */
export function rejectProposal(proposalId, reason) {
  const ctx = readContext();
  const idx = ctx.pending_proposals.findIndex(p => p.id === proposalId);
  if (idx === -1) throw new Error(`Proposal ${proposalId} not found`);
  const [proposal] = ctx.pending_proposals.splice(idx, 1);
  ctx.rejected_keys.push({ key: proposal.key, reason, agent: proposal.agent, timestamp: new Date().toISOString() });
  atomicWrite(CTX_PATH, ctx);
  console.log(`✓ rejected: ${proposal.key} (${reason})`);
}

/** Append a completed task to session context. */
export function appendTask(task) {
  const ctx = readContext();
  ctx.completed_tasks.push({ id: randomUUID(), ...task, timestamp: new Date().toISOString() });
  atomicWrite(CTX_PATH, ctx);
}

/** Advance dispatch cycle counter on pending proposals — expire after 2 cycles. */
export function advanceDispatchCycle() {
  const ctx = readContext();
  const expired = [];
  ctx.pending_proposals = ctx.pending_proposals.filter(p => {
    p.dispatch_cycles_pending = (p.dispatch_cycles_pending || 0) + 1;
    if (p.dispatch_cycles_pending >= 2) { expired.push(p); return false; }
    return true;
  });
  if (expired.length > 0) {
    console.log(`⚠ ${expired.length} proposal(s) expired after 2 dispatch cycles`);
  }
  atomicWrite(CTX_PATH, ctx);
  return expired;
}

if (process.argv[2] === '--reset') resetSession();
if (process.argv[2] === '--show') {
  const ctx = readContext();
  console.log(`Session: ${ctx.session_id}`);
  console.log(`Branch: ${ctx.branch}`);
  console.log(`Conventions: ${JSON.stringify(ctx.conventions)}`);
  console.log(`Pending proposals: ${ctx.pending_proposals.length}`);
  console.log(`Completed tasks: ${ctx.completed_tasks.length}`);
}
