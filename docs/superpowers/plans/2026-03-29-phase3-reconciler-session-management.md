# Phase 3: Reconciler + Session Management -- Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the site box into an orchestrator that manages GPU lifecycle, session approval via Discord, and proxies all ComfyUI API/WebSocket traffic to GPU private IPs. Users click "Request Access," the owner approves via Discord reaction, and the reconciler auto-launches/monitors GPU instances. When the session expires or GPUs idle, they shut down automatically.

**Architecture:** The site box Express server (port 3100) gains: (1) a SQLite database for session/request/GPU state, (2) a 5-second reconciler loop that is the sole owner of all EC2 actions, (3) Discord webhook + API polling for the approval flow, (4) HTTP proxy routes for ComfyUI API calls, (5) WebSocket proxying for real-time generation progress. The GPU instances lose their Cloudflare tunnel and are accessed directly via VPC private IP on port 8188.

**Tech Stack:** Express.js, better-sqlite3, http-proxy-middleware, ws, @aws-sdk/client-ec2, @aws-sdk/client-ssm, node-fetch (or built-in fetch in Node 22)

**Spec:** `docs/superpowers/specs/2026-03-29-multi-user-fabrication-terminal-design.md` -- Phase 3 section, Reconciler Loop, Request/Session State Machine, SQLite Schema, Site Box API Routes, GPU Proxy Routes, GPU Instance Changes

**Site box:** Existing `t3.micro spot`, EIP `<SITE_BOX_EIP>`, Ubuntu, Node.js v22, runs `fabricate.prismata.live` via nginx reverse proxy to port 3100. SSH: `ssh -i ~/.ssh/<SSH_KEY>.pem ubuntu@<SITE_BOX_EIP>`

**Prerequisites:** Phase 1 (queue isolation) and Phase 2 (always-on frontend) are deployed and working.

**Key constraints:**
- The reconciler is the ONLY code that calls EC2 APIs (launch, describe, terminate). No API endpoint directly calls EC2.
- `/api/status` is strictly read-only -- it never triggers launches or side effects.
- Discord bot token and webhook URL are stored in SSM parameters (already exist for the bot).
- The launch template name is `prismata-3d-gen`, instances are g5.xlarge spot.
- The GPU security group is `sg-0fdc130ad1d5dc373`.
- Max 2 GPU instances (Phase 3 implements single-GPU; multi-GPU sticky assignment is Phase 4).

---

## File Structure

### New files

```
infra/site/
├── lib/
│   ├── db.js                 # SQLite setup + schema init + helper queries
│   ├── reconciler.js         # Background 5s loop: EC2 lifecycle, health checks, cleanup
│   └── discord.js            # Discord webhook send + reaction polling
├── routes/
│   ├── access.js             # POST /api/request-access
│   └── gpu.js                # GPU proxy routes (prompt, queue, history, metadata, system_stats)

infra/cli.js                  # CLI admin tool (create-session, status, revoke, launch-gpu)
```

### Modified files

```
infra/site/package.json       # Add: better-sqlite3, http-proxy-middleware, ws, @aws-sdk/client-ec2, @aws-sdk/client-ssm
infra/site/server.js          # Add: db init, reconciler startup, GPU proxy routes, WS proxy, access routes
infra/site/routes/status.js   # Expand to return real session/GPU state from DB
infra/site/fabricate.service   # Add env var for DB path
infra/site/deploy.sh          # Add new files to deploy list
infra/frontend/index.html     # New state machine, Request Access button, session countdown, auto-reconnect
infra/ec2/user-data.sh        # Remove cloudflared tunnel
infra/ec2/idle-watchdog.sh    # 20min threshold, remove Discord notification
```

---

### Task 1: Add new npm dependencies

**Files:**
- Modify: `infra/site/package.json`

- [ ] **Step 1: Update package.json with new dependencies**

```json
{
  "name": "fabricate-server",
  "version": "0.2.0",
  "private": true,
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "@aws-sdk/client-ec2": "^3.700.0",
    "@aws-sdk/client-s3": "^3.700.0",
    "@aws-sdk/client-ssm": "^3.700.0",
    "@aws-sdk/s3-request-presigner": "^3.700.0",
    "better-sqlite3": "^11.7.0",
    "express": "^4.21.0",
    "http-proxy-middleware": "^3.0.0",
    "ws": "^8.18.0"
  }
}
```

- [ ] **Step 2: Run npm install on the site box** (handled by deploy.sh, no action needed here)

---

### Task 2: Create SQLite database module

**Files:**
- Create: `infra/site/lib/db.js`

This module initializes the SQLite database at `/opt/fabricate/fabricate.db` with all five tables from the spec, plus convenience query functions.

- [ ] **Step 1: Create `infra/site/lib/db.js`**

```js
'use strict';

const Database = require('better-sqlite3');
const path = require('path');

const DB_PATH = process.env.DB_PATH || '/opt/fabricate/fabricate.db';

let db;

function getDb() {
  if (db) return db;
  db = new Database(DB_PATH);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  initSchema();
  return db;
}

function initSchema() {
  db.exec(`
    CREATE TABLE IF NOT EXISTS requests (
      id INTEGER PRIMARY KEY,
      status TEXT NOT NULL DEFAULT 'pending',
      requested_at TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      discord_message_id TEXT,
      discord_channel_id TEXT,
      approved_by TEXT,
      approved_at TEXT,
      requester_ip TEXT
    );

    CREATE TABLE IF NOT EXISTS sessions (
      id INTEGER PRIMARY KEY,
      status TEXT NOT NULL DEFAULT 'active',
      approved_at TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      request_id INTEGER REFERENCES requests(id),
      revoked_at TEXT
    );

    CREATE TABLE IF NOT EXISTS gpu_instances (
      instance_id TEXT PRIMARY KEY,
      slot TEXT NOT NULL,
      private_ip TEXT,
      status TEXT NOT NULL DEFAULT 'launching',
      launched_at TEXT NOT NULL,
      ready_at TEXT,
      gone_at TEXT,
      session_id INTEGER REFERENCES sessions(id)
    );

    CREATE TABLE IF NOT EXISTS client_assignments (
      client_id TEXT PRIMARY KEY,
      gpu_instance_id TEXT REFERENCES gpu_instances(instance_id),
      assigned_at TEXT NOT NULL,
      last_seen_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS prompts (
      prompt_id TEXT PRIMARY KEY,
      client_id TEXT NOT NULL,
      gpu_instance_id TEXT NOT NULL,
      submitted_at TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending'
    );
  `);
}

// ── Query helpers ──

function getActiveSession() {
  const d = getDb();
  return d.prepare(`
    SELECT * FROM sessions
    WHERE status = 'active' AND expires_at > datetime('now')
    ORDER BY id DESC LIMIT 1
  `).get() || null;
}

function getPendingRequest() {
  const d = getDb();
  return d.prepare(`
    SELECT * FROM requests
    WHERE status = 'pending' AND expires_at > datetime('now')
    ORDER BY id DESC LIMIT 1
  `).get() || null;
}

function getLatestRequest() {
  const d = getDb();
  return d.prepare(`
    SELECT * FROM requests ORDER BY id DESC LIMIT 1
  `).get() || null;
}

function createRequest(ip) {
  const d = getDb();
  const now = new Date().toISOString();
  const expiresAt = new Date(Date.now() + 60 * 60 * 1000).toISOString(); // 1h TTL
  const info = d.prepare(`
    INSERT INTO requests (status, requested_at, expires_at, requester_ip)
    VALUES ('pending', ?, ?, ?)
  `).run(now, expiresAt, ip);
  return d.prepare('SELECT * FROM requests WHERE id = ?').get(info.lastInsertRowid);
}

function updateRequestDiscord(requestId, messageId, channelId) {
  const d = getDb();
  d.prepare(`
    UPDATE requests SET discord_message_id = ?, discord_channel_id = ? WHERE id = ?
  `).run(messageId, channelId, requestId);
}

function approveRequest(requestId, approvedBy) {
  const d = getDb();
  const now = new Date().toISOString();
  const sessionExpires = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(); // 24h

  const approve = d.transaction(() => {
    d.prepare(`
      UPDATE requests SET status = 'approved', approved_by = ?, approved_at = ? WHERE id = ?
    `).run(approvedBy, now, requestId);

    const info = d.prepare(`
      INSERT INTO sessions (status, approved_at, expires_at, request_id)
      VALUES ('active', ?, ?, ?)
    `).run(now, sessionExpires, requestId);

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
  const now = new Date().toISOString();
  d.prepare(`UPDATE sessions SET status = 'revoked', revoked_at = ? WHERE id = ?`).run(now, sessionId);
}

function createSessionDirect(hours) {
  const d = getDb();
  const now = new Date().toISOString();
  const expiresAt = new Date(Date.now() + hours * 60 * 60 * 1000).toISOString();
  const info = d.prepare(`
    INSERT INTO sessions (status, approved_at, expires_at)
    VALUES ('active', ?, ?)
  `).run(now, expiresAt);
  return d.prepare('SELECT * FROM sessions WHERE id = ?').get(info.lastInsertRowid);
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
  const now = new Date().toISOString();
  d.prepare(`
    INSERT OR REPLACE INTO gpu_instances (instance_id, slot, status, launched_at, session_id)
    VALUES (?, ?, 'launching', ?, ?)
  `).run(instanceId, slot, now, sessionId);
}

function markGpuReady(instanceId, privateIp) {
  const d = getDb();
  const now = new Date().toISOString();
  d.prepare(`
    UPDATE gpu_instances SET status = 'ready', private_ip = ?, ready_at = ? WHERE instance_id = ?
  `).run(privateIp, now, instanceId);
}

function markGpuGone(instanceId) {
  const d = getDb();
  const now = new Date().toISOString();
  d.prepare(`
    UPDATE gpu_instances SET status = 'gone', gone_at = ? WHERE instance_id = ?
  `).run(now, instanceId);
  // Clear client assignments for this GPU
  d.prepare('DELETE FROM client_assignments WHERE gpu_instance_id = ?').run(instanceId);
}

function getNextSlot() {
  const d = getDb();
  const usedSlots = d.prepare("SELECT slot FROM gpu_instances WHERE status IN ('launching', 'ready')").all().map(r => r.slot);
  if (!usedSlots.includes('A')) return 'A';
  if (!usedSlots.includes('B')) return 'B';
  return null; // Both slots taken
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
  const now = new Date().toISOString();
  d.prepare(`
    INSERT OR REPLACE INTO client_assignments (client_id, gpu_instance_id, assigned_at, last_seen_at)
    VALUES (?, ?, ?, ?)
  `).run(clientId, gpuInstanceId, now, now);
}

function touchClient(clientId) {
  const d = getDb();
  const now = new Date().toISOString();
  d.prepare(`UPDATE client_assignments SET last_seen_at = ? WHERE client_id = ?`).run(now, clientId);
}

function recordPrompt(promptId, clientId, gpuInstanceId) {
  const d = getDb();
  const now = new Date().toISOString();
  d.prepare(`
    INSERT INTO prompts (prompt_id, client_id, gpu_instance_id, submitted_at, status)
    VALUES (?, ?, ?, ?, 'pending')
  `).run(promptId, clientId, gpuInstanceId, now);
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
  return d.prepare(`
    UPDATE requests SET status = 'expired'
    WHERE status = 'pending' AND expires_at <= datetime('now')
  `).run().changes;
}

function expireStaleSessions() {
  const d = getDb();
  return d.prepare(`
    UPDATE sessions SET status = 'expired'
    WHERE status = 'active' AND expires_at <= datetime('now')
  `).run().changes;
}

function cleanStaleClientAssignments() {
  const d = getDb();
  return d.prepare(`
    DELETE FROM client_assignments
    WHERE last_seen_at < datetime('now', '-1 hour')
  `).run().changes;
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

module.exports = {
  getDb,
  getActiveSession,
  getPendingRequest,
  getLatestRequest,
  createRequest,
  updateRequestDiscord,
  approveRequest,
  expireRequest,
  denyRequest,
  expireSession,
  revokeSession,
  createSessionDirect,
  getGpuInstances,
  getReadyGpu,
  registerGpuInstance,
  markGpuReady,
  markGpuGone,
  getNextSlot,
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
```

---

### Task 3: Create Discord webhook + reaction polling module

**Files:**
- Create: `infra/site/lib/discord.js`

This module sends access request notifications via Discord webhook and polls for approval reactions via the Discord API.

- [ ] **Step 1: Create `infra/site/lib/discord.js`**

```js
'use strict';

const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');

const REGION = process.env.AWS_REGION || 'us-east-1';
const ssm = new SSMClient({ region: REGION });

// Cache SSM values
let discordWebhookUrl = null;
let discordBotToken = null;
let discordChannelId = null;

async function getSSMParam(name) {
  try {
    const resp = await ssm.send(new GetParameterCommand({
      Name: name,
      WithDecryption: true,
    }));
    return resp.Parameter.Value;
  } catch (err) {
    console.error(`[discord] Failed to get SSM param ${name}:`, err.message);
    return null;
  }
}

async function ensureConfig() {
  if (!discordWebhookUrl) {
    discordWebhookUrl = await getSSMParam('/prismata-3d/discord-webhook-url');
  }
  if (!discordBotToken) {
    discordBotToken = await getSSMParam('/prismata-3d/discord-bot-token');
  }
  if (!discordChannelId) {
    discordChannelId = await getSSMParam('/prismata-3d/discord-channel-id');
  }
}

/**
 * Send an access request notification to Discord via webhook.
 * Returns the message ID so we can poll for reactions.
 */
async function sendAccessRequest(requestId, requesterIp) {
  await ensureConfig();
  if (!discordWebhookUrl) {
    console.error('[discord] No webhook URL configured');
    return null;
  }

  // Use webhook with ?wait=true to get the message object back
  const webhookWaitUrl = discordWebhookUrl.includes('?')
    ? `${discordWebhookUrl}&wait=true`
    : `${discordWebhookUrl}?wait=true`;

  const body = {
    content: `**Fabrication Terminal Access Request** (ID: ${requestId})\n` +
      `IP: \`${requesterIp}\`\n` +
      `React with ✅ to approve or ❌ to deny.\n` +
      `Expires in 1 hour.\n` +
      `<@337042753060823040>`,  // @Surfinite user ID
    allowed_mentions: { users: ['337042753060823040'] },
  };

  try {
    const resp = await fetch(webhookWaitUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });

    if (!resp.ok) {
      const text = await resp.text();
      console.error(`[discord] Webhook failed ${resp.status}: ${text}`);
      return null;
    }

    const msg = await resp.json();
    return { messageId: msg.id, channelId: msg.channel_id };
  } catch (err) {
    console.error('[discord] Webhook error:', err.message);
    return null;
  }
}

