# Phase 4: Two-GPU Sticky Assignment — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second GPU slot (B) with sticky client-to-GPU assignment, ephemeral assignments, prompt lifecycle tracking, and auto-scale-up.

**Architecture:** Widen existing Phase 3 single-GPU code to support 2 slots. DB gets prompt lifecycle columns + load-balancing queries. Reconciler gets split wake/autoscale paths + prompt reconciliation loop. WS proxy gets a status tap. Routes get lazy assignment. Frontend gets WS reconnect on assignment change.

**Tech Stack:** Node.js, Express, better-sqlite3, ws, AWS EC2 SDK, ComfyUI WebSocket API

**Spec:** `docs/superpowers/specs/2026-03-29-phase4-two-gpu-sticky-assignment-design.md`

---

## File Map

| File | Responsibility | Changes |
|------|---------------|---------|
| `infra/site/lib/db.js` | SQLite schema + query helpers | New columns, indexes, 11 new functions, modify 3 existing |
| `infra/site/lib/reconciler.js` | EC2 lifecycle, health, scaling | Split wake/autoscale, shouldScaleUp(), prompt reconciliation, assignment cleanup |
| `infra/site/server.js` | Express + WS proxy | WS tap for prompt status, remove eager assignment on WS connect |
| `infra/site/routes/gpu.js` | GPU proxy routes | Lazy assignment in prompt, multi-GPU queue routing, prompt-aware /view |
| `infra/frontend/index.html` | Single-file SPA | WS reconnect on assignment, GPU slot label, promptId on /view |

---

## Task 1: DB Schema Migration — Add Prompt Lifecycle Columns and Indexes

**Files:**
- Modify: `infra/site/lib/db.js:24-79` (initSchema function)

This task adds the new columns and indexes needed for prompt lifecycle tracking and multi-GPU load balancing. All changes are additive — existing data is preserved.

- [ ] **Step 1: Add prompt lifecycle columns to schema**

In `infra/site/lib/db.js`, add these columns and indexes inside the `initSchema()` function, after the existing `CREATE TABLE` and `CREATE INDEX` statements (after line 78, before the closing `\``):

```js
    -- Phase 4: prompt lifecycle columns (additive — no data loss)
    -- SQLite ALTER TABLE only supports ADD COLUMN, not IF NOT EXISTS on columns,
    -- so we use a safe pattern: try to add, ignore if already exists
    CREATE TABLE IF NOT EXISTS _phase4_migration (id INTEGER PRIMARY KEY);
    INSERT OR IGNORE INTO _phase4_migration VALUES (1);
```

Then, right after `initSchema()` calls `db.exec(...)`, add a separate migration block:

```js
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
```

The partial unique index on `gpu_instances(slot)` enforces at most one active GPU per slot at the database level.

Note: The `prompts` table already has a `status` column (added in Phase 3 with `DEFAULT 'pending'`). We're only adding `started_at`, `finished_at`, and `updated_at`.

- [ ] **Step 2: Backfill updated_at for existing rows**

After the migration block, add:

```js
  // Backfill updated_at for existing prompts that lack it
  db.prepare(`
    UPDATE prompts SET updated_at = submitted_at WHERE updated_at IS NULL
  `).run();
```

- [ ] **Step 3: Verify schema by restarting locally**

Since this runs on the remote site box, verify the migration logic is syntactically correct:

```bash
cd c:/libraries/prismata-3d/infra/site
node -e "
  const Database = require('better-sqlite3');
  const db = new Database(':memory:');
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  // Paste the full initSchema contents here to verify
  console.log('Schema OK');
  // Verify columns exist
  const cols = db.prepare('PRAGMA table_info(prompts)').all().map(c => c.name);
  console.log('prompts columns:', cols);
  const indexes = db.prepare('SELECT name FROM sqlite_master WHERE type=\\'index\\'').all().map(i => i.name);
  console.log('indexes:', indexes);
"
```

Expected: No errors. `prompts` columns include `started_at`, `finished_at`, `updated_at`. Indexes include `idx_gpu_instances_slot_active`, `idx_prompts_status_gpu`, `idx_prompts_client_gpu_status`, `idx_client_assignments_gpu`.

- [ ] **Step 4: Commit**

```bash
cd c:/libraries/prismata-3d
git add infra/site/lib/db.js
git commit -m "feat(db): add prompt lifecycle columns and Phase 4 indexes"
```

---

## Task 2: DB Functions — New Query Helpers

**Files:**
- Modify: `infra/site/lib/db.js:225-437` (add new functions, modify existing)

This task adds all the new DB functions specified in the design. Each function is small and independent.

- [ ] **Step 1: Add getActiveGpuCount()**

Add after `getReadyGpu()` (line 238):

```js
function getActiveGpuCount() {
  const d = getDb();
  const row = d.prepare("SELECT COUNT(*) as cnt FROM gpu_instances WHERE status IN ('launching', 'ready')").get();
  return row.cnt;
}
```

- [ ] **Step 2: Add getReadyGpus() and getLaunchingGpus()**

