# Phase 4: Two-GPU Sticky Assignment — Design Spec

**Date:** 2026-03-29
**Status:** Approved for implementation
**Depends on:** Phases 1-3 (deployed)
**Parent spec:** `docs/superpowers/specs/2026-03-29-multi-user-fabrication-terminal-design.md`

## Overview

Add a second GPU slot (B) with sticky client-to-GPU assignment. Clients are lazily assigned to the least-loaded GPU on first prompt submission. Assignments are ephemeral — cleared when the client has no active work. The reconciler auto-scales to GPU B when demand warrants it.

Hard cap: 2 GPU instances (slots A and B). No general-purpose pool scheduler.

## Design Decisions

These were resolved during brainstorming and are not open for re-discussion:

1. **Scale-up trigger uses SQLite, not ComfyUI queue polling.** The reconciler counts active prompts (`pending` + `running`) in the `prompts` table. No dependency on GPU health for scale-up decisions.

2. **Strict sticky — no job migration.** When GPU B launches, existing clients stay on GPU A. GPU B only serves new clients (or existing clients whose assignment was cleared). No migration button.

3. **Lazy assignment on first prompt submission.** Clients are not assigned to a GPU on connect, session creation, or queue polling — only when they submit their first prompt. This prevents the scenario where a client browses for a while and gets stuck on a now-overloaded GPU.

4. **Ephemeral assignments.** Once a client has zero active prompts (`pending` + `running`) on their assigned GPU, the assignment is cleared. Next prompt goes to whichever GPU is least loaded.

5. **Four prompt statuses only:** `pending | running | completed | failed`. No `interrupted` or `deleted` — both resolve to `failed` from the DB's perspective.

6. **WS sniffing is the fast path, reconciler is eventual correctness.** Prompt status updates come primarily from the WebSocket tap (low latency), but the reconciler periodically verifies active prompts against ComfyUI's queue/history to catch missed events.

7. **Prompt rows inserted after ComfyUI acceptance only.** No phantom pending prompts. Assignment is also persisted only after ComfyUI accepts the prompt.

## Schema Changes

### `prompts` table — new columns

| Column | Type | Default | Description |
|--------|------|---------|-------------|
| `status` | TEXT | `'pending'` | `pending \| running \| completed \| failed` |
| `started_at` | INTEGER | NULL | Epoch seconds, set on `pending → running` |
| `finished_at` | INTEGER | NULL | Epoch seconds, set on any terminal state |
| `updated_at` | INTEGER | NULL | Epoch seconds, bumped on every status change |

### New indexes

| Table | Columns | Notes |
|-------|---------|-------|
| `gpu_instances` | `(status)` | Active GPU count queries |
| `gpu_instances` | `(slot) WHERE status IN ('launching', 'ready')` | Partial unique index — enforces at most one active GPU per slot |
| `prompts` | `(status, gpu_instance_id)` | Load-balancing queries |
| `prompts` | `(client_id, gpu_instance_id, status)` | Assignment cleanup queries |
| `client_assignments` | `(gpu_instance_id)` | Bulk cleanup on GPU gone |

### Monotonic prompt transitions

`updatePromptStatus(promptId, newStatus)` enforces:

```
pending  → running, completed, failed
running  → completed, failed
```

All other transitions are silently rejected (function returns false). This protects against races between WS tap, reconciler, and API handlers. Every accepted transition bumps `updated_at`. Terminal transitions (`completed`, `failed`) also set `finished_at`. The `pending → running` transition sets `started_at`.

## DB Functions

