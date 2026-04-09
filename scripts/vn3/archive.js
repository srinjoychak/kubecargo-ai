// scripts/vn3/archive.js
// POSIX-atomic archive migration for skill-registry.json
// Entries older than 6 months are moved to skill-registry-archive/<year>-H<1|2>.json
// Uses mv --no-clobber (no TOCTOU race — eliminates guard check).

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { execSync } from 'child_process';

const ROOT = process.cwd();
const REGISTRY_PATH = join(ROOT, '.vn-squad', 'skill-registry.json');
const ARCHIVE_DIR = join(ROOT, '.vn-squad', 'skill-registry-archive');

function getPeriod(dateStr) {
  const d = new Date(dateStr);
  const half = d.getMonth() < 6 ? 'H1' : 'H2';
  return `${d.getFullYear()}-${half}`;
}

export function runArchiveMigration() {
  if (!existsSync(REGISTRY_PATH)) { console.log('No registry to migrate'); return 0; }
  if (!existsSync(ARCHIVE_DIR)) mkdirSync(ARCHIVE_DIR, { recursive: true });

  const registry = JSON.parse(readFileSync(REGISTRY_PATH, 'utf8'));
  const cutoff = new Date();
  cutoff.setMonth(cutoff.getMonth() - 6);

  const toArchive = registry.entries.filter(e => new Date(e.timestamp) < cutoff);
  const toKeep = registry.entries.filter(e => new Date(e.timestamp) >= cutoff);

  if (toArchive.length === 0) { console.log('✓ No entries to archive'); return 0; }

  // Group by period
  const byPeriod = {};
  toArchive.forEach(e => {
    const p = getPeriod(e.timestamp);
    if (!byPeriod[p]) byPeriod[p] = [];
    byPeriod[p].push(e);
  });

  let archived = 0;
  for (const [period, entries] of Object.entries(byPeriod)) {
    const archivePath = join(ARCHIVE_DIR, `${period}.json`);
    const archiveData = { schema_version: 1, period, entries };
    // Write to temp, mv --no-clobber (atomic, no TOCTOU)
    const tmp = join(tmpdir(), `archive-${period}-${Date.now()}.json`);
    writeFileSync(tmp, JSON.stringify(archiveData, null, 2) + '\n');
    try {
      execSync(`mv --no-clobber "${tmp}" "${archivePath}"`);
      archived += entries.length;
      console.log(`✓ archived ${entries.length} entries → ${period}.json`);
    } catch {
      // Another session won the race — archive already exists
      execSync(`rm -f "${tmp}"`);
      console.log(`  ${period}.json already exists (concurrent session) — skipped`);
    }
  }

  // Strip archived entries from active registry (atomic)
  const updated = { ...registry, entries: toKeep };
  const tmp2 = join(tmpdir(), `registry-stripped-${Date.now()}.json`);
  writeFileSync(tmp2, JSON.stringify(updated, null, 2) + '\n');
  execSync(`mv "${tmp2}" "${REGISTRY_PATH}"`);
  console.log(`✓ active registry: ${toKeep.length} entries (removed ${archived} archived)`);
  return archived;
}

if (process.argv[2] === '--run') runArchiveMigration();