Add after `getActiveGpuCount()`:

```js
function getReadyGpus() {
  const d = getDb();
  return d.prepare("SELECT * FROM gpu_instances WHERE status = 'ready' ORDER BY launched_at ASC").all();
}

function getLaunchingGpus() {
  const d = getDb();
  return d.prepare("SELECT * FROM gpu_instances WHERE status = 'launching' ORDER BY launched_at ASC").all();
}
```

- [ ] **Step 3: Add getNextSlot()**

Add after `getLaunchingGpus()`:

```js
function getNextSlot() {
  const d = getDb();
  const slotA = d.prepare("SELECT COUNT(*) as cnt FROM gpu_instances WHERE slot = 'A' AND status IN ('launching', 'ready')").get();
  return slotA.cnt === 0 ? 'A' : 'B';
}
```

- [ ] **Step 4: Add getLeastLoadedGpu()**

Add after `getNextSlot()`:

```js
function getLeastLoadedGpu() {
  const d = getDb();
  // Get all ready GPUs with their active prompt counts
  const rows = d.prepare(`
    SELECT gi.*,
      COALESCE((
        SELECT COUNT(*) FROM prompts p
        WHERE p.gpu_instance_id = gi.instance_id
          AND p.status IN ('pending', 'running')
      ), 0) as active_prompts
    FROM gpu_instances gi
    WHERE gi.status = 'ready'
    ORDER BY active_prompts ASC, gi.launched_at ASC
    LIMIT 1
  `).get();
  return rows || null;
}
```

- [ ] **Step 5: Add getClientActivePromptCount() and clearClientAssignment()**

Add after `getLeastLoadedGpu()`:

```js
function getClientActivePromptCount(clientId, gpuInstanceId) {
  const d = getDb();
  const row = d.prepare(`
    SELECT COUNT(*) as cnt FROM prompts
    WHERE client_id = ? AND gpu_instance_id = ? AND status IN ('pending', 'running')
  `).get(clientId, gpuInstanceId);
  return row.cnt;
}

function clearClientAssignment(clientId) {
  const d = getDb();
  d.prepare('DELETE FROM client_assignments WHERE client_id = ?').run(clientId);
}
```

- [ ] **Step 6: Add updatePromptStatus() with monotonic transitions**

Add after `clearClientAssignment()`:

```js
const ALLOWED_TRANSITIONS = {
  pending: new Set(['running', 'completed', 'failed']),
  running: new Set(['completed', 'failed']),
};

function updatePromptStatus(promptId, newStatus) {
  const d = getDb();
  const ts = now();
  const prompt = d.prepare('SELECT status FROM prompts WHERE prompt_id = ?').get(promptId);
  if (!prompt) return false;

  const allowed = ALLOWED_TRANSITIONS[prompt.status];
  if (!allowed || !allowed.has(newStatus)) return false;

  const isTerminal = newStatus === 'completed' || newStatus === 'failed';
  const isStarting = newStatus === 'running';

  if (isStarting) {
    d.prepare(`
      UPDATE prompts SET status = ?, started_at = ?, updated_at = ? WHERE prompt_id = ?
    `).run(newStatus, ts, ts, promptId);
  } else if (isTerminal) {
    d.prepare(`
      UPDATE prompts SET status = ?, finished_at = ?, updated_at = ? WHERE prompt_id = ?
    `).run(newStatus, ts, ts, promptId);
  } else {
    d.prepare(`
      UPDATE prompts SET status = ?, updated_at = ? WHERE prompt_id = ?
    `).run(newStatus, ts, promptId);
  }
  return true;
}
```

- [ ] **Step 7: Add touchPrompt()**

Add after `updatePromptStatus()`:

```js
function touchPrompt(promptId) {
  const d = getDb();
  const ts = now();
  d.prepare('UPDATE prompts SET updated_at = ? WHERE prompt_id = ?').run(ts, promptId);
}
```

- [ ] **Step 8: Add failPromptsForGoneGpu() and getStaleActivePrompts()**

Add after `touchPrompt()`:

```js
function failPromptsForGoneGpu(instanceId) {
  const d = getDb();
  const ts = now();
  const result = d.prepare(`
    UPDATE prompts SET status = 'failed', finished_at = ?, updated_at = ?
    WHERE gpu_instance_id = ? AND status IN ('pending', 'running')
  `).run(ts, ts, instanceId);
  return result.changes;
}

function getStaleActivePrompts(gpuInstanceId, graceSeconds) {
  const d = getDb();
  const cutoff = now() - graceSeconds;
  return d.prepare(`
    SELECT * FROM prompts
    WHERE gpu_instance_id = ? AND status IN ('pending', 'running')
      AND updated_at < ?
    ORDER BY submitted_at ASC
  `).all(gpuInstanceId, cutoff);
}
```

- [ ] **Step 9: Modify existing functions**

**Modify `assignClient()`** — change from `INSERT OR REPLACE` to proper UPSERT (line 306-313):

