# Phase 1: Queue Isolation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Fabrication Terminal usable by multiple people simultaneously — each user sees only their own jobs, can only kill/clear their own work, and gets a queue position indicator.

**Architecture:** Frontend-only changes to `infra/frontend/index.html`. Uses ComfyUI's existing `client_id` mechanism (already sent with prompts and stored in queue `extra_data`). No server-side changes, no infrastructure changes. Deploys by re-uploading the single HTML file to S3.

**Tech Stack:** Vanilla JavaScript (existing SPA), ComfyUI REST API + WebSocket

**Spec:** `docs/superpowers/specs/2026-03-29-multi-user-fabrication-terminal-design.md` — "Multi-User Queue Isolation" section

---

### Task 1: Persist client_id in sessionStorage

**Files:**
- Modify: `infra/frontend/index.html:1640`

Currently `wsClientId` is regenerated on every page load via `crypto.randomUUID()`. This means refreshing the page loses ownership of queued/running jobs. Change to persist in `sessionStorage` so the same tab keeps its identity across refreshes.

- [ ] **Step 1: Change client_id initialization to use sessionStorage**

Find this line (around line 1640):

```javascript
const wsClientId = crypto.randomUUID();
```

Replace with:

```javascript
const wsClientId = sessionStorage.getItem('fabricate_client_id') || crypto.randomUUID();
sessionStorage.setItem('fabricate_client_id', wsClientId);
```

- [ ] **Step 2: Verify in browser**

Open the Fabrication Terminal in a browser tab. Open DevTools console and run:
```javascript
sessionStorage.getItem('fabricate_client_id')
```
Confirm it returns a UUID. Refresh the page. Run the same command. Confirm the UUID is the same.

Open a **new tab** to the same URL. Confirm it gets a **different** UUID.

- [ ] **Step 3: Commit**

```bash
git add infra/frontend/index.html
git commit -m "feat(fabricate): persist client_id in sessionStorage across refreshes"
```

---

### Task 2: Filter reconnectToRunningJobs() by client_id

**Files:**
- Modify: `infra/frontend/index.html:1702-1765`

Currently `reconnectToRunningJobs()` grabs `running[0] || pending[0]` regardless of who submitted it. A second user opening the page would hijack the first user's progress display. Change to only reconnect to jobs that match this tab's `client_id`.

- [ ] **Step 1: Update reconnectToRunningJobs to filter by client_id**

Replace the entire `reconnectToRunningJobs` function (lines ~1702-1765) with:

```javascript
async function reconnectToRunningJobs() {
  try {
    const resp = await fetch(`${API_BASE}/api/queue`);
    if (!resp.ok) return;
    const q = await resp.json();

    const running = q.queue_running || [];
    const pending = q.queue_pending || [];
    if (running.length === 0 && pending.length === 0) return;

    // Each queue entry: [index, prompt_id, prompt_workflow, extra_data, output_node_ids]
    // extra_data.client_id contains the submitter's client_id
    const allJobs = [...running, ...pending];
    const myJob = allJobs.find(job => {
      const extraData = job[3] || {};
      return extraData.client_id === wsClientId;
    });

    if (!myJob) return;  // No jobs belonging to this tab

    const promptId = myJob[1];
    const prompt = myJob[2] || {};
    const isRunning = running.some(j => j[1] === promptId);

    // Extract output prefix and export node from the workflow
    let prefix = null;
    let exportNodeId = null;
    for (const [nodeId, node] of Object.entries(prompt)) {
      if (node.class_type === 'Hy3DExportMesh') {
        prefix = node.inputs?.filename_prefix;
        exportNodeId = nodeId;
      }
    }

    // Build stage map from the workflow
    nodeStageMap = {};
    const stageNames = {
      'LoadImage': 'Loading image',
      'Hy3DModelLoader': 'Loading 3D model into VRAM',
      'Hy3DGenerateMesh': 'Generating mesh (diffusion)',
      'Hy3DVAEDecode': 'Decoding mesh (marching cubes)',
      'Hy3DPostprocessMesh': 'Cleaning up mesh',
      'Hy3DMeshUVWrap': 'Unwrapping UVs',
      'DownloadAndLoadHy3DPaintModel': 'Loading paint model',
      'Hy3DRenderMultiView': 'Rendering multiview',
      'Hy3DSampleMultiView': 'Painting multiview textures',
      'Hy3DBakeFromMultiview': 'Baking texture',
      'Hy3DMeshVerticeInpaintTexture': 'Inpainting texture gaps',
      'CV2InpaintTexture': 'Refining texture',
      'Hy3DApplyTexture': 'Applying texture to mesh',
      'Hy3DExportMesh': 'Exporting GLB',
    };
    for (const [id, node] of Object.entries(prompt)) {
      nodeStageMap[id] = stageNames[node.class_type] || node.class_type;
    }

    // Resume tracking
    currentPromptId = promptId;
    currentExportNodeId = exportNodeId;
    currentOutputPrefix = prefix;
    stageIndex = 0;
    stageTotal = Object.keys(nodeStageMap).length;

    const label = prefix ? prefix.replace(/_3d$/, '').replace(/_/g, ' ') : 'Unknown';
    log(`Reconnected to ${isRunning ? 'running' : 'pending'} job: ${label}`, 'success');
    setGenerating(true, `${isRunning ? 'Fabricating' : 'Queued'}: ${label}...`);
    startPolling();
  } catch {}
}
```