/**
 * Check if the request message has a ✅ or ❌ reaction from the owner.
 * Uses the Discord bot token to read reactions.
 * Returns: 'approved' | 'denied' | null
 */
async function checkReactions(channelId, messageId) {
  await ensureConfig();
  if (!discordBotToken || !channelId || !messageId) return null;

  const OWNER_ID = '337042753060823040'; // Surfinite's Discord user ID

  // Check for ✅ reaction
  try {
    const approveResp = await fetch(
      `https://discord.com/api/v10/channels/${channelId}/messages/${messageId}/reactions/${encodeURIComponent('✅')}`,
      { headers: { Authorization: `Bot ${discordBotToken}` } }
    );
    if (approveResp.ok) {
      const users = await approveResp.json();
      if (users.some(u => u.id === OWNER_ID)) {
        return 'approved';
      }
    }
  } catch (err) {
    console.error('[discord] Reaction check (approve) error:', err.message);
  }

  // Check for ❌ reaction
  try {
    const denyResp = await fetch(
      `https://discord.com/api/v10/channels/${channelId}/messages/${messageId}/reactions/${encodeURIComponent('❌')}`,
      { headers: { Authorization: `Bot ${discordBotToken}` } }
    );
    if (denyResp.ok) {
      const users = await denyResp.json();
      if (users.some(u => u.id === OWNER_ID)) {
        return 'denied';
      }
    }
  } catch (err) {
    console.error('[discord] Reaction check (deny) error:', err.message);
  }

  return null;
}

module.exports = {
  sendAccessRequest,
  checkReactions,
};
```

**Note:** The Surfinite Discord user ID `337042753060823040` is hardcoded. The SSM parameter `/prismata-3d/discord-bot-token` must contain the bot token. The SSM parameter `/prismata-3d/discord-channel-id` stores the channel ID for fallback but is typically extracted from the webhook response. If the webhook returns a channel_id, that is used; otherwise the SSM param is used.

---

### Task 4: Create the Reconciler loop

**Files:**
- Create: `infra/site/lib/reconciler.js`

This is the core control plane. It runs every 5 seconds and is the sole owner of all EC2 actions.

- [ ] **Step 1: Create `infra/site/lib/reconciler.js`**

```js
'use strict';

const { EC2Client, DescribeInstancesCommand, RunInstancesCommand } = require('@aws-sdk/client-ec2');
const db = require('./db');
const discord = require('./discord');

const REGION = process.env.AWS_REGION || 'us-east-1';
const ec2 = new EC2Client({ region: REGION });

const LAUNCH_TEMPLATE = 'prismata-3d-gen';
const TAG_KEY = 'Project';
const TAG_VALUE = 'prismata-3d-gen';
const SPOT_MAX_PRICE = '0.80';
const LAUNCH_TIMEOUT_MS = 5 * 60 * 1000; // 5 minutes
const HEALTH_CHECK_TIMEOUT_MS = 5000;

let reconcilerInterval = null;
let tickInProgress = false;

function start() {
  if (reconcilerInterval) return;
  console.log('[reconciler] Starting reconciler loop (5s interval)');
  reconcilerInterval = setInterval(tick, 5000);
  // Run first tick immediately
  tick();
}

function stop() {
  if (reconcilerInterval) {
    clearInterval(reconcilerInterval);
    reconcilerInterval = null;
  }
}

async function tick() {
  if (tickInProgress) return; // Prevent overlapping ticks
  tickInProgress = true;
  try {
    await reconcile();
  } catch (err) {
    console.error('[reconciler] Tick error:', err.message);
  } finally {
    tickInProgress = false;
  }
}

async function reconcile() {
  // 1. Expire stale requests and sessions
  const expiredRequests = db.expireStaleRequests();
  const expiredSessions = db.expireStaleSessions();
  if (expiredRequests > 0) console.log(`[reconciler] Expired ${expiredRequests} stale request(s)`);
  if (expiredSessions > 0) console.log(`[reconciler] Expired ${expiredSessions} stale session(s)`);

  // 2. Clean stale client assignments
  db.cleanStaleClientAssignments();

  // 3. Check for pending requests that need Discord polling
  await checkPendingRequests();

  // 4. Get active session
  const session = db.getActiveSession();

  // 5. Query EC2 for running instances
  const ec2Instances = await describeGpuInstances();

  // 6. Sync DB state with EC2 reality
  await syncInstanceState(ec2Instances, session);

  // 7. Health-check running GPUs
  await healthCheckInstances();

  // 8. Reconcile desired vs actual state
  if (session) {
    await reconcileDesiredState(session);
  }
}

// ── Discord polling for pending requests ──

async function checkPendingRequests() {
  const req = db.getPendingRequest();
  if (!req) return;
  if (!req.discord_message_id || !req.discord_channel_id) return;

  const result = await discord.checkReactions(req.discord_channel_id, req.discord_message_id);
  if (result === 'approved') {
    console.log(`[reconciler] Request ${req.id} approved via Discord`);
    const session = db.approveRequest(req.id, 'discord_reaction');
    console.log(`[reconciler] Session ${session.id} created, expires ${session.expires_at}`);
  } else if (result === 'denied') {
    console.log(`[reconciler] Request ${req.id} denied via Discord`);
    db.denyRequest(req.id);
  }
}

// ── EC2 instance discovery ──

async function describeGpuInstances() {
  try {
    const resp = await ec2.send(new DescribeInstancesCommand({
      Filters: [
        { Name: `tag:${TAG_KEY}`, Values: [TAG_VALUE] },
        { Name: 'instance-state-name', Values: ['pending', 'running'] },
      ],
    }));
    const instances = [];
    for (const res of resp.Reservations || []) {
      for (const inst of res.Instances || []) {
        if (['pending', 'running'].includes(inst.State.Name)) {
          instances.push({
            instanceId: inst.InstanceId,
            state: inst.State.Name,
            privateIp: inst.PrivateIpAddress || null,
            launchTime: inst.LaunchTime,
            lifecycle: inst.InstanceLifecycle || 'on-demand',
          });
        }
      }
    }
    return instances;
  } catch (err) {
    console.error('[reconciler] EC2 describe error:', err.message);
    return [];
  }
}

// ── Sync DB with EC2 reality ──

