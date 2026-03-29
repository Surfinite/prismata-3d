'use strict';

const Database = require('better-sqlite3');
const path = require('path');

const DB_PATH = process.env.DB_PATH || '/opt/fabricate/fabricate.db';

let db;

const ALLOWED_TRANSITIONS = {
  pending: new Set(['running', 'completed', 'failed']),
  running: new Set(['completed', 'failed']),
};

function now() {
  return Math.floor(Date.now() / 1000);
}

function getDb() {
  if (db) return db;
  db = new Database(DB_PATH);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.pragma('busy_timeout = 5000');
  initSchema();
  return db;
}

function initSchema() {
  db.exec(`
    CREATE TABLE IF NOT EXISTS requests (
      id INTEGER PRIMARY KEY,
      status TEXT NOT NULL DEFAULT 'pending',
      requested_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL,
      discord_message_id TEXT,
      discord_channel_id TEXT,
      approved_by TEXT,
      approved_at INTEGER,
      requester_ip TEXT
    );

    CREATE TABLE IF NOT EXISTS sessions (
      id INTEGER PRIMARY KEY,
      status TEXT NOT NULL DEFAULT 'active',
      approved_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL,
      request_id INTEGER REFERENCES requests(id),
      revoked_at INTEGER,
      wake_requested_at INTEGER
    );

    CREATE TABLE IF NOT EXISTS gpu_instances (
      instance_id TEXT PRIMARY KEY,
      slot TEXT NOT NULL,
      private_ip TEXT,
      status TEXT NOT NULL DEFAULT 'launching',
      launched_at INTEGER NOT NULL,
      ready_at INTEGER,
      gone_at INTEGER,
      session_id INTEGER REFERENCES sessions(id),
      health_failures INTEGER DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS client_assignments (
      client_id TEXT PRIMARY KEY,
      gpu_instance_id TEXT REFERENCES gpu_instances(instance_id),
      assigned_at INTEGER NOT NULL,
      last_seen_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS prompts (
      prompt_id TEXT PRIMARY KEY,
      client_id TEXT NOT NULL,
      gpu_instance_id TEXT NOT NULL,
      submitted_at INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending'
    );

    CREATE INDEX IF NOT EXISTS idx_requests_status ON requests(status);
    CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
    CREATE INDEX IF NOT EXISTS idx_gpu_instances_status ON gpu_instances(status);
    CREATE INDEX IF NOT EXISTS idx_client_assignments_last_seen ON client_assignments(last_seen_at);
  `);

  // Phase 4 migration: add prompt lifecycle columns if missing
  try {
    db.exec(`ALTER TABLE prompts ADD COLUMN started_at INTEGER`);
  } catch (e) { /* column already exists */ }
  try {
    db.exec(`ALTER TABLE prompts ADD COLUMN finished_at INTEGER`);
  } catch (e) { /* column already exists */ }
  try {
    db.exec(`ALTER TABLE prompts ADD COLUMN updated_at INTEGER`);
  } catch (e) { /* column already exists */ }

  // Phase 4 indexes
  db.exec(`
    CREATE INDEX IF NOT EXISTS idx_gpu_instances_slot_active
      ON gpu_instances(slot) WHERE status IN ('launching', 'ready');
    CREATE INDEX IF NOT EXISTS idx_prompts_status_gpu
      ON prompts(status, gpu_instance_id);
    CREATE INDEX IF NOT EXISTS idx_prompts_client_gpu_status
      ON prompts(client_id, gpu_instance_id, status);
    CREATE INDEX IF NOT EXISTS idx_client_assignments_gpu
      ON client_assignments(gpu_instance_id);
  `);

  // Backfill updated_at for existing prompts that lack it
  db.prepare(`
    UPDATE prompts SET updated_at = submitted_at WHERE updated_at IS NULL
  `).run();
}

// ── Query helpers ──

