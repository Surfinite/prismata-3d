# Phase 2: Always-On Frontend — Implementation Plan (v2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve the Fabrication Terminal at `fabricate.prismata.live` on the existing site box, with S3-backed model browsing available 24/7 — even when no GPU is running. Users can browse all generated models, view 3D previews, manage favorites, and see generation history without needing GPU access.

**Architecture:** A small Express.js API server on the site box (port 3100) serves the SPA and handles S3 operations. Nginx reverse-proxies `fabricate.prismata.live` to it. The frontend detects mode by hostname: `fabricate.prismata.live` = site-box browse mode, anything else = GPU legacy mode. Model downloads use presigned S3 URLs on the site box (browser fetches directly from S3). On the GPU, the existing ComfyUI custom-node routes are preserved unchanged.

**Tech Stack:** Express.js, AWS SDK v3, nginx, certbot, systemd

**Spec:** `docs/superpowers/specs/2026-03-29-multi-user-fabrication-terminal-design.md` — Phase 2 section + "Site Box API Routes" + "DNS and Nginx"

**Site box:** Existing `t3.micro spot`, EIP `<SITE_BOX_EIP>`, Ubuntu, Node.js v22, runs prismata.live (Next.js port 3000), nginx + certbot SSL. SSH: `ssh -i ~/.ssh/<SSH_KEY>.pem ubuntu@<SITE_BOX_EIP>`

**Note:** This phase does NOT include GPU proxying, session management, or auto-wake. Those are Phase 3. The frontend gracefully degrades to browse-only mode when served from the site box. When served from a GPU instance (trycloudflare URL), all existing behavior is preserved unchanged — the legacy `/fabricate/api/...` ComfyUI custom-node routes remain active.

**Note:** SQLite is not used in Phase 2. It is introduced in Phase 3 for session/reconciler state.

---

## File Structure

### New files (site box service)

```
infra/site/
├── package.json              # Express + AWS SDK deps
├── .gitignore                # node_modules/
├── server.js                 # Main server: static files + API routes + API 404 handler
├── routes/
│   ├── s3.js                 # S3 routes (check, list, model-url, favorites, reject)
│   └── status.js             # GET /api/status + GET /healthz
├── lib/
│   └── s3client.js           # Shared S3 client singleton
├── fabricate.service          # systemd unit file
├── fabricate.nginx.conf       # nginx vhost config (HTTP-only, certbot adds SSL)
└── deploy.sh                 # Deploy script (SCP to site box + restart)
```

### Modified files

```
infra/frontend/index.html     # Mode-aware API routing by hostname
```

---

### Task 1: Create the Express server skeleton with route stubs

**Files:**
- Create: `infra/site/package.json`
- Create: `infra/site/.gitignore`
- Create: `infra/site/server.js`
- Create: `infra/site/lib/s3client.js`
- Create: `infra/site/routes/s3.js` (stub)
- Create: `infra/site/routes/status.js` (stub)

Create the full skeleton including stub route files so the server can start immediately.

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

- [ ] **Step 2: Create .gitignore**

```
node_modules/
```

Write to `c:/libraries/prismata-3d/infra/site/.gitignore`.

- [ ] **Step 3: Create S3 client singleton**

```javascript
// infra/site/lib/s3client.js
const { S3Client } = require('@aws-sdk/client-s3');

const BUCKET = process.env.S3_BUCKET || 'prismata-3d-models';
const REGION = process.env.AWS_REGION || 'us-east-1';

const s3 = new S3Client({ region: REGION });

module.exports = { s3, BUCKET, REGION };
```

Write to `c:/libraries/prismata-3d/infra/site/lib/s3client.js`.

- [ ] **Step 4: Create stub route files**

```javascript
// infra/site/routes/s3.js — stub, filled in Task 2
const express = require('express');
const router = express.Router();
module.exports = router;
```

```javascript
// infra/site/routes/status.js — stub, filled in Task 2
const express = require('express');
const router = express.Router();

router.get('/status', (req, res) => {
  res.json({ state: 'browse', session: null, gpu: null, message: 'GPU offline — browse models below' });
});

module.exports = router;
```

Write to their respective paths.

- [ ] **Step 5: Create main server with API 404 handler**

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

// API routes (before static files)
app.use('/api/s3', s3Routes);
app.use('/api', statusRoutes);

// Health endpoint
app.get('/healthz', (req, res) => {
  res.json({ ok: true, uptime: process.uptime() });
});