async function syncInstanceState(ec2Instances, session) {
  const dbInstances = db.getGpuInstances(); // launching + ready
  const ec2Ids = new Set(ec2Instances.map(i => i.instanceId));
  const dbIds = new Set(dbInstances.map(i => i.instance_id));

  // Instance in DB but not in EC2 → mark gone
  for (const dbInst of dbInstances) {
    if (!ec2Ids.has(dbInst.instance_id)) {
      console.log(`[reconciler] Instance ${dbInst.instance_id} not in EC2, marking gone`);
      db.markGpuGone(dbInst.instance_id);
      // If this was a launching instance, clear the launch lock
      if (dbInst.status === 'launching') {
        db.setLaunchLock(false);
        db.setLaunchCooldown();
      }
    }
  }

  // Instance in EC2 but not in DB → register it (discovered instance)
  for (const ec2Inst of ec2Instances) {
    if (!dbIds.has(ec2Inst.instanceId)) {
      console.log(`[reconciler] Discovered instance ${ec2Inst.instanceId}, registering`);
      const slot = db.getNextSlot() || 'A';
      db.registerGpuInstance(ec2Inst.instanceId, slot, session?.id || null);
      if (ec2Inst.privateIp) {
        // Try a quick health check
        const healthy = await healthCheck(ec2Inst.privateIp);
        if (healthy) {
          db.markGpuReady(ec2Inst.instanceId, ec2Inst.privateIp);
        }
      }
    }
  }

  // Update private IPs for launching instances that now have one
  for (const ec2Inst of ec2Instances) {
    if (dbIds.has(ec2Inst.instanceId)) {
      const dbInst = dbInstances.find(i => i.instance_id === ec2Inst.instanceId);
      if (dbInst && dbInst.status === 'launching' && !dbInst.private_ip && ec2Inst.privateIp) {
        // IP available but not yet marked ready — store it for next health check
        db.getDb().prepare('UPDATE gpu_instances SET private_ip = ? WHERE instance_id = ?')
          .run(ec2Inst.privateIp, ec2Inst.instanceId);
      }
    }
  }
}

// ── Health checks ──

async function healthCheck(privateIp) {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), HEALTH_CHECK_TIMEOUT_MS);
    const resp = await fetch(`http://${privateIp}:8188/system_stats`, {
      signal: controller.signal,
    });
    clearTimeout(timeout);
    return resp.ok;
  } catch {
    return false;
  }
}

async function healthCheckInstances() {
  const instances = db.getGpuInstances();

  for (const inst of instances) {
    if (!inst.private_ip) continue;

    const healthy = await healthCheck(inst.private_ip);

    if (inst.status === 'launching' && healthy) {
      console.log(`[reconciler] Instance ${inst.instance_id} is healthy, marking ready`);
      db.markGpuReady(inst.instance_id, inst.private_ip);
      db.setLaunchLock(false);
    }

    if (inst.status === 'ready' && !healthy) {
      // Could be temporarily busy (GPU under load). Don't mark gone immediately.
      // Only mark gone if the instance is actually gone from EC2 (handled in syncInstanceState).
      // Log a warning but take no action.
      console.warn(`[reconciler] Health check failed for ready instance ${inst.instance_id} — may be under load`);
    }
  }

  // Check for launch timeout
  const lock = db.getLaunchLock();
  if (lock.inProgress && lock.timestamp) {
    const elapsed = Date.now() - lock.timestamp;
    if (elapsed > LAUNCH_TIMEOUT_MS) {
      console.error('[reconciler] Launch timed out after 5 minutes');
      // Mark any launching instances as gone
      const launching = db.getGpuInstances('launching');
      for (const inst of launching) {
        db.markGpuGone(inst.instance_id);
      }
      db.setLaunchLock(false);
      db.setLaunchCooldown();
    }
  }
}

// ── Desired state reconciliation ──

async function reconcileDesiredState(session) {
  const readyGpus = db.getGpuInstances('ready');
  const launchingGpus = db.getGpuInstances('launching');
  const lock = db.getLaunchLock();

  // Session active + no GPU running + no launch in progress → launch GPU
  if (readyGpus.length === 0 && launchingGpus.length === 0 && !lock.inProgress) {
    if (db.isLaunchCoolingDown()) {
      return; // Respect cooldown
    }
    await launchGpu(session);
  }
}

async function launchGpu(session) {
  const slot = db.getNextSlot();
  if (!slot) {
    console.log('[reconciler] No available GPU slots');
    return;
  }

  console.log(`[reconciler] Launching GPU instance (slot ${slot}) for session ${session.id}`);
  db.setLaunchLock(true);

  try {
    const resp = await ec2.send(new RunInstancesCommand({
      LaunchTemplate: { LaunchTemplateName: LAUNCH_TEMPLATE },
      MinCount: 1,
      MaxCount: 1,
      InstanceMarketOptions: {
        MarketType: 'spot',
        SpotOptions: {
          MaxPrice: SPOT_MAX_PRICE,
          SpotInstanceType: 'one-time',
          InstanceInterruptionBehavior: 'terminate',
        },
      },
      TagSpecifications: [{
        ResourceType: 'instance',
        Tags: [
          { Key: TAG_KEY, Value: TAG_VALUE },
          { Key: 'Slot', Value: slot },
          { Key: 'SessionId', Value: String(session.id) },
        ],
      }],
    }));

    const instanceId = resp.Instances[0].InstanceId;
    console.log(`[reconciler] Launched instance ${instanceId}`);
    db.registerGpuInstance(instanceId, slot, session.id);
  } catch (err) {
    console.error('[reconciler] Launch failed:', err.message);
    db.setLaunchLock(false);
    db.setLaunchCooldown();
  }
}

// ── Public API for CLI force-launch ──

async function forceLaunch() {
  const session = db.getActiveSession();
  if (!session) throw new Error('No active session');
  const lock = db.getLaunchLock();
  if (lock.inProgress) throw new Error('Launch already in progress');
  await launchGpu(session);
}

module.exports = {
  start,
  stop,
  forceLaunch,
  // Exported for testing/CLI
  describeGpuInstances,
  healthCheck,
};
```

---

### Task 5: Create the access request route

**Files:**
- Create: `infra/site/routes/access.js`

- [ ] **Step 1: Create `infra/site/routes/access.js`**

```js
'use strict';

const express = require('express');
const db = require('../lib/db');
const discord = require('../lib/discord');

const router = express.Router();

// In-memory rate limit: 1 request per IP per 5 minutes
const rateLimitMap = new Map();
const RATE_LIMIT_MS = 5 * 60 * 1000;

function isRateLimited(ip) {
  const last = rateLimitMap.get(ip);
  if (last && Date.now() - last < RATE_LIMIT_MS) {
    return true;
  }
  return false;
}

function recordRateLimit(ip) {
  rateLimitMap.set(ip, Date.now());
  // Clean old entries every 100 inserts
  if (rateLimitMap.size > 100) {
    const cutoff = Date.now() - RATE_LIMIT_MS;
    for (const [k, v] of rateLimitMap) {
      if (v < cutoff) rateLimitMap.delete(k);
    }
  }
}

// POST /api/request-access
router.post('/request-access', async (req, res) => {
  const ip = req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.ip;

  // Check rate limit
  if (isRateLimited(ip)) {
    const last = rateLimitMap.get(ip);
    const retryAfter = Math.ceil((RATE_LIMIT_MS - (Date.now() - last)) / 1000);
    return res.status(429).json({
      error: 'Rate limited. Try again later.',
      retry_after_seconds: retryAfter,
    });
  }

  // Check if there's already an active session
  const activeSession = db.getActiveSession();
  if (activeSession) {
    return res.json({
      status: 'already_active',
      session: {
        id: activeSession.id,
        expires_at: activeSession.expires_at,
      },
    });
  }

  // Check if there's already a pending request
  const pendingRequest = db.getPendingRequest();
  if (pendingRequest) {
    return res.json({
      status: 'already_pending',
      request: {
        id: pendingRequest.id,
        expires_at: pendingRequest.expires_at,
      },
    });
  }

  // Create request
  recordRateLimit(ip);
  const request = db.createRequest(ip);

  // Send Discord notification
  const discordResult = await discord.sendAccessRequest(request.id, ip);
  if (discordResult) {
    db.updateRequestDiscord(request.id, discordResult.messageId, discordResult.channelId);
  } else {
    console.error('[access] Discord notification failed for request', request.id);
  }

  res.json({
    status: 'pending',
    request: {
      id: request.id,
      expires_at: request.expires_at,
    },
  });
});

module.exports = router;
```

---

### Task 6: Expand the status route

**Files:**
- Modify: `infra/site/routes/status.js`

Replace the stub with a real status endpoint that returns session state, GPU status, and request state.

- [ ] **Step 1: Replace `infra/site/routes/status.js`**

```js
'use strict';

const express = require('express');
const db = require('../lib/db');

const router = express.Router();

// GET /api/status — strictly read-only, never triggers side effects
router.get('/status', (req, res) => {
  const session = db.getActiveSession();
  const pendingRequest = db.getPendingRequest();
  const latestRequest = db.getLatestRequest();
  const readyGpus = db.getGpuInstances('ready');
  const launchingGpus = db.getGpuInstances('launching');
  const lock = db.getLaunchLock();

  let state, message;

  if (session) {
    const expiresAt = new Date(session.expires_at);
    const remainingMs = expiresAt.getTime() - Date.now();
    const remainingMin = Math.max(0, Math.floor(remainingMs / 60000));
    const remainingHrs = Math.floor(remainingMin / 60);
    const remainingMinPart = remainingMin % 60;
    const countdown = remainingHrs > 0
      ? `${remainingHrs}h ${remainingMinPart}m`
      : `${remainingMin}m`;

    if (readyGpus.length > 0) {
      state = 'ready';
      message = `GPU online — session expires in ${countdown}`;
    } else if (launchingGpus.length > 0 || lock.inProgress) {
      state = 'starting';
      message = `GPU starting up (~4 min) — session expires in ${countdown}`;
    } else if (lock.cooldownUntil && Date.now() < lock.cooldownUntil) {
      // Just failed, in cooldown
      state = 'launch_failed';
      message = 'GPU launch failed — retrying shortly';
    } else {
      // Session active but no GPU and no launch in progress
      // Reconciler will pick this up on next tick
      state = 'starting';
      message = `GPU starting up — session expires in ${countdown}`;
    }

    return res.json({
      state,
      message,
      session: {
        id: session.id,
        expires_at: session.expires_at,
        remaining_seconds: Math.max(0, Math.floor(remainingMs / 1000)),
      },
      gpu: readyGpus.length > 0 ? {
        instance_id: readyGpus[0].instance_id,
        slot: readyGpus[0].slot,
        ready_at: readyGpus[0].ready_at,
      } : null,
    });
  }

  // No active session — check request state
  if (pendingRequest) {
    state = 'requesting';
    message = 'Access requested — waiting for approval...';
    return res.json({
      state,
      message,
      request: {
        id: pendingRequest.id,
        expires_at: pendingRequest.expires_at,
      },
      session: null,
      gpu: null,
    });
  }

  // Check if latest request was expired or denied
  if (latestRequest) {
    if (latestRequest.status === 'expired') {
      state = 'request_expired';
      message = 'Request expired. Try again?';
      return res.json({ state, message, session: null, gpu: null });
    }
    if (latestRequest.status === 'denied') {
      state = 'request_denied';
      message = 'Request denied.';
      return res.json({ state, message, session: null, gpu: null });
    }
  }

  // Check for expired session
  const d = db.getDb();
  const lastSession = d.prepare(`
    SELECT * FROM sessions ORDER BY id DESC LIMIT 1
  `).get();
  if (lastSession && (lastSession.status === 'expired' || lastSession.status === 'revoked')) {
    state = 'session_expired';
    message = 'Session expired. Request new access.';
    return res.json({ state, message, session: null, gpu: null });
  }

  // Default: browse mode
  state = 'browse';
  message = 'GPU offline — browse models below';
  res.json({ state, message, session: null, gpu: null });
});