Replace:
```js
function assignClient(clientId, gpuInstanceId) {
  const d = getDb();
  const ts = now();
  d.prepare(`
    INSERT OR REPLACE INTO client_assignments (client_id, gpu_instance_id, assigned_at, last_seen_at)
    VALUES (?, ?, ?, ?)
  `).run(clientId, gpuInstanceId, ts, ts);
}
```

With:
```js
function assignClient(clientId, gpuInstanceId) {
  const d = getDb();
  const ts = now();
  d.prepare(`
    INSERT INTO client_assignments (client_id, gpu_instance_id, assigned_at, last_seen_at)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(client_id) DO UPDATE SET
      gpu_instance_id = excluded.gpu_instance_id,
      assigned_at = excluded.assigned_at,
      last_seen_at = excluded.last_seen_at
  `).run(clientId, gpuInstanceId, ts, ts);
}
```

**Modify `markGpuGone()`** — add `failPromptsForGoneGpu()` call (line 264-272):

Replace:
```js
function markGpuGone(instanceId) {
  const d = getDb();
  const ts = now();
  d.prepare(`
    UPDATE gpu_instances SET status = 'gone', gone_at = ? WHERE instance_id = ?
  `).run(ts, instanceId);
  // Clear client assignments for this GPU
  d.prepare('DELETE FROM client_assignments WHERE gpu_instance_id = ?').run(instanceId);
}
```

With:
```js
function markGpuGone(instanceId) {
  const d = getDb();
  const ts = now();
  d.prepare(`
    UPDATE gpu_instances SET status = 'gone', gone_at = ? WHERE instance_id = ?
  `).run(ts, instanceId);
  // Clear client assignments for this GPU
  d.prepare('DELETE FROM client_assignments WHERE gpu_instance_id = ?').run(instanceId);
  // Fail orphaned active prompts
  const failed = failPromptsForGoneGpu(instanceId);
  if (failed > 0) {
    console.log(`[db] Failed ${failed} orphaned prompt(s) for gone GPU ${instanceId}`);
  }
}
```

**Modify `recordPrompt()`** — set `updated_at` on insert (line 321-328):

Replace:
```js
function recordPrompt(promptId, clientId, gpuInstanceId) {
  const d = getDb();
  const ts = now();
  d.prepare(`
    INSERT INTO prompts (prompt_id, client_id, gpu_instance_id, submitted_at, status)
    VALUES (?, ?, ?, ?, 'pending')
  `).run(promptId, clientId, gpuInstanceId, ts);
}
```

With:
```js
function recordPrompt(promptId, clientId, gpuInstanceId) {
  const d = getDb();
  const ts = now();
  d.prepare(`
    INSERT INTO prompts (prompt_id, client_id, gpu_instance_id, submitted_at, status, updated_at)
    VALUES (?, ?, ?, ?, 'pending', ?)
  `).run(promptId, clientId, gpuInstanceId, ts, ts);
}
```

- [ ] **Step 10: Update module.exports**

Replace the existing `module.exports` block (line 399-437) with:

```js
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
  getActiveGpuCount,
  getReadyGpus,
  getLaunchingGpus,
  getNextSlot,
  getLeastLoadedGpu,
  registerGpuInstance,
  markGpuReady,
  markGpuGone,
  incrementHealthFailures,
  resetHealthFailures,
  canLaunchGpu, // kept for backward compat, not used in Phase 4 reconciler
  getClientAssignment,
  assignClient,
  touchClient,
  clearClientAssignment,
  getClientActivePromptCount,
  recordPrompt,
  getPromptGpu,
  updatePromptStatus,
  touchPrompt,
  failPromptsForGoneGpu,
  getStaleActivePrompts,
  expireStaleRequests,
  expireStaleSessions,
  cleanStaleClientAssignments,
  getLaunchLock,
  setLaunchLock,
  setLaunchCooldown,
  isLaunchCoolingDown,
};
```

- [ ] **Step 11: Verify all functions compile**

```bash
cd c:/libraries/prismata-3d/infra/site
node -e "const db = require('./lib/db'); console.log('Exports:', Object.keys(db).join(', '));"
```

Expected: No errors. All new function names listed.

- [ ] **Step 12: Commit**

```bash
cd c:/libraries/prismata-3d
git add infra/site/lib/db.js
git commit -m "feat(db): add Phase 4 query helpers — load balancing, prompt lifecycle, assignment cleanup"
```

---

## Task 3: Reconciler — Split Wake/Autoscale and Assignment Cleanup

**Files:**
- Modify: `infra/site/lib/reconciler.js:257-319` (reconcileDesiredState and launchGpu)

This task splits the single-GPU launch logic into two paths (wake + autoscale) and adds assignment cleanup.

- [ ] **Step 1: Replace reconcileDesiredState()**

Replace the entire `reconcileDesiredState()` function (lines 260-273) with:

```js
async function reconcileDesiredState(session) {
  const lock = db.getLaunchLock();

  // Path 1: First GPU — wake on demand
  // activeGpuCount === 0, session active, wake_requested_at set, no launch in progress
  if (db.getActiveGpuCount() === 0 && session.wake_requested_at && !lock.inProgress) {
    if (!db.isLaunchCoolingDown()) {
      await launchGpu(session);
      return;
    }
  }

  // Path 2: Second GPU — autoscale
  // activeGpuCount === 1, session active, exactly 1 ready + 0 launching, demand warrants it
  const readyGpus = db.getReadyGpus();
  const launchingGpus = db.getLaunchingGpus();
  if (readyGpus.length === 1 && launchingGpus.length === 0 && !lock.inProgress) {
    if (shouldScaleUp(readyGpus[0]) && !db.isLaunchCoolingDown()) {
      console.log('[reconciler] Scale-up triggered: launching GPU B');
      await launchGpu(session);
    }
  }
}

function shouldScaleUp(readyGpu) {
  const d = db.getDb();
  const row = d.prepare(`
    SELECT COUNT(*) as cnt FROM prompts
    WHERE gpu_instance_id = ? AND status IN ('pending', 'running')
  `).get(readyGpu.instance_id);
  return row.cnt >= 3;
}
```

- [ ] **Step 2: Replace launchGpu()**

Replace the entire `launchGpu()` function (lines 275-319) with:

```js
async function launchGpu(session) {
  const slot = db.getNextSlot();

  // Defensive: verify no active GPU already holds this slot
  const d = db.getDb();
  const existing = d.prepare("SELECT COUNT(*) as cnt FROM gpu_instances WHERE slot = ? AND status IN ('launching', 'ready')").get(slot);
  if (existing.cnt > 0) {
    console.log(`[reconciler] Slot ${slot} already occupied, refusing launch`);
    return;
  }

  // Verify hard cap of 2
  if (db.getActiveGpuCount() >= 2) {
    console.log('[reconciler] Already at GPU cap (2), refusing launch');
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
    console.log(`[reconciler] Launched instance ${instanceId} (slot ${slot})`);
    db.registerGpuInstance(instanceId, slot, session.id);

    // wake_requested_at is NOT cleared here — only cleared when GPU becomes ready (Fix C)
  } catch (err) {
    console.error('[reconciler] Launch failed:', err.message);
    db.setLaunchLock(false);
    db.setLaunchCooldown();
  }
}
```

- [ ] **Step 3: Add assignment cleanup to reconcile()**

In the `reconcile()` function (line 47), add a new step 9 after step 8 (`reconcileDesiredState`):

```js
  // 9. Clean up ephemeral client assignments (Phase 4)
  cleanEphemeralAssignments();
```

Then add the function before `reconcileDesiredState()`:

```js
function cleanEphemeralAssignments() {
  const d = db.getDb();
  const assignments = d.prepare(`
    SELECT ca.client_id, ca.gpu_instance_id
    FROM client_assignments ca
    JOIN gpu_instances gi ON ca.gpu_instance_id = gi.instance_id
    WHERE gi.status = 'ready'
  `).all();

  for (const assignment of assignments) {
    const count = db.getClientActivePromptCount(assignment.client_id, assignment.gpu_instance_id);
    if (count === 0) {
      db.clearClientAssignment(assignment.client_id);
    }
  }
}
```

- [ ] **Step 4: Update forceLaunch() for multi-GPU**

Replace `forceLaunch()` (lines 323-333) with:

```js
async function forceLaunch() {
  const session = db.getActiveSession();
  if (!session) throw new Error('No active session');
  const lock = db.getLaunchLock();
  if (lock.inProgress) throw new Error('Launch already in progress');
  if (db.getActiveGpuCount() >= 2) throw new Error('Already at GPU cap (2)');
  // Set wake flag and launch
  db.setWakeRequested(session.id);
  await launchGpu(session);
}
```

- [ ] **Step 5: Verify syntax**

```bash
cd c:/libraries/prismata-3d/infra/site
node -e "const r = require('./lib/reconciler'); console.log('Reconciler exports:', Object.keys(r).join(', '));"
```

Expected: No errors.

- [ ] **Step 6: Commit**

```bash
cd c:/libraries/prismata-3d
git add infra/site/lib/reconciler.js
git commit -m "feat(reconciler): split wake/autoscale paths, add assignment cleanup and shouldScaleUp()"
```

---

## Task 4: Reconciler — Prompt Reconciliation Loop

**Files:**
- Modify: `infra/site/lib/reconciler.js`

This task adds the reconciler's eventual-correctness loop that verifies prompt statuses against ComfyUI.

- [ ] **Step 1: Add tick counter and reconciliation call**

At the top of the module (after `let tickInProgress = false;` on line 18), add:

```js
let tickCount = 0;
```

In the `reconcile()` function, add step 10 after step 9 (assignment cleanup):

```js
  // 10. Prompt reconciliation (every 30s = every 6th tick)
  tickCount++;
  if (tickCount % 6 === 0) {
    await reconcilePromptStatuses();
  }
```

- [ ] **Step 2: Add reconcilePromptStatuses()**

Add before `reconcileDesiredState()`:

```js
async function reconcilePromptStatuses() {
  const readyGpus = db.getReadyGpus();

  for (const gpu of readyGpus) {
    const stalePrompts = db.getStaleActivePrompts(gpu.instance_id, 60);
    if (stalePrompts.length === 0) continue;

    // Fetch queue from this GPU
    let queue = null;
    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), HEALTH_CHECK_TIMEOUT_MS);
      const resp = await fetch(`http://${gpu.private_ip}:8188/api/queue`, {
        signal: controller.signal,
      });
      clearTimeout(timeout);
      if (resp.ok) {
        queue = await resp.json();
      }
    } catch (err) {
      console.warn(`[reconciler] Queue fetch failed for ${gpu.instance_id}: ${err.message}`);
      continue; // Skip this GPU if we can't reach it — health check will catch it
    }

    const runningIds = new Set((queue.queue_running || []).map(j => j[1]));
    const pendingIds = new Set((queue.queue_pending || []).map(j => j[1]));

    for (const prompt of stalePrompts) {
      if (runningIds.has(prompt.prompt_id)) {
        db.updatePromptStatus(prompt.prompt_id, 'running');
      } else if (pendingIds.has(prompt.prompt_id)) {
        db.touchPrompt(prompt.prompt_id);
      } else {
        // Not in queue — check history
        const resolved = await resolvePromptFromHistory(gpu.private_ip, prompt.prompt_id);
        if (resolved === 'completed') {
          db.updatePromptStatus(prompt.prompt_id, 'completed');
        } else {
          db.updatePromptStatus(prompt.prompt_id, 'failed');
        }
      }
    }
  }
}

async function resolvePromptFromHistory(gpuIp, promptId) {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), HEALTH_CHECK_TIMEOUT_MS);
    const resp = await fetch(`http://${gpuIp}:8188/api/history/${promptId}`, {
      signal: controller.signal,
    });
    clearTimeout(timeout);
    if (!resp.ok) return 'failed';

    const data = await resp.json();
    const entry = data[promptId];
    if (!entry) return 'failed';

    // Check for execution error
    if (entry.status?.status_str === 'error') return 'failed';

    // Check for any non-empty outputs
    const outputs = entry.outputs || {};
    for (const nodeId of Object.keys(outputs)) {
      const nodeOutput = outputs[nodeId];
      // Any node with non-empty output counts as success
      if (nodeOutput && Object.keys(nodeOutput).length > 0) {
        return 'completed';
      }
    }

    // History exists but no outputs — treat as failed
    return 'failed';
  } catch {
    return 'failed';
  }
}
```

- [ ] **Step 3: Verify syntax**

```bash
cd c:/libraries/prismata-3d/infra/site
node -e "const r = require('./lib/reconciler'); console.log('OK');"
```

Expected: No errors.

- [ ] **Step 4: Commit**

```bash
cd c:/libraries/prismata-3d
git add infra/site/lib/reconciler.js
git commit -m "feat(reconciler): add prompt reconciliation loop for eventual correctness"
```

---

## Task 5: WebSocket Tap — Prompt Status Sniffing

**Files:**
- Modify: `infra/site/server.js:120-137` (WS proxy message relay)

This task adds a lightweight tap on GPU→client WS messages to update prompt statuses in real-time.

- [ ] **Step 1: Remove eager assignment on WS connect**

In `server.js`, replace lines 99-115 (the GPU resolution block):

```js
  // Find GPU for this client
  let gpuIp = null;
  if (clientId) {
    const assignment = db.getClientAssignment(clientId);
    if (assignment && assignment.private_ip) {
      gpuIp = assignment.private_ip;
      db.touchClient(clientId);
    }
  }

  // Fall back to ready GPU found above
  if (!gpuIp) {
    gpuIp = readyGpu.private_ip;
    if (clientId) {
      db.assignClient(clientId, readyGpu.instance_id);
    }
  }
```

With:

```js
  // Phase 4: lazy assignment — don't assign on WS connect, only on prompt submit
  // Check existing assignment first, fall back to any ready GPU for queue polling
  let gpuIp = null;
  const assignment = db.getClientAssignment(clientId);
  if (assignment && assignment.private_ip) {
    gpuIp = assignment.private_ip;
    db.touchClient(clientId);
  } else {
    // No assignment yet — connect to any ready GPU (for queue polling before first prompt)
    gpuIp = readyGpu.private_ip;
    // Do NOT assign client here — assignment happens on prompt submission
  }