function getActiveSession() {
  const d = getDb();
  const ts = now();
  return d.prepare(`
    SELECT * FROM sessions
    WHERE status = 'active' AND expires_at > ?
    ORDER BY id DESC LIMIT 1
  `).get(ts) || null;
}

function getPendingRequest() {
  const d = getDb();
  const ts = now();
  return d.prepare(`
    SELECT * FROM requests
    WHERE status = 'pending' AND expires_at > ?
    ORDER BY id DESC LIMIT 1
  `).get(ts) || null;
}

function getLatestRequest() {
  const d = getDb();
  return d.prepare(`
    SELECT * FROM requests ORDER BY id DESC LIMIT 1
  `).get() || null;
}

function createRequest(ip) {
  const d = getDb();
  const ts = now();
  const expiresAt = ts + 3600; // 1h TTL

  // DB-level protection against duplicate pending requests (Fix I)
  const create = d.transaction(() => {
    const existing = getPendingRequest();
    if (existing) throw new Error('Request already pending');
    const info = d.prepare(`
      INSERT INTO requests (status, requested_at, expires_at, requester_ip)
      VALUES ('pending', ?, ?, ?)
    `).run(ts, expiresAt, ip);
    return d.prepare('SELECT * FROM requests WHERE id = ?').get(info.lastInsertRowid);
  });
  return create();
}

function deleteRequest(requestId) {
  const d = getDb();
  d.prepare('DELETE FROM requests WHERE id = ?').run(requestId);
}

function updateRequestDiscord(requestId, messageId, channelId) {
  const d = getDb();
  d.prepare(`
    UPDATE requests SET discord_message_id = ?, discord_channel_id = ? WHERE id = ?
  `).run(messageId, channelId, requestId);
}

function approveRequest(requestId, approvedBy) {
  const d = getDb();
  const ts = now();
  const sessionExpires = ts + 86400; // 24h

  const approve = d.transaction(() => {
    // Expire any existing active session before creating a new one
    d.prepare(`
      UPDATE sessions SET status = 'expired' WHERE status = 'active'
    `).run();

    d.prepare(`
      UPDATE requests SET status = 'approved', approved_by = ?, approved_at = ? WHERE id = ?
    `).run(approvedBy, ts, requestId);

    // Create session with wake_requested_at set (auto-wake on approval)
    const info = d.prepare(`
      INSERT INTO sessions (status, approved_at, expires_at, request_id, wake_requested_at)
      VALUES ('active', ?, ?, ?, ?)
    `).run(ts, sessionExpires, requestId, ts);

    return d.prepare('SELECT * FROM sessions WHERE id = ?').get(info.lastInsertRowid);
  });

  return approve();
}

function expireRequest(requestId) {
  const d = getDb();
  d.prepare(`UPDATE requests SET status = 'expired' WHERE id = ?`).run(requestId);
}

function denyRequest(requestId) {
  const d = getDb();
  d.prepare(`UPDATE requests SET status = 'denied' WHERE id = ?`).run(requestId);
}

function expireSession(sessionId) {
  const d = getDb();
  d.prepare(`UPDATE sessions SET status = 'expired' WHERE id = ?`).run(sessionId);
}

function revokeSession(sessionId) {
  const d = getDb();
  const ts = now();
  d.prepare(`UPDATE sessions SET status = 'revoked', revoked_at = ? WHERE id = ?`).run(ts, sessionId);
}

function createSessionDirect(hours) {
  const d = getDb();
  const ts = now();
  const expiresAt = ts + hours * 3600;

  // Transaction: refuse if active session exists, expire pending requests, create session (Fix G, Fix I)
  const create = d.transaction(() => {
    const existing = getActiveSession();
    if (existing) {
      throw new Error(`Active session ${existing.id} already exists (expires at ${existing.expires_at})`);
    }

    // Expire all pending requests before creating the session
    d.prepare(`UPDATE requests SET status = 'expired' WHERE status = 'pending'`).run();

    // Create session with wake_requested_at set (auto-wake on direct creation)
    const info = d.prepare(`
      INSERT INTO sessions (status, approved_at, expires_at, wake_requested_at)
      VALUES ('active', ?, ?, ?)
    `).run(ts, expiresAt, ts);
    return d.prepare('SELECT * FROM sessions WHERE id = ?').get(info.lastInsertRowid);
  });
  return create();
}