module.exports = router;
```

---

### Task 7: Create GPU proxy routes

**Files:**
- Create: `infra/site/routes/gpu.js`

This provides HTTP proxy routes for ComfyUI API calls. WebSocket proxying is handled separately in server.js.

- [ ] **Step 1: Create `infra/site/routes/gpu.js`**

```js
'use strict';

const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');
const db = require('../lib/db');

const router = express.Router();

// In-memory rate limit: 1 prompt per client per 10 seconds
const promptRateLimitMap = new Map();
const PROMPT_RATE_LIMIT_MS = 10 * 1000;

function isPromptRateLimited(clientId) {
  const last = promptRateLimitMap.get(clientId);
  if (last && Date.now() - last < PROMPT_RATE_LIMIT_MS) {
    return true;
  }
  return false;
}

function recordPromptRateLimit(clientId) {
  promptRateLimitMap.set(clientId, Date.now());
  if (promptRateLimitMap.size > 200) {
    const cutoff = Date.now() - PROMPT_RATE_LIMIT_MS;
    for (const [k, v] of promptRateLimitMap) {
      if (v < cutoff) promptRateLimitMap.delete(k);
    }
  }
}

// Helper: get GPU IP for this client, or the first ready GPU
function getGpuIpForClient(clientId) {
  // Try client assignment first
  if (clientId) {
    const assignment = db.getClientAssignment(clientId);
    if (assignment && assignment.private_ip) {
      db.touchClient(clientId);
      return assignment.private_ip;
    }
  }

  // Fall back to first ready GPU
  const gpu = db.getReadyGpu();
  if (!gpu || !gpu.private_ip) return null;

  // Auto-assign if client_id provided
  if (clientId) {
    db.assignClient(clientId, gpu.instance_id);
  }

  return gpu.private_ip;
}

