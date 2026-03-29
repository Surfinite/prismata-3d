# Multi-User Fabrication Terminal — Design Spec

**Date:** 2026-03-29
**Status:** Draft v2
**Author:** Surfinite + Claude
**Reviewed by:** GPT-5.4

## Problem

The Fabrication Terminal (Prismata 3D model generator) currently runs entirely on a GPU spot instance. When the GPU shuts down, the frontend disappears. Multiple users on the same link have no queue isolation. There is no way to share access without manually launching instances via Discord bot.

## Vision

`fabricate.prismata.live` — an always-available web UI where users can browse generated 3D models, request GPU access for generation, and share a single GPU (or two) with proper queue isolation. The GPU auto-sleeps when idle and auto-wakes when needed, within an owner-approved session window.

## Architecture

### Two Tiers

**Tier 1: Site Box** (existing `t3.micro spot`, EIP `<SITE_BOX_EIP>`)
- Hosts `fabricate.prismata.live` alongside `prismata.live`
- Nginx vhost reverse-proxies to a Node API process (port 3100)
- Serves the static SPA (index.html, manifest.json, descriptions.json)
- Handles S3 API routes (favorites, reject, model metadata checks)
- Issues presigned S3 URLs for model downloads (GLB files served directly from S3, not proxied through Node)
- Manages GPU session state via SQLite (`/opt/fabricate/fabricate.db`)
- Sends Discord webhook notifications for access requests
- Polls Discord API for approval reactions
- Proxies ComfyUI API and WebSocket traffic to GPU private IP
- Runs a **reconciler loop** (sole owner of all EC2 launch/terminate actions)

**Tier 2: GPU Instances** (g5.xlarge spot, max 2)
- Same as today: ComfyUI + Hunyuan3D + warmup
- No Cloudflare tunnel — site box connects via VPC private IP on port 8188
- Site box discovers private IP via EC2 API (no SSM writes needed from GPU)
- 20-minute idle GPU timeout (nvidia-smi based, existing watchdog)
- Output sync to S3 (unchanged)

### What Gets Retired

- **Discord bot** (`bot.py`, `ec2_manager.py`, `config.py`) — replaced by session management on site box. Keep running until new control plane is proven stable, then decommission.
- **Cloudflare tunnel** (`cloudflared` in user-data.sh) — replaced by VPC private IP
- **Manual `!start`/`!stop`** — replaced by auto-wake within sessions
- **SSM IP writes from GPU** — site box discovers IPs via EC2 API

### What Gets Reused

- `idle-watchdog.sh` — unchanged, stays on GPU (threshold updated to 20 min)
- `output-sync.sh` — unchanged, stays on GPU
- `warmup.sh` — unchanged, stays on GPU
- `install-comfyui.sh`, `install-assets.sh`, `install-frontend.sh` — unchanged for AMI build
- All S3 structure (`models/`, `favorites/`, `rejections/`) — unchanged

## Frontend States

The SPA has seven states based on GPU and session status:

| State | Condition | User Sees | Available Actions |
|---|---|---|---|
| **Browse** | No active session | "GPU offline" banner | Browse models, 3D preview, favorites, generation history |
| **Requesting** | Request sent, awaiting approval | "Access requested — waiting for approval..." | Same as Browse + pending indicator |
| **Request Expired** | Pending request timed out (1h TTL) | "Request expired. Try again?" | Same as Browse + retry button |
| **Starting** | Session active, GPU booting | "GPU starting up (~4 min)..." | Same as Browse + progress indicator |
| **Ready** | Session active, GPU connected | Full generation UI | Generate, queue, download, favorite, reject |
| **Launch Failed** | GPU failed to start (spot capacity, etc.) | "GPU unavailable — no spot capacity. Try again later." | Same as Browse |
| **Session Expired** | 24h session window ended | "Session expired. Request new access." | Same as Browse + request button |

### State Transitions

