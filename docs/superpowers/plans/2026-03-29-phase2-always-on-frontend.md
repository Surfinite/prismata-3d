# Phase 2: Always-On Frontend — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve the Fabrication Terminal at `fabricate.prismata.live` on the existing site box, with S3-backed model browsing available 24/7 — even when no GPU is running. Users can browse all generated models, view 3D previews, manage favorites, and see generation history without needing GPU access.

**Architecture:** A small Express.js API server on the site box (port 3100) serves the SPA and handles S3 operations. Nginx reverse-proxies `fabricate.prismata.live` to it. The frontend detects whether it's running on the site box (always-on, browse-only) or on a GPU instance (full generation mode) based on whether ComfyUI's `/api/system_stats` responds. Model downloads use presigned S3 URLs (browser fetches directly from S3, not proxied through Node).

**Tech Stack:** Express.js, AWS SDK v3, better-sqlite3, nginx, certbot, systemd

**Spec:** `docs/superpowers/specs/2026-03-29-multi-user-fabrication-terminal-design.md` — Phase 2 section + "Site Box API Routes" + "DNS and Nginx"

**Site box:** Existing `t3.micro spot`, EIP `<SITE_BOX_EIP>`, Ubuntu, Node.js v22, runs prismata.live (Next.js port 3000), nginx + certbot SSL. SSH: `ssh -i ~/.ssh/<SSH_KEY>.pem ubuntu@<SITE_BOX_EIP>`

**Note:** This phase does NOT include GPU proxying, session management, or auto-wake. Those are Phase 3. The frontend gracefully degrades to browse-only mode when no GPU is available.

---

## File Structure

### New files (site box service)

```
infra/site/
├── package.json              # Express + AWS SDK deps
├── server.js                 # Main server: static files + API routes
├── routes/
│   ├── s3.js                 # S3 proxy routes (check, list, model-url, favorites, reject)
│   └── status.js             # GET /api/status (read-only session/GPU state)
├── lib/
│   └── s3client.js           # Shared S3 client singleton
├── fabricate.service          # systemd unit file
├── fabricate.nginx.conf       # nginx vhost config
└── deploy.sh                 # Deploy script (rsync to site box + restart)
```

### Modified files

```
infra/frontend/index.html     # Refactor API routing for dual-mode
```

### Assets to copy to site box

```
/opt/fabricate/
├── public/
│   ├── index.html            # SPA (from infra/frontend/index.html)
│   ├── manifest.json         # Unit manifest (from S3)
│   └── descriptions.json     # Unit descriptions (from S3)
├── server.js
├── routes/
├── lib/
├── package.json
├── node_modules/
└── fabricate.db              # SQLite (created on first run, used more in Phase 3)
```

---

### Task 1: Create the Express server skeleton

**Files:**
- Create: `infra/site/package.json`
- Create: `infra/site/server.js`
- Create: `infra/site/lib/s3client.js`

- [ ] **Step 1: Create package.json**

```json
{
  "name": "fabricate-server",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "@aws-sdk/client-s3": "^3.700.0",
    "@aws-sdk/s3-request-presigner": "^3.700.0",
    "express": "^4.21.0"
  }
}
```

Write to `c:/libraries/prismata-3d/infra/site/package.json`.

- [ ] **Step 2: Create S3 client singleton**

```javascript
// infra/site/lib/s3client.js
const { S3Client } = require('@aws-sdk/client-s3');

const BUCKET = process.env.S3_BUCKET || 'prismata-3d-models';
const REGION = process.env.AWS_REGION || 'us-east-1';

const s3 = new S3Client({ region: REGION });

module.exports = { s3, BUCKET, REGION };
```

Write to `c:/libraries/prismata-3d/infra/site/lib/s3client.js`.

- [ ] **Step 3: Create main server**