function setWakeRequested(sessionId) {
  const d = getDb();
  const ts = now();
  d.prepare(`UPDATE sessions SET wake_requested_at = ? WHERE id = ?`).run(ts, sessionId);
}

function clearWakeRequested(sessionId) {
  const d = getDb();
  d.prepare(`UPDATE sessions SET wake_requested_at = NULL WHERE id = ?`).run(sessionId);
}

// ── GPU instance helpers ──

function getGpuInstances(statusFilter) {
  const d = getDb();
  if (statusFilter) {
    return d.prepare('SELECT * FROM gpu_instances WHERE status = ?').all(statusFilter);
  }
  return d.prepare("SELECT * FROM gpu_instances WHERE status IN ('launching', 'ready')").all();
}

function getReadyGpu() {
  const d = getDb();
  return d.prepare("SELECT * FROM gpu_instances WHERE status = 'ready' ORDER BY launched_at ASC LIMIT 1").get() || null;
}

function registerGpuInstance(instanceId, slot, sessionId) {
  const d = getDb();
  const ts = now();
  // UPSERT instead of INSERT OR REPLACE to preserve columns not in the SET clause (Fix J)
  d.prepare(`
    INSERT INTO gpu_instances (instance_id, slot, status, launched_at, session_id, health_failures)
    VALUES (?, ?, 'launching', ?, ?, 0)
    ON CONFLICT(instance_id) DO UPDATE SET
      slot = excluded.slot,
      status = excluded.status,
      launched_at = excluded.launched_at,
      session_id = excluded.session_id,
      health_failures = 0
  `).run(instanceId, slot, ts, sessionId);
}

function markGpuReady(instanceId, privateIp) {
  const d = getDb();
  const ts = now();
  d.prepare(`
    UPDATE gpu_instances SET status = 'ready', private_ip = ?, ready_at = ? WHERE instance_id = ?
  `).run(privateIp, ts, instanceId);
}

function markGpuGone(instanceId) {
  const d = getDb();
  const ts = now();
  d.prepare(`
    UPDATE gpu_instances SET status = 'gone', gone_at = ? WHERE instance_id = ?
  `).run(ts, instanceId);
  // Clear client assignments for this GPU
  d.prepare('DELETE FROM client_assignments WHERE gpu_instance_id = ?').run(instanceId);
}

// Health failure tracking (Fix D)
function incrementHealthFailures(instanceId) {
  const d = getDb();
  d.prepare(`UPDATE gpu_instances SET health_failures = health_failures + 1 WHERE instance_id = ?`).run(instanceId);
  return d.prepare('SELECT health_failures FROM gpu_instances WHERE instance_id = ?').get(instanceId)?.health_failures || 0;
}

function resetHealthFailures(instanceId) {
  const d = getDb();
  d.prepare(`UPDATE gpu_instances SET health_failures = 0 WHERE instance_id = ?`).run(instanceId);
}

// Phase 3: hard-limit to 1 GPU, always slot 'A' (Fix B)
// getNextSlot() removed -- always use 'A'. The slot column is kept for Phase 4.
function canLaunchGpu() {
  const d = getDb();
  const active = d.prepare("SELECT COUNT(*) as cnt FROM gpu_instances WHERE status IN ('launching', 'ready')").get();
  return active.cnt === 0;
}

// ── Client assignment helpers ──

function getClientAssignment(clientId) {
  const d = getDb();
  return d.prepare(`
    SELECT ca.*, gi.private_ip, gi.status as gpu_status
    FROM client_assignments ca
    JOIN gpu_instances gi ON ca.gpu_instance_id = gi.instance_id
    WHERE ca.client_id = ? AND gi.status = 'ready'
  `).get(clientId) || null;
}

