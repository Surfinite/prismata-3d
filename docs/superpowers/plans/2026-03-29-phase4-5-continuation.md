# Fabrication Terminal — Phase 4 & 5 Continuation Prompt

**Date:** 2026-03-29
**Status:** Ready for next session
**Context window:** Start fresh — this is a continuation prompt.

## What Was Done

### This Session (2026-03-29)

**GPU Warmup** — Pre-loads v2.0 shape model into VRAM on boot. `warmup.sh` submits a 1-step Drone generation on startup, discards output. Launch template v11→v13.

**Phase 1: Queue Isolation** (frontend-only, deployed)
- `client_id` in `sessionStorage` (persists across refresh)
- `reconnectToRunningJobs()` filters by client_id
- Kill button disabled when another user's job is running (server-side enforcement in Phase 3)
- Clear My Queue only removes own pending jobs (server-side enforcement in Phase 3)
- Queue position indicator ("Your job: #2 (~4m)")

**Phase 2: Always-On Frontend** (deployed at `fabricate.prismata.live`)
- Express server on site box (port 3100, systemd `fabricate` service)
- S3 API routes (presigned URLs for model downloads, favorites, reject)
- Mode-aware frontend routing (`IS_SITE_BOX` flag, `ORIGIN`-based helpers)
- nginx vhost + certbot SSL
- S3 bucket CORS for presigned URL browser access
- IAM: `prismata-3d-s3-models` policy on `prismata-live-ec2` role

**Phase 3: Reconciler + Session Management** (deployed)
- SQLite database (`/opt/fabricate/fabricate.db`) with 5 tables: requests, sessions, gpu_instances, client_assignments, prompts
- Reconciler loop (5s interval, sole owner of EC2 actions)
- Discord webhook notifications for access requests → #prismata-ops
- Discord API reaction polling (✅ approve, ❌ deny, owner ID: `292290258777800704`)
- Request/session state machine (pending→approved→active, 1h request TTL, 24h session TTL)
- Demand-based GPU wake (`wake_requested_at` flag, cleared only on GPU ready)
- GPU discovery via EC2 API + health checks (no more Cloudflare tunnel)
- ComfyUI HTTP proxy routes (`/api/gpu/*` → GPU private IP port 8188)
- WebSocket proxy for real-time generation progress
- Server-side ownership enforcement (interrupt checks client_id, queue-delete filters)
- Rate limiting (1 request-access per IP per 5min, 1 prompt per client per 10s)
- Unhealthy GPU detection (6 consecutive health failures → mark gone)
- Hard-limited to 1 GPU (slot A only) — Phase 4 adds slot B
- Launch template v13: `InstanceInitiatedShutdownBehavior: terminate`, no cloudflared, 20-min idle watchdog
- Security group: port 8188 open from VPC CIDR
- CLI tool: `node infra/cli.js create-session|status|revoke|launch-gpu`
- Admin API: `/api/admin/*` protected by `ADMIN_KEY`
- Fabricator name field (optional, stored in localStorage, included in metadata)

### Known Issues

- **SageAttn**: Removed from dropdown — causes `NoneType` errors on some units. SDPA hardcoded.
- **Unit sprite previews**: Not available in browse mode (sprites on GPU filesystem). Shows placeholder.
- **Favorite thumbnails**: Use sprite images, so blank in browse mode.
- **Discord mention shows @unknown-user**: The webhook mention works but displays incorrectly. Approval still works fine.
- **Phase 1 manual testing**: Queue isolation multi-tab testing still pending formal verification (tested informally — works).

## What Needs Doing

### Phase 4: Two-GPU Sticky Assignment

**Spec:** `docs/superpowers/specs/2026-03-29-multi-user-fabrication-terminal-design.md` — "Two-GPU Sticky Assignment Model" section

Key requirements:
- Hard cap of 2 GPU instances (slots A and B)
- Sticky client-to-GPU assignment: each `client_id` pinned to one GPU
- Assignment on first prompt submission, stays until GPU dies
- Reconciler scale-up trigger: queue depth >= 3 on GPU A → launch GPU B
- New clients get assigned to less-loaded GPU
- When GPU dies, client assignments cleared, reassigned on next prompt
- WebSocket stays sticky to assigned GPU (no cross-GPU multiplexing)
- Queue/history routed to client's assigned GPU

Changes needed:
1. **Reconciler** (`lib/reconciler.js`): Remove single-GPU hard limit. Add `canLaunchGpu()` that allows up to 2. Add queue-depth monitoring on ready GPUs. Scale-up trigger logic.
2. **DB** (`lib/db.js`): Re-enable `getNextSlot()` for A/B assignment. Client assignment helpers already exist.
3. **GPU proxy routes** (`routes/gpu.js`): `getGpuForClient()` already assigns clients — needs to handle 2 GPUs. Prompt submission routes to assigned GPU. History lookup uses prompt→GPU mapping.
4. **Frontend**: Minimal changes — queue display should reflect assigned GPU. WebSocket reconnects to new GPU if old one dies.
5. **EC2 tags**: Slot tag ('A' or 'B') on launch for rediscovery.

### Phase 5: Polish

**Spec:** Same file, "Phase 5" section