- [ ] **Step 2: Test with two tabs**

1. Open Tab A, submit a generation.
2. While it's running, open Tab B to the same URL.
3. Confirm Tab B does **not** show Tab A's progress (no "Reconnected to running job" log).
4. Confirm Tab A still shows its own progress normally.
5. Refresh Tab A — confirm it reconnects to its own running job.

- [ ] **Step 3: Commit**

```bash
git add infra/frontend/index.html
git commit -m "feat(fabricate): only reconnect to own jobs via client_id filtering"
```

---

### Task 3: Per-user Kill button

**Files:**
- Modify: `infra/frontend/index.html:1946-1952`

Currently the Kill button calls `/api/interrupt` unconditionally, killing whoever's job is running. Change to only allow killing if the running job belongs to this client. If it's someone else's job, disable the button with a tooltip.

- [ ] **Step 1: Add helper function to check running job ownership**

Add this function right before the `bindEvents()` function definition (around line 1920):

```javascript
async function getRunningJobClientId() {
  try {
    const resp = await fetch(`${API_BASE}/api/queue`);
    if (!resp.ok) return null;
    const q = await resp.json();
    const running = q.queue_running || [];
    if (running.length === 0) return null;
    const extraData = running[0][3] || {};
    return extraData.client_id || null;
  } catch { return null; }
}
```

- [ ] **Step 2: Update Kill button handler**

Replace the Kill button event listener (lines ~1946-1952):

```javascript
  $('btnKill').addEventListener('click', async () => {
    try {
      await fetch(`${API_BASE}/api/interrupt`, { method: 'POST' });
      log('Interrupted running job', 'error');
      setGenerating(false);
      setStatus('Interrupted', 'error');
    } catch (e) { log('Kill failed: ' + e.message, 'error'); }
  });
```

With:

```javascript
  $('btnKill').addEventListener('click', async () => {
    try {
      const runningClientId = await getRunningJobClientId();
      if (runningClientId && runningClientId !== wsClientId) {
        log('Cannot kill — another user\'s job is running', 'error');
        return;
      }
      await fetch(`${API_BASE}/api/interrupt`, { method: 'POST' });
      log('Interrupted running job', 'error');
      setGenerating(false);
      setStatus('Interrupted', 'error');
    } catch (e) { log('Kill failed: ' + e.message, 'error'); }
  });
```

- [ ] **Step 3: Test kill isolation**

1. Open Tab A, submit a generation.
2. Open Tab B, click Kill.
3. Confirm Tab B's log shows "Cannot kill — another user's job is running".
4. Confirm Tab A's job continues running.
5. In Tab A, click Kill. Confirm it works.

- [ ] **Step 4: Commit**

```bash
git add infra/frontend/index.html
git commit -m "feat(fabricate): kill button only affects own running jobs"
```

---

### Task 4: Per-user Clear Queue

**Files:**
- Modify: `infra/frontend/index.html:1954-1963`