// Helper: check session and GPU, return error response or null
function checkAccess(res) {
  const session = db.getActiveSession();
  if (!session) {
    return res.status(503).json({ status: 'no_session', session_active: false });
  }

  const readyGpus = db.getGpuInstances('ready');
  const launchingGpus = db.getGpuInstances('launching');

  if (readyGpus.length === 0) {
    if (launchingGpus.length > 0) {
      return res.status(503).json({
        status: 'gpu_starting',
        session_active: true,
        started_at: launchingGpus[0].launched_at,
      });
    }
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  return null; // Access OK
}

// POST /api/gpu/prompt
router.post('/prompt', async (req, res) => {
  const denied = checkAccess(res);
  if (denied) return;

  const clientId = req.body.client_id;
  if (!clientId) {
    return res.status(400).json({ error: 'client_id required' });
  }

  // Rate limit
  if (isPromptRateLimited(clientId)) {
    const last = promptRateLimitMap.get(clientId);
    const retryAfter = Math.ceil((PROMPT_RATE_LIMIT_MS - (Date.now() - last)) / 1000);
    return res.status(429).json({
      error: 'Rate limited. Wait before submitting another prompt.',
      retry_after_seconds: retryAfter,
    });
  }

  const gpuIp = getGpuIpForClient(clientId);
  if (!gpuIp) {
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  recordPromptRateLimit(clientId);

  // Forward to ComfyUI
  try {
    const gpuResp = await fetch(`http://${gpuIp}:8188/api/prompt`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req.body),
    });

    const data = await gpuResp.json();

    // Record prompt in DB
    if (data.prompt_id) {
      const gpu = db.getReadyGpu();
      if (gpu) {
        db.recordPrompt(data.prompt_id, clientId, gpu.instance_id);
      }
    }

    res.status(gpuResp.status).json(data);
  } catch (err) {
    console.error('[gpu-proxy] Prompt forward error:', err.message);
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});

// GET /api/gpu/queue
router.get('/queue', async (req, res) => {
  const denied = checkAccess(res);
  if (denied) return;

  const clientId = req.query.clientId;
  const gpuIp = getGpuIpForClient(clientId);
  if (!gpuIp) {
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  try {
    const gpuResp = await fetch(`http://${gpuIp}:8188/api/queue`);
    const data = await gpuResp.json();
    res.json(data);
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});

// GET /api/gpu/history/:promptId
router.get('/history/:promptId', async (req, res) => {
  const promptId = req.params.promptId;

  // Look up which GPU has this prompt
  const promptInfo = db.getPromptGpu(promptId);
  let gpuIp;

  if (promptInfo && promptInfo.private_ip) {
    gpuIp = promptInfo.private_ip;
  } else {
    // Fall back to first ready GPU
    const gpu = db.getReadyGpu();
    gpuIp = gpu?.private_ip;
  }

  if (!gpuIp) {
    return res.status(503).json({ status: 'gpu_offline', session_active: !!db.getActiveSession() });
  }

  try {
    const gpuResp = await fetch(`http://${gpuIp}:8188/api/history/${promptId}`);
    const data = await gpuResp.json();
    res.json(data);
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});

// POST /api/gpu/metadata
router.post('/metadata', async (req, res) => {
  const denied = checkAccess(res);
  if (denied) return;

  const clientId = req.body.client_id;
  const gpuIp = getGpuIpForClient(clientId);
  if (!gpuIp) {
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  try {
    const gpuResp = await fetch(`http://${gpuIp}:8188/fabricate/metadata`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req.body),
    });
    const data = await gpuResp.json();
    res.status(gpuResp.status).json(data);
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});

// GET /api/gpu/system_stats
router.get('/system_stats', async (req, res) => {
  const gpu = db.getReadyGpu();
  if (!gpu || !gpu.private_ip) {
    return res.status(503).json({ status: 'gpu_offline', session_active: !!db.getActiveSession() });
  }

  try {
    const gpuResp = await fetch(`http://${gpu.private_ip}:8188/system_stats`);
    const data = await gpuResp.json();
    res.json(data);
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});

// POST /api/gpu/interrupt
router.post('/interrupt', async (req, res) => {
  const denied = checkAccess(res);
  if (denied) return;

  const clientId = req.body.client_id;
  const gpuIp = getGpuIpForClient(clientId);
  if (!gpuIp) {
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  try {
    const gpuResp = await fetch(`http://${gpuIp}:8188/api/interrupt`, { method: 'POST' });
    res.status(gpuResp.status).json({ ok: true });
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});

// POST /api/gpu/queue (delete items)
router.post('/queue', async (req, res) => {
  const denied = checkAccess(res);
  if (denied) return;

  const clientId = req.body.client_id;
  const gpuIp = getGpuIpForClient(clientId);
  if (!gpuIp) {
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  try {
    const gpuResp = await fetch(`http://${gpuIp}:8188/api/queue`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req.body),
    });
    const data = await gpuResp.json();
    res.status(gpuResp.status).json(data);
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});

// GET /api/gpu/view — proxy file downloads from GPU output dir
router.get('/view', async (req, res) => {
  const gpu = db.getReadyGpu();
  if (!gpu || !gpu.private_ip) {
    return res.status(503).json({ status: 'gpu_offline' });
  }

  const qs = new URLSearchParams(req.query).toString();
  try {
    const gpuResp = await fetch(`http://${gpu.private_ip}:8188/api/view?${qs}`);
    if (!gpuResp.ok) {
      return res.status(gpuResp.status).end();
    }
    // Pipe response headers and body
    res.set('Content-Type', gpuResp.headers.get('content-type') || 'application/octet-stream');
    const arrayBuffer = await gpuResp.arrayBuffer();
    res.send(Buffer.from(arrayBuffer));
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});

module.exports = router;
```

---

### Task 8: Update server.js with reconciler, routes, and WebSocket proxy

**Files:**
- Modify: `infra/site/server.js`

This is the most critical modification. The server now initializes the DB, starts the reconciler, mounts new routes, and handles WebSocket upgrade for the GPU proxy.

- [ ] **Step 1: Replace `infra/site/server.js`**

```js
'use strict';

const express = require('express');
const http = require('http');
const path = require('path');
const { WebSocketServer, WebSocket } = require('ws');

const db = require('./lib/db');
const reconciler = require('./lib/reconciler');
const s3Routes = require('./routes/s3');
const statusRoutes = require('./routes/status');
const accessRoutes = require('./routes/access');
const gpuRoutes = require('./routes/gpu');

const PORT = process.env.PORT || 3100;
const PUBLIC_DIR = path.join(__dirname, 'public');

const app = express();
app.use(express.json());

// Trust nginx proxy for X-Forwarded-For
app.set('trust proxy', 'loopback');

// API routes (before static files)
app.use('/api/s3', s3Routes);
app.use('/api', statusRoutes);
app.use('/api', accessRoutes);
app.use('/api/gpu', gpuRoutes);

// Health endpoint
app.get('/healthz', (req, res) => {
  res.json({ ok: true, uptime: process.uptime() });
});

// API 404 — must come BEFORE static/SPA fallback
app.use('/api', (req, res) => {
  res.status(404).json({ error: 'Not found' });
});

// Static files (SPA, manifest, descriptions)
app.use(express.static(PUBLIC_DIR));

// SPA fallback — serve index.html for any unmatched non-API route
app.get('*', (req, res) => {
  res.sendFile(path.join(PUBLIC_DIR, 'index.html'));
});

// ── HTTP Server + WebSocket Proxy ──

const server = http.createServer(app);
const wss = new WebSocketServer({ noServer: true });

// Handle WebSocket upgrade requests
server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  // Only handle /api/gpu/ws
  if (url.pathname !== '/api/gpu/ws') {
    socket.destroy();
    return;
  }

  const clientId = url.searchParams.get('clientId');

  // Find GPU for this client
  let gpuIp = null;
  if (clientId) {
    const assignment = db.getClientAssignment(clientId);
    if (assignment && assignment.private_ip) {
      gpuIp = assignment.private_ip;
      db.touchClient(clientId);
    }
  }

  // Fall back to first ready GPU
  if (!gpuIp) {
    const gpu = db.getReadyGpu();
    if (gpu && gpu.private_ip) {
      gpuIp = gpu.private_ip;
      if (clientId) {
        db.assignClient(clientId, gpu.instance_id);
      }
    }
  }

  if (!gpuIp) {
    // No GPU available — reject WebSocket
    socket.write('HTTP/1.1 503 Service Unavailable\r\n\r\n');
    socket.destroy();
    return;
  }

  // Open upstream WebSocket to GPU
  const upstreamUrl = `ws://${gpuIp}:8188/ws?clientId=${clientId || 'anonymous'}`;

  wss.handleUpgrade(req, socket, head, (clientWs) => {
    const upstream = new WebSocket(upstreamUrl);

    upstream.on('open', () => {
      // Relay messages: GPU → Client
      upstream.on('message', (data, isBinary) => {
        if (clientWs.readyState === WebSocket.OPEN) {
          clientWs.send(data, { binary: isBinary });
        }
      });

      // Relay messages: Client → GPU
      clientWs.on('message', (data, isBinary) => {
        if (upstream.readyState === WebSocket.OPEN) {
          upstream.send(data, { binary: isBinary });
        }
      });
    });

    upstream.on('error', (err) => {
      console.error(`[ws-proxy] Upstream error for client ${clientId}:`, err.message);
      if (clientWs.readyState === WebSocket.OPEN) {
        clientWs.close(1011, 'GPU connection error');
      }
    });

    upstream.on('close', () => {
      if (clientWs.readyState === WebSocket.OPEN) {
        clientWs.close(1000, 'GPU disconnected');
      }
    });

    clientWs.on('close', () => {
      if (upstream.readyState === WebSocket.OPEN) {
        upstream.close();
      }
    });

    clientWs.on('error', (err) => {
      console.error(`[ws-proxy] Client error for ${clientId}:`, err.message);
      if (upstream.readyState === WebSocket.OPEN) {
        upstream.close();
      }
    });
  });
});

// ── Start ──

// Initialize DB (creates tables if needed)
db.getDb();
console.log('[server] SQLite database initialized');

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Fabricate server listening on 127.0.0.1:${PORT}`);

  // Start reconciler loop
  reconciler.start();
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('[server] SIGTERM received, shutting down...');
  reconciler.stop();
  server.close(() => {
    process.exit(0);
  });
});

process.on('SIGINT', () => {
  console.log('[server] SIGINT received, shutting down...');
  reconciler.stop();
  server.close(() => {
    process.exit(0);
  });
});
```

---

### Task 9: Update the frontend for the new state machine

**Files:**
- Modify: `infra/frontend/index.html`

The frontend needs major changes: (1) new states in `checkConnection()`, (2) Request Access button, (3) session countdown display, (4) route all GPU API calls through `/api/gpu/...`, (5) WebSocket URL changed to `/api/gpu/ws`.

This is the largest single change. The key areas to modify are:

1. The route helpers (switch from direct ComfyUI URLs to `/api/gpu/...` proxied routes)
2. `checkConnection()` (the full state machine)
3. `connectWebSocket()` (new URL)
4. `init()` (enable features based on state, not IS_SITE_BOX)
5. Add Request Access button to the header
6. Add session countdown display

- [ ] **Step 1: Update route helpers (around line 1580)**

Replace the route helper section. The old `IS_SITE_BOX` browse-only flag is replaced by a state machine driven by `/api/status`.

Find and replace lines 1580-1626 with:

```js
// Mode-aware API routing.
// On site box: S3 via /api/s3/..., GPU via /api/gpu/... (proxied by Express)
// GPU legacy mode (direct trycloudflare URL): everything via ComfyUI /fabricate/api/... and /api/...
const ORIGIN = window.location.origin;
const IS_SITE_BOX = window.location.hostname === 'fabricate.prismata.live';

// Application state — driven by /api/status polling
let appState = 'browse'; // browse, requesting, request_expired, request_denied, starting, ready, launch_failed, session_expired
let gpuAvailable = false;
let sessionInfo = null; // { id, expires_at, remaining_seconds }
let countdownInterval = null;

// Route helpers — S3 routes (same as before)
function s3CheckUrl(unit, skin) {
  return IS_SITE_BOX
    ? `${ORIGIN}/api/s3/check/${encodeURIComponent(unit)}/${encodeURIComponent(skin)}`
    : `${ORIGIN}/fabricate/api/s3-check/${encodeURIComponent(unit)}/${encodeURIComponent(skin)}`;
}
function s3ListUrl() {
  return IS_SITE_BOX ? `${ORIGIN}/api/s3/list` : `${ORIGIN}/fabricate/api/s3-list`;
}
function s3FavoritesUrl() {
  return IS_SITE_BOX ? `${ORIGIN}/api/s3/favorites` : `${ORIGIN}/fabricate/api/favorites`;
}
function s3FavoriteUrl() {
  return IS_SITE_BOX ? `${ORIGIN}/api/s3/favorite` : `${ORIGIN}/fabricate/api/favorite`;
}
function s3UnfavoriteUrl() {
  return IS_SITE_BOX ? `${ORIGIN}/api/s3/unfavorite` : `${ORIGIN}/fabricate/api/unfavorite`;
}
function s3RejectUrl() {
  return IS_SITE_BOX ? `${ORIGIN}/api/s3/reject` : `${ORIGIN}/fabricate/api/reject`;
}
async function s3ModelUrl(unit, skin, fmt, filename) {
  if (IS_SITE_BOX) {
    const params = new URLSearchParams({ format: fmt || 'glb' });
    if (filename) params.set('filename', filename);
    const resp = await fetch(`${ORIGIN}/api/s3/model-url/${encodeURIComponent(unit)}/${encodeURIComponent(skin)}?${params}`);
    if (!resp.ok) return null;
    const data = await resp.json();
    return data.url;
  }
  const params = new URLSearchParams({ format: fmt || 'glb' });
  if (filename) params.set('filename', filename);
  return `${ORIGIN}/fabricate/api/s3-model/${encodeURIComponent(unit)}/${encodeURIComponent(skin)}?${params}`;
}

// GPU route helpers — site box proxies through /api/gpu/..., legacy mode uses direct ComfyUI URLs
function gpuUrl(path) {
  if (IS_SITE_BOX) {
    // Map legacy ComfyUI paths to proxy routes
    if (path === '/api/prompt') return `${ORIGIN}/api/gpu/prompt`;
    if (path === '/api/queue') return `${ORIGIN}/api/gpu/queue`;
    if (path.startsWith('/api/history/')) return `${ORIGIN}/api/gpu/history/${path.slice('/api/history/'.length)}`;
    if (path === '/api/interrupt') return `${ORIGIN}/api/gpu/interrupt`;
    if (path === '/api/system_stats') return `${ORIGIN}/api/gpu/system_stats`;
    if (path === '/api/view') return `${ORIGIN}/api/gpu/view`;
    return `${ORIGIN}/api/gpu${path}`;
  }
  return `${ORIGIN}${path}`;
}
function metadataUrl() {
  return IS_SITE_BOX ? `${ORIGIN}/api/gpu/metadata` : `${ORIGIN}/fabricate/metadata`;
}
```

- [ ] **Step 2: Add Request Access button and session countdown to header HTML (around line 1213)**

Find the header-right section and add the new UI elements. Replace the existing `<div class="header-right">` block:

```html
      <div class="header-right">
        <span><span class="status-dot" id="connDot"></span><span id="connText">Checking...</span></span>
        <span id="sessionCountdown" style="display:none; font-family:var(--mono); font-size:12px; color:var(--accent);"></span>
        <span id="queueStatus"></span>
        <button class="btn-action" id="btnRequestAccess" style="display:none; background:var(--accent); color:var(--bg-base); font-weight:600; border:none; padding:6px 14px; cursor:pointer; border-radius:3px;">Request Access</button>
      </div>
```

- [ ] **Step 3: Update `connectWebSocket()` (around line 1689)**

Replace the function:

```js
function connectWebSocket() {
  if (!IS_SITE_BOX && !gpuAvailable) return; // Legacy mode: no GPU
  if (IS_SITE_BOX && appState !== 'ready') return; // Site box: only connect when GPU ready

  const wsProto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  let wsUrl;
  if (IS_SITE_BOX) {
    wsUrl = `${wsProto}//${location.host}/api/gpu/ws?clientId=${wsClientId}`;
  } else {
    wsUrl = `${wsProto}//${location.host}/ws?clientId=${wsClientId}`;
  }

  try {
    ws = new WebSocket(wsUrl);
    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data);
        handleWsMessage(msg);
      } catch {}
    };
    ws.onclose = () => {
      ws = null;
      // Reconnect after 5s if still in ready state
      setTimeout(() => {
        if (IS_SITE_BOX && appState === 'ready') connectWebSocket();
        if (!IS_SITE_BOX && gpuAvailable) connectWebSocket();
      }, 5000);
    };
    ws.onerror = () => {};
  } catch {}
}
```

- [ ] **Step 4: Update `checkConnection()` (around line 1839)**

Replace with the full state machine:

```js
async function checkConnection() {
  if (IS_SITE_BOX) {
    try {
      const resp = await fetch(`${ORIGIN}/api/status`, { signal: AbortSignal.timeout(5000) });
      if (!resp.ok) throw new Error('status fetch failed');
      const status = await resp.json();
      const prevState = appState;
      appState = status.state;
      sessionInfo = status.session;

      // Update connection indicator
      if (appState === 'ready') {
        connDot.classList.add('connected');
        connText.textContent = status.message || 'GPU Online';
        gpuAvailable = true;
      } else {
        connDot.classList.remove('connected');
        connText.textContent = status.message || 'GPU Offline';
        gpuAvailable = false;
      }

      // Update session countdown
      const countdownEl = $('sessionCountdown');
      if (sessionInfo && sessionInfo.remaining_seconds > 0) {
        countdownEl.style.display = '';
        updateCountdown(sessionInfo.remaining_seconds);
      } else {
        countdownEl.style.display = 'none';
        if (countdownInterval) { clearInterval(countdownInterval); countdownInterval = null; }
      }

      // Update Request Access button visibility
      const btnRequest = $('btnRequestAccess');
      if (['browse', 'request_expired', 'request_denied', 'session_expired'].includes(appState)) {
        btnRequest.style.display = '';
        btnRequest.textContent = appState === 'browse' ? 'Request Access' : 'Request Access Again';
      } else {
        btnRequest.style.display = 'none';
      }

      // Update generation controls
      if (appState === 'ready') {
        $('btnGenerate').disabled = false;
        $('btnGenerate').title = '';
        $('btnKill').disabled = false;
        $('btnClearQueue').disabled = false;
      } else {
        if (!currentPromptId) {
          $('btnGenerate').disabled = true;
          $('btnGenerate').title = appState === 'starting' ? 'GPU starting up...' : 'GPU not available';
        }
        if (appState !== 'ready') {
          $('btnKill').disabled = true;
          $('btnClearQueue').disabled = true;
        }
      }

      // Queue status (only when GPU is ready)
      if (appState === 'ready') {
        try {
          const qResp = await fetch(gpuUrl('/api/queue'));
          if (qResp.ok) {
            const q = await qResp.json();
            const running = q.queue_running || [];
            const pending = q.queue_pending || [];
            const totalRunning = running.length;
            const totalPending = pending.length;

            let myPosition = -1;
            for (let i = 0; i < pending.length; i++) {
              const extraData = pending[i][3] || {};
              if (extraData.client_id === wsClientId) {
                myPosition = totalRunning + i + 1;
                break;
              }
            }
            const myJobRunning = running.some(j => (j[3] || {}).client_id === wsClientId);

            let statusStr = '';
            if (totalRunning > 0 || totalPending > 0) {
              statusStr = `Queue: ${totalRunning} running, ${totalPending} pending`;
              if (myJobRunning) {
                statusStr += ' | Your job is running';
              } else if (myPosition > 0) {
                const estMinutes = myPosition * 2;
                statusStr += ` | Your job: #${myPosition} (~${estMinutes}m)`;
              }
            }
            queueStatus.textContent = statusStr;
            updateKillButtonState(running, myJobRunning, totalRunning);
          }
        } catch {}
      } else {
        queueStatus.textContent = '';
      }

      // State transitions — connect/disconnect WS
      if (prevState !== 'ready' && appState === 'ready') {
        // GPU just became ready — connect WS and try reconnecting to jobs
        connectWebSocket();
        reconnectToRunningJobs();
        log('GPU online — ready to fabricate', 'success');
      }
      if (prevState === 'ready' && appState !== 'ready') {
        // GPU went away
        if (ws) { ws.close(); ws = null; }
        log('GPU offline', 'error');
      }
    } catch {
      connDot.classList.remove('connected');
      connText.textContent = 'Offline';
      queueStatus.textContent = '';
    }
    return;
  }

  // GPU legacy mode: existing checkConnection behavior unchanged
  try {
    const resp = await fetch(gpuUrl('/api/system_stats'), { signal: AbortSignal.timeout(5000) });
    if (resp.ok) {
      connDot.classList.add('connected');
      connText.textContent = 'ComfyUI Online';
      gpuAvailable = true;
      const qResp = await fetch(gpuUrl('/api/queue'));
      if (!qResp.ok) return;
      const q = await qResp.json();
      const running = q.queue_running || [];
      const pending = q.queue_pending || [];
      const totalRunning = running.length;
      const totalPending = pending.length;

      let myPosition = -1;
      for (let i = 0; i < pending.length; i++) {
        const extraData = pending[i][3] || {};
        if (extraData.client_id === wsClientId) {
          myPosition = totalRunning + i + 1;
          break;
        }
      }
      const myJobRunning = running.some(j => (j[3] || {}).client_id === wsClientId);

      let statusStr = '';
      if (totalRunning > 0 || totalPending > 0) {
        statusStr = `Queue: ${totalRunning} running, ${totalPending} pending`;
        if (myJobRunning) {
          statusStr += ' | Your job is running';
        } else if (myPosition > 0) {
          const estMinutes = myPosition * 2;
          statusStr += ` | Your job: #${myPosition} (~${estMinutes}m)`;
        }
      }
      queueStatus.textContent = statusStr;
      updateKillButtonState(running, myJobRunning, totalRunning);
    }
  } catch {
    if (!currentPromptId) {
      connDot.classList.remove('connected');
      connText.textContent = 'Offline';
      gpuAvailable = false;
      queueStatus.textContent = '';
    }
  }
}

function updateKillButtonState(running, myJobRunning, totalRunning) {
  const killBtn = $('btnKill');
  if (myJobRunning) {
    killBtn.disabled = false;
    killBtn.title = 'Interrupt your running job';
  } else if (totalRunning > 0) {
    killBtn.disabled = true;
    killBtn.title = "Another user's job is running";
  } else {
    killBtn.disabled = true;
    killBtn.title = 'No running job';
  }
}

function updateCountdown(remainingSeconds) {
  const countdownEl = $('sessionCountdown');
  let remaining = remainingSeconds;

  if (countdownInterval) clearInterval(countdownInterval);

  function render() {
    if (remaining <= 0) {
      countdownEl.textContent = 'Session expired';
      if (countdownInterval) { clearInterval(countdownInterval); countdownInterval = null; }
      return;
    }
    const h = Math.floor(remaining / 3600);
    const m = Math.floor((remaining % 3600) / 60);
    const s = remaining % 60;
    countdownEl.textContent = `Session: ${h}h ${String(m).padStart(2,'0')}m ${String(s).padStart(2,'0')}s`;
    remaining--;
  }

  render();
  countdownInterval = setInterval(render, 1000);
}
```

- [ ] **Step 5: Update `init()` (around line 1823)**

Replace with:

```js
async function init() {
  await checkConnection();
  await loadManifest();
  bindEvents();

  // Initial UI state based on appState
  if (!gpuAvailable) {
    $('btnGenerate').disabled = true;
    $('btnGenerate').title = 'GPU not available';
    $('btnKill').disabled = true;
    $('btnClearQueue').disabled = true;
  }

  connectWebSocket();
  if (gpuAvailable) {
    await reconnectToRunningJobs();
  }

  // Adaptive polling interval
  setInterval(() => {
    checkConnection();
  }, getPollingInterval());

  // Re-evaluate polling interval every 30s
  let currentPollTimer = null;
  function startAdaptivePolling() {
    if (currentPollTimer) clearInterval(currentPollTimer);
    currentPollTimer = setInterval(checkConnection, getPollingInterval());
  }
  setInterval(startAdaptivePolling, 30000);

  // Request Access button handler
  $('btnRequestAccess').addEventListener('click', requestAccess);
}

function getPollingInterval() {
  switch (appState) {
    case 'requesting': return 5000;
    case 'starting': return 5000;
    case 'ready': return 15000;
    default: return 30000; // browse, session_expired, etc.
  }
}

async function requestAccess() {
  const btn = $('btnRequestAccess');
  btn.disabled = true;
  btn.textContent = 'Requesting...';

  try {
    const resp = await fetch(`${ORIGIN}/api/request-access`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
    });
    const data = await resp.json();

    if (resp.status === 429) {
      log(`Rate limited — try again in ${data.retry_after_seconds}s`, 'error');
      btn.disabled = false;
      btn.textContent = 'Request Access';
      return;
    }

    if (data.status === 'pending' || data.status === 'already_pending') {
      log('Access request sent — waiting for approval...', 'success');
      appState = 'requesting';
      btn.style.display = 'none';
      connText.textContent = 'Access requested — waiting for approval...';
    } else if (data.status === 'already_active') {
      log('Session already active!', 'success');
      await checkConnection();
    }
  } catch (err) {
    log('Failed to send request: ' + err.message, 'error');
    btn.disabled = false;
    btn.textContent = 'Request Access';
  }
}
```

- [ ] **Step 6: Update `reconnectToRunningJobs()` (around line 1751)**

Change the guard:

```js
async function reconnectToRunningJobs() {
  if (IS_SITE_BOX && appState !== 'ready') return;
  if (!IS_SITE_BOX && !gpuAvailable) return;
  // ... rest of function unchanged
```

- [ ] **Step 7: Update `startGeneration()` guard (around line 2204)**

Replace the IS_SITE_BOX guard:

```js
  if (!gpuAvailable) {
    log('GPU is not available', 'error');
    return;
  }
```

- [ ] **Step 8: Update Kill button handler (around line 2103)**

Replace `if (IS_SITE_BOX) return;` with `if (!gpuAvailable) return;`

Also pass `client_id` in the interrupt request body when on site box:

```js
  $('btnKill').addEventListener('click', async () => {
    if (!gpuAvailable) return;
    try {
      const runningClientId = await getRunningJobClientId();
      if (runningClientId && runningClientId !== wsClientId) {
        log('Cannot kill — another user\'s job is running', 'error');
        return;
      }
      if (IS_SITE_BOX) {
        await fetch(gpuUrl('/api/interrupt'), {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ client_id: wsClientId }),
        });
      } else {
        await fetch(gpuUrl('/api/interrupt'), { method: 'POST' });
      }
      log('Interrupted running job', 'error');
      setGenerating(false);
      setStatus('Interrupted', 'error');
      await checkConnection();
    } catch (e) { log('Kill failed: ' + e.message, 'error'); }
  });