### New functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `getActiveGpuCount()` | `() → number` | Count GPUs with status `launching` or `ready` |
| `getReadyGpus()` | `() → row[]` | All GPUs with status `ready` |
| `getLaunchingGpus()` | `() → row[]` | All GPUs with status `launching` |
| `getNextSlot()` | `() → 'A' \| 'B'` | Returns `'A'` if no active GPU holds slot A, else `'B'` |
| `getLeastLoadedGpu()` | `() → row \| null` | Counts `pending` + `running` prompts per ready GPU. Returns GPU with fewer. Ties → older instance (earlier `launched_at`). |
| `getClientActivePromptCount(clientId, gpuInstanceId)` | `(string, string) → number` | Count `pending` + `running` prompts for client on that GPU |
| `clearClientAssignment(clientId)` | `(string) → void` | Delete assignment row |
| `updatePromptStatus(promptId, newStatus)` | `(string, string) → boolean` | Monotonic transition with timestamp updates. Returns false if rejected. |
| `failPromptsForGoneGpu(instanceId)` | `(string) → number` | Bulk-update all `pending`/`running` prompts on instance → `failed`. Returns count affected. |
| `getStaleActivePrompts(gpuInstanceId, graceSeconds)` | `(string, number) → row[]` | Active prompts where `updated_at` is older than `now - graceSeconds`. For reconciler verification. |
| `touchPrompt(promptId)` | `(string) → void` | Bump `updated_at` only. Used by reconciler when a prompt is still in ComfyUI's pending queue (no state change, just confirms it's alive). |

### Existing functions — unchanged

| Function | Notes |
|----------|-------|
| `getReadyGpu()` | Returns first ready GPU. Used for "is any GPU up?" checks. **Not used for placement.** |
| `getClientAssignment(clientId)` | Returns assignment if GPU is ready |
| `assignClient(clientId, gpuInstanceId)` | UPSERT (INSERT ... ON CONFLICT UPDATE), not REPLACE (which has delete/insert semantics in SQLite) |
| `touchClient(clientId)` | Update `last_seen_at` |
| `markGpuGone(instanceId)` | Already clears client assignments. Now also calls `failPromptsForGoneGpu()`. |
| `registerGpuInstance(instanceId, slot, sessionId)` | Accepts slot param — reconciler now passes A or B |
| `cleanStaleClientAssignments()` | 1-hour timeout cleanup — kept as safety net alongside active-prompt-based cleanup |
| `insertPrompt(promptId, clientId, gpuInstanceId)` | Existing insert — now sets `status='pending'`, `submitted_at`, and `updated_at` |

## Reconciler (`lib/reconciler.js`)

Loop interval stays at 5 seconds. Three new responsibilities.

### 1. GPU Launch — Two Distinct Paths

**First GPU (wake on demand):**

```
if activeGpuCount === 0
   AND session is active
   AND wake_requested_at is set
   AND getLaunchingGpus().length === 0:
  → launch GPU on slot from getNextSlot()
```

**Second GPU (autoscale):**

```
if activeGpuCount === 1
   AND session is active
   AND getReadyGpus().length === 1       // exactly 1 ready
   AND getLaunchingGpus().length === 0    // nothing in flight
   AND shouldScaleUp() is true:
  → launch GPU on slot from getNextSlot()
```

**`shouldScaleUp()` logic:**

```
for the single ready GPU:
  count = pending + running prompts (from prompts table)
  return count >= 3
```

Threshold of 3 active prompts. At ~2 min per generation, that's ~6 min of queue. GPU B boots in ~3 min, so it's ready before the queue drains.

**Slot uniqueness:** Before launching, reconciler verifies no active GPU already holds the target slot (defensive check on top of partial unique index).

**EC2 tags:** `Slot: A|B` and `SessionId` on launch, for rediscovery after reconciler restart.

### 2. Prompt Reconciliation (eventual correctness)

Runs every 30 seconds (every 6th tick):

```
for each ready GPU:
  stalePrompts = getStaleActivePrompts(gpuInstanceId, graceSeconds=60)
  if none: continue

  queue = fetch GPU /api/queue
  history = {} (fetched per-prompt as needed)

  for each stale prompt:
    if prompt_id found in queue.queue_running → updatePromptStatus('running')
    if prompt_id found in queue.queue_pending → touchPrompt(promptId)
    if prompt_id not in queue:
      historyResp = fetch GPU /api/history/{prompt_id}
      if history exists and no error marker → updatePromptStatus('completed')
      else → updatePromptStatus('failed')
```

**History success criterion:** `history[prompt_id]` exists AND contains outputs for at least one node with a non-empty result AND does not contain an execution error status. This is intentionally generic — not hardcoded to `images` output, since fabrication workflows produce mesh/export outputs. During implementation, log real ComfyUI history responses to define the concrete success test.