// API 404 — must come BEFORE static/SPA fallback
// Without this, unknown /api/* routes would return index.html with 200
app.use('/api', (req, res) => {
  res.status(404).json({ error: 'Not found' });
});

// Static files (SPA, manifest, descriptions)
app.use(express.static(PUBLIC_DIR));

// SPA fallback — serve index.html for any unmatched non-API route
app.get('*', (req, res) => {
  res.sendFile(path.join(PUBLIC_DIR, 'index.html'));
});

app.listen(PORT, '127.0.0.1', () => {
  console.log(`Fabricate server listening on 127.0.0.1:${PORT}`);
});
```

Write to `c:/libraries/prismata-3d/infra/site/server.js`.

- [ ] **Step 6: Install dependencies and verify server starts**

```bash
cd c:/libraries/prismata-3d/infra/site && npm install
mkdir -p public && echo "<h1>test</h1>" > public/index.html
node server.js &
sleep 1
curl -s http://localhost:3100/api/status
curl -s http://localhost:3100/healthz
curl -si http://localhost:3100/api/does-not-exist | head -5
curl -s http://localhost:3100/
kill %1
rm public/index.html
```

Verify:
- `/api/status` returns JSON with `state: "browse"`
- `/healthz` returns JSON with `ok: true`
- `/api/does-not-exist` returns HTTP 404 with JSON `{"error":"Not found"}` (NOT index.html)
- `/` returns the test HTML

- [ ] **Step 7: Commit**

```bash
cd c:/libraries/prismata-3d
git add infra/site/
git commit -m "feat(fabricate): express server skeleton with API 404 handler and health endpoint"
```

---

### Task 2: S3 API routes

**Files:**
- Modify: `infra/site/routes/s3.js` (replace stub)

Port all S3 operations from the ComfyUI custom node (`install-frontend.sh` `__init__.py`) to Express routes. Key change: model downloads return **presigned S3 URLs** instead of proxying bytes. The `model-url` route uses `HeadObjectCommand` to verify the key exists before signing (avoids returning signed URLs for missing objects).

- [ ] **Step 1: Replace S3 route stub with full implementation**

```javascript
// infra/site/routes/s3.js
const express = require('express');
const { s3, BUCKET } = require('../lib/s3client');
const {
  ListObjectsV2Command, GetObjectCommand, PutObjectCommand,
  DeleteObjectCommand, HeadObjectCommand
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
// Uses HeadObject to verify key exists before signing
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
    // Verify object exists before signing
    await s3.send(new HeadObjectCommand({ Bucket: BUCKET, Key: key }));
    const url = await getSignedUrl(s3, new GetObjectCommand({ Bucket: BUCKET, Key: key }), {
      expiresIn: 3600
    });
    res.json({ url, key, filename: filename || `latest.${fmt}` });
  } catch (e) {
    if (e.name === 'NotFound' || e.$metadata?.httpStatusCode === 404) {
      return res.status(404).json({ error: 'Model not found' });
    }
    res.status(500).json({ error: e.message });
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

Write to `c:/libraries/prismata-3d/infra/site/routes/s3.js` (replacing the stub).

- [ ] **Step 2: Commit**

```bash
git add infra/site/routes/s3.js
git commit -m "feat(fabricate): S3 API routes with presigned URLs and HeadObject verification"
```

---

### Task 3: S3 bucket CORS configuration

**Files:** None (AWS configuration)

Presigned S3 URLs served to the browser need CORS headers, otherwise `<model-viewer>`, `fetch()`, and `three.js` loaders will be blocked by the browser.

- [ ] **Step 1: Apply CORS configuration to the S3 bucket**

```bash
aws s3api put-bucket-cors --bucket prismata-3d-models --region us-east-1 --cors-configuration '{
  "CORSRules": [
    {
      "AllowedOrigins": ["https://fabricate.prismata.live"],
      "AllowedMethods": ["GET", "HEAD"],
      "AllowedHeaders": ["*"],
      "MaxAgeSeconds": 3600
    }
  ]
}'
```

- [ ] **Step 2: Verify CORS is set**

```bash
aws s3api get-bucket-cors --bucket prismata-3d-models --region us-east-1
```

Should show the CORS rule with `fabricate.prismata.live` in AllowedOrigins.

- [ ] **Step 3: Commit a note (no code change, but document it)**

No file to commit — this is an infrastructure configuration. The CORS config is documented in the spec and this plan.

---

### Task 4: Refactor frontend for mode-aware API routing

**Files:**
- Modify: `infra/frontend/index.html`

The frontend detects mode by hostname — no probing needed:
- **Site-box mode** (`fabricate.prismata.live`): S3 calls use new Express routes (`/api/s3/...`), GPU calls disabled, browse-only.
- **GPU legacy mode** (any other hostname): ALL calls use existing paths (`/fabricate/api/...` for S3, `/api/...` for ComfyUI). Zero changes to GPU behavior.

This is the critical backward-compatibility fix: on the GPU URL, we keep the old route patterns. Only on the site box do we use the new Express routes.

- [ ] **Step 1: Replace API_BASE with mode-aware routing**

Find (around line 1580):
```javascript
const API_BASE = window.location.origin;
```

Replace with:
```javascript
// Mode-aware API routing by hostname.
// Site-box mode: S3 via Express /api/s3/..., no GPU available.
// GPU legacy mode: everything via ComfyUI /fabricate/api/... and /api/...
const ORIGIN = window.location.origin;
const IS_SITE_BOX = window.location.hostname === 'fabricate.prismata.live';
let gpuAvailable = !IS_SITE_BOX;  // GPU mode starts available, site box starts offline

// Route helpers — each call site uses these instead of building URLs directly
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
    // Presigned URL from Express
    const params = new URLSearchParams({ format: fmt || 'glb' });
    if (filename) params.set('filename', filename);
    const resp = await fetch(`${ORIGIN}/api/s3/model-url/${encodeURIComponent(unit)}/${encodeURIComponent(skin)}?${params}`);
    if (!resp.ok) return null;
    const data = await resp.json();
    return data.url;
  }
  // GPU legacy: direct proxy through ComfyUI custom node
  const params = new URLSearchParams({ format: fmt || 'glb' });
  if (filename) params.set('filename', filename);
  return `${ORIGIN}/fabricate/api/s3-model/${encodeURIComponent(unit)}/${encodeURIComponent(skin)}?${params}`;
}
function gpuUrl(path) {
  // All ComfyUI API calls — only available in GPU mode
  return `${ORIGIN}${path}`;
}
function metadataUrl() {
  return `${ORIGIN}/fabricate/metadata`;
}
```

- [ ] **Step 2: Replace all S3 API call sites**

Search for every occurrence of `${API_BASE}/fabricate/api/s3-check/` and replace with `s3CheckUrl(unit, skin)`.
Search for every occurrence of `${API_BASE}/fabricate/api/s3-model/` and replace with `await s3ModelUrl(unit, skin, fmt, filename)`. Note: this is now async — the calling function must await.
Search for every occurrence of `${API_BASE}/fabricate/api/s3-list` and replace with `s3ListUrl()`.
Search for every occurrence of `${API_BASE}/fabricate/api/favorites` and replace with `s3FavoritesUrl()`.
Search for every occurrence of `${API_BASE}/fabricate/api/favorite` (POST) and replace with `s3FavoriteUrl()`.
Search for every occurrence of `${API_BASE}/fabricate/api/unfavorite` and replace with `s3UnfavoriteUrl()`.
Search for every occurrence of `${API_BASE}/fabricate/api/reject` and replace with `s3RejectUrl()`.
Search for every occurrence of `${API_BASE}/fabricate/metadata` and replace with `metadataUrl()`.

- [ ] **Step 3: Replace all ComfyUI API call sites**

Replace `${API_BASE}/api/prompt` with `gpuUrl('/api/prompt')`.
Replace `${API_BASE}/api/queue` with `gpuUrl('/api/queue')`.
Replace `${API_BASE}/api/interrupt` with `gpuUrl('/api/interrupt')`.
Replace `${API_BASE}/api/history/` with `gpuUrl('/api/history/')`.
Replace `${API_BASE}/api/view?` with `gpuUrl('/api/view?')`.
Replace `${API_BASE}/api/system_stats` with `gpuUrl('/api/system_stats')`.

- [ ] **Step 4: Update WebSocket connection for mode awareness**

In `connectWebSocket()`, add a guard at the top:

```javascript
function connectWebSocket() {
  if (IS_SITE_BOX) return;  // No WebSocket in browse mode
  const wsProto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const wsUrl = `${wsProto}//${location.host}/ws?clientId=${wsClientId}`;
  // ... rest unchanged
```

- [ ] **Step 5: Update checkConnection for site-box mode**

In `checkConnection()`, add a fast path for site-box mode that skips the ComfyUI probe entirely:

At the very start of the function, add:

```javascript
async function checkConnection() {
  if (IS_SITE_BOX) {
    // Site-box mode: no ComfyUI, just check our status API
    try {
      const resp = await fetch(`${ORIGIN}/api/status`, { signal: AbortSignal.timeout(5000) });
      if (resp.ok) {
        const status = await resp.json();
        connDot.classList.remove('connected');
        connText.textContent = status.message || 'GPU Offline — Browse Mode';
        queueStatus.textContent = '';
      }
    } catch {
      connDot.classList.remove('connected');
      connText.textContent = 'Offline';
      queueStatus.textContent = '';
    }
    return;
  }
  // GPU legacy mode: existing checkConnection behavior...
```

The rest of the existing `checkConnection` function (ComfyUI probe, queue status, kill button state) remains unchanged — it only runs in GPU mode.

- [ ] **Step 6: Disable GPU controls in site-box browse mode**

Add guards to GPU-dependent actions. At the top of `startGeneration()`:

```javascript
  if (IS_SITE_BOX) {
    log('GPU is not available — browse mode only', 'error');
    return;
  }
```

Add the same guard at the top of the Kill handler and Clear My Queue handler.

Also add to `init()`, after `bindEvents()`:

```javascript
  if (IS_SITE_BOX) {
    // Disable generation controls in browse mode
    $('btnGenerate').disabled = true;
    $('btnGenerate').title = 'GPU not available — browse mode';
    $('btnKill').disabled = true;
    $('btnClearQueue').disabled = true;
  }
```

- [ ] **Step 7: Update manifest loading**

```javascript
  const paths = [
    'manifest.json',                    // works on both site box and GPU
    `${ORIGIN}/manifest.json`,
  ];
  if (!IS_SITE_BOX) {
    paths.push(`${ORIGIN}/api/view?filename=prismata-assets/manifest.json&type=input`);
    paths.push(`${ORIGIN}/prismata-assets/manifest.json`);
  }
```

- [ ] **Step 8: Remove all remaining references to API_BASE**

Search the file for `API_BASE`. There should be zero remaining. Every call should use a route helper or `ORIGIN` directly.

- [ ] **Step 9: Commit**

```bash
git add infra/frontend/index.html
git commit -m "feat(fabricate): mode-aware routing — site box browse mode + GPU legacy compatibility"
```

---

### Task 5: Systemd service and nginx config

**Files:**
- Create: `infra/site/fabricate.service`
- Create: `infra/site/fabricate.nginx.conf`

The nginx config is **HTTP-only**. Certbot will add the SSL server block in Task 8.

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

- [ ] **Step 2: Create nginx vhost config (HTTP-only)**

```nginx
# HTTP-only config for fabricate.prismata.live
# After running certbot, it will add the SSL server block automatically.
server {
    listen 80;
    server_name fabricate.prismata.live;

    # Long timeouts for future WebSocket/generation proxying (Phase 3)
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
git commit -m "feat(fabricate): systemd service + HTTP-only nginx vhost (certbot adds SSL)"
```

---

### Task 6: Deploy script

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

# 4. Upload infrastructure files
echo "--- Uploading service + nginx config ---"
$SCP "$SCRIPT_DIR/fabricate.service" "$SITE_BOX:/tmp/fabricate.service"
$SCP "$SCRIPT_DIR/fabricate.nginx.conf" "$SITE_BOX:/tmp/fabricate.nginx.conf"

# 5. Download static assets from S3 on the site box
echo "--- Downloading assets from S3 ---"
$SSH "aws s3 cp s3://prismata-3d-models/asset-prep/manifest.json /tmp/fabricate-manifest.json --region us-east-1"
$SSH "aws s3 cp s3://prismata-3d-models/asset-prep/descriptions.json /tmp/fabricate-descriptions.json --region us-east-1"

# 6. Move files into place
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

# 7. Install npm dependencies
echo "--- Installing dependencies ---"
$SSH "cd /opt/fabricate && npm install --production"

# 8. Install systemd service
echo "--- Installing service ---"
$SSH "sudo cp /tmp/fabricate.service /etc/systemd/system/fabricate.service && \
      sudo systemctl daemon-reload && \
      sudo systemctl enable fabricate && \
      sudo systemctl restart fabricate"

# 9. Check service is running
echo "--- Verifying service ---"
sleep 2
$SSH "sudo systemctl is-active fabricate && curl -sf http://127.0.0.1:3100/healthz"

echo ""
echo "=== Fabricate server deployed ==="
echo "Service: sudo systemctl status fabricate"
echo "Logs: sudo journalctl -u fabricate -f"
```

Write to `c:/libraries/prismata-3d/infra/site/deploy.sh`.

- [ ] **Step 2: Commit**

```bash
chmod +x infra/site/deploy.sh
git add infra/site/deploy.sh
git commit -m "feat(fabricate): deploy script for site box"
```

---

### Task 7: DNS setup

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

Should return `<SITE_BOX_EIP>`. May take a few minutes.

---

### Task 8: Deploy to site box, configure nginx + SSL

**Files:** None (server-side operations)

- [ ] **Step 1: Run deploy script**

```bash
cd c:/libraries/prismata-3d
bash infra/site/deploy.sh
```

Confirm output shows "Fabricate server deployed" and the healthz check passes.

- [ ] **Step 2: Install nginx config (HTTP-only)**

```bash
SSH_KEY="$HOME/.ssh/<SSH_KEY>.pem"
ssh -i $SSH_KEY ubuntu@<SITE_BOX_EIP> "sudo cp /tmp/fabricate.nginx.conf /etc/nginx/sites-available/fabricate && \
  sudo ln -sf /etc/nginx/sites-available/fabricate /etc/nginx/sites-enabled/ && \
  sudo nginx -t && sudo systemctl reload nginx"
```

Confirm `nginx -t` passes. At this point `http://fabricate.prismata.live` should work (if DNS has propagated).

- [ ] **Step 3: Get SSL certificate via certbot**

```bash
ssh -i $SSH_KEY ubuntu@<SITE_BOX_EIP> "sudo certbot --nginx -d fabricate.prismata.live"
```

Certbot will create the 443 SSL server block automatically. Follow prompts.

- [ ] **Step 4: Verify HTTPS**

```bash
curl -sf https://fabricate.prismata.live/healthz
curl -sf https://fabricate.prismata.live/api/status
```

Should return `{"ok":true,...}` and `{"state":"browse",...}`.

- [ ] **Step 5: Verify API 404 returns JSON**

```bash
curl -si https://fabricate.prismata.live/api/does-not-exist | head -5
```

Should return HTTP 404 with `{"error":"Not found"}`, NOT index.html.

- [ ] **Step 6: Verify frontend loads**

Open `https://fabricate.prismata.live` in a browser. Confirm:
- Page loads with unit selector
- Connection status shows "GPU Offline — Browse Mode"
- Generate button is disabled
- Can browse units/skins

---

### Task 9: Upload updated frontend to S3 (for GPU instances)

**Files:** None (S3 upload)

The updated frontend (with mode-aware routing) must also work on GPU instances.

- [ ] **Step 1: Upload to S3**

```bash
aws s3 cp infra/frontend/index.html s3://prismata-3d-models/frontend/index.html --region us-east-1
```

---

### Task 10: End-to-end verification

No files changed — manual test pass.

- [ ] **Step 1: Test browse mode on fabricate.prismata.live**

Visit `https://fabricate.prismata.live`. Confirm:
- Page loads, shows unit selector
- Connection status shows "GPU Offline — Browse Mode"
- Can browse units and skins
- Previously generated 3D models load and rotate in preview (via presigned S3 URLs — this validates CORS)
- Favorites work (star, unstar, favorites dropdown)
- Reject works
- Generate button is disabled with tooltip
- Kill and Clear My Queue are disabled
- No WebSocket connection attempts in DevTools Network tab
- No JS console errors

- [ ] **Step 2: Test GPU legacy mode still works**

Start a GPU instance via `!start`. Visit the trycloudflare URL `/fabricate/`. Confirm:
- Full generation UI works, Generate enabled
- `IS_SITE_BOX` is `false` — all routes use legacy ComfyUI paths
- S3 browsing works (still using `/fabricate/api/s3-*` on GPU)
- Queue isolation from Phase 1 still works
- WebSocket connects normally

- [ ] **Step 3: Test API 404 on site box**

```bash
curl -si https://fabricate.prismata.live/api/system_stats
```

Should return 404 JSON (not index.html). This confirms the GPU detection probe won't false-positive on the site box.

- [ ] **Step 4: Test presigned URL CORS**

In DevTools on `fabricate.prismata.live`, go to Network tab. Browse to a unit with a generated model. Confirm the `<model-viewer>` loads the GLB from an S3 presigned URL without CORS errors.