```

- [ ] **Step 9: Update Clear Queue handler (around line 2120)**

Replace `if (IS_SITE_BOX) return;` with `if (!gpuAvailable) return;`

When on site box, pass `client_id` in the delete request body:

```js
  $('btnClearQueue').addEventListener('click', async () => {
    if (!gpuAvailable) return;
    try {
      const resp = await fetch(gpuUrl('/api/queue'));
      if (!resp.ok) { log('Clear failed: could not fetch queue', 'error'); return; }
      const q = await resp.json();
      const pending = q.queue_pending || [];
      const myPendingIds = pending
        .filter(job => (job[3] || {}).client_id === wsClientId)
        .map(job => job[1]);
      if (myPendingIds.length === 0) { log('No pending jobs to clear'); return; }

      if (IS_SITE_BOX) {
        await fetch(gpuUrl('/api/queue'), {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ delete: myPendingIds, client_id: wsClientId }),
        });
      } else {
        await fetch(gpuUrl('/api/queue'), {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ delete: myPendingIds }),
        });
      }
      log(`Cleared ${myPendingIds.length} pending job(s)`);
      await checkConnection();
    } catch (e) { log('Clear failed: ' + e.message, 'error'); }
  });
```

- [ ] **Step 10: Update `loadManifest()` guard (around line 1923)**

Change `if (!IS_SITE_BOX)` to `if (!IS_SITE_BOX || gpuAvailable)` for the GPU-specific paths.

---

### Task 10: Update GPU instance scripts

**Files:**
- Modify: `infra/ec2/user-data.sh`
- Modify: `infra/ec2/idle-watchdog.sh`

- [ ] **Step 1: Update `infra/ec2/user-data.sh`**

Remove the entire cloudflared section (lines 62-85 in original). Keep everything else. The new file:

```bash
#!/bin/bash
# EC2 instance boot script. Runs as root via user-data.
# ComfyUI, monitoring scripts, and systemd services are
# pre-installed in the AMI. This script just starts them and injects
# runtime config (webhook URL).

set -euo pipefail
exec > /var/log/user-data.log 2>&1
echo "=== Prismata 3D Gen — Instance Boot $(date) ==="