Currently Clear Queue sends `{ clear: true }` which wipes all pending jobs for all users. Change to selectively delete only this client's pending jobs using ComfyUI's `{ delete: [prompt_id, ...] }` API.

- [ ] **Step 1: Update Clear Queue handler**

Replace the Clear Queue event listener (lines ~1954-1963):

```javascript
  $('btnClearQueue').addEventListener('click', async () => {
    try {
      await fetch(`${API_BASE}/api/queue`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ clear: true })
      });
      log('Queue cleared', 'error');
    } catch (e) { log('Clear failed: ' + e.message, 'error'); }
  });
```

With:

```javascript
  $('btnClearQueue').addEventListener('click', async () => {
    try {
      // Get current queue and find only our pending jobs
      const resp = await fetch(`${API_BASE}/api/queue`);
      if (!resp.ok) { log('Clear failed: could not fetch queue', 'error'); return; }
      const q = await resp.json();
      const pending = q.queue_pending || [];

      const myPendingIds = pending
        .filter(job => {
          const extraData = job[3] || {};
          return extraData.client_id === wsClientId;
        })
        .map(job => job[1]);

      if (myPendingIds.length === 0) {
        log('No pending jobs to clear');
        return;
      }

      // ComfyUI API: { delete: [prompt_id, ...] } removes specific entries
      await fetch(`${API_BASE}/api/queue`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ delete: myPendingIds })
      });
      log(`Cleared ${myPendingIds.length} pending job(s)`, 'error');
    } catch (e) { log('Clear failed: ' + e.message, 'error'); }
  });
```

- [ ] **Step 2: Test selective clearing**

1. Open Tab A, submit 3 generations (they'll queue).
2. Open Tab B, submit 1 generation (it'll queue behind A's).
3. In Tab B, click Clear Queue.
4. Confirm only Tab B's 1 pending job is removed.
5. Confirm Tab A's 3 jobs are still in the queue.

- [ ] **Step 3: Commit**

```bash
git add infra/frontend/index.html
git commit -m "feat(fabricate): clear queue only removes own pending jobs"
```

---

### Task 5: Queue position indicator

**Files:**
- Modify: `infra/frontend/index.html:1777-1800` (checkConnection function)
- Modify: `infra/frontend/index.html:1214` (queue status display area)

Add a per-user queue position display. When this user has pending jobs, show "Your job is #N in queue" in the status bar. Also show total queue info for context.

- [ ] **Step 1: Update checkConnection to show per-user queue position**

Replace the `checkConnection` function (lines ~1777-1800):

```javascript
async function checkConnection() {
  try {
    const resp = await fetch(`${API_BASE}/api/system_stats`, { signal: AbortSignal.timeout(5000) });
    if (resp.ok) {
      connDot.classList.add('connected');
      connText.textContent = 'ComfyUI Online';
      // Check queue
      const qResp = await fetch(`${API_BASE}/api/queue`);
      const q = await qResp.json();
      const running = q.queue_running?.length || 0;
      const pending = q.queue_pending?.length || 0;
      queueStatus.textContent = running > 0
        ? `Queue: ${running} running, ${pending} pending`
        : pending > 0 ? `Queue: ${pending} pending` : '';
    }
  } catch {
    // Don't show "Offline" during active generation — ComfyUI is just busy on GPU
    if (!currentPromptId) {
      connDot.classList.remove('connected');
      connText.textContent = 'Offline';
      queueStatus.textContent = '';
    }
  }
}
```

With:

```javascript
async function checkConnection() {
  try {
    const resp = await fetch(`${API_BASE}/api/system_stats`, { signal: AbortSignal.timeout(5000) });
    if (resp.ok) {
      connDot.classList.add('connected');
      connText.textContent = 'ComfyUI Online';
      // Check queue with per-user position
      const qResp = await fetch(`${API_BASE}/api/queue`);
      const q = await qResp.json();
      const running = q.queue_running || [];
      const pending = q.queue_pending || [];
      const totalRunning = running.length;
      const totalPending = pending.length;

      // Find this user's position in the queue
      let myPosition = -1;
      for (let i = 0; i < pending.length; i++) {
        const extraData = pending[i][3] || {};
        if (extraData.client_id === wsClientId) {
          // Position = jobs running (1) + jobs ahead in pending queue
          myPosition = totalRunning + i + 1;
          break;
        }
      }
      // Also check if our job is the one running
      const myJobRunning = running.some(j => (j[3] || {}).client_id === wsClientId);

      let statusText = '';
      if (totalRunning > 0 || totalPending > 0) {
        statusText = `Queue: ${totalRunning} running, ${totalPending} pending`;
        if (myPosition > 0) {
          const estMinutes = myPosition * 2;  // ~2 min per generation
          statusText += ` | Your job: #${myPosition} (~${estMinutes}m)`;
        }
      }
      queueStatus.textContent = statusText;
    }
  } catch {
    if (!currentPromptId) {
      connDot.classList.remove('connected');
      connText.textContent = 'Offline';
      queueStatus.textContent = '';
    }
  }
}
```

- [ ] **Step 2: Test queue position display**

1. Open Tab A, submit a generation.
2. Open Tab B, submit a generation (it'll be pending behind A's).
3. Confirm Tab B's status bar shows something like "Queue: 1 running, 1 pending | Your job: #2 (~4m)".
4. Confirm Tab A's status bar shows "Queue: 1 running, 1 pending" (no position — their job is the one running).
5. When Tab A's job finishes, confirm Tab B's job starts and position indicator disappears.

- [ ] **Step 3: Commit**

```bash
git add infra/frontend/index.html
git commit -m "feat(fabricate): show per-user queue position in status bar"
```

---

### Task 6: Update Clear Queue button label

**Files:**
- Modify: `infra/frontend/index.html:1533`

Small UX change — rename "Clear Queue" to "Clear My Queue" so users understand the scope.

- [ ] **Step 1: Update button text and title**

Find (around line 1533):

```html
          <button class="btn-action btn-danger" id="btnClearQueue" title="Remove all pending jobs from the queue">Clear Queue</button>