function assignClient(clientId, gpuInstanceId) {
  const d = getDb();
  const ts = now();
  d.prepare(`
    INSERT OR REPLACE INTO client_assignments (client_id, gpu_instance_id, assigned_at, last_seen_at)
    VALUES (?, ?, ?, ?)
  `).run(clientId, gpuInstanceId, ts, ts);
}

function touchClient(clientId) {
  const d = getDb();
  const ts = now();
  d.prepare(`UPDATE client_assignments SET last_seen_at = ? WHERE client_id = ?`).run(ts, clientId);
}

function recordPrompt(promptId, clientId, gpuInstanceId) {
  const d = getDb();
  const ts = now();
  d.prepare(`
    INSERT INTO prompts (prompt_id, client_id, gpu_instance_id, submitted_at, status)
    VALUES (?, ?, ?, ?, 'pending')
  `).run(promptId, clientId, gpuInstanceId, ts);
}

function getPromptGpu(promptId) {
  const d = getDb();
  const row = d.prepare(`
    SELECT p.*, gi.private_ip
    FROM prompts p
    JOIN gpu_instances gi ON p.gpu_instance_id = gi.instance_id
    WHERE p.prompt_id = ?
  `).get(promptId);
  return row || null;
}

// ── Cleanup helpers ──

function expireStaleRequests() {
  const d = getDb();
  const ts = now();
  return d.prepare(`
    UPDATE requests SET status = 'expired'
    WHERE status = 'pending' AND expires_at <= ?
  `).run(ts).changes;
}

function expireStaleSessions() {
  const d = getDb();
  const ts = now();
  return d.prepare(`
    UPDATE sessions SET status = 'expired'
    WHERE status = 'active' AND expires_at <= ?
  `).run(ts).changes;
}

function cleanStaleClientAssignments() {
  const d = getDb();
  const cutoff = now() - 3600; // 1 hour ago
  return d.prepare(`
    DELETE FROM client_assignments
    WHERE last_seen_at < ?
  `).run(cutoff).changes;
}

// ── Launch lock helpers ──

// We use a simple in-memory launch lock. The reconciler is single-threaded.
let launchLock = { inProgress: false, timestamp: null, cooldownUntil: null };

function getLaunchLock() {
  return { ...launchLock };
}

function setLaunchLock(inProgress) {
  launchLock.inProgress = inProgress;
  launchLock.timestamp = inProgress ? Date.now() : null;
}

function setLaunchCooldown() {
  launchLock.cooldownUntil = Date.now() + 60 * 1000; // 60s cooldown
}

function isLaunchCoolingDown() {
  return launchLock.cooldownUntil && Date.now() < launchLock.cooldownUntil;
}

// ── Epoch-to-ISO conversion helper (for API responses) ──

function epochToIso(epoch) {
  if (epoch == null) return null;
  return new Date(epoch * 1000).toISOString();
}

module.exports = {
  getDb,
  now,
  epochToIso,
  getActiveSession,
  getPendingRequest,
  getLatestRequest,
  createRequest,
  deleteRequest,
  updateRequestDiscord,
  approveRequest,
  expireRequest,
  denyRequest,
  expireSession,
  revokeSession,
  createSessionDirect,
  setWakeRequested,
  clearWakeRequested,
  getGpuInstances,
  getReadyGpu,
  registerGpuInstance,
  markGpuReady,
  markGpuGone,
  incrementHealthFailures,
  resetHealthFailures,
  canLaunchGpu,
  getClientAssignment,
  assignClient,
  touchClient,
  recordPrompt,
  getPromptGpu,
  expireStaleRequests,
  expireStaleSessions,
  cleanStaleClientAssignments,
  getLaunchLock,
  setLaunchLock,
  setLaunchCooldown,
  isLaunchCoolingDown,
};