**Grace period:** 60 seconds from last `updated_at`. Avoids racing with normal WS updates on fresh prompts.

### 3. Assignment Cleanup

After prompt reconciliation, every tick:

```
for each client assignment:
  count = getClientActivePromptCount(clientId, gpuInstanceId)
  if count === 0:
    clearClientAssignment(clientId)
```

### 4. GPU Gone Cleanup (modified)

When `markGpuGone()` is called:
- Client assignments for that GPU are cleared (existing behavior)
- `failPromptsForGoneGpu(instanceId)` marks orphaned active prompts as `failed` (new)

## WebSocket Tap (`server.js`)

The WS proxy already relays all messages between client and ComfyUI. A lightweight tap is added on GPU→client messages:

```
on upstream GPU message:
  if not text frame: skip
  try:
    msg = JSON.parse(data)
    if msg indicates execution started:
      db.updatePromptStatus(promptId, 'running')
    if msg indicates execution completed successfully:
      db.updatePromptStatus(promptId, 'completed')
    if msg indicates execution error:
      db.updatePromptStatus(promptId, 'failed')
  catch: skip (don't break relay on parse failure)

  relay message to client unchanged
```

**Important:** Exact ComfyUI WebSocket event names and payload structure must be validated by logging real frames before hardcoding the tap logic. The monotonic transition rules make this safe even if events are duplicated or arrive out of order.

### WebSocket GPU Resolution (modified)

Current: `db.getReadyGpu()` returns one GPU. WS connect eagerly assigns client.

New behavior:
- Check `db.getClientAssignment(clientId)` first. If assigned and GPU is ready, connect to that GPU.
- If no assignment, connect to any ready GPU (for queue polling before first prompt).
- **Assignment is NOT created on WS connect** — only on prompt submission.
- **WS reconnect on assignment change:** When `POST /api/gpu/prompt` assigns the client to a different GPU than their current WS connection, the response includes `assigned_gpu_slot` and `reconnect: true`. The frontend closes the current WS and reconnects, which routes to the newly assigned GPU. See Frontend section.

## GPU Routes (`routes/gpu.js`)

### Prompt Submission (`POST /api/gpu/prompt`) — modified flow

```
1. Extract client_id from request
2. Check existing assignment: db.getClientAssignment(clientId)
3. If assigned and GPU ready → targetGpu = assigned GPU
4. If not assigned → targetGpu = db.getLeastLoadedGpu()
5. If no GPU available → return 503

6. Forward prompt to targetGpu ComfyUI /api/prompt
7. If ComfyUI returns error → return error, no DB changes
8. If ComfyUI returns 200 with prompt_id:
   a. If client was not assigned → db.assignClient(clientId, targetGpu.id)
   b. db.insertPrompt(promptId, clientId, targetGpu.id, status='pending')
   c. Return success with prompt_id, assigned_gpu_slot, reconnect flag
```

Key: assignment and prompt row are persisted only after ComfyUI accepts. If the forward fails, no state changes.

The response includes:
- `prompt_id` — as before
- `assigned_gpu_slot` — `'A'` or `'B'`, for frontend display
- `reconnect` — `true` if this is a new assignment or assignment changed, `false` if already assigned to this GPU. Frontend uses this to trigger WS reconnect.

### Queue (`GET /api/gpu/queue`) — minor change

Route to client's assigned GPU if they have one. If no assignment, route to any ready GPU (client is browsing, hasn't submitted yet).

### History (`GET /api/gpu/history/:promptId`) — unchanged

Already looks up GPU per-prompt via `db.getPromptGpu(promptId)`. Works correctly across GPU reassignment.

### Interrupt (`POST /api/gpu/interrupt`) — unchanged

Server-side ownership enforcement already implemented in Phase 3 (lines 268-284 of current code). Fetches queue, checks running job's `client_id`, returns 403 if not owner.

### Queue Delete (`POST /api/gpu/queue`) — unchanged

Server-side ownership enforcement already implemented in Phase 3 (lines 309-319). Ignores client-supplied IDs, computes owned pending IDs server-side.

### View (`GET /api/gpu/view`) — prompt-aware routing

Current code routes to `db.getReadyGpu()` with no prompt awareness. With ephemeral assignments and 2 GPUs, a client may view output from a prompt that ran on a GPU they're no longer assigned to.

