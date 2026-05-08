#!/usr/bin/env node
'use strict';

/**
 * Conductor MCP autonomous mode runner.
 *
 * Spawns a fresh provider session for each task and enforces a strict
 * one-task-per-session contract:
 *
 *   1. Resume from handoff and pick up the next task
 *   2. Implement exactly that task
 *   3. Commit only the files changed for that task
 *   4. record_commit, mark_task_complete, and end_work
 *   5. Rotate context before the next task
 *
 * Usage:
 *   node autonomous.js <project-name> [--max-budget=N] [--provider=codex|claude] [--model=MODEL]
 */

const { spawn, execSync } = require('child_process');
const { createInterface } = require('readline');
const fs = require('fs');
const path = require('path');

const PINNED_NODE_BIN = process.env.CONDUCTOR_AUTONOMOUS_NODE_BIN || '/opt/homebrew/Cellar/node/23.11.0/bin';
if (fs.existsSync(path.join(PINNED_NODE_BIN, 'node'))) {
  const pathParts = String(process.env.PATH || '').split(path.delimiter).filter(Boolean);
  if (!pathParts.includes(PINNED_NODE_BIN)) {
    process.env.PATH = [PINNED_NODE_BIN, ...pathParts].join(path.delimiter);
  }
}

const DEFAULT_PROVIDER = 'codex';
const DEFAULT_CODEX_MODEL = 'gpt-5.5';
const DEFAULT_CODEX_REASONING = 'medium';

const rawArgs = process.argv.slice(2);
let projectName = null;
let maxBudget = null;
let maxIterations = null;
let provider = process.env.CONDUCTOR_AUTONOMOUS_PROVIDER || DEFAULT_PROVIDER;
let model = process.env.CONDUCTOR_AUTONOMOUS_MODEL || null;

for (const arg of rawArgs) {
  if (arg.startsWith('--max-budget=')) {
    maxBudget = arg.split('=')[1];
  } else if (arg.startsWith('--max-iterations=')) {
    const n = parseInt(arg.split('=')[1], 10);
    if (Number.isFinite(n) && n > 0) maxIterations = n;
  } else if (arg === '--once') {
    maxIterations = 1;
  } else if (arg.startsWith('--provider=')) {
    provider = arg.split('=')[1];
  } else if (arg.startsWith('--model=')) {
    model = arg.split('=')[1];
  } else if (!arg.startsWith('--')) {
    projectName = arg;
  }
}

provider = String(provider || '').toLowerCase();
if (!model && provider === 'codex') {
  model = DEFAULT_CODEX_MODEL;
}

if (!projectName) {
  console.error('Usage: autonomous.js <project-name> [--max-budget=N] [--provider=codex|claude] [--model=MODEL]');
  process.exit(1);
}

if (!['codex', 'claude'].includes(provider)) {
  console.error(`Unsupported autonomous provider: ${provider}`);
  console.error('Supported providers: codex, claude');
  process.exit(1);
}

const SCRIPT_DIR = __dirname;
const CONDUCTOR_DIR = process.env.CONDUCTOR_DIR || path.resolve(SCRIPT_DIR, '..');
const LOG_FILE = path.join(CONDUCTOR_DIR, 'autonomous.log');
const DB_FILE = path.join(CONDUCTOR_DIR, 'conductor.db');

let currentProc = null;
let claudeBudgetSupport = null;

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function extractTicketId(text) {
  const m = /\b([A-Z]{2,4}(?:-[A-Z]?\d+[a-z]?){1,3})\b/.exec(String(text || ''));
  return m ? m[1] : null;
}

function isQaTicketId(value) {
  return /^[A-Z]{2,4}(?:-[A-Z]?\d+[a-z]?){1,3}$/.test(String(value || ''));
}

/**
 * Resolve the project's workspace_path from the Conductor SQLite DB.
 *
 * Conductor allows a project to live in a subdirectory of the orchestrator
 * cwd (e.g. parent dir holds .conductor/, code lives under selectus-ms/).
 * Without this lookup the runner pinned -C and spawn cwd to process.cwd(),
 * causing Codex to patch files at the parent path instead of the project.
 *
 * Returns process.cwd() if the DB is missing, the project is missing, the
 * row has a null workspace_path, the path doesn't exist on disk, or any
 * step throws. Override via CONDUCTOR_WORKSPACE for tests.
 */