```

Replace with:

```html
          <button class="btn-action btn-danger" id="btnClearQueue" title="Remove your pending jobs from the queue">Clear My Queue</button>
```

- [ ] **Step 2: Commit**

```bash
git add infra/frontend/index.html
git commit -m "feat(fabricate): rename Clear Queue to Clear My Queue"
```

---

### Task 7: Deploy updated frontend

**Files:**
- Deploy: `infra/frontend/index.html` → S3

Upload the modified frontend to S3 so the next GPU instance picks it up. Also update the live custom node if a GPU is currently running.

- [ ] **Step 1: Upload to S3**

```bash
aws s3 cp infra/frontend/index.html s3://prismata-3d-models/frontend/index.html --region us-east-1
```

Expected output: `upload: infra/frontend/index.html to s3://prismata-3d-models/frontend/index.html`

- [ ] **Step 2: Verify upload**

```bash
aws s3 ls s3://prismata-3d-models/frontend/index.html --region us-east-1
```

Confirm the file exists with a recent timestamp.

- [ ] **Step 3: Commit all changes if not already committed**

```bash
git status
```

If there are uncommitted changes:

```bash
git add infra/frontend/index.html
git commit -m "feat(fabricate): phase 1 queue isolation — deploy to S3"
```

---

### Task 8: End-to-end verification

No files changed — this is a manual test pass.

- [ ] **Step 1: Test client_id persistence**

Open Fabrication Terminal. Check `sessionStorage.getItem('fabricate_client_id')` in DevTools. Refresh. Confirm same UUID. Open new tab — confirm different UUID.

- [ ] **Step 2: Test reconnect isolation**

Tab A: submit generation. Tab B: open page. Confirm Tab B does not reconnect to Tab A's job. Refresh Tab A — confirm it reconnects to its own job.

- [ ] **Step 3: Test kill isolation**

Tab A: submit generation. Tab B: click Kill. Confirm refused. Tab A: click Kill. Confirm works.

- [ ] **Step 4: Test clear queue isolation**

Tab A: submit 2 jobs. Tab B: submit 1 job. Tab B: click Clear My Queue. Confirm only Tab B's job removed. Tab A's jobs unchanged.

- [ ] **Step 5: Test queue position**

Tab A: submit generation. Tab B: submit generation. Confirm Tab B shows position indicator. When Tab A's job finishes, confirm Tab B's job starts and indicator disappears.