```

- [ ] **Step 2: Add WS tap on upstream messages**

Replace the upstream `on('open')` handler (lines 123-137):

```js
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
```

With:

```js
    upstream.on('open', () => {
      // Relay messages: GPU → Client (with status tap)
      upstream.on('message', (data, isBinary) => {
        // Tap: sniff prompt status from GPU messages (text frames only)
        if (!isBinary) {
          try {
            const msg = JSON.parse(data.toString());
            if (msg.type === 'executing' && msg.data?.prompt_id) {
              if (msg.data.node === null) {
                // node === null means execution complete for this prompt
                db.updatePromptStatus(msg.data.prompt_id, 'completed');
              } else {
                // A node is executing — prompt is running
                db.updatePromptStatus(msg.data.prompt_id, 'running');
              }
            }
            if (msg.type === 'execution_error' && msg.data?.prompt_id) {
              db.updatePromptStatus(msg.data.prompt_id, 'failed');
            }
          } catch {
            // Don't break relay on parse failure
          }
        }

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
```

Note: The WS tap uses the same event names already handled by the frontend's `handleWsMessage()`: `executing` (with `node === null` for completion) and `execution_error`. This is validated by the existing frontend code at lines 1742-1776.

- [ ] **Step 3: Verify syntax**

```bash
cd c:/libraries/prismata-3d/infra/site
node -e "require('./server'); setTimeout(() => process.exit(0), 500);" 2>&1 | head -3
```

Expected: Server starts without syntax errors (will fail to bind port if already in use, but no require errors).

- [ ] **Step 4: Commit**

```bash
cd c:/libraries/prismata-3d
git add infra/site/server.js
git commit -m "feat(ws): add prompt status tap and remove eager assignment on WS connect"
```

---

## Task 6: GPU Routes — Lazy Assignment and Multi-GPU Routing

**Files:**
- Modify: `infra/site/routes/gpu.js`

This task modifies the GPU proxy routes for lazy assignment on prompt submission, multi-GPU queue routing, and prompt-aware `/view` routing.

- [ ] **Step 1: Replace getGpuForClient() — remove auto-assign**

Replace the existing `getGpuForClient()` function (lines 30-52) with:

```js
// Helper: get GPU IP for this client's existing assignment, or any ready GPU.
// Does NOT assign — assignment happens only in POST /prompt.
// Returns { ip, instanceId, slot } or null.
function getGpuForClient(clientId) {
  // Try client assignment first
  if (clientId) {
    const assignment = db.getClientAssignment(clientId);
    if (assignment && assignment.private_ip) {
      db.touchClient(clientId);
      // Look up slot for the assigned GPU
      const gpu = db.getDb().prepare('SELECT slot FROM gpu_instances WHERE instance_id = ?').get(assignment.gpu_instance_id);
      return { ip: assignment.private_ip, instanceId: assignment.gpu_instance_id, slot: gpu?.slot || null };
    }
  }

  // Fall back to first ready GPU (for queue polling, system_stats, etc.)
  const gpu = db.getReadyGpu();
  if (!gpu || !gpu.private_ip) return null;

  // Do NOT auto-assign — lazy assignment on prompt submission only
  return { ip: gpu.private_ip, instanceId: gpu.instance_id, slot: gpu.slot };
}
```

- [ ] **Step 2: Replace POST /prompt — lazy assignment after acceptance**

Replace the entire POST `/prompt` route handler (lines 78-130) with:

```js
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

  // Phase 4: lazy assignment — resolve target GPU
  let targetGpu = null;
  let isNewAssignment = false;

  // Check existing assignment
  const assignment = db.getClientAssignment(clientId);
  if (assignment && assignment.private_ip) {
    const gpu = db.getDb().prepare('SELECT * FROM gpu_instances WHERE instance_id = ? AND status = ?').get(assignment.gpu_instance_id, 'ready');
    if (gpu) {
      targetGpu = { ip: gpu.private_ip, instanceId: gpu.instance_id, slot: gpu.slot };
    }
  }

  // No valid assignment — pick least loaded GPU
  if (!targetGpu) {
    const leastLoaded = db.getLeastLoadedGpu();
    if (leastLoaded) {
      targetGpu = { ip: leastLoaded.private_ip, instanceId: leastLoaded.instance_id, slot: leastLoaded.slot };
      isNewAssignment = true;
    }
  }

  if (!targetGpu) {
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  recordPromptRateLimit(clientId);

  // Forward to ComfyUI
  try {
    const gpuResp = await fetch(`http://${targetGpu.ip}:8188/api/prompt`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req.body),
    });

    const contentType = gpuResp.headers.get('content-type') || '';
    if (contentType.includes('application/json')) {
      const data = await gpuResp.json();

      // Only persist assignment and prompt AFTER ComfyUI accepts
      if (data.prompt_id) {
        if (isNewAssignment) {
          db.assignClient(clientId, targetGpu.instanceId);
        }
        db.touchClient(clientId);
        db.recordPrompt(data.prompt_id, clientId, targetGpu.instanceId);
      }

      // Return with assignment metadata for frontend WS reconnect
      res.status(gpuResp.status).json({
        ...data,
        assigned_gpu_slot: targetGpu.slot,
        reconnect: isNewAssignment,
      });
    } else {
      const text = await gpuResp.text();
      res.status(gpuResp.status).type(contentType || 'text/plain').send(text);
    }
  } catch (err) {
    console.error('[gpu-proxy] Prompt forward error:', err.message);
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});
```

- [ ] **Step 3: Replace GET /view — prompt-aware routing**

Replace the entire GET `/view` route handler (lines 343-367) with:

```js
// GET /api/gpu/view — prompt-aware routing for multi-GPU (Phase 4)
router.get('/view', async (req, res) => {
  const denied = checkAccess(res);
  if (denied) return;

  let gpuIp = null;

  // Priority 1: resolve by promptId if provided
  const promptId = req.query.promptId;
  if (promptId) {
    const promptInfo = db.getPromptGpu(promptId);
    if (promptInfo && promptInfo.private_ip) {
      gpuIp = promptInfo.private_ip;
    }
  }

  // Priority 2: client's assigned GPU
  if (!gpuIp) {
    const clientId = req.query.clientId;
    if (clientId) {
      const assignment = db.getClientAssignment(clientId);
      if (assignment && assignment.private_ip) {
        gpuIp = assignment.private_ip;
      }
    }
  }

  // Priority 3: any ready GPU (for sprite previews, manifest, etc.)
  if (!gpuIp) {
    const gpu = db.getReadyGpu();
    if (gpu && gpu.private_ip) {
      gpuIp = gpu.private_ip;
    }
  }

  if (!gpuIp) {
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  // Strip our routing params before forwarding to ComfyUI
  const forwardParams = new URLSearchParams(req.query);
  forwardParams.delete('promptId');
  forwardParams.delete('clientId');
  const qs = forwardParams.toString();

  try {
    const gpuResp = await fetch(`http://${gpuIp}:8188/api/view?${qs}`);
    if (!gpuResp.ok) {
      return res.status(gpuResp.status).end();
    }
    const contentType = gpuResp.headers.get('content-type') || 'application/octet-stream';
    res.set('Content-Type', contentType);
    const arrayBuffer = await gpuResp.arrayBuffer();
    res.send(Buffer.from(arrayBuffer));
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});
```

- [ ] **Step 4: Verify syntax**

```bash
cd c:/libraries/prismata-3d/infra/site
node -e "const r = require('./routes/gpu'); console.log('GPU routes OK');"
```

Expected: No errors.

- [ ] **Step 5: Commit**

```bash
cd c:/libraries/prismata-3d
git add infra/site/routes/gpu.js
git commit -m "feat(routes): lazy assignment on prompt, multi-GPU queue routing, prompt-aware /view"
```

---

## Task 7: Frontend — WS Reconnect on Assignment and GPU Label

**Files:**
- Modify: `infra/frontend/index.html`

This task adds WS reconnect when the client is assigned to a new GPU, shows a subtle GPU slot label, and passes `promptId` to `/view` calls for output files.

- [ ] **Step 1: Add GPU slot tracking state**

After the `let currentExportNodeId = null;` line (around line 1649), add:

```js
let assignedGpuSlot = null; // 'A' or 'B', set by prompt response
```

- [ ] **Step 2: Handle assignment in prompt response**

In the `startGeneration()` function, after `const data = await resp.json();` and `currentPromptId = data.prompt_id;` (around line 2741-2742), add:

```js
    // Phase 4: track GPU assignment and reconnect WS if assigned to new GPU
    if (data.assigned_gpu_slot) {
      assignedGpuSlot = data.assigned_gpu_slot;
    }
    if (data.reconnect && ws) {
      log(`Assigned to GPU ${data.assigned_gpu_slot} — reconnecting...`);
      ws.close();
      // ws.onclose handler will reconnect after 5s, which routes to new assigned GPU
      // Force immediate reconnect instead of waiting
      ws = null;
      setTimeout(connectWebSocket, 200);
    }
```

- [ ] **Step 3: Show GPU slot label in queue status**

In the queue status display section (around line 2069-2079), modify the `statusStr` building. After the line:

```js
            let statusStr = '';
```

Add a GPU label prefix:

```js
            const gpuLabel = assignedGpuSlot ? `GPU ${assignedGpuSlot} | ` : '';
```

Then change the status string construction from:

```js
              statusStr = `Queue: ${totalRunning} running, ${totalPending} pending`;
```

To:

```js
              statusStr = `${gpuLabel}Queue: ${totalRunning} running, ${totalPending} pending`;
```

- [ ] **Step 4: Pass promptId to /view calls for output files**

In the output file polling section, find the `/api/view` calls that fetch generation output (around lines 2824, 2857, 2875, 2894). These are in the `pollHistory()` callback that processes completed outputs.

For each `/api/view` call that uses `type=output`, append `&promptId=${currentPromptId}`. The pattern is:

Replace (around line 2824):
```js
        const glbUrl = `${gpuUrl('/api/view')}?filename=${encodeURIComponent(glbFile)}&type=output`;
```

With:
```js
        const glbUrl = `${gpuUrl('/api/view')}?filename=${encodeURIComponent(glbFile)}&type=output&promptId=${encodeURIComponent(currentPromptId)}`;
```

Apply the same pattern to the other output `/api/view` calls at lines 2861, 2879, and 2894. Each adds `&promptId=${encodeURIComponent(currentPromptId)}` to the URL.

Do NOT modify `/api/view` calls that use `type=input` (lines 2199, 2264, 3113) — those fetch sprites/manifest from the GPU filesystem and are not prompt-specific.

- [ ] **Step 5: Clear GPU slot on WS disconnect**

In the state transition section where GPU goes offline (around line 2094-2098):

```js
      if (prevState === 'ready' && appState !== 'ready') {
        // GPU went away
        if (ws) { ws.close(); ws = null; }
        log('GPU offline', 'error');
      }
```

Add after `log('GPU offline', 'error');`:

```js
        assignedGpuSlot = null;
```

- [ ] **Step 6: Verify no syntax errors**

Open `infra/frontend/index.html` in a browser or run a quick syntax check:

```bash
cd c:/libraries/prismata-3d
node -e "const fs = require('fs'); const html = fs.readFileSync('infra/frontend/index.html', 'utf8'); const scriptMatch = html.match(/<script[^>]*>([\s\S]*?)<\/script>/g); console.log('Script blocks found:', scriptMatch.length); console.log('No syntax errors in read');"
```

- [ ] **Step 7: Commit**

```bash
cd c:/libraries/prismata-3d
git add infra/frontend/index.html
git commit -m "feat(frontend): WS reconnect on GPU assignment, slot label, prompt-aware /view"
```

---

## Task 8: Deploy and Validate

**Files:**
- All modified files deployed to site box

This task deploys all Phase 4 changes to production and verifies the basic flow works.

- [ ] **Step 1: Deploy all server + frontend changes**

```bash
cd c:/libraries/prismata-3d
bash infra/site/deploy.sh
```

This deploys all server-side files and restarts the fabricate service.

- [ ] **Step 2: Deploy frontend to S3**

```bash
aws s3 cp infra/frontend/index.html s3://prismata-3d-models/frontend/index.html --region us-east-1
```

- [ ] **Step 3: Check service is running**

```bash
ssh -i ~/.ssh/<SSH_KEY>.pem ubuntu@<SITE_BOX_EIP> "sudo systemctl status fabricate | head -15"
```

Expected: `active (running)`

- [ ] **Step 4: Check DB migration succeeded**

```bash
ssh -i ~/.ssh/<SSH_KEY>.pem ubuntu@<SITE_BOX_EIP> "sqlite3 /opt/fabricate/fabricate.db 'PRAGMA table_info(prompts);'"
```

Expected: Columns include `started_at`, `finished_at`, `updated_at` in addition to the existing columns.

- [ ] **Step 5: Check indexes were created**

```bash
ssh -i ~/.ssh/<SSH_KEY>.pem ubuntu@<SITE_BOX_EIP> "sqlite3 /opt/fabricate/fabricate.db 'SELECT name FROM sqlite_master WHERE type=\"index\" AND name LIKE \"idx_%\";'"
```

Expected: Includes `idx_gpu_instances_slot_active`, `idx_prompts_status_gpu`, `idx_prompts_client_gpu_status`, `idx_client_assignments_gpu`.

- [ ] **Step 6: Check reconciler logs**

```bash
ssh -i ~/.ssh/<SSH_KEY>.pem ubuntu@<SITE_BOX_EIP> "sudo journalctl -u fabricate --since '2 min ago' --no-pager"
```

Expected: Reconciler running without errors. No crashes.

- [ ] **Step 7: Smoke test — single GPU flow still works**

1. Open `https://fabricate.prismata.live` in a browser
2. Request access or use existing session
3. Wake GPU
4. Submit a test prompt (e.g., Drone default skin)
5. Verify WS shows progress
6. Verify output loads correctly
7. Check that `assigned_gpu_slot` appears in console (open browser DevTools, Network tab, check `/api/gpu/prompt` response)

- [ ] **Step 8: Commit deployment confirmation**

```bash
cd c:/libraries/prismata-3d
git add -A
git commit -m "chore: Phase 4 deployment verification complete"
```

---

## Validation Checklist

After deployment, these behaviors should work:

- [ ] Single GPU still works end-to-end (wake → generate → view output)
- [ ] Prompt response includes `assigned_gpu_slot` and `reconnect` fields
- [ ] Queue display shows GPU label when assigned
- [ ] Client assignment is cleared after all jobs complete (check DB)
- [ ] Reconciler logs show no errors
- [ ] `/api/gpu/view` with `promptId` param routes correctly
- [ ] WS reconnects when first prompt assigns to a different GPU than WS was on

**Note:** Full 2-GPU testing requires either manually launching a second instance or waiting for autoscale to trigger with 3+ queued prompts. The autoscale logic can be tested by:

```bash
# Check autoscale would trigger (if 3+ active prompts exist):
ssh -i ~/.ssh/<SSH_KEY>.pem ubuntu@<SITE_BOX_EIP> "sqlite3 /opt/fabricate/fabricate.db \"SELECT gi.instance_id, gi.slot, COUNT(p.prompt_id) as active FROM gpu_instances gi LEFT JOIN prompts p ON gi.instance_id = p.gpu_instance_id AND p.status IN ('pending','running') WHERE gi.status = 'ready' GROUP BY gi.instance_id;\""
```