REGION="us-east-1"
export AWS_DEFAULT_REGION="$REGION"

# Get instance ID
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "http://169.254.169.254/latest/meta-data/instance-id")
echo "Instance ID: $INSTANCE_ID"

# Get Discord webhook URL from SSM and inject into monitoring services
DISCORD_WEBHOOK_URL=$(aws ssm get-parameter \
    --name /prismata-3d/discord-webhook-url \
    --region "$REGION" --with-decryption \
    --query "Parameter.Value" --output text 2>/dev/null || echo "")

# Update the webhook URL in baked service files via drop-in overrides
mkdir -p /etc/systemd/system/idle-watchdog.service.d
cat > /etc/systemd/system/idle-watchdog.service.d/webhook.conf <<EOF
[Service]
Environment=DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL
EOF

mkdir -p /etc/systemd/system/spot-monitor.service.d
cat > /etc/systemd/system/spot-monitor.service.d/webhook.conf <<EOF
[Service]
Environment=DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL
EOF

# 1. Start ComfyUI
echo "--- Starting ComfyUI ---"
systemctl daemon-reload
systemctl start comfyui

# Wait for ComfyUI to be ready
echo "Waiting for ComfyUI to be ready..."
for i in $(seq 1 60); do
    if curl -sf http://localhost:8188/system_stats > /dev/null 2>&1; then
        echo "ComfyUI ready after ${i}s"
        break
    fi
    sleep 2
done

# 1b. Warmup: pre-load v2.0 shape model into GPU VRAM
# Runs before output-sync starts so warmup output won't upload to S3
echo "--- Warming up GPU (shape model pre-load) ---"
# Download latest warmup script from S3 (works even before AMI rebuild)
aws s3 cp s3://prismata-3d-models/scripts/warmup.sh /opt/prismata-3d/warmup.sh --region "$REGION" 2>/dev/null || true
chmod +x /opt/prismata-3d/warmup.sh 2>/dev/null || true
bash /opt/prismata-3d/warmup.sh &
WARMUP_PID=$!

# 2. Wait for warmup to finish before starting output-sync (prevents warmup files uploading to S3)
if [ -n "${WARMUP_PID:-}" ]; then
    echo "Waiting for GPU warmup to complete..."
    wait "$WARMUP_PID" || echo "WARNING: Warmup exited with non-zero status (non-fatal)"
fi

# 3. Start monitoring and output sync (services are baked into AMI, just start them)
echo "--- Starting monitoring ---"
systemctl start idle-watchdog
systemctl start spot-monitor
systemctl start output-sync

echo "=== Boot complete $(date) ==="
```

- [ ] **Step 2: Update `infra/ec2/idle-watchdog.sh`**

Change `IDLE_THRESHOLD` from 600 to 1200 (20 minutes). Remove the Discord notification on shutdown since the site box detects termination via EC2 API.

```bash
#!/bin/bash
# Monitors activity and shuts down after 20 minutes of inactivity.
# Runs as a systemd service.

IDLE_THRESHOLD=1200  # 20 minutes
LAST_ACTIVITY_FILE="/tmp/last_activity"

date +%s > "$LAST_ACTIVITY_FILE"

log() { echo "[watchdog $(date +%H:%M:%S)] $*"; }

check_activity() {
    # GPU processes running (= generation in progress)
    if nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -q .; then
        date +%s > "$LAST_ACTIVITY_FILE"
        return 0
    fi
    return 1
}

while true; do
    sleep 60
    check_activity || true

    last=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    idle=$((now - last))

    if [ "$idle" -ge "$IDLE_THRESHOLD" ]; then
        log "Idle for ${idle}s (threshold: ${IDLE_THRESHOLD}s). Shutting down..."
        sleep 60  # Grace period

        # Re-check after grace period
        check_activity && { log "Activity resumed during grace period."; continue; }

        # Sync outputs to S3
        aws s3 sync /opt/prismata-3d/output/ "s3://prismata-3d-models/models/" --region us-east-1 2>/dev/null || true

        log "Shutting down now."
        sudo shutdown -h now
        exit 0
    fi
    log "Idle: ${idle}s / ${IDLE_THRESHOLD}s"
done
```

---

### Task 11: Create CLI admin tool

**Files:**
- Create: `infra/cli.js`

- [ ] **Step 1: Create `infra/cli.js`**

```js
#!/usr/bin/env node
'use strict';

/**
 * CLI admin tool for the Fabrication Terminal.
 * Talks to the site box API over HTTPS.
 *
 * Usage:
 *   node infra/cli.js create-session --hours 24
 *   node infra/cli.js status
 *   node infra/cli.js revoke
 *   node infra/cli.js launch-gpu
 */

const API_BASE = 'https://fabricate.prismata.live';

const [,, command, ...args] = process.argv;

async function main() {
  switch (command) {
    case 'create-session': return await createSession();
    case 'status': return await getStatus();
    case 'revoke': return await revokeSession();
    case 'launch-gpu': return await launchGpu();
    default:
      console.log('Usage: node infra/cli.js <command>');
      console.log('Commands:');
      console.log('  create-session --hours <N>  Create a session directly (bypasses Discord)');
      console.log('  status                      Show current status');
      console.log('  revoke                      Revoke active session');
      console.log('  launch-gpu                  Force-launch a GPU');
      process.exit(1);
  }
}

async function createSession() {
  let hours = 24;
  const hoursIdx = args.indexOf('--hours');
  if (hoursIdx !== -1 && args[hoursIdx + 1]) {
    hours = parseInt(args[hoursIdx + 1]);
  }

  const resp = await fetch(`${API_BASE}/api/admin/create-session`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Admin-Key': getAdminKey(),
    },
    body: JSON.stringify({ hours }),
  });
  const data = await resp.json();
  console.log(JSON.stringify(data, null, 2));
}

async function getStatus() {
  const resp = await fetch(`${API_BASE}/api/status`);
  const data = await resp.json();
  console.log(JSON.stringify(data, null, 2));
}

async function revokeSession() {
  const resp = await fetch(`${API_BASE}/api/admin/revoke-session`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Admin-Key': getAdminKey(),
    },
  });
  const data = await resp.json();
  console.log(JSON.stringify(data, null, 2));
}

async function launchGpu() {
  const resp = await fetch(`${API_BASE}/api/admin/launch-gpu`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Admin-Key': getAdminKey(),
    },
  });
  const data = await resp.json();
  console.log(JSON.stringify(data, null, 2));
}

function getAdminKey() {
  const key = process.env.FABRICATE_ADMIN_KEY;
  if (!key) {
    console.error('Set FABRICATE_ADMIN_KEY environment variable');
    process.exit(1);
  }
  return key;
}

main().catch(err => {
  console.error('Error:', err.message);
  process.exit(1);
});
```

---

### Task 12: Add admin API routes to server.js

**Files:**
- Modify: `infra/site/server.js` (add admin routes inline, or create `infra/site/routes/admin.js`)

These routes are used by the CLI tool and are protected by an admin key.

- [ ] **Step 1: Create `infra/site/routes/admin.js`**

```js
'use strict';

const express = require('express');
const db = require('../lib/db');
const reconciler = require('../lib/reconciler');

const router = express.Router();

// Admin key from environment
const ADMIN_KEY = process.env.ADMIN_KEY || '';

function requireAdmin(req, res, next) {
  if (!ADMIN_KEY) {
    return res.status(500).json({ error: 'Admin key not configured on server' });
  }
  const key = req.headers['x-admin-key'];
  if (key !== ADMIN_KEY) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
}

// POST /api/admin/create-session
router.post('/create-session', requireAdmin, (req, res) => {
  const hours = req.body.hours || 24;
  const session = db.createSessionDirect(hours);
  console.log(`[admin] Session ${session.id} created directly, expires ${session.expires_at}`);
  res.json({ ok: true, session });
});

// POST /api/admin/revoke-session
router.post('/revoke-session', requireAdmin, (req, res) => {
  const session = db.getActiveSession();
  if (!session) {
    return res.json({ ok: false, error: 'No active session' });
  }
  db.revokeSession(session.id);
  console.log(`[admin] Session ${session.id} revoked`);
  res.json({ ok: true, session_id: session.id });
});

// POST /api/admin/launch-gpu
router.post('/launch-gpu', requireAdmin, async (req, res) => {
  try {
    await reconciler.forceLaunch();
    res.json({ ok: true, message: 'GPU launch initiated' });
  } catch (err) {
    res.status(400).json({ ok: false, error: err.message });
  }
});

module.exports = router;
```

- [ ] **Step 2: Mount admin routes in server.js**

Add this line alongside the other route mounts in server.js (after the `gpuRoutes` require):

```js
const adminRoutes = require('./routes/admin');
```

And mount it:

```js
app.use('/api/admin', adminRoutes);
```

---

### Task 13: Update fabricate.service with new environment variables

**Files:**
- Modify: `infra/site/fabricate.service`

- [ ] **Step 1: Update `infra/site/fabricate.service`**

```ini
[Unit]
Description=Fabrication Terminal API Server
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/fabricate
ExecStart=/usr/bin/node server.js
Environment=NODE_ENV=production
Environment=PORT=3100
Environment=AWS_REGION=us-east-1
Environment=S3_BUCKET=prismata-3d-models
Environment=DB_PATH=/opt/fabricate/fabricate.db
Environment=ADMIN_KEY=__ADMIN_KEY_PLACEHOLDER__
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

**Note:** Replace `__ADMIN_KEY_PLACEHOLDER__` during deployment. The admin key should be stored in SSM and injected at deploy time. Alternatively, fetch it from SSM at startup in server.js.

---

### Task 14: Update deploy.sh

**Files:**
- Modify: `infra/site/deploy.sh`

- [ ] **Step 1: Update `infra/site/deploy.sh`**

Add the new files to the upload and install steps. The complete updated script:

```bash
#!/bin/bash
# infra/site/deploy.sh
# Deploy the Fabrication Terminal to the site box.
# Run from local machine. Requires SSH access to the site box.
set -euo pipefail

SITE_BOX="ubuntu@<SITE_BOX_EIP>"
SSH_KEY="$HOME/.ssh/<SSH_KEY>.pem"
SSH="ssh -i $SSH_KEY $SITE_BOX"
SCP="scp -i $SSH_KEY"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRONTEND_DIR="$(cd "$SCRIPT_DIR/../frontend" && pwd)"

echo "=== Deploying Fabrication Terminal ==="

# 1. Create directory structure on site box
echo "--- Setting up directories ---"
$SSH "sudo mkdir -p /opt/fabricate/public /opt/fabricate/routes /opt/fabricate/lib"

# 2. Upload server files
echo "--- Uploading server files ---"
$SCP "$SCRIPT_DIR/package.json" "$SITE_BOX:/tmp/fabricate-package.json"
$SCP "$SCRIPT_DIR/server.js" "$SITE_BOX:/tmp/fabricate-server.js"
$SCP "$SCRIPT_DIR/routes/s3.js" "$SITE_BOX:/tmp/fabricate-s3.js"
$SCP "$SCRIPT_DIR/routes/status.js" "$SITE_BOX:/tmp/fabricate-status.js"
$SCP "$SCRIPT_DIR/routes/access.js" "$SITE_BOX:/tmp/fabricate-access.js"
$SCP "$SCRIPT_DIR/routes/gpu.js" "$SITE_BOX:/tmp/fabricate-gpu.js"
$SCP "$SCRIPT_DIR/routes/admin.js" "$SITE_BOX:/tmp/fabricate-admin.js"
$SCP "$SCRIPT_DIR/lib/s3client.js" "$SITE_BOX:/tmp/fabricate-s3client.js"
$SCP "$SCRIPT_DIR/lib/db.js" "$SITE_BOX:/tmp/fabricate-db.js"
$SCP "$SCRIPT_DIR/lib/reconciler.js" "$SITE_BOX:/tmp/fabricate-reconciler.js"
$SCP "$SCRIPT_DIR/lib/discord.js" "$SITE_BOX:/tmp/fabricate-discord.js"

# 3. Upload frontend
echo "--- Uploading frontend ---"
$SCP "$FRONTEND_DIR/index.html" "$SITE_BOX:/tmp/fabricate-index.html"

# 4. Upload infrastructure files
echo "--- Uploading service + nginx config ---"
$SCP "$SCRIPT_DIR/fabricate.service" "$SITE_BOX:/tmp/fabricate.service"
$SCP "$SCRIPT_DIR/fabricate.nginx.conf" "$SITE_BOX:/tmp/fabricate.nginx.conf"

# 5. Download static assets from S3 locally, then upload to site box
echo "--- Downloading assets from S3 (locally) ---"
aws s3 cp s3://prismata-3d-models/asset-prep/manifest.json /tmp/fabricate-manifest.json --region us-east-1
aws s3 cp s3://prismata-3d-models/asset-prep/descriptions.json /tmp/fabricate-descriptions.json --region us-east-1
$SCP /tmp/fabricate-manifest.json "$SITE_BOX:/tmp/fabricate-manifest.json"
$SCP /tmp/fabricate-descriptions.json "$SITE_BOX:/tmp/fabricate-descriptions.json"

# 6. Fetch admin key from SSM and inject into service file
echo "--- Configuring admin key ---"
ADMIN_KEY=$(aws ssm get-parameter --name /prismata-3d/admin-key --region us-east-1 --with-decryption --query "Parameter.Value" --output text 2>/dev/null || echo "")
if [ -n "$ADMIN_KEY" ]; then
  sed -i "s/__ADMIN_KEY_PLACEHOLDER__/$ADMIN_KEY/" /tmp/fabricate.service 2>/dev/null || true
fi

# 7. Move files into place
echo "--- Installing files ---"
$SSH "sudo cp /tmp/fabricate-package.json /opt/fabricate/package.json && \
      sudo cp /tmp/fabricate-server.js /opt/fabricate/server.js && \
      sudo cp /tmp/fabricate-s3.js /opt/fabricate/routes/s3.js && \
      sudo cp /tmp/fabricate-status.js /opt/fabricate/routes/status.js && \
      sudo cp /tmp/fabricate-access.js /opt/fabricate/routes/access.js && \
      sudo cp /tmp/fabricate-gpu.js /opt/fabricate/routes/gpu.js && \
      sudo cp /tmp/fabricate-admin.js /opt/fabricate/routes/admin.js && \
      sudo cp /tmp/fabricate-s3client.js /opt/fabricate/lib/s3client.js && \
      sudo cp /tmp/fabricate-db.js /opt/fabricate/lib/db.js && \
      sudo cp /tmp/fabricate-reconciler.js /opt/fabricate/lib/reconciler.js && \
      sudo cp /tmp/fabricate-discord.js /opt/fabricate/lib/discord.js && \
      sudo cp /tmp/fabricate-index.html /opt/fabricate/public/index.html && \
      sudo cp /tmp/fabricate-manifest.json /opt/fabricate/public/manifest.json && \
      sudo cp /tmp/fabricate-descriptions.json /opt/fabricate/public/descriptions.json && \
      sudo chown -R ubuntu:ubuntu /opt/fabricate"

# 8. Install npm dependencies
echo "--- Installing dependencies ---"
$SSH "cd /opt/fabricate && npm install --omit=dev"

# 9. Install systemd service
echo "--- Installing service ---"
$SSH "sudo cp /tmp/fabricate.service /etc/systemd/system/fabricate.service && \
      sudo systemctl daemon-reload && \
      sudo systemctl enable fabricate && \
      sudo systemctl restart fabricate"

# 10. Check service is running
echo "--- Verifying service ---"
sleep 2
if ! $SSH "sudo systemctl is-active fabricate && curl -sf http://127.0.0.1:3100/healthz"; then
    echo "ERROR: Service failed to start. Recent logs:"
    $SSH "sudo journalctl -u fabricate -n 50 --no-pager"
    exit 1
fi

echo ""
echo "=== Fabricate server deployed ==="
echo "Service: sudo systemctl status fabricate"
echo "Logs: sudo journalctl -u fabricate -f"
```

---

### Task 15: Security group update for GPU port 8188

This is a manual AWS CLI step, not a code file change.

- [ ] **Step 1: Add inbound rule to GPU security group**

Run this from a machine with AWS credentials:

```bash
# Allow port 8188 from the VPC CIDR (172.31.0.0/16 for default VPC)
aws ec2 authorize-security-group-ingress \
  --group-id sg-0fdc130ad1d5dc373 \
  --protocol tcp \
  --port 8188 \
  --cidr 172.31.0.0/16 \
  --region us-east-1
```

Alternatively, if the site box has a specific security group, restrict to that SG:

```bash
# More restrictive: allow only from site box's security group
aws ec2 authorize-security-group-ingress \
  --group-id sg-0fdc130ad1d5dc373 \
  --protocol tcp \
  --port 8188 \
  --source-group <site-box-sg-id> \
  --region us-east-1
```

---

### Task 16: Create SSM parameters for Discord and admin key

Manual prerequisite steps.

- [ ] **Step 1: Verify or create SSM parameters**

```bash
# Discord bot token (needed for reaction polling — may already exist from bot)
aws ssm put-parameter \
  --name /prismata-3d/discord-bot-token \
  --type SecureString \
  --value "YOUR_BOT_TOKEN" \
  --region us-east-1

# Discord channel ID (where access requests are posted)
aws ssm put-parameter \
  --name /prismata-3d/discord-channel-id \
  --type String \
  --value "YOUR_CHANNEL_ID" \
  --region us-east-1

# Admin key for CLI tool
aws ssm put-parameter \
  --name /prismata-3d/admin-key \
  --type SecureString \
  --value "$(openssl rand -hex 32)" \
  --region us-east-1
```

The Discord webhook URL (`/prismata-3d/discord-webhook-url`) should already exist from the bot setup.

---

### Task 17: Verify IAM permissions for site box

The site box IAM role needs EC2 describe/run permissions and SSM read access.

- [ ] **Step 1: Verify IAM policy**

The site box instance role needs these permissions (may already exist for the S3 access):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:RunInstances",
        "ec2:CreateTags"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter"
      ],
      "Resource": "arn:aws:ssm:us-east-1:*:parameter/prismata-3d/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": "arn:aws:iam::*:role/prismata-3d-*"
    }
  ]
}
```

Check the existing role:
```bash
# Get the instance profile attached to the site box
aws ec2 describe-instances --instance-ids <site-box-instance-id> \
  --query "Reservations[0].Instances[0].IamInstanceProfile.Arn" --output text
```

---

## Implementation Order

The tasks have these dependencies:

1. **Task 1** (package.json) -- no deps
2. **Task 2** (db.js) -- no deps
3. **Task 3** (discord.js) -- no deps
4. **Task 4** (reconciler.js) -- depends on Task 2, 3
5. **Task 5** (access.js) -- depends on Task 2, 3
6. **Task 6** (status.js) -- depends on Task 2
7. **Task 7** (gpu.js) -- depends on Task 2
8. **Task 8** (server.js) -- depends on Task 2, 4, 5, 6, 7
9. **Task 9** (frontend) -- depends on Task 6, 7
10. **Task 10** (GPU scripts) -- independent
11. **Task 11** (cli.js) -- depends on Task 12
12. **Task 12** (admin.js) -- depends on Task 2, 4
13. **Task 13** (service file) -- depends on Task 16
14. **Task 14** (deploy.sh) -- depends on all above
15. **Task 15** (security group) -- independent, do first
16. **Task 16** (SSM params) -- independent, do first
17. **Task 17** (IAM) -- independent, do first

**Recommended execution order:**

1. Tasks 15, 16, 17 (AWS prerequisites -- can be done in parallel)
2. Tasks 1, 2, 3 (foundation -- can be done in parallel)
3. Tasks 4, 5, 6, 7 (core modules -- can be done in parallel after foundation)
4. Tasks 8, 12 (server assembly)
5. Task 9 (frontend)
6. Tasks 10, 11, 13 (peripheral changes -- can be done in parallel)
7. Task 14 (deploy script -- last)

---

## Testing Checklist

After deployment, verify:

- [ ] `curl https://fabricate.prismata.live/api/status` returns `{"state":"browse",...}`
- [ ] `curl https://fabricate.prismata.live/healthz` returns `{"ok":true,...}`
- [ ] Click "Request Access" in frontend, verify Discord notification appears
- [ ] React with checkmark on Discord, verify session activates within 10s
- [ ] Verify GPU launches automatically (~4 min boot)
- [ ] Verify frontend transitions: browse -> requesting -> starting -> ready
- [ ] Submit a generation, verify WS progress works through the proxy
- [ ] Verify generated model appears in 3D preview
- [ ] Verify session countdown displays correctly
- [ ] Wait 20+ min idle, verify GPU self-terminates
- [ ] Visit frontend again within session window, verify auto-wake
- [ ] `node infra/cli.js status` shows current state
- [ ] `node infra/cli.js revoke` terminates session
- [ ] Browse models with no GPU running (S3 still works)
- [ ] Two tabs with different client IDs see their own queue positions

### Critical Files for Implementation
- `c:/libraries/prismata-3d/infra/site/server.js`
- `c:/libraries/prismata-3d/infra/site/lib/reconciler.js`
- `c:/libraries/prismata-3d/infra/site/routes/gpu.js`
- `c:/libraries/prismata-3d/infra/frontend/index.html`
- `c:/libraries/prismata-3d/infra/site/lib/db.js`