#!/usr/bin/env node
/**
 * gemini-ask.js — Lightweight Gemini CLI adapter for VN-Squad v2
 *
 * Calls the Gemini CLI directly (no Docker) with isolated auth.
 * Ported from src/providers/gemini.js (v1), Docker wrapper stripped.
 *
 * Usage:
 *   node scripts/gemini-ask.js "<prompt>" [--model flash|pro] [--work-dir <path>]
 */

import { join } from 'node:path';
import { homedir, tmpdir } from 'node:os';
import { mkdtemp, copyFile, rm, access } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const WORKER_SETTINGS = join(__dirname, '../config/gemini-settings.json');

// --- Parse args ---
const args = process.argv.slice(2);
const promptIdx = args.findIndex(a => !a.startsWith('--'));
const prompt = promptIdx !== -1 ? args[promptIdx] : null;
const modelFlag = args.indexOf('--model');
const model = modelFlag !== -1 ? args[modelFlag + 1] : null;
const workDirFlag = args.indexOf('--work-dir');
const workDir = workDirFlag !== -1 ? args[workDirFlag + 1] : process.cwd();

if (!prompt) {
  console.error('Usage: node scripts/gemini-ask.js "<prompt>" [--model flash|pro] [--work-dir <path>]');
  process.exit(1);
}

// --- Isolated auth ---
async function isolatedGeminiAuth() {
  const sourceDir = join(homedir(), '.gemini');
  if (!existsSync(sourceDir)) {
    return { tempDir: null, cleanup: async () => {} };
  }

  const tempDir = await mkdtemp(join(tmpdir(), 'gemini-auth-'));
  const credFiles = ['oauth_creds.json', 'google_accounts.json', 'user_id', 'installation_id', 'state.json'];

  for (const f of credFiles) {
    const src = join(sourceDir, f);
    if (existsSync(src)) {
      await copyFile(src, join(tempDir, f));
    }
  }

  // Worker-safe settings: disables host MCP servers inside the subprocess
  if (existsSync(WORKER_SETTINGS)) {
    await copyFile(WORKER_SETTINGS, join(tempDir, 'settings.json'));
  }

  return {
    tempDir,
    cleanup: async () => rm(tempDir, { recursive: true, force: true }).catch(() => {})
  };
}

// --- Output parsing ---
function parseOutput(stdout) {
  const trimmed = stdout.trim();
  if (!trimmed) return { summary: '', raw: '' };

  let parsed = null;
  try { parsed = JSON.parse(trimmed); } catch { /* try next */ }

  if (!parsed && trimmed.includes('\n')) {
    for (const line of trimmed.split('\n').reverse()) {
      try { parsed = JSON.parse(line); break; } catch { /* try next */ }
    }
  }

  if (!parsed) {
    const s = trimmed.indexOf('{'), e = trimmed.lastIndexOf('}');
    if (s !== -1 && e > s) {
      try { parsed = JSON.parse(trimmed.slice(s, e + 1)); } catch { /* fail */ }
    }
  }

  if (parsed) {
    const summary = parsed.response ?? parsed.text ??
      (Array.isArray(parsed.candidates)
        ? parsed.candidates[0]?.content?.parts?.map(p => p.text).join('')
        : null) ??
      trimmed.slice(0, 2000);

    const models = parsed.stats?.models ?? {};
    const firstModel = Object.values(models)[0];
    const tokenUsage = firstModel ? {
      input: firstModel.tokens?.input ?? 0,
      output: firstModel.tokens?.candidates ?? 0,
      total: firstModel.tokens?.total ?? 0,
    } : undefined;

    return { summary, tokenUsage, raw: trimmed };
  }

  return { summary: trimmed.slice(0, 2000), raw: trimmed };
}

// --- Main ---
const { tempDir, cleanup } = await isolatedGeminiAuth();

const env = { ...process.env };
if (tempDir) env.GEMINI_CONFIG_DIR = tempDir;

const cliArgs = ['-p', prompt, '--approval-mode', 'yolo', '--output-format', 'json'];
if (model) cliArgs.push('--model', model);

const result = spawnSync('gemini', cliArgs, {
  cwd: workDir,
  env,
  encoding: 'utf8',
  maxBuffer: 32 * 1024 * 1024,
  stdio: ['ignore', 'pipe', 'pipe'],
});

await cleanup();

if (result.error) {
  console.error('Failed to spawn gemini CLI:', result.error.message);
  process.exit(1);
}

const { summary, tokenUsage } = parseOutput(result.stdout ?? '');
const output = {
  summary,
  model: model ?? 'gemini-2.0-flash',
  exitCode: result.status,
  tokenUsage,
};

process.stdout.write(JSON.stringify(output, null, 2) + '\n');
process.exit(result.status ?? 0);