function resolveWorkspacePath(projectName) {
  if (process.env.CONDUCTOR_WORKSPACE) {
    return process.env.CONDUCTOR_WORKSPACE;
  }
  const fallback = process.cwd();
  if (!fs.existsSync(DB_FILE)) return fallback;
  // Use the system sqlite3 binary so the runner does not depend on a
  // node_modules directory that may not exist alongside .conductor/
  // (orchestrators frequently run from a parent dir).
  const safeName = String(projectName).replace(/'/g, "''");
  const sql = `SELECT COALESCE(workspace_path, '') FROM projects WHERE name = '${safeName}';`;
  let out;
  try {
    out = execSync(`sqlite3 -readonly ${JSON.stringify(DB_FILE)} ${JSON.stringify(sql)}`, {
      encoding: 'utf8',
      timeout: 5000,
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
  } catch (err) {
    // sqlite3 missing or query failed; check whether the project even
    // exists so we can be loud when it does (silent fallback masks
    // real bugs).
    log('autonomous', `WARN: sqlite3 query failed for project '${projectName}': ${err.message}; using cwd fallback`);
    return fallback;
  }
  if (out === '') {
    // Project not found OR row exists with null/empty workspace_path.
    // Distinguish: look up just the name to see if the row exists.
    try {
      const existsSql = `SELECT 1 FROM projects WHERE name = '${safeName}';`;
      const existsOut = execSync(`sqlite3 -readonly ${JSON.stringify(DB_FILE)} ${JSON.stringify(existsSql)}`, {
        encoding: 'utf8',
        timeout: 5000,
        stdio: ['pipe', 'pipe', 'pipe'],
      }).trim();
      if (existsOut === '1') {
        log('autonomous', `WARN: project '${projectName}' has no workspace_path; using cwd fallback`);
      }
    } catch {
      // ignore
    }
    return fallback;
  }
  const resolved = path.isAbsolute(out) ? out : path.resolve(fallback, out);
  if (!fs.existsSync(resolved)) {
    log('autonomous', `WARN: workspace_path '${resolved}' does not exist; using cwd fallback`);
    return fallback;
  }
  return resolved;
}

/**
 * Look up the human-readable ticket id (e.g. "CC-7-1") for a commit by
 * querying Conductor's task and commit linkage. Codex sets this via
 * the record_commit MCP tool. Returns null if no task is linked or if
 * the description does not contain a ticket-id-shaped token.
 *
 * Lets the runner verify autonomous commits without parsing subject
 * lines, so commit messages can follow project convention (no ticket
 * prefixes) without breaking the post-session gate.
 */
function lookupTicketIdInConductor(sha) {
  if (!fs.existsSync(DB_FILE)) {
    return { ticketId: null, lastLookupReason: `conductor DB not found at ${DB_FILE}` };
  }
  const safeSha = String(sha || '').replace(/[^0-9a-fA-F]/g, '');
  if (safeSha.length < 7) {
    return { ticketId: null, lastLookupReason: `invalid commit hash for lookup: ${sha}` };
  }
  const sql = [
    `SELECT description FROM tasks WHERE commit_hash = '${safeSha}'`,
    'UNION ALL',
    'SELECT t.description',
    'FROM commits c',
    'JOIN tasks t ON t.id = c.task_id',
    `WHERE c.commit_hash = '${safeSha}'`,
    'UNION ALL',
    'SELECT ct.description',
    'FROM commits c',
    'JOIN completed_tasks ct ON ct.original_task_id = c.task_id',
    `WHERE c.commit_hash = '${safeSha}'`,
    'LIMIT 1;',
  ].join(' ');
  let out;
  try {
    out = execSync(`sqlite3 -readonly ${JSON.stringify(DB_FILE)} ${JSON.stringify(sql)}`, {
      encoding: 'utf8',
      timeout: 5000,
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
  } catch (err) {
    const msg = String(err.stderr || err.message || err).trim().split('\n')[0];
    log('autonomous', `WARN: commit linkage lookup failed using DB_FILE=${DB_FILE}: ${msg}`);
    return { ticketId: null, lastLookupReason: `commit linkage lookup failed using DB_FILE=${DB_FILE}: ${msg}` };
  }
  if (!out) {
    return { ticketId: null, lastLookupReason: `no commit linkage row for ${safeSha} in ${DB_FILE}` };
  }
  // Description format examples: "CC-7-1: ..." and
  // "Phase E1: Pilot ... on CC-8-1 ...".
  const ticketId = extractTicketId(out);
  if (!ticketId) {
    return { ticketId: null, lastLookupReason: `commit linkage row has no ticket id in task description: ${out.slice(0, 120)}` };
  }
  return { ticketId, lastLookupReason: null };
}

function lookupTicketIdInConductorWithRetry(sha, opts = {}) {
  const retries = opts.retries || 4;
  const delayMs = opts.delayMs || 500;
  let lastLookupReason = null;
  for (let i = 0; i < retries; i++) {
    const result = lookupTicketIdInConductor(sha);
    if (result.ticketId) return result;
    lastLookupReason = result.lastLookupReason;
    if (i < retries - 1) sleepSync(delayMs);
  }
  return { ticketId: null, lastLookupReason };
}

function lookupTicketIdInCommitFiles(workspacePath, sha) {
  let files;
  try {
    files = execSync(
      `git -C ${JSON.stringify(workspacePath)} show --name-only --format= ${sha}`,
      { encoding: 'utf8', timeout: 5000, stdio: ['pipe', 'pipe', 'pipe'] }
    ).split('\n').map((s) => s.trim()).filter(Boolean);
  } catch {
    return null;
  }
  const records = files
    .filter((f) => /^test\/qa-round-5\/records\/[^/]+\.md$/.test(f))
    .map((record) => path.basename(record, '.md'))
    .filter((basename) => isQaTicketId(basename));
  return records.length === 1 ? records[0] : null;
}

function lookupTicketIdForCurrentTask(project, sessionFacts = {}) {
  const ids = [
    sessionFacts.currentTaskId,
    ...(sessionFacts.completedTaskIds ? [...sessionFacts.completedTaskIds] : []),
    ...(sessionFacts.recordCommits || []).map((r) => r.taskId),
  ].filter(Boolean);
  const uniqueIds = [...new Set(ids)];
  if (uniqueIds.length === 0 || !fs.existsSync(DB_FILE)) return null;

  for (const id of uniqueIds) {
    const safeId = String(id).replace(/'/g, "''");
    const sql = [
      `SELECT description FROM tasks WHERE id = '${safeId}'`,
      'UNION ALL',
      `SELECT description FROM completed_tasks WHERE original_task_id = '${safeId}'`,
      'LIMIT 1;',
    ].join(' ');
    try {
      const out = execSync(`sqlite3 -readonly ${JSON.stringify(DB_FILE)} ${JSON.stringify(sql)}`, {
        encoding: 'utf8',
        timeout: 5000,
        stdio: ['pipe', 'pipe', 'pipe'],
      }).trim();
      const ticketId = extractTicketId(out);
      if (ticketId) return ticketId;
    } catch (err) {
      const msg = String(err.stderr || err.message || err).trim().split('\n')[0];
      log('autonomous', `WARN: current task lookup failed for project=${project} task=${id} DB_FILE=${DB_FILE}: ${msg}`);
    }
  }
  return null;
}

function lookupTaskInfoByTaskId(taskId) {
  if (!taskId || !fs.existsSync(DB_FILE)) return null;
  const safeId = String(taskId).replace(/'/g, "''");
  const sql = [
    `SELECT id, category, status, description FROM tasks WHERE id = '${safeId}'`,
    'UNION ALL',
    `SELECT original_task_id AS id, category, 'passed' AS status, description FROM completed_tasks WHERE original_task_id = '${safeId}'`,
    'LIMIT 1;',
  ].join(' ');
  try {
    const out = execSync(`sqlite3 -readonly ${JSON.stringify(DB_FILE)} ${JSON.stringify(sql)}`, {
      encoding: 'utf8',
      timeout: 5000,
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
    if (!out) return null;
    const [id, category, status, ...descriptionParts] = out.split('|');
    return { id, category, status, description: descriptionParts.join('|') };
  } catch (err) {
    const msg = String(err.stderr || err.message || err).trim().split('\n')[0];
    log('autonomous', `WARN: task info lookup failed for task=${taskId} DB_FILE=${DB_FILE}: ${msg}`);
    return null;
  }
}

function lookupTaskInfoByTicketId(ticketId) {
  if (!ticketId || !fs.existsSync(DB_FILE)) return null;
  const safeTicket = String(ticketId).replace(/'/g, "''");
  const sql = [
    'SELECT id, category, status, description FROM tasks',
    `WHERE description LIKE '${safeTicket}:%' OR description LIKE '% ${safeTicket}:%' OR description LIKE '% ${safeTicket} %'`,
    'UNION ALL',
    "SELECT original_task_id AS id, category, 'passed' AS status, description FROM completed_tasks",
    `WHERE description LIKE '${safeTicket}:%' OR description LIKE '% ${safeTicket}:%' OR description LIKE '% ${safeTicket} %'`,
    'LIMIT 1;',
  ].join(' ');
  try {
    const out = execSync(`sqlite3 -readonly ${JSON.stringify(DB_FILE)} ${JSON.stringify(sql)}`, {
      encoding: 'utf8',
      timeout: 5000,
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
    if (!out) return null;
    const [id, category, status, ...descriptionParts] = out.split('|');
    return { id, category, status, description: descriptionParts.join('|') };
  } catch (err) {
    const msg = String(err.stderr || err.message || err).trim().split('\n')[0];
    log('autonomous', `WARN: task info lookup failed for ticket=${ticketId} DB_FILE=${DB_FILE}: ${msg}`);
    return null;
  }
}

function permitsRecordOnlyCommit(taskInfo, files) {
  if (!taskInfo) return false;
  const category = String(taskInfo.category || '').toLowerCase();
  const description = String(taskInfo.description || '').toLowerCase();
  const allEvidenceFiles = files.length > 0 && files.every((f) => {
    return f === 'test/qa-round-5/inventory.json' ||
      f.startsWith('test/qa-round-5/records/') ||
      f.startsWith('test/qa-round-5/audit');
  });
  if (!allEvidenceFiles) return false;
  if (category === 'docs') return true;
  return /evidence|record|audit|waiver|citation|re-check|reconcile|regenerat|artifact-manifest|manifest coverage|verifiedsection|verified section|closed-ticket artifacts|phase g-|skill loop/.test(description);
}

function recordOnlyCommitTaskCandidates({ taskInfo, ticketId, sessionFacts }) {
  const candidates = [];
  const seen = new Set();
  const add = (info) => {
    if (!info || !info.id || seen.has(info.id)) return;
    seen.add(info.id);
    candidates.push(info);
  };

  add(taskInfo);

  if (sessionFacts && sessionFacts.recordCommits) {
    for (const record of sessionFacts.recordCommits) {
      if (record && record.taskId) {
        add(lookupTaskInfoByTaskId(record.taskId));
      }
    }
  }

  if (sessionFacts && sessionFacts.currentTaskId) {
    add(lookupTaskInfoByTaskId(sessionFacts.currentTaskId));
  }

  add(lookupTaskInfoByTicketId(ticketId));
  return candidates;
}

function verifyTrackedRecordFile(workspacePath, ticketId) {
  const recordPath = `test/qa-round-5/records/${ticketId}.md`;
  const abs = path.join(workspacePath, recordPath);
  if (!fs.existsSync(abs)) {
    return { ok: false, reason: `record file is missing: ${recordPath}` };
  }
  try {
    execSync(`git -C ${JSON.stringify(workspacePath)} ls-files --error-unmatch ${JSON.stringify(recordPath)}`, {
      encoding: 'utf8',
      timeout: 5000,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
  } catch {
    return { ok: false, reason: `record file is not tracked by git: ${recordPath}` };
  }
  return { ok: true, recordPath };
}

function listChangedFiles(workspacePath) {
  try {
    return execSync(`git -C ${JSON.stringify(workspacePath)} status --porcelain`, {
      encoding: 'utf8',
      timeout: 5000,
      stdio: ['pipe', 'pipe', 'pipe'],
    }).split('\n').map((s) => s.trim()).filter(Boolean).map((line) => line.slice(3));
  } catch {
    return [];
  }
}

function amendVerifiedRecordIfNeeded(workspacePath, ticketId) {
  const recordPath = `test/qa-round-5/records/${ticketId}.md`;
  const inventoryPath = 'test/qa-round-5/inventory.json';
  const changed = new Set(listChangedFiles(workspacePath));
  const needsRecord = changed.has(recordPath);
  const needsInventory = changed.has(inventoryPath);

  if (!needsRecord && !needsInventory) {
    return { amended: false, sha: null };
  }

  try {
    execSync(`node scripts/qa-atlas.js --verify ${ticketId}`, {
      cwd: workspacePath,
      encoding: 'utf8',
      timeout: 30000,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
  } catch (e) {
    const detail = String(e.stderr || e.stdout || e.message || '').trim().split('\n').slice(0, 5).join(' | ');
    return {
      amended: false,
      error: `record/inventory changed after commit but qa-atlas --verify ${ticketId} failed before auto-amend: ${detail}`,
    };
  }

  try {
    const files = [recordPath];
    if (needsInventory) files.push(inventoryPath);
    execSync(`git -C ${JSON.stringify(workspacePath)} add -- ${files.map((f) => JSON.stringify(f)).join(' ')}`, {
      encoding: 'utf8',
      timeout: 5000,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    execSync(`git -C ${JSON.stringify(workspacePath)} commit --amend --no-edit`, {
      encoding: 'utf8',
      timeout: 30000,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const sha = execSync(`git -C ${JSON.stringify(workspacePath)} rev-parse HEAD`, {
      encoding: 'utf8',
      timeout: 5000,
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
    return { amended: true, sha, files };
  } catch (e) {
    const detail = String(e.stderr || e.stdout || e.message || '').trim().split('\n')[0];
    return { amended: false, error: `auto-amend of verified record failed: ${detail}` };
  }
}

function log(tag, msg) {
  const ts = new Date().toISOString().replace('T', ' ').replace('Z', '');
  const line = `[${ts}] [${tag}] ${msg}`;
  console.log(line);
  try { fs.appendFileSync(LOG_FILE, line + '\n'); } catch {}
}

function claudeSupportsMaxBudget() {
  if (claudeBudgetSupport != null) return claudeBudgetSupport;
  try {
    const out = execSync('claude --help', {
      encoding: 'utf8',
      timeout: 10000,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    claudeBudgetSupport = out.includes('--max-budget-usd');
  } catch {
    claudeBudgetSupport = false;
  }
  return claudeBudgetSupport;
}

function extractJSON(text) {
  let depth = 0;
  let start = -1;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '{') {
      if (depth === 0) start = i;
      depth++;
    } else if (text[i] === '}') {
      depth--;
      if (depth === 0 && start !== -1) {
        try {
          return JSON.parse(text.slice(start, i + 1));
        } catch {
          start = -1;
        }
      }
    }
  }
  return null;
}

function gitCommitSafetyNet() {
  try {
    const status = execSync('git status --porcelain', {
      encoding: 'utf8',
      timeout: 10000,
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
    if (!status) return;

    log('git', 'Safety net: uncommitted changes remain; not auto-committing in a dirty workspace.');
  } catch {
    // Best effort only.
  }
}

function checkTasks(project) {
  try {
    const output = execSync(`conductor-mcp next "${project}"`, {
      encoding: 'utf8',
      timeout: 15000,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    if (output.includes('All tasks complete')) return 'complete';
    if (output.includes(`Project '${project}' not found`)) return 'not_found';
    if (output.includes('Next Task')) return 'has_tasks';
    if (output.includes('waiting on dependencies')) return 'blocked';
    return 'unknown';
  } catch (e) {
    const output = (e.stdout || '') + (e.stderr || '');
    if (output.includes('All tasks complete')) return 'complete';
    if (output.includes(`Project '${project}' not found`)) return 'not_found';
    return 'error';
  }
}

const WRAP_UP_TOOLS = new Set([
  'Bash',
  'end_work',
  'record_commit',
  'save_memory',
]);

const CONDUCTOR_TERMINAL_TOOLS = new Set([
  'mark_task_complete',
  'end_work',
]);

function normalizeToolName(name) {
  return String(name || '').replace(/^mcp__conductor__/, '');
}

function isConductorToolName(name) {
  const normalized = normalizeToolName(name);
  return normalized.startsWith('conductor__') ||
    normalized.startsWith('mcp__conductor__') ||
    WRAP_UP_TOOLS.has(normalized) ||
    CONDUCTOR_TERMINAL_TOOLS.has(normalized);
}

function collectToolNames(value, names = []) {
  if (!value || typeof value !== 'object') return names;
  if (Array.isArray(value)) {
    for (const item of value) collectToolNames(item, names);
    return names;
  }

  const type = String(value.type || value.kind || value.event || '').toLowerCase();
  const hasToolShape = type.includes('tool') ||
    Object.prototype.hasOwnProperty.call(value, 'arguments') ||
    Object.prototype.hasOwnProperty.call(value, 'input') ||
    Object.prototype.hasOwnProperty.call(value, 'tool_call_id');

  for (const key of ['name', 'tool_name', 'toolName']) {
    if (typeof value[key] === 'string' && hasToolShape && isConductorToolName(value[key])) {
      names.push(value[key]);
    }
  }

  if (typeof value.tool === 'string' && hasToolShape && isConductorToolName(value.tool)) {
    names.push(value.tool);
  }

  for (const child of Object.values(value)) collectToolNames(child, names);
  return names;
}

function collectText(value, chunks = []) {
  if (!value || typeof value !== 'object') return chunks;
  if (Array.isArray(value)) {
    for (const item of value) collectText(item, chunks);
    return chunks;
  }

  const type = String(value.type || '').toLowerCase();
  if ((type === 'text' || type === 'output_text') && typeof value.text === 'string') {
    chunks.push(value.text);
  }

  for (const child of Object.values(value)) collectText(child, chunks);
  return chunks;
}

function collectRecordCommitResults(value, commits = []) {
  if (!value || typeof value !== 'object') return commits;
  if (Array.isArray(value)) {
    for (const item of value) collectRecordCommitResults(item, commits);
    return commits;
  }

  if (typeof value.commitHash === 'string' && typeof value.taskId === 'string') {
    commits.push({ commitHash: value.commitHash, taskId: value.taskId });
  }

  for (const child of Object.values(value)) collectRecordCommitResults(child, commits);
  return commits;
}

function collectCompletedTaskIds(value, ids = []) {
  if (!value || typeof value !== 'object') return ids;
  if (Array.isArray(value)) {
    for (const item of value) collectCompletedTaskIds(item, ids);
    return ids;
  }

  if (typeof value.taskId === 'string' && String(value.status || '').toLowerCase() === 'passed') {
    ids.push(value.taskId);
  }

  for (const child of Object.values(value)) collectCompletedTaskIds(child, ids);
  return ids;
}

function buildSystemPrompt() {
  return [
    'AUTONOMOUS MODE - STRICT ONE-TASK-PER-SESSION CONTRACT:',
    'You are orchestrated by an autonomous runner that starts a fresh session for each task.',
    'Complete EXACTLY ONE task per session, then hand off. Follow this exact sequence:',
    '',
    '0. BEFORE your first edit, run `git status --porcelain` and SAVE the',
    '   pre-existing dirty file list. You will compare against it later.',
    '1. Resume from handoff and implement the current task. Edit any files',
    '   you need to.',
    '2. Before committing, write/update the per-fix evidence record at',
    '   `test/qa-round-5/records/<ticket-id>.md` using the 5-block contract',
    '   below. Read `test/qa-round-5/records/_TEMPLATE.md` for the layout.',
    '3. Run `node scripts/qa-atlas.js --verify <ticket-id>`. If --verify',
    '   exits non-zero, read its reasons, fix the record, and re-run until',
    '   it exits 0. Do not commit before the record verifies.',
    '4. After implementing and writing the verified record, run',
    '   `git status --porcelain` again. Stage:',
    '   - Files you CREATED this session (new entries vs step 0).',
    '   - Files you EDITED this session: stage them even if already dirty in step 0.',
    '   - The verified record file and inventory.json if you updated it.',
    '   Do NOT stage files from step 0 that you did not touch this session.',
    '   Do NOT run `git add -A` or `git add .`.',
    '5. Commit. Use the project\'s existing Conventional Commits convention:',
    '   Format: <type>(<scope>): <imperative description>',
    '     type:  fix | feat | refactor | test | chore | docs',
    '     scope: feature area — label, order, fz, print, delivery-note,',
    '            dg, npk, gma, qa-round-5, colour, etc. NEVER the ticket id.',
    '     description: imperative present tense, plain English, no period.',
    '   Examples from existing history:',
    '     fix(label): render tote indicator on both label halves (B7, C7)',
    '     fix(order): tank sort follows live FZ order in GraphQL resolvers',
    '     fix(label): NPK stability across multi-recipe orders',
    '     feat(qa-round-5): atlas toolkit (legacy refs, fixtures, section maps)',
    '   Optional: trailing section code in parens, e.g. (A4) or (B7, C7),',
    '   following the legacy section-code convention.',
    '   Do NOT include the ticket id (CC-X-Y, DN-X-Y, FB-X-Y, BB-X-Y,',
    '   OP-X-Y, e.g. CC-7-1) anywhere in the commit message — the runner',
    '   tracks ticket linkage via Conductor\'s record_commit, not the',
    '   subject. Ticket prefixes pollute git history when squash-merged.',
    '   Do NOT include Co-Authored-By trailers (per CLAUDE.md).',
    '6. SUBSTANCE GATE: run `git show --name-only HEAD` and verify the',
    '   implementation tickets changed at least one file outside',
    '   `test/qa-round-5/records/` and `test/qa-round-5/inventory.json`.',
    '   For docs/evidence tasks, record-only commits are allowed if',
    '   `node scripts/qa-atlas.js --verify <ticket-id>` passes. If an',
    '   implementation-ticket commit only touches records/inventory, your',
    '   session has produced NO substantive change: STOP, do not call',
    '   mark_task_complete, surface the issue, and exit.',
    '6b. SELF-REVIEW: run `git show HEAD` and re-read your own diff against',
    '   the QUALITY CHECKLIST below. If you find ANY of the 6 defects,',
    '   amend the commit (or revert + re-edit) before continuing. Do not',
    '   proceed to step 5 until the diff is clean. This is not stylistic',
    '   feedback — only objective defects from the list. Do NOT refactor',
    '   for cleanliness; only reject the items below.',
    '',
    '   QUALITY CHECKLIST (reject any of these):',
    '   1. Dead code: ternaries that return identical values for both',
    '      branches (e.g. `x ? a : a`), unreachable branches, unused',
    '      imports, if/else blocks with identical bodies.',
    '   2. Magic-number fallbacks: hardcoded literals returned on invalid',
    '      input (e.g. `if (!isFinite(x)) return \'1000\';`). Either throw,',
    '      return undefined, or fix the upstream cause. Magic defaults',
    '      hide bugs; do not paper over data issues at the display layer.',
    '   3. CLAUDE.md violations (read CLAUDE.md if you have not):',
    '      - em-dashes / en-dashes in user-visible strings',
    '      - backwards-compat shims (`A ?? B ?? false` patterns) without',
    '        explicit justification; pick one field name and migrate.',
    '      - personal names in code, comments, or commit messages',
    '      - Co-Authored-By trailers in commit messages',
    '   4. Test coverage gaps: every new branch in production code must',
    '      be exercised by a test. If your diff adds a fallback path, the',
    '      diff must add a test for that fallback.',
    '   5. Wrong abstraction layer: do not fix in the display when the',
    '      bug is in the data; do not fix in the template when the bug',
    '      is in the binding. Cite the test that proves the chosen layer.',
    '   6. Half-finished work: TODO / FIXME / `throw new Error("not',
    '      implemented")` / dummy return values left in shipped code.',
    '      Remove or finish before committing.',
    '',
    '7. Call record_commit with the commit hash.',
    '8. Call mark_task_complete to mark the task done.',
    '9. Call end_work to save the handoff.',
    '',
    'CRITICAL: Do NOT call complete_work or get_next_task.',
    'Do NOT start implementing another task.',
    'The orchestrator will kill this session after end_work and start a new one.',
    '',
    '=== PER-FIX EVIDENCE RECORD CONTRACT (5-block format) ===',
    '',
    'Required `## ` headings, in order, exact case:',
    '  TL;DR | What is broken | Why | Fix | Proof | Gotchas',
    '',
    'Citation requirement: every claim line (sentence ending in . ! or ?)',
    'in "What is broken", "Why", "Fix", and "Gotchas" must include at',
    'least one of:',
    '  - file:line          (services/labelService.js:142)',
    '  - memory path        (memory/dg-authoritative-rules-apr9.md)',
    '  - PNG path           (test/qa-round-5/atlas/.../bands/03.png)',
    '  - test path          (test/unit/labelService.dg.test.js)',
    'Bullet metadata lines (e.g. "- Layer: data") are NOT claims.',
    '',
    'TL;DR section MUST include:',
    '  - "Verdict: pass | concerns | still-broken" line.',
    '  - The Verdict line OR another TL;DR line MUST cite a gate by',
    '    naming one of: RED, GREEN, J=, review.md, review.json.',
    '',
    'Proof section MUST include ALL of these gate citations (the false-',
    'positive guard — three gates):',
    '  - Literal "RED" naming the failing test that proved the bug.',
    '  - Literal "GREEN" naming the same test passing after the fix.',
    '  - At least one of review.md / review.json / J= referencing a',
    '    calibrated visual review (or a note that visual review is N/A).',
    'Proof section MUST also reference:',
    '  - At least 2 distinct fixture-* paths (target + cross-fixture).',
    '  - At least 1 .png path under test/qa-round-5/atlas/...',
    '  - A "Visual sanity" row or line citing full-page.png plus either',
    '    a bands/<n>.png, compare/<n>.png, annotated.png, or',
    '    contact-sheet.png.',
    '  - Plain-English readability evidence naming font/readable text,',
    '    clipping, and overlap. This is a cheap whole-page guard; do',
    '    not run extra LLM review just to satisfy it.',
    '',
    'Gotchas section names: similar problems elsewhere in the codebase,',
    'the domain knowledge gap behind the chosen approach, and one',
    'alternative considered + why rejected. Cite each.',
    '',
    'Per-fix records describe ONE fix only. Do NOT include claims about',
    'the wider toolkit\'s state — calibration J score, other tickets\'',
    'status, repo-wide refactor rationale. Those belong in memory.',
  ].join('\n');
}

function buildClaudeCommand(project, opts = {}) {
  const cmdArgs = [
    '-p', `/conductor-resume ${project}`,
    '--output-format', 'stream-json',
    '--dangerously-skip-permissions',
    '--permission-mode', 'bypassPermissions',
    '--append-system-prompt', buildSystemPrompt(),
  ];

  if (opts.model) {
    cmdArgs.push('--model', opts.model);
  }
  if (opts.maxBudget && claudeSupportsMaxBudget()) {
    cmdArgs.push('--max-budget-usd', opts.maxBudget);
  } else if (opts.maxBudget) {
    log('session', 'Claude CLI does not support --max-budget-usd; continuing without CLI budget cap.');
  }

  return { command: 'claude', args: cmdArgs };
}

function buildCodexCommand(project, opts = {}) {
  const prompt = [
    `/conductor-resume ${project}`,
    '',
    buildSystemPrompt(),
  ].join('\n');

  const workspacePath = opts.workspacePath || process.cwd();

  const cmdArgs = [
    'exec',
    '-m', opts.model || DEFAULT_CODEX_MODEL,
    '-s', 'danger-full-access',
    '--dangerously-bypass-approvals-and-sandbox',
    '-c', `model_reasoning_effort="${opts.reasoningEffort || DEFAULT_CODEX_REASONING}"`,
    '--json',
    '--skip-git-repo-check',
    '-C', workspacePath,
    '-',
  ];

  if (opts.maxBudget) {
    log('session', 'Codex CLI does not support autonomous --max-budget; continuing without CLI budget cap.');
  }

  return { command: 'codex', args: cmdArgs, stdin: prompt };
}

function providerCommand(project, opts) {
  if (opts.provider === 'claude') return buildClaudeCommand(project, opts);
  return buildCodexCommand(project, opts);
}

function spawnSession(project, opts = {}) {
  return new Promise((resolve) => {
    let state = 'running';
    let wrapUpTimeout = null;
    const trackedTools = new Map();
    const sessionFacts = { recordCommits: [], completedTaskIds: new Set(), currentTaskId: null };
    const sessionProvider = opts.provider || DEFAULT_PROVIDER;
    const workspacePath = opts.workspacePath || process.cwd();
    const { command, args, stdin } = providerCommand(project, opts);

    log('session', `Spawning ${sessionProvider} session (iteration ${opts.iteration || '?'}) cwd=${workspacePath}`);

    const proc = spawn(command, args, {
      cwd: workspacePath,
      stdio: [stdin !== undefined ? 'pipe' : 'ignore', 'pipe', 'pipe'],
    });
    currentProc = proc;
    if (stdin !== undefined) {
      proc.stdin.end(stdin);
    }

    proc.stderr.on('data', (chunk) => {
      process.stderr.write(chunk);
    });

    function doResolve(result) {
      if (state === 'resolved') return;
      state = 'resolved';
      if (wrapUpTimeout) clearTimeout(wrapUpTimeout);
      currentProc = null;
      setTimeout(() => {
        if (!proc.killed) {
          try { proc.kill('SIGTERM'); } catch {}
        }
      }, 1000);
      resolve({ status: result, sessionFacts });
    }

    function enterWrapUp() {
      if (state !== 'running') return;
      state = 'wrapping_up';
      log('rotate', 'Waiting for end_work. 60s timeout.');
      wrapUpTimeout = setTimeout(() => {
        log('rotate', 'Wrap-up timeout. Killing session.');
        try { proc.kill('SIGTERM'); } catch {}
        doResolve('rotate');
      }, 60000);
    }

    function handleToolCall(toolName) {
      if (state === 'resolved') return;
      const name = normalizeToolName(toolName);
      log('tool', `Calling: ${toolName}`);

      if (state === 'wrapping_up' && !WRAP_UP_TOOLS.has(name)) {
        if (name === 'mark_task_complete') {
          log('rotate', 'WARN: duplicate mark_task_complete during wrap-up; continuing to wait for end_work.');
          return;
        }
        log('rotate', `Agent called ${toolName} during wrap-up. Killing session.`);
        try { proc.kill('SIGTERM'); } catch {}
        doResolve('rotate');
        return;
      }

      if (sessionProvider === 'codex' && name === 'mark_task_complete') {
        log('tool', 'mark_task_complete -> task done, entering wrap-up');
        enterWrapUp();
      }

      if (sessionProvider === 'codex' && name === 'end_work') {
        log('rotate', 'end_work called by Codex. Rotating.');
        doResolve('rotate');
      }
    }

    function handleToolResult(toolName, text) {
      if (state === 'resolved') return;
      const name = normalizeToolName(toolName);

      if (name === 'mark_task_complete') {
        const data = extractJSON(text);
        if (data && data.taskId) {
          sessionFacts.currentTaskId = data.taskId;
          if (String(data.status || '').toLowerCase() === 'passed') {
            sessionFacts.completedTaskIds.add(data.taskId);
          }
        }
        log('tool', 'mark_task_complete -> task done, entering wrap-up');
        enterWrapUp();
        return;
      }

      if (name === 'record_commit') {
        const data = extractJSON(text);
        if (data && data.commitHash && data.taskId) {
          sessionFacts.recordCommits.push({ commitHash: data.commitHash, taskId: data.taskId });
          sessionFacts.currentTaskId = data.taskId;
        }
        return;
      }

      if (name === 'end_work') {
        const data = extractJSON(text);
        log('tool', `end_work -> ${text.slice(0, 200)}`);

        if (data) {
          const p = data.progress || data.remaining || data;
          const pending = p.pending ?? 0;
          const inProgress = p.inProgress ?? 0;

          if (pending + inProgress > 0) {
            log('rotate', `Handoff saved. ${pending} pending, ${inProgress} in-progress remaining.`);
            doResolve('rotate');
          } else {
            log('rotate', 'All tasks done.');
            doResolve('done');
          }
        } else {
          log('rotate', 'end_work called with unparseable result. Rotating.');
          doResolve('rotate');
        }
      }
    }

    function handleClaudeEvent(event) {
      const type = event.type;
      const message = event.message;

      if (type === 'assistant' && message?.content) {
        for (const block of message.content) {
          if (block.type === 'text' && block.text) {
            process.stdout.write(block.text);
          }
          if (block.type === 'tool_use') {
            trackedTools.set(block.id, { id: block.id, name: block.name });
            handleToolCall(block.name);
          }
        }
        return;
      }

      if (type === 'user' && message?.content) {
        for (const part of message.content) {
          if (part.type !== 'tool_result') continue;
          const tool = trackedTools.get(part.tool_use_id);
          if (!tool) continue;

          let text = '';
          if (typeof part.content === 'string') {
            text = part.content;
          } else if (Array.isArray(part.content)) {
            text = part.content
              .filter(c => c.type === 'text')
              .map(c => c.text)
              .join('');
          }

          handleToolResult(tool.name, text);
        }
        return;
      }

      if (type === 'result') {
        const cost = event.cost_usd ?? event.total_cost_usd ?? event.cost ?? '?';
        const turns = event.num_turns ?? event.turns ?? '?';
        const duration = event.duration_ms ? `${(event.duration_ms / 1000).toFixed(1)}s` : (event.duration_secs ? `${event.duration_secs}s` : '?');
        log('session', `Cost: $${cost}, turns: ${turns}, duration: ${duration}`);
      }
    }

    function handleCodexEvent(event) {
      for (const text of collectText(event)) {
        process.stdout.write(text);
      }

      const toolNames = [...new Set(collectToolNames(event))];
      for (const toolName of toolNames) {
        handleToolCall(toolName);
      }

      for (const commit of collectRecordCommitResults(event)) {
        sessionFacts.recordCommits.push(commit);
        sessionFacts.currentTaskId = commit.taskId;
      }

      for (const taskId of collectCompletedTaskIds(event)) {
        sessionFacts.completedTaskIds.add(taskId);
        sessionFacts.currentTaskId = taskId;
      }

      const usage = event.usage || event.metrics || event.cost;
      if (usage && event.type && String(event.type).includes('completed')) {
        log('session', `Codex event ${event.type}: ${JSON.stringify(usage).slice(0, 200)}`);
      }
    }

    const rl = createInterface({ input: proc.stdout });
    rl.on('line', (rawLine) => {
      let event;
      try {
        event = JSON.parse(rawLine);
      } catch {
        if (rawLine.trim()) process.stdout.write(rawLine + '\n');
        return;
      }

      if (sessionProvider === 'claude') {
        handleClaudeEvent(event);
      } else {
        handleCodexEvent(event);
      }
    });

    proc.on('close', (code) => {
      log('session', `Process exited (code ${code})`);
      if (state !== 'resolved') {
        doResolve(code === 0 ? 'finished' : 'error');
      }
    });

    proc.on('error', (err) => {
      log('session', `Process error: ${err.message}`);
      if (state !== 'resolved') {
        doResolve('error');
      }
    });
  });
}

/**
 * Runner-side defense-in-depth check. Mirrors the substance gate and
 * --verify gate that the system prompt asks Codex to run, but enforces
 * them from the runner so a Codex session that ignores its instructions
 * cannot close a ticket with a bad commit or malformed record.
 *
 * Returns { ok, reason?, ticketId?, sha? }. Does not throw.
 */
function postSessionVerify({ workspacePath, headBefore, project, sessionFacts }) {
  let headAfter;
  try {
    headAfter = execSync(`git -C ${JSON.stringify(workspacePath)} rev-parse HEAD`, {
      encoding: 'utf8',
      timeout: 5000,
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
  } catch (e) {
    return { ok: false, reason: `git rev-parse HEAD failed: ${e.message.split('\n')[0]}` };
  }

  if (headAfter === headBefore) {
    // No new commit produced this session. Codex may have legitimately
    // determined no change was needed; let the loop continue.
    return { ok: true, reason: 'no-commit', sha: headAfter };
  }

  // Primary: ask Conductor which task owns this commit. record_commit
  // sets tasks.commit_hash; reading it back is more reliable than
  // parsing the subject (Codex picks varying conventions).
  const committedRecordTicketId = lookupTicketIdInCommitFiles(workspacePath, headAfter);
  const conductorLookup = lookupTicketIdInConductorWithRetry(headAfter);
  let ticketId = committedRecordTicketId || conductorLookup.ticketId;
  let lookupFailureReason = conductorLookup.lastLookupReason;
  let taskInfo = null;

  if (!ticketId && sessionFacts && sessionFacts.recordCommits) {
    const match = sessionFacts.recordCommits.find((r) => String(r.commitHash || '').startsWith(headAfter) || headAfter.startsWith(String(r.commitHash || '')));
    if (match && match.taskId) {
      taskInfo = lookupTaskInfoByTaskId(match.taskId);
      ticketId = lookupTicketIdForCurrentTask(project, { ...sessionFacts, currentTaskId: match.taskId });
    }
  }

  if (!ticketId) {
    ticketId = lookupTicketIdForCurrentTask(project, sessionFacts);
  }

  // Fallback: scan the commit subject (and body) for any ticket-id-shaped
  // token. Permissive enough to handle Conventional-Commits scope style
  // like "fix(CC-7-1): ..." or trailing refs like "... (CC-7-1)".
  if (!ticketId) {
    let subject;
    try {
      subject = execSync(`git -C ${JSON.stringify(workspacePath)} log -1 --format=%B ${headAfter}`, {
        encoding: 'utf8',
        timeout: 5000,
        stdio: ['pipe', 'pipe', 'pipe'],
      }).trim();
    } catch (e) {
      return { ok: false, reason: `git log failed: ${e.message.split('\n')[0]}`, sha: headAfter };
    }
    const m = /\b([A-Z]{2,4}(?:-[A-Z]?\d+[a-z]?){1,3})\b/.exec(subject);
    if (!m) {
      const linkageDetail = lookupFailureReason
        ? `Conductor lookup failed or found no ticket (${lookupFailureReason}).`
        : 'Conductor lookup found no ticket.';
      if (!taskInfo && sessionFacts && sessionFacts.currentTaskId) {
        taskInfo = lookupTaskInfoByTaskId(sessionFacts.currentTaskId);
      }
      if (!taskInfo) {
        return {
          ok: false,
          reason: `cannot match commit ${headAfter.slice(0, 7)} to a ticket or task. ${linkageDetail} No committed ticket record path or ticket-id-shaped token in subject was found.`,
          sha: headAfter,
        };
      }
      log('autonomous', `No QA ticket id for commit ${headAfter.slice(0, 7)}; using Conductor task ${taskInfo.id}`);
    } else {
      ticketId = m[1];
    }
  }

  // Substance check: at least one file outside records/ + inventory.json.
  let files;
  try {
    files = execSync(
      `git -C ${JSON.stringify(workspacePath)} show --name-only --format= ${headAfter}`,
      { encoding: 'utf8', timeout: 5000, stdio: ['pipe', 'pipe', 'pipe'] }
    ).split('\n').map((s) => s.trim()).filter(Boolean);
  } catch (e) {
    return { ok: false, reason: `git show failed: ${e.message.split('\n')[0]}`, sha: headAfter, ticketId };
  }
  const NO_OP_PREFIXES = ['test/qa-round-5/records/'];
  const NO_OP_FILES = new Set(['test/qa-round-5/inventory.json']);
  const substantive = files.filter((f) => {
    if (NO_OP_FILES.has(f)) return false;
    if (NO_OP_PREFIXES.some((p) => f.startsWith(p))) return false;
    return true;
  });
  if (substantive.length === 0) {
    const allowedTaskInfo = recordOnlyCommitTaskCandidates({ taskInfo, ticketId, sessionFacts })
      .find((candidate) => permitsRecordOnlyCommit(candidate, files));
    if (!allowedTaskInfo) {
      return {
        ok: false,
        reason: `commit ${headAfter.slice(0, 7)} touched only records + inventory (no-op substance)`,
        sha: headAfter,
        ticketId,
      };
    }
    taskInfo = allowedTaskInfo;
    log('autonomous', `Record-only commit allowed for ${taskInfo.category || 'evidence'} task ${ticketId || taskInfo.id}`);
  }

  // Per-ticket print-fix records use the QA Atlas verifier. Toolkit and
  // orchestration tasks can legitimately write different record formats,
  // so they are gated by commit substance + Conductor linkage instead.
  if (ticketId && isQaTicketId(ticketId)) {
    try {
      execSync(`node scripts/qa-atlas.js --verify ${ticketId}`, {
        cwd: workspacePath,
        encoding: 'utf8',
        timeout: 30000,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
    } catch (e) {
      const detail = String(e.stderr || e.stdout || e.message || '').trim().split('\n').slice(0, 5).join(' | ');
      return {
        ok: false,
        reason: `qa-atlas --verify ${ticketId} failed: ${detail}`,
        sha: headAfter,
        ticketId,
      };
    }
  }

  if (ticketId && isQaTicketId(ticketId)) {
    const amendResult = amendVerifiedRecordIfNeeded(workspacePath, ticketId);
    if (amendResult.error) {
      return { ok: false, reason: amendResult.error, sha: headAfter, ticketId };
    }
    if (amendResult.amended) {
      log('autonomous', `Auto-amended verified record evidence into commit: ${amendResult.files.join(', ')}`);
      headAfter = amendResult.sha;
    }

    const recordCheck = verifyTrackedRecordFile(workspacePath, ticketId);
    if (!recordCheck.ok) {
      return {
        ok: false,
        reason: recordCheck.reason,
        sha: headAfter,
        ticketId,
      };
    }
  }

  return { ok: true, sha: headAfter, ticketId: ticketId || (taskInfo && taskInfo.id) };
}

async function main() {
  if (!fs.existsSync(CONDUCTOR_DIR)) {
    console.error('Error: .conductor/ not found. Run "conductor-mcp init" first.');
    process.exit(1);
  }

  const workspacePath = resolveWorkspacePath(projectName);

  log('autonomous', `=== Autonomous mode started for project: ${projectName} ===`);
  log('autonomous', `Provider: ${provider}${model ? `, model: ${model}` : ''}`);
  log('autonomous', `Workspace: ${workspacePath}${workspacePath === process.cwd() ? ' (cwd fallback)' : ''}`);
  if (maxBudget) {
    log('autonomous', `Max budget per session: $${maxBudget}`);
  }

  let iteration = 0;

  while (true) {
    iteration++;
    if (maxIterations && iteration > maxIterations) {
      log('autonomous', `Reached --max-iterations=${maxIterations}. Exiting.`);
      break;
    }

    const status = checkTasks(projectName);

    if (status === 'complete') {
      log('autonomous', 'All tasks complete! Exiting.');
      break;
    }
    if (status === 'not_found') {
      log('autonomous', `Project '${projectName}' not found. Exiting.`);
      process.exit(1);
    }
    if (status === 'blocked') {
      log('autonomous', 'All remaining tasks are blocked on dependencies. Exiting.');
      break;
    }

    log('autonomous', `--- Iteration ${iteration} ---`);

    let headBefore = null;
    try {
      headBefore = execSync(`git -C ${JSON.stringify(workspacePath)} rev-parse HEAD`, {
        encoding: 'utf8',
        timeout: 5000,
        stdio: ['pipe', 'pipe', 'pipe'],
      }).trim();
    } catch (e) {
      log('autonomous', `WARN: could not capture HEAD before session (${e.message.split('\n')[0]}); post-session verify will be skipped`);
    }

    const sessionResult = await spawnSession(projectName, { maxBudget, iteration, provider, model, workspacePath });
    const result = typeof sessionResult === 'string' ? sessionResult : sessionResult.status;
    const sessionFacts = typeof sessionResult === 'object' && sessionResult ? sessionResult.sessionFacts : null;

    gitCommitSafetyNet();

    if (result === 'error') {
      log('autonomous', 'Autonomous session failed. Stopping instead of retrying.');
      process.exit(1);
    }

    // Defense-in-depth: runner-side substance + --verify gate. The
    // system prompt asks Codex to run --verify before mark_task_complete,
    // but if Codex skips that step a malformed record can still close
    // the ticket. Re-run both gates here from the runner.
    if (headBefore) {
      const v = postSessionVerify({ workspacePath, headBefore, project: projectName, sessionFacts });
      if (!v.ok && v.reason !== 'no-commit') {
        log('autonomous', `HALT: post-session verify failed: ${v.reason}`);
        log('autonomous', `Commit ${(v.sha || '').slice(0, 7)} (ticket=${v.ticketId || '?'}) is left in place. Recovery options:`);
        log('autonomous', `  - revert:  git -C ${workspacePath} reset --hard ${headBefore}`);
        log('autonomous', `  - or fix:  edit record + git commit --amend, then re-run autonomous`);
        log('autonomous', `Task may have been marked complete in Conductor; check status before re-running.`);
        process.exit(1);
      }
      if (v.ok && v.ticketId) {
        log('autonomous', `Post-session verify PASS: ticket=${v.ticketId} sha=${v.sha.slice(0, 7)}`);
      } else if (v.ok && v.reason === 'no-commit') {
        log('autonomous', `Post-session verify SKIP: no new commit this session`);
      }
    }

    if (result === 'rotate') {
      log('autonomous', 'Rotation complete. Starting new session in 2s...');
      await new Promise(r => setTimeout(r, 2000));
      continue;
    }

    if (result === 'done') {
      log('autonomous', 'All tasks done. Exiting.');
      break;
    }

    const recheck = checkTasks(projectName);

    if (recheck === 'complete') {
      log('autonomous', 'All tasks complete! Exiting.');
      break;
    }

    if (recheck === 'has_tasks') {
      log('autonomous', 'Session ended without rotation signal but tasks remain. Continuing in 2s...');
      await new Promise(r => setTimeout(r, 2000));
      continue;
    }

    log('autonomous', 'No more actionable tasks. Exiting.');
    break;
  }

  log('autonomous', '=== Autonomous mode finished ===');
}

function cleanup() {
  log('autonomous', 'Received shutdown signal.');
  if (currentProc && !currentProc.killed) {
    try { currentProc.kill('SIGTERM'); } catch {}
  }
  process.exit(0);
}

process.on('SIGINT', cleanup);
process.on('SIGTERM', cleanup);

main().catch((err) => {
  log('autonomous', `Fatal error: ${err.message}`);
  process.exit(1);
});