New behavior:
- Frontend includes `promptId` query parameter when requesting generated artifacts
- Server resolves GPU via `db.getPromptGpu(promptId)` — same lookup as `/history`
- Falls back to client's assigned GPU, then any ready GPU, for non-prompt-specific files (e.g. sprite previews)

## Frontend (`infra/frontend/index.html`)

### GPU label
- **No GPU selector UI.** Clients don't choose their GPU.
- **Subtle GPU label:** Show "GPU A" or "GPU B" next to queue status when assigned. Sourced from the `assigned_gpu_slot` field returned by `POST /api/gpu/prompt`. Cached client-side; updated on each prompt submission response.

### WebSocket reconnect on assignment
- When prompt response includes `reconnect: true`, frontend closes current WS and reconnects
- New WS connect routes to the assigned GPU via `db.getClientAssignment(clientId)` in `server.js`
- This handles the lazy-assignment race: WS may initially connect to GPU A for queue polling, but after first prompt lands on GPU B, WS reconnects to B for progress updates

### Queue display
- Already filters by `client_id` — works as-is with multi-GPU

### GPU death recovery
- If assigned GPU dies, WS drops. Frontend shows "GPU offline" as today.
- Next prompt submission triggers reassignment to surviving GPU. WS reconnects automatically.
- If no GPUs exist, prompt returns 503. User must click Wake GPU (Phase 3 behavior preserved).

## Error Handling & Edge Cases

| Scenario | Behavior |
|----------|----------|
| GPU A spot reclaim | Reconciler marks gone, clears assignments, fails orphaned prompts. Affected clients reassigned on next prompt. |
| GPU B idle timeout (20 min) | Watchdog self-terminates. Reconciler marks gone, clears assignments. Clients reassigned to GPU A. |
| Both GPUs die simultaneously | Both marked gone. Prompt returns 503. User must click Wake GPU (Phase 3 behavior — no auto-wake from prompt submission). |
| Client submits during GPU B launch | Assigned to GPU A (only ready GPU). GPU B serves future clients. |
| Reconciler restart | Rediscovers GPUs via EC2 tags (Slot + SessionId). Reconstructs state from DB + EC2 API. |
| Prompt stuck in `running` (WS missed) | Reconciler catches it after 60s via `getStaleActivePrompts()`, verifies against ComfyUI queue/history. |
| Scale-up during GPU A health check failure | `getReadyGpus().length === 1` check prevents scale-up if GPU A is unhealthy (not ready). |
| WS on GPU A, first prompt goes to GPU B | Prompt response includes `reconnect: true`. Frontend drops WS to A, reconnects to B. |
| Client views output from old GPU | Frontend passes `promptId` to `/view`. Server routes to correct GPU via `db.getPromptGpu()`. |

## Implementation Notes

- WS tap: only parse text frames, ignore binary, narrow try/catch around JSON.parse
- Autoscale guard: require exactly 1 ready + 0 launching before considering GPU B
- Prompt reconciliation: per-prompt `/api/history/{id}` lookups, not bulk history fetch
- Scale-up cost: GPU B self-terminates after 20 min idle (~$0.15 worst case for false scale-up)
- Threshold of 3: at ~2 min/gen, 3 pending = ~6 min queue. GPU B boots in ~3 min. Queue still has ~3 min when B is ready.

## Files to Modify

| File | Changes |
|------|---------|
| `lib/db.js` | New columns, indexes, 10 new/modified functions |
| `lib/reconciler.js` | Two-path launch, shouldScaleUp(), prompt reconciliation loop, assignment cleanup |
| `server.js` | WS tap for prompt status, multi-GPU WS resolution |
| `routes/gpu.js` | Lazy assignment in prompt submission, multi-GPU routing |
| `infra/frontend/index.html` | Subtle GPU label display |

## What This Does NOT Include

- Migration button (deferred — may never be needed with lazy assignment)
- 3+ GPU support (YAGNI — hard cap at 2)
- Per-GPU queue display in frontend (single queue view is sufficient)
- Prompt failure_reason column (can add later if needed for UI)
- Phase 5 polish items (separate spec)