```javascript
// infra/site/server.js
const express = require('express');
const path = require('path');

const s3Routes = require('./routes/s3');
const statusRoutes = require('./routes/status');

const PORT = process.env.PORT || 3100;
const PUBLIC_DIR = path.join(__dirname, 'public');

const app = express();
app.use(express.json());

// Static files (SPA, manifest, descriptions)
app.use(express.static(PUBLIC_DIR));

// API routes
app.use('/api/s3', s3Routes);
app.use('/api', statusRoutes);

// SPA fallback — serve index.html for any unmatched route
app.get('*', (req, res) => {
  res.sendFile(path.join(PUBLIC_DIR, 'index.html'));
});

app.listen(PORT, '127.0.0.1', () => {
  console.log(`Fabricate server listening on 127.0.0.1:${PORT}`);
});
```

Write to `c:/libraries/prismata-3d/infra/site/server.js`.

- [ ] **Step 4: Install dependencies locally to verify**

```bash
cd c:/libraries/prismata-3d/infra/site && npm install
```

Confirm `node_modules` is created and no errors.

- [ ] **Step 5: Commit**

```bash
cd c:/libraries/prismata-3d
git add infra/site/package.json infra/site/server.js infra/site/lib/s3client.js
git commit -m "feat(fabricate): express server skeleton for always-on frontend"
```

Do NOT commit `node_modules/`. If there's no `.gitignore` in `infra/site/`, create one with `node_modules/`.

---

### Task 2: S3 API routes

**Files:**
- Create: `infra/site/routes/s3.js`

Port all S3 operations from the ComfyUI custom node (`install-frontend.sh` `__init__.py`) to Express routes. Key change: model downloads now return **presigned S3 URLs** instead of proxying the file through the server.

- [ ] **Step 1: Create S3 routes**

```javascript
// infra/site/routes/s3.js
const express = require('express');
const { s3, BUCKET } = require('../lib/s3client');
const {
  ListObjectsV2Command, GetObjectCommand, PutObjectCommand, DeleteObjectCommand
} = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');

const router = express.Router();

// GET /api/s3/check/:unit/:skin — check if model exists, return metadata
router.get('/check/:unit/:skin', async (req, res) => {
  const { unit, skin } = req.params;
  try {
    const prefix = `models/${unit}/${skin}/`;
    const resp = await s3.send(new ListObjectsV2Command({ Bucket: BUCKET, Prefix: prefix }));
    if (!resp.KeyCount) return res.json({ exists: false });

    const files = [];
    let meta = null;
    for (const obj of resp.Contents || []) {
      const name = obj.Key.split('/').pop();
      if (name.endsWith('.meta.json')) {
        try {
          const m = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: obj.Key }));
          meta = JSON.parse(await m.Body.transformToString());
        } catch {}
      } else if (name.startsWith('latest.')) {
        continue;
      } else if (!name.endsWith('.json')) {
        files.push({
          key: obj.Key, name, size: obj.Size,
          modified: obj.LastModified.toISOString()
        });
      }
    }
    files.sort((a, b) => b.modified.localeCompare(a.modified));
    res.json({ exists: true, files, meta });
  } catch (e) {
    res.json({ exists: false, error: e.message });
  }
});

// GET /api/s3/model-url/:unit/:skin — return presigned URL for model download
router.get('/model-url/:unit/:skin', async (req, res) => {
  const { unit, skin } = req.params;
  const fmt = req.query.format || 'glb';
  const filename = req.query.filename || '';
  try {
    let key;
    if (filename && !filename.includes('..') && !filename.includes('/')) {
      key = `models/${unit}/${skin}/${filename}`;
    } else {
      key = `models/${unit}/${skin}/latest.${fmt}`;
    }
    const url = await getSignedUrl(s3, new GetObjectCommand({ Bucket: BUCKET, Key: key }), {
      expiresIn: 3600  // 1 hour
    });
    res.json({ url, key, filename: filename || `latest.${fmt}` });
  } catch (e) {
    const status = e.name === 'NoSuchKey' ? 404 : 500;
    res.status(status).json({ error: e.message });
  }
});

// GET /api/s3/list — list all units with models
router.get('/list', async (req, res) => {
  try {
    const resp = await s3.send(new ListObjectsV2Command({
      Bucket: BUCKET, Prefix: 'models/', Delimiter: '/'
    }));
    const units = {};
    for (const prefix of resp.CommonPrefixes || []) {
      const unit = prefix.Prefix.split('/')[1];
      const skinResp = await s3.send(new ListObjectsV2Command({
        Bucket: BUCKET, Prefix: `models/${unit}/`, Delimiter: '/'
      }));
      const skins = (skinResp.CommonPrefixes || []).map(p => p.Prefix.split('/')[2]);
      if (skins.length) units[unit] = skins;
    }
    res.json(units);
  } catch (e) {
    res.json({ error: e.message });
  }
});

// GET /api/s3/favorites — list all favorited models
router.get('/favorites', async (req, res) => {
  try {
    const resp = await s3.send(new ListObjectsV2Command({
      Bucket: BUCKET, Prefix: 'favorites/'
    }));
    const favs = [];
    for (const obj of resp.Contents || []) {
      if (obj.Key.endsWith('.fav.json')) {
        try {
          const m = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: obj.Key }));
          favs.push(JSON.parse(await m.Body.transformToString()));
        } catch {}
      }
    }
    res.json(favs);
  } catch {
    res.json([]);
  }
});

// POST /api/s3/favorite — mark a model as favorite
router.post('/favorite', async (req, res) => {
  const { unit, skin, filename, params } = req.body;
  if (!unit || !skin || !filename) return res.status(400).json({ error: 'Missing fields' });
  try {
    const fav = {
      unit, skin, filename, params,
      favorited_at: new Date().toISOString()
    };
    await s3.send(new PutObjectCommand({
      Bucket: BUCKET,
      Key: `favorites/${unit}/${skin}/${filename}.fav.json`,
      Body: JSON.stringify(fav, null, 2),
      ContentType: 'application/json'
    }));
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// POST /api/s3/unfavorite — remove a favorite
router.post('/unfavorite', async (req, res) => {
  const { unit, skin, filename } = req.body;
  if (!unit || !skin || !filename) return res.status(400).json({ error: 'Missing fields' });
  try {
    await s3.send(new DeleteObjectCommand({
      Bucket: BUCKET,
      Key: `favorites/${unit}/${skin}/${filename}.fav.json`
    }));
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// POST /api/s3/reject — mark a model as bad generation
router.post('/reject', async (req, res) => {
  const { unit, skin, filename, params } = req.body;
  if (!unit || !skin || !filename) return res.status(400).json({ error: 'Missing fields' });
  try {
    const rej = {
      unit, skin, filename, params,
      rejected_at: new Date().toISOString()
    };
    await s3.send(new PutObjectCommand({
      Bucket: BUCKET,
      Key: `rejections/${unit}/${skin}/${filename}.rej.json`,
      Body: JSON.stringify(rej, null, 2),
      ContentType: 'application/json'
    }));
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

module.exports = router;
```