Key items:
1. **GPU idle shutdown countdown** — Show "GPU shutting down in X:XX" when <5 min of idle time remains. Reconciler tracks idle state via queue polling (empty queue = idle). Frontend shows warning banner.
2. **Unit color coding** — Green text in unit dropdown for units with any S3 model. Yellow text in skin dropdown for skins without a model when other skins have one. Requires fetching `/api/s3/list` on load and cross-referencing with manifest.
3. **Frontend failure states** — Launch Failed, Spot Unavailable, Request Expired states should show clear user-facing messages (most are already implemented in Phase 3).
4. **Retire Discord bot** — After new control plane is proven stable. Remove bot.py, ec2_manager.py, config.py from infra/bot/. Stop the bot wherever it's running.
5. **Update AMI build scripts** — Remove cloudflared installation from `install-comfyui.sh` / `build-ami.sh` (no longer needed).

## Key Files

### Site Box Server (c:/libraries/prismata-3d/infra/site/)
- `server.js` — Express server, WS proxy, reconciler startup
- `lib/db.js` — SQLite schema + query helpers (5 tables)
- `lib/reconciler.js` — Reconciler loop (EC2, health, Discord polling)
- `lib/discord.js` — Discord webhook + reaction check
- `lib/s3client.js` — AWS S3 client
- `routes/s3.js` — S3 API routes (check, model-url, list, favorites, reject)
- `routes/status.js` — GET /api/status (7-state machine)
- `routes/access.js` — POST /api/request-access, POST /api/wake-gpu
- `routes/gpu.js` — GPU proxy routes (prompt, queue, history, interrupt, view, metadata, system_stats)
- `routes/admin.js` — Admin API (create-session, revoke, launch-gpu)
- `deploy.sh` — Deploy to site box
- `fabricate.service` — systemd unit
- `fabricate.nginx.conf` — nginx vhost

### Frontend
- `infra/frontend/index.html` — Single-file SPA (~3400 lines)

### GPU Instance
- `infra/ec2/user-data.sh` — Boot script (no cloudflared, warmup, monitoring)
- `infra/ec2/idle-watchdog.sh` — 20-min idle → self-terminate
- `infra/ec2/warmup.sh` — Pre-load v2.0 shape model into VRAM

### Specs & Plans
- `docs/superpowers/specs/2026-03-29-multi-user-fabrication-terminal-design.md` — Full design spec (v2)
- `docs/superpowers/plans/2026-03-29-phase1-queue-isolation.md` — Phase 1 plan (done)
- `docs/superpowers/plans/2026-03-29-phase2-always-on-frontend.md` — Phase 2 plan (done)
- `docs/superpowers/plans/2026-03-29-phase3-reconciler-session-management.md` — Phase 3 plan (done)

### Infrastructure
- Launch template: `prismata-3d-gen` v13 (default)
- GPU security group: `sg-0fdc130ad1d5dc373` (port 8188 from VPC)
- Site box: `t3.micro spot`, EIP `<SITE_BOX_EIP>`
- S3 bucket: `prismata-3d-models` (CORS configured for fabricate.prismata.live)
- SSM params: `/prismata-3d/discord-bot-token`, `/prismata-3d/discord-webhook-url`, `/prismata-3d/discord-channel-id`, `/prismata-3d/admin-key`
- Discord owner ID: `292290258777800704` (Surfinite)
- Admin key: stored in SSM at `/prismata-3d/admin-key`

## How to Deploy Changes

```bash
# Deploy site box (all server + frontend changes)
cd c:/libraries/prismata-3d && bash infra/site/deploy.sh

# Quick frontend-only deploy (skip npm install)
scp -i ~/.ssh/<SSH_KEY>.pem infra/frontend/index.html ubuntu@<SITE_BOX_EIP>:/tmp/fabricate-index.html
ssh -i ~/.ssh/<SSH_KEY>.pem ubuntu@<SITE_BOX_EIP> "sudo cp /tmp/fabricate-index.html /opt/fabricate/public/index.html"

# Also update S3 for GPU instances
aws s3 cp infra/frontend/index.html s3://prismata-3d-models/frontend/index.html --region us-east-1

# Quick server-side file deploy + restart
scp -i ~/.ssh/<SSH_KEY>.pem infra/site/lib/reconciler.js ubuntu@<SITE_BOX_EIP>:/tmp/fabricate-reconciler.js
ssh -i ~/.ssh/<SSH_KEY>.pem ubuntu@<SITE_BOX_EIP> "sudo cp /tmp/fabricate-reconciler.js /opt/fabricate/lib/reconciler.js && sudo systemctl restart fabricate"

# Check logs
ssh -i ~/.ssh/<SSH_KEY>.pem ubuntu@<SITE_BOX_EIP> "sudo journalctl -u fabricate -f"

# Check DB state
ssh -i ~/.ssh/<SSH_KEY>.pem ubuntu@<SITE_BOX_EIP> "sqlite3 /opt/fabricate/fabricate.db 'SELECT * FROM sessions;'"
```

## Suggested Approach for Next Session

1. **Use /brainstorming** to refine Phase 4 scope (it's smaller than Phase 3)
2. **Write Phase 4 plan** using writing-plans skill
3. **Execute Phase 4** with subagent-driven-development
4. **Then Phase 5 polish items** — these are mostly independent small tasks that can be done in parallel or sequentially
5. **Test the full lifecycle**: request → approve → generate → idle shutdown → wake → generate again → session expire