```
Browse ──[click Request Access]──► Requesting
Requesting ──[owner reacts ✅]──► Starting
Requesting ──[1h TTL expires]──► Request Expired
Request Expired ──[click Retry]──► Requesting
Starting ──[GPU warm, health check passes]──► Ready
Starting ──[spot capacity fail / launch error]──► Launch Failed
Launch Failed ──[click Retry]──► Starting (if session still active)
Ready ──[GPU idle 20min]──► Starting (auto-wake, session still active)
Ready ──[session expires 24h]──► Session Expired
Starting ──[session expires 24h]──► Session Expired
Session Expired ──[click Request Access]──► Requesting
```

The frontend polls `/api/status` (read-only) for state changes:
- **Browse / Session Expired**: every 30s (low frequency)
- **Requesting**: every 5s (waiting for approval)
- **Starting**: every 5s (waiting for GPU)
- **Ready**: every 15s (monitoring session countdown + GPU health)

`/api/status` is **strictly read-only**. It never triggers launches or side effects.

## Reconciler Loop

A single background loop running on the site box every 5 seconds. This is the **sole owner** of all EC2 launch/terminate decisions. No API endpoint directly calls EC2.

### Each tick:

1. **Check session state** — is there an active session? Is it expired?
2. **Check EC2 instances** — query EC2 for running instances with `Project=prismata-3d-gen` tag. Get private IPs, lifecycle state.
3. **Health-check running GPUs** — `GET http://{private_ip}:8188/system_stats`. Mark as `ready` only after successful response. Mark as `gone` if instance no longer in EC2 results.
4. **Check queue depth** — if GPU(s) ready, query `/api/queue` on each. Sum pending jobs.
5. **Reconcile desired vs actual state:**
   - Session active + no GPU running + no launch in progress → **launch GPU** (set `launch_in_progress = true`, record timestamp)
   - Session active + 1 GPU ready + queue depth >= 3 + no second GPU → **launch second GPU**
   - Launch in progress + instance running + health check passes → **mark ready**, clear `launch_in_progress`
   - Launch in progress + >5 min elapsed + no instance → **mark launch failed**, clear `launch_in_progress`
   - Instance in EC2 but not in DB → **register it** (discovered instance)
   - Instance in DB but not in EC2 → **mark gone**, clean up client assignments
   - Session expired + GPUs running → **let watchdog handle shutdown** (don't force-terminate, let idle timeout work)
6. **Clean up stale requests** — pending requests older than 1h → expire them
7. **Clean up stale client assignments** — assignments with `last_seen_at` > 1h ago → remove

### Launch Lock

Only one launch at a time. `launch_in_progress` flag with timestamp prevents duplicate launches from concurrent reconciler ticks. Cooldown of 60 seconds between launch attempts (prevents rapid retry on transient failures).

## Request and Session State Machine

### Request States

```
none ──[user clicks Request Access]──► pending
pending ──[owner reacts ✅]──► approved (creates session)
pending ──[1h TTL expires]──► expired
pending ──[owner reacts ❌]──► denied
expired ──[user clicks Retry]──► pending (new request)
denied ──[user clicks Request Again]──► pending (new request)
```

### Session States

```
inactive ──[request approved]──► active
active ──[24h expires]──► expired
active ──[owner revokes via CLI]──► revoked
expired / revoked → treated as inactive
```

### Stored State

Primary source of truth: **SQLite** on site box (`/opt/fabricate/fabricate.db`).

Recovery on site box restart: SQLite file persists on disk. If site box is spot-reclaimed and relaunched, the EBS volume is gone — but the reconciler loop will rediscover running GPU instances via EC2 API and reconstruct operational state. Session approval state is also cached in SSM (`/prismata-3d/session`) as a backup for this scenario.

## SQLite Schema

```sql
CREATE TABLE requests (
    id INTEGER PRIMARY KEY,
    status TEXT NOT NULL DEFAULT 'pending',  -- pending, approved, expired, denied
    requested_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,                 -- request TTL (1h)
    discord_message_id TEXT,
    discord_channel_id TEXT,
    approved_by TEXT,
    approved_at TEXT
);

CREATE TABLE sessions (
    id INTEGER PRIMARY KEY,
    status TEXT NOT NULL DEFAULT 'active',    -- active, expired, revoked
    approved_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,                 -- session TTL (24h)
    request_id INTEGER REFERENCES requests(id),
    revoked_at TEXT
);

CREATE TABLE gpu_instances (
    instance_id TEXT PRIMARY KEY,
    slot TEXT NOT NULL,                       -- 'A' or 'B'
    private_ip TEXT,
    status TEXT NOT NULL DEFAULT 'launching', -- launching, ready, gone
    launched_at TEXT NOT NULL,
    ready_at TEXT,
    gone_at TEXT,
    session_id INTEGER REFERENCES sessions(id)
);

CREATE TABLE client_assignments (
    client_id TEXT PRIMARY KEY,
    gpu_instance_id TEXT REFERENCES gpu_instances(instance_id),
    assigned_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL
);

CREATE TABLE prompts (
    prompt_id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL,
    gpu_instance_id TEXT NOT NULL,
    submitted_at TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending'    -- pending, running, completed, failed
);
```

## Multi-User Queue Isolation

### Client ID Persistence

`client_id` stored in `sessionStorage` (persists across page refresh within the same tab, new tab gets new ID). This is **cooperative UX isolation** for trusted users, not security enforcement.

### Phase 1 (This Spec)

Frontend-side isolation using ComfyUI's existing `client_id` mechanism:

- Each browser tab has a unique `client_id` (stored in `sessionStorage`)
- `client_id` is sent with each `/api/prompt` submission (already exists in ComfyUI protocol)
- ComfyUI stores `client_id` in queue entry `extra_data` (already exists)

**Changes needed:**

1. **`reconnectToRunningJobs()`** — filter by `client_id`. Only reconnect to jobs submitted by this tab, not any random running job.
2. **Kill button** — only interrupt if the currently running job's `client_id` matches. Otherwise disable with tooltip "Another user's job is running."
3. **Clear Queue** — only delete pending entries whose `client_id` matches, not the entire queue.
4. **Queue position indicator** — count pending entries ahead of this user's first pending job. Show "Your job is #N in queue (~Xm wait)".
5. **WebSocket progress filtering** — already filters by `prompt_id` (working correctly today).

### Phase 2 (Future, Not This Spec)

Round-robin fairness via a queue proxy on the site box. Deferred until concurrent usage patterns are observed.

## Two-GPU Sticky Assignment Model

Hard cap of 2 GPU instances. Rather than building a general multi-GPU scheduler, this uses a simple **sticky client-to-GPU assignment** model.

### Core Rules

1. **Each `client_id` is pinned to exactly one GPU.** A client never has jobs on both GPUs simultaneously.
2. **Assignment happens on first prompt submission.** If the client has no assignment (or their assigned GPU is gone), assign to the GPU with fewer pending jobs.
3. **Existing clients stay on their assigned GPU.** No rebalancing of in-flight or queued work.
4. **GPU B is overflow for new clients.** When GPU A's queue is deep enough, the reconciler launches GPU B. New clients get assigned to GPU B. Existing GPU A clients stay on GPU A.
5. **All state in SQLite.** The `client_assignments` and `prompts` tables track who is where.

### What This Simplifies

- **WebSocket**: each client connects to their assigned GPU only. No cross-GPU WS multiplexing.
- **Queue/History**: routed to the client's assigned GPU. No aggregate queue merging.
- **Kill/Clear**: routed to the client's assigned GPU. No cross-instance lookups.
- **Reconnect**: trivial — look up `client_id` in `client_assignments`, proxy to that GPU.

### What This Trades Off

- One user's burst of jobs won't automatically split across both GPUs.
- Total utilization isn't globally optimal.
- For max 2 GPUs with 2-3 concurrent users, this is an excellent tradeoff.

### GPU Lifecycle with Assignments

- GPU goes down (idle timeout or spot reclaim) → reconciler marks it `gone` → client assignments for that GPU are cleared → affected clients get reassigned on their next prompt submission.
- GPU B idle with no assigned clients → watchdog shuts it down naturally.

## Site Box API Routes

### Always Available (no GPU needed)

| Route | Method | Description |
|---|---|---|
| `/` | GET | Serve SPA (index.html) |
| `/manifest.json` | GET | Unit manifest |
| `/descriptions.json` | GET | Unit descriptions |
| `/api/status` | GET | Read-only. Session state, GPU status, queue info, session countdown |
| `/api/request-access` | POST | Send Discord notification, create pending request. Rate-limited: 1 per IP per 5 min. |
| `/api/s3/check/{unit}/{skin}` | GET | Check if model exists in S3, return metadata |
| `/api/s3/model-url/{unit}/{skin}` | GET | Return presigned S3 URL for GLB download (browser fetches directly from S3) |
| `/api/s3/list` | GET | List all units with models |
| `/api/s3/favorites` | GET | List favorited models |
| `/api/s3/favorite` | POST | Mark model as favorite |
| `/api/s3/unfavorite` | POST | Remove favorite |
| `/api/s3/reject` | POST | Mark model as bad generation |

### GPU Proxy Routes (forwarded to client's assigned GPU)

| Route | Method | Proxied To |
|---|---|---|
| `/api/gpu/prompt` | POST | `http://{gpu_ip}:8188/api/prompt` — also records prompt in SQLite, updates `last_seen_at`. Rate-limited: 1 per client per 10s. |
| `/api/gpu/queue` | GET | `http://{gpu_ip}:8188/api/queue` — filtered to client's assigned GPU |
| `/api/gpu/history/{prompt_id}` | GET | Looks up GPU from `prompts` table, proxies to correct instance |
| `/api/gpu/ws` | WS | `ws://{gpu_ip}:8188/ws` — sticky to client's assigned GPU |
| `/api/gpu/metadata` | POST | `http://{gpu_ip}:8188/fabricate/metadata` |
| `/api/gpu/system_stats` | GET | `http://{gpu_ip}:8188/system_stats` |

When no GPU is available, proxy routes return `503` with `{"status": "gpu_offline", "session_active": true/false}`.

When GPU is launching, proxy routes return `503` with `{"status": "gpu_starting", "started_at": "..."}`.

## DNS and Nginx

### DNS

Add A record for `fabricate.prismata.live` pointing to the site box EIP `<SITE_BOX_EIP>`.

### Nginx

New vhost on the site box:

```nginx
server {
    listen 443 ssl;
    server_name fabricate.prismata.live;

    ssl_certificate /etc/letsencrypt/live/fabricate.prismata.live/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/fabricate.prismata.live/privkey.pem;

    # Long timeouts for WS and generation proxying
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;

    location / {
        proxy_pass http://127.0.0.1:3100;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

### SSL

Use certbot with the existing Let's Encrypt setup on the site box. `certbot --nginx -d fabricate.prismata.live`.

## GPU Instance Changes

### user-data.sh Changes

- Remove cloudflared tunnel startup and SSM tunnel URL write
- Remove cloudflared install/dependency
- Keep: warmup.sh execution (downloaded from S3)
- Keep: ComfyUI start
- Keep: monitoring services (idle-watchdog, output-sync)
- Keep: spot-monitor (for graceful spot interruption handling)
- No SSM IP writes needed — site box discovers IP via EC2 API

### idle-watchdog.sh Changes

- Change `IDLE_THRESHOLD` from 600 to 1200 (20 minutes)
- Remove Discord webhook notification on shutdown (site box detects instance termination via EC2 API)

### Security Group

Ensure the GPU security group (`sg-0fdc130ad1d5dc373`) allows inbound TCP port 8188 from the site box's security group or VPC CIDR. This replaces the Cloudflare tunnel path.

## CLI Tool

`infra/cli.js` — local CLI for admin operations. Uses AWS SDK with local credentials. Talks to the site box API over HTTPS.

```bash
# Create a session directly (bypasses Discord flow, for testing)
node infra/cli.js create-session --hours 24

# Check current session status
node infra/cli.js status

# Revoke active session immediately
node infra/cli.js revoke

# Force-launch a GPU (within active session)
node infra/cli.js launch-gpu
```

## Testing Requirements

1. **Idle GPU shutdown works** — GPU must reliably self-terminate after 20 minutes of no nvidia-smi activity. Verify by launching, waiting 20+ min, confirming termination via EC2 API.
2. **Auto-wake works** — Within an active session, visit the frontend after GPU shutdown, confirm reconciler launches new instance and it becomes available.
3. **Session expiry enforced** — After 24h, confirm no auto-wake occurs and frontend returns to Session Expired state.
4. **Multi-user queue isolation** — Two browser tabs, each submits a job. Confirm each only sees their own progress. Kill on one doesn't affect the other.
5. **Second GPU auto-launch** — Queue 3+ jobs, confirm reconciler launches second instance. Confirm new clients route to GPU B.
6. **S3 browsing while GPU offline** — With no GPU running, confirm model browsing, 3D preview (via presigned URLs), and favorites all work.
7. **Discord approval flow** — Click Request Access, confirm webhook fires, react with ✅, confirm session creates and reconciler launches GPU.
8. **Cost safety** — Session expires, both GPUs terminate on next idle, no orphaned instances.
9. **Site box recovery** — Site box spot reclaim + recovery. Confirm fabricate.prismata.live comes back up, reconciler rediscovers running GPU instances from EC2 API.
10. **Spot interruption during generation** — GPU interrupted mid-job. Verify frontend shows failure cleanly, client assignment is cleared, user can retry.
11. **No spot capacity** — Launch fails. Verify frontend shows "Launch Failed" state, not endless "Starting..."
12. **Concurrent polling race** — Multiple tabs/users polling simultaneously. Verify reconciler only launches one instance (launch lock).
13. **Site box restart during active session** — SQLite persists, reconciler rediscovers GPU instances from EC2, prompt routing recovers.
14. **Request TTL expiry** — Submit access request, don't approve for >1h, verify it expires and user sees "Request Expired."

## Implementation Phases

### Phase 1: Queue Isolation (frontend-only)
Fix `reconnectToRunningJobs()`, per-user Kill/Clear, queue position indicator, `client_id` in `sessionStorage`. No infrastructure changes. Can deploy immediately on existing architecture.

### Phase 2: Always-On Frontend on Site Box
- Node API process on site box with SQLite
- Nginx vhost + SSL for `fabricate.prismata.live`
- S3 API routes (presigned URLs for model downloads, favorites, reject)
- Frontend refactored for dual-mode (Browse vs Ready)
- Static assets (SPA, manifest, descriptions) served from site box

### Phase 3: Reconciler + Session Management + Auto-Wake
- Reconciler loop (sole owner of EC2 actions)
- Discord webhook for access requests
- Discord API polling for approval reactions
- Request/session state machine with SQLite persistence
- GPU discovery via EC2 API + health checks
- ComfyUI API/WebSocket proxying to GPU private IP
- Rate limiting on request-access and prompt submission
- CLI admin tool

### Phase 4: Two-GPU Sticky Assignment
- Sticky client-to-GPU assignment in SQLite
- Reconciler scale-up trigger (queue depth >= 3)
- Per-client GPU routing for all proxy routes
- Client reassignment on GPU loss
- Scale-down via existing idle watchdog

### Phase 5: Polish + Retire Discord Bot
- Frontend failure states (Launch Failed, Spot Unavailable, Request Expired, etc.)
- Session countdown display in frontend
- GPU status indicators
- Remove cloudflared from GPU boot sequence
- Retire Discord bot (after new control plane is proven stable)
- Update AMI build scripts