Write to `c:/libraries/prismata-3d/infra/site/routes/s3.js`.

- [ ] **Step 2: Create status route (stub for Phase 2)**

```javascript
// infra/site/routes/status.js
const express = require('express');
const router = express.Router();

// GET /api/status — read-only session/GPU state
// Phase 2: returns browse-only state (no session management yet)
// Phase 3 will add session, GPU, and queue info
router.get('/status', (req, res) => {
  res.json({
    state: 'browse',
    session: null,
    gpu: null,
    message: 'GPU offline — browse models below'
  });
});

module.exports = router;
```

Write to `c:/libraries/prismata-3d/infra/site/routes/status.js`.

- [ ] **Step 3: Verify server starts locally**

```bash
cd c:/libraries/prismata-3d/infra/site
mkdir -p public
echo "<h1>test</h1>" > public/index.html
node server.js
```

In another terminal: `curl http://localhost:3100/` should return the test HTML. `curl http://localhost:3100/api/status` should return the JSON stub. Kill the server.

```bash
rm public/index.html
```

- [ ] **Step 4: Commit**

```bash
cd c:/libraries/prismata-3d
git add infra/site/routes/s3.js infra/site/routes/status.js
git commit -m "feat(fabricate): S3 API routes + status stub for site box"
```

---

### Task 3: Refactor frontend for dual-mode API routing

**Files:**
- Modify: `infra/frontend/index.html`

The frontend needs to work in two modes:
1. **GPU mode** (served by ComfyUI at trycloudflare URL): all APIs go to same origin (current behavior)
2. **Site box mode** (served by fabricate.prismata.live): S3 APIs go to same origin, GPU APIs are unavailable

The key change: replace hardcoded `API_BASE` with two bases, and detect which mode we're in based on whether `/api/system_stats` (ComfyUI-specific) responds.

- [ ] **Step 1: Replace API_BASE with dual-base routing**

Find (around line 1580):
```javascript
const API_BASE = window.location.origin;
```

Replace with:
```javascript
// Dual-mode API routing:
// - SITE_BASE: always-on S3/status routes (works even when GPU is off)
// - GPU_BASE: ComfyUI routes (only available when GPU is running)
// When served from the GPU (trycloudflare), both point to the same origin.
// When served from the site box (fabricate.prismata.live), GPU_BASE starts null.
const SITE_BASE = window.location.origin;
let GPU_BASE = null;  // Set when GPU is detected as available
let gpuAvailable = false;
```

- [ ] **Step 2: Update checkConnection for GPU detection**

In the `checkConnection()` function, update the `/api/system_stats` check to set `gpuAvailable` and handle the browse-only case. The function currently tries to fetch `/api/system_stats` — on the site box this will fail (no ComfyUI). On the GPU instance it works.

Replace the `checkConnection` function with:

```javascript
async function checkConnection() {
  // Try ComfyUI system_stats — if this works, we have a GPU
  const statsUrl = GPU_BASE
    ? `${GPU_BASE}/api/system_stats`
    : `${SITE_BASE}/api/system_stats`;
  try {
    const resp = await fetch(statsUrl, { signal: AbortSignal.timeout(5000) });
    if (resp.ok) {
      gpuAvailable = true;
      if (!GPU_BASE) GPU_BASE = SITE_BASE;  // Same origin has ComfyUI
      connDot.classList.add('connected');
      connText.textContent = 'ComfyUI Online';

      const queueUrl = `${GPU_BASE}/api/queue`;
      const qResp = await fetch(queueUrl);
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

      let statusText = '';
      if (totalRunning > 0 || totalPending > 0) {
        statusText = `Queue: ${totalRunning} running, ${totalPending} pending`;
        if (myJobRunning) {
          statusText += ' | Your job is running';
        } else if (myPosition > 0) {
          const estMinutes = myPosition * 2;
          statusText += ` | Your job: #${myPosition} (~${estMinutes}m)`;
        }
      }
      queueStatus.textContent = statusText;

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
      return;
    }
  } catch {}

  // ComfyUI not available — check if site box status API is available
  gpuAvailable = false;
  GPU_BASE = null;
  try {
    const statusResp = await fetch(`${SITE_BASE}/api/status`, { signal: AbortSignal.timeout(5000) });
    if (statusResp.ok) {
      const status = await statusResp.json();
      connDot.classList.remove('connected');
      connText.textContent = status.message || 'GPU Offline — Browse Mode';
      queueStatus.textContent = '';
      return;
    }
  } catch {}

  // Nothing available
  if (!currentPromptId) {
    connDot.classList.remove('connected');
    connText.textContent = 'Offline';
    queueStatus.textContent = '';
  }
}
```

- [ ] **Step 3: Update all S3/fabricate API calls to use SITE_BASE**

Replace every occurrence of `${API_BASE}/fabricate/api/s3-check/` with `${SITE_BASE}/api/s3/check/`.
Replace every occurrence of `${API_BASE}/fabricate/api/s3-model/` with model-url presigned approach (see below).
Replace every occurrence of `${API_BASE}/fabricate/api/s3-list` with `${SITE_BASE}/api/s3/list`.
Replace every occurrence of `${API_BASE}/fabricate/api/favorites` with `${SITE_BASE}/api/s3/favorites`.
Replace every occurrence of `${API_BASE}/fabricate/api/favorite` with `${SITE_BASE}/api/s3/favorite`.
Replace every occurrence of `${API_BASE}/fabricate/api/unfavorite` with `${SITE_BASE}/api/s3/unfavorite`.
Replace every occurrence of `${API_BASE}/fabricate/api/reject` with `${SITE_BASE}/api/s3/reject`.
Replace every occurrence of `${API_BASE}/fabricate/metadata` with `${GPU_BASE}/fabricate/metadata` (this one stays on GPU since it writes to local disk).

For the model download, the old pattern:
```javascript
const s3Url = `${API_BASE}/fabricate/api/s3-model/${unit}/${skin}?format=${fmt}`;
```

Must become a presigned URL fetch:
```javascript
const urlResp = await fetch(`${SITE_BASE}/api/s3/model-url/${encodeURIComponent(unit)}/${encodeURIComponent(skin)}?format=${fmt}`);
const urlData = await urlResp.json();
const s3Url = urlData.url;
```

This applies everywhere `s3-model` is referenced (model preview loading, download button, favorites gallery). Search for all occurrences.

- [ ] **Step 4: Update all ComfyUI API calls to use GPU_BASE**

Replace `${API_BASE}/api/prompt` with `${GPU_BASE}/api/prompt`.
Replace `${API_BASE}/api/queue` with `${GPU_BASE}/api/queue`.
Replace `${API_BASE}/api/interrupt` with `${GPU_BASE}/api/interrupt`.
Replace `${API_BASE}/api/history/` with `${GPU_BASE}/api/history/`.
Replace `${API_BASE}/api/view?` with `${GPU_BASE}/api/view?`.
Replace `${API_BASE}/api/system_stats` with the `statsUrl` variable (already handled in checkConnection).

For the WebSocket connection, replace:
```javascript
const wsUrl = `${wsProto}//${location.host}/ws?clientId=${wsClientId}`;
```
With:
```javascript
if (!GPU_BASE) return;  // No GPU, no WebSocket
const gpuHost = new URL(GPU_BASE).host;
const wsUrl = `${wsProto}//${gpuHost}/ws?clientId=${wsClientId}`;
```

- [ ] **Step 5: Guard GPU-dependent UI actions**

The Generate button, Kill, and Clear Queue should be disabled when `gpuAvailable` is false. Add a check at the top of `startGeneration()`:

```javascript
  if (!gpuAvailable || !GPU_BASE) {
    log('GPU is not available — cannot generate', 'error');
    return;
  }
```

Add a similar guard at the top of the Kill and Clear Queue handlers.

Also guard the metadata save (which writes to GPU local disk):
```javascript
  if (!GPU_BASE) return;  // Can't save metadata without GPU
```

- [ ] **Step 6: Update manifest loading for site box mode**

The manifest loading currently tries ComfyUI-specific paths. Add the site box path as the first option:

```javascript
  const paths = [
    'manifest.json',                    // site box serves this as static file
    `${SITE_BASE}/manifest.json`,       // explicit site box path
    `${GPU_BASE || SITE_BASE}/api/view?filename=prismata-assets/manifest.json&type=input`,
    `${GPU_BASE || SITE_BASE}/prismata-assets/manifest.json`,
  ];
```

- [ ] **Step 7: Remove all remaining references to API_BASE**

Search the file for `API_BASE`. There should be zero remaining. Every call should use either `SITE_BASE` or `GPU_BASE`.

If any `API_BASE` references remain, determine whether they're S3/always-on (use `SITE_BASE`) or ComfyUI/GPU (use `GPU_BASE` with a guard).

- [ ] **Step 8: Commit**

```bash
git add infra/frontend/index.html
git commit -m "feat(fabricate): dual-mode API routing — SITE_BASE for S3, GPU_BASE for ComfyUI"
```

---

### Task 4: Systemd service and nginx config

**Files:**
- Create: `infra/site/fabricate.service`
- Create: `infra/site/fabricate.nginx.conf`

- [ ] **Step 1: Create systemd service file**

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
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Write to `c:/libraries/prismata-3d/infra/site/fabricate.service`.

- [ ] **Step 2: Create nginx vhost config**

```nginx
server {
    listen 80;
    server_name fabricate.prismata.live;

    # Redirect HTTP to HTTPS (certbot will add SSL block)
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name fabricate.prismata.live;

    # SSL certs will be added by certbot
    # ssl_certificate /etc/letsencrypt/live/fabricate.prismata.live/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/fabricate.prismata.live/privkey.pem;

    # Long timeouts for WebSocket and generation proxying (Phase 3)
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;

    location / {
        proxy_pass http://127.0.0.1:3100;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Write to `c:/libraries/prismata-3d/infra/site/fabricate.nginx.conf`.

- [ ] **Step 3: Commit**

```bash
git add infra/site/fabricate.service infra/site/fabricate.nginx.conf
git commit -m "feat(fabricate): systemd service + nginx vhost config"
```

---

### Task 5: Deploy script

**Files:**
- Create: `infra/site/deploy.sh`

- [ ] **Step 1: Create deploy script**

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
$SCP "$SCRIPT_DIR/lib/s3client.js" "$SITE_BOX:/tmp/fabricate-s3client.js"

# 3. Upload frontend
echo "--- Uploading frontend ---"
$SCP "$FRONTEND_DIR/index.html" "$SITE_BOX:/tmp/fabricate-index.html"

# 4. Upload static assets from S3
echo "--- Downloading assets from S3 ---"
$SSH "aws s3 cp s3://prismata-3d-models/asset-prep/manifest.json /tmp/fabricate-manifest.json --region us-east-1"
$SSH "aws s3 cp s3://prismata-3d-models/asset-prep/descriptions.json /tmp/fabricate-descriptions.json --region us-east-1"

# 5. Move files into place
echo "--- Installing files ---"
$SSH "sudo cp /tmp/fabricate-package.json /opt/fabricate/package.json && \
      sudo cp /tmp/fabricate-server.js /opt/fabricate/server.js && \
      sudo cp /tmp/fabricate-s3.js /opt/fabricate/routes/s3.js && \
      sudo cp /tmp/fabricate-status.js /opt/fabricate/routes/status.js && \
      sudo cp /tmp/fabricate-s3client.js /opt/fabricate/lib/s3client.js && \
      sudo cp /tmp/fabricate-index.html /opt/fabricate/public/index.html && \
      sudo cp /tmp/fabricate-manifest.json /opt/fabricate/public/manifest.json && \
      sudo cp /tmp/fabricate-descriptions.json /opt/fabricate/public/descriptions.json && \
      sudo chown -R ubuntu:ubuntu /opt/fabricate"

# 6. Install npm dependencies
echo "--- Installing dependencies ---"
$SSH "cd /opt/fabricate && npm install --production"

# 7. Install systemd service (first time only — safe to re-run)
echo "--- Installing service ---"
$SCP "$SCRIPT_DIR/fabricate.service" "$SITE_BOX:/tmp/fabricate.service"
$SSH "sudo cp /tmp/fabricate.service /etc/systemd/system/fabricate.service && \
      sudo systemctl daemon-reload && \
      sudo systemctl enable fabricate && \
      sudo systemctl restart fabricate"

# 8. Check service is running
echo "--- Verifying service ---"
sleep 2
$SSH "sudo systemctl is-active fabricate && curl -sf http://127.0.0.1:3100/api/status"

echo ""
echo "=== Fabricate server deployed ==="
echo "Service: sudo systemctl status fabricate"
echo "Logs: sudo journalctl -u fabricate -f"
echo ""
echo "Next steps:"
echo "  1. Add DNS: A record for fabricate.prismata.live → <SITE_BOX_EIP>"
echo "  2. Install nginx config:"
echo "     sudo cp /tmp/fabricate-nginx.conf /etc/nginx/sites-available/fabricate"
echo "     sudo ln -sf /etc/nginx/sites-available/fabricate /etc/nginx/sites-enabled/"
echo "     sudo nginx -t && sudo systemctl reload nginx"
echo "  3. Get SSL cert:"
echo "     sudo certbot --nginx -d fabricate.prismata.live"
```

Write to `c:/libraries/prismata-3d/infra/site/deploy.sh`.

- [ ] **Step 2: Commit**

```bash
chmod +x infra/site/deploy.sh
git add infra/site/deploy.sh
git commit -m "feat(fabricate): deploy script for site box"
```

---

### Task 6: DNS setup

**Files:** None (external configuration)

- [ ] **Step 1: Add DNS A record**

Log into Porkbun (where `prismata.live` is registered) and add:

```
Type: A
Name: fabricate
Value: <SITE_BOX_EIP>
TTL: 600
```

- [ ] **Step 2: Verify DNS propagation**

```bash
dig fabricate.prismata.live +short
```

Should return `<SITE_BOX_EIP>`. May take a few minutes to propagate.

---

### Task 7: Deploy to site box and configure nginx + SSL

**Files:** None (server-side operations)

This task runs the deploy script and does the one-time nginx/SSL setup.

- [ ] **Step 1: Run deploy script**

```bash
cd c:/libraries/prismata-3d
bash infra/site/deploy.sh
```

Confirm output shows "Fabricate server deployed" and the status check passes.

- [ ] **Step 2: Upload and install nginx config**

```bash
SSH_KEY="$HOME/.ssh/<SSH_KEY>.pem"
scp -i $SSH_KEY infra/site/fabricate.nginx.conf ubuntu@<SITE_BOX_EIP>:/tmp/fabricate.nginx.conf
ssh -i $SSH_KEY ubuntu@<SITE_BOX_EIP> "sudo cp /tmp/fabricate.nginx.conf /etc/nginx/sites-available/fabricate && \
  sudo ln -sf /etc/nginx/sites-available/fabricate /etc/nginx/sites-enabled/ && \
  sudo nginx -t && sudo systemctl reload nginx"
```

Confirm `nginx -t` passes.

- [ ] **Step 3: Get SSL certificate**

```bash
ssh -i $SSH_KEY ubuntu@<SITE_BOX_EIP> "sudo certbot --nginx -d fabricate.prismata.live"
```

Follow prompts. Certbot will update the nginx config to add SSL.

- [ ] **Step 4: Verify HTTPS works**

```bash
curl -sf https://fabricate.prismata.live/api/status
```

Should return: `{"state":"browse","session":null,"gpu":null,"message":"GPU offline — browse models below"}`

- [ ] **Step 5: Verify frontend loads**

Open `https://fabricate.prismata.live` in a browser. Should see the Fabrication Terminal UI in browse mode — able to browse units, view previously generated 3D models, manage favorites. The connection status should show "GPU Offline — Browse Mode".

---

### Task 8: Upload updated frontend to S3 (for GPU instances)

**Files:** None (S3 upload)

The updated frontend (with dual-mode routing) also needs to work when served by ComfyUI on GPU instances. Upload it to S3 so new GPU instances get it.

- [ ] **Step 1: Upload to S3**

```bash
aws s3 cp infra/frontend/index.html s3://prismata-3d-models/frontend/index.html --region us-east-1
```

- [ ] **Step 2: Verify**

The frontend should work on both:
- `https://fabricate.prismata.live` (site box, browse-only)
- GPU trycloudflare URL `/fabricate/` (full generation, same origin for both API bases)

---

### Task 9: End-to-end verification

No files changed — manual test pass.

- [ ] **Step 1: Test browse mode on fabricate.prismata.live**

Visit `https://fabricate.prismata.live`. Confirm:
- Page loads, shows unit selector
- Connection status shows "GPU Offline — Browse Mode"
- Can browse units and skins
- Previously generated models load as 3D previews (via presigned S3 URLs)
- Favorites work (star, unstar, favorites dropdown)
- Reject works
- Generate button is disabled or shows appropriate message

- [ ] **Step 2: Test GPU mode still works**

Start a GPU instance via `!start`. Visit the trycloudflare URL `/fabricate/`. Confirm:
- Full generation UI works
- `GPU_BASE` auto-detects (same origin has ComfyUI)
- All existing generation features work unchanged
- Queue isolation from Phase 1 still works

- [ ] **Step 3: Test S3 browsing on GPU URL**

While on the GPU's trycloudflare URL, browse units that have S3 models. Confirm the S3 routes still work (now using the `/fabricate/api/s3-*` paths on the GPU, which still exist in the ComfyUI custom node).

Note: In Phase 3, the GPU URL will be retired in favor of `fabricate.prismata.live` for everything. But for Phase 2, both paths must work.
