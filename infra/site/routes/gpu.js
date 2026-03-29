'use strict';

const express = require('express');
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

// Helper: get GPU IP for this client, or the first ready GPU.
// Returns { ip, instanceId } or null.
function getGpuForClient(clientId) {
  // Try client assignment first
  if (clientId) {
    const assignment = db.getClientAssignment(clientId);
    if (assignment && assignment.private_ip) {
      db.touchClient(clientId);
      return { ip: assignment.private_ip, instanceId: assignment.gpu_instance_id };
    }
  }

  // Fall back to first ready GPU
  const gpu = db.getReadyGpu();
  if (!gpu || !gpu.private_ip) return null;

  // Auto-assign if client_id provided
  if (clientId) {
    db.assignClient(clientId, gpu.instance_id);
  }

  return { ip: gpu.private_ip, instanceId: gpu.instance_id };
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
        started_at: db.epochToIso(launchingGpus[0].launched_at),
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

  const gpuInfo = getGpuForClient(clientId);
  if (!gpuInfo) {
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  recordPromptRateLimit(clientId);

  // Forward to ComfyUI
  try {
    const gpuResp = await fetch(`http://${gpuInfo.ip}:8188/api/prompt`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req.body),
    });

    // Proxy JSON parsing with content-type fallback (Fix O)
    const contentType = gpuResp.headers.get('content-type') || '';
    if (contentType.includes('application/json')) {
      const data = await gpuResp.json();
      // Record prompt in DB with the actual GPU instance that was used
      if (data.prompt_id) {
        db.recordPrompt(data.prompt_id, clientId, gpuInfo.instanceId);
      }
      res.status(gpuResp.status).json(data);
    } else {
      const text = await gpuResp.text();
      res.status(gpuResp.status).type(contentType || 'text/plain').send(text);
    }
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
  const gpuInfo = getGpuForClient(clientId);
  if (!gpuInfo) {
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  try {
    const gpuResp = await fetch(`http://${gpuInfo.ip}:8188/api/queue`);
    // Proxy JSON parsing with content-type fallback (Fix O)
    const contentType = gpuResp.headers.get('content-type') || '';
    if (contentType.includes('application/json')) {
      const data = await gpuResp.json();
      res.status(gpuResp.status).json(data);
    } else {
      const text = await gpuResp.text();
      res.status(gpuResp.status).type(contentType || 'text/plain').send(text);
    }
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});

// GET /api/gpu/history/:promptId (Fix M: enforce active session)
router.get('/history/:promptId', async (req, res) => {
  const denied = checkAccess(res);
  if (denied) return;

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
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  try {
    const gpuResp = await fetch(`http://${gpuIp}:8188/api/history/${promptId}`);
    const contentType = gpuResp.headers.get('content-type') || '';
    if (contentType.includes('application/json')) {
      const data = await gpuResp.json();
      res.status(gpuResp.status).json(data);
    } else {
      const text = await gpuResp.text();
      res.status(gpuResp.status).type(contentType || 'text/plain').send(text);
    }
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});

// POST /api/gpu/metadata
router.post('/metadata', async (req, res) => {
  const denied = checkAccess(res);
  if (denied) return;

  const clientId = req.body.client_id;
  const gpuInfo = getGpuForClient(clientId);
  if (!gpuInfo) {
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  try {
    const gpuResp = await fetch(`http://${gpuInfo.ip}:8188/fabricate/metadata`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req.body),
    });
    // Proxy JSON parsing with content-type fallback (Fix O)
    const contentType = gpuResp.headers.get('content-type') || '';
    if (contentType.includes('application/json')) {
      const data = await gpuResp.json();
      res.status(gpuResp.status).json(data);
    } else {
      const text = await gpuResp.text();
      res.status(gpuResp.status).type(contentType || 'text/plain').send(text);
    }
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});

// GET /api/gpu/system_stats (Fix M: enforce active session)
router.get('/system_stats', async (req, res) => {
  const denied = checkAccess(res);
  if (denied) return;

  const gpu = db.getReadyGpu();
  if (!gpu || !gpu.private_ip) {
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  try {
    const gpuResp = await fetch(`http://${gpu.private_ip}:8188/system_stats`);
    const contentType = gpuResp.headers.get('content-type') || '';
    if (contentType.includes('application/json')) {
      const data = await gpuResp.json();
      res.status(gpuResp.status).json(data);
    } else {
      const text = await gpuResp.text();
      res.status(gpuResp.status).type(contentType || 'text/plain').send(text);
    }
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});

// POST /api/gpu/interrupt (Fix E: server-side ownership enforcement)
router.post('/interrupt', async (req, res) => {
  const denied = checkAccess(res);
  if (denied) return;

  const clientId = req.headers['x-client-id'] || req.body.client_id;
  if (!clientId) {
    return res.status(400).json({ error: 'X-Client-Id header or client_id required' });
  }

  const gpuInfo = getGpuForClient(clientId);
  if (!gpuInfo) {
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  // Server-side ownership check: verify running job belongs to this client (Fix E)
  try {
    const queueResp = await fetch(`http://${gpuInfo.ip}:8188/api/queue`);
    if (queueResp.ok) {
      const queue = await queueResp.json();
      const running = queue.queue_running || [];
      if (running.length > 0) {
        const runningExtraData = running[0][3] || {};
        if (runningExtraData.client_id && runningExtraData.client_id !== clientId) {
          return res.status(403).json({ error: 'Cannot interrupt another client\'s job' });
        }
      }
    }
  } catch (err) {
    // If queue check fails, allow the interrupt (fail-open for usability)
    console.warn('[gpu-proxy] Queue check failed during interrupt ownership check:', err.message);
  }

  try {
    const gpuResp = await fetch(`http://${gpuInfo.ip}:8188/api/interrupt`, { method: 'POST' });
    res.status(gpuResp.status).json({ ok: true });
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});

// POST /api/gpu/queue (delete items — Fix E: server-side ownership enforcement)
router.post('/queue', async (req, res) => {
  const denied = checkAccess(res);
  if (denied) return;

  const clientId = req.headers['x-client-id'] || req.body.client_id;
  if (!clientId) {
    return res.status(400).json({ error: 'X-Client-Id header or client_id required' });
  }

  const gpuInfo = getGpuForClient(clientId);
  if (!gpuInfo) {
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  // Server-side ownership: ignore client-supplied delete IDs, filter by caller's client_id (Fix E)
  try {
    const queueResp = await fetch(`http://${gpuInfo.ip}:8188/api/queue`);
    if (!queueResp.ok) {
      return res.status(502).json({ error: 'Failed to fetch queue from GPU' });
    }
    const queue = await queueResp.json();
    const pending = queue.queue_pending || [];
    const ownedIds = pending
      .filter(job => (job[3] || {}).client_id === clientId)
      .map(job => job[1]);

    if (ownedIds.length === 0) {
      return res.json({ status: 'ok', deleted: [] });
    }

    const gpuResp = await fetch(`http://${gpuInfo.ip}:8188/api/queue`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ delete: ownedIds }),
    });
    const contentType = gpuResp.headers.get('content-type') || '';
    if (contentType.includes('application/json')) {
      const data = await gpuResp.json();
      res.status(gpuResp.status).json(data);
    } else {
      const text = await gpuResp.text();
      res.status(gpuResp.status).type(contentType || 'text/plain').send(text);
    }
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});

// GET /api/gpu/view — proxy file downloads from GPU output dir (Fix M: enforce active session)
router.get('/view', async (req, res) => {
  const denied = checkAccess(res);
  if (denied) return;

  const gpu = db.getReadyGpu();
  if (!gpu || !gpu.private_ip) {
    return res.status(503).json({ status: 'gpu_offline', session_active: true });
  }

  const qs = new URLSearchParams(req.query).toString();
  try {
    const gpuResp = await fetch(`http://${gpu.private_ip}:8188/api/view?${qs}`);
    if (!gpuResp.ok) {
      return res.status(gpuResp.status).end();
    }
    // Pipe response headers and body (Fix O: content-type aware proxying)
    const contentType = gpuResp.headers.get('content-type') || 'application/octet-stream';
    res.set('Content-Type', contentType);
    const arrayBuffer = await gpuResp.arrayBuffer();
    res.send(Buffer.from(arrayBuffer));
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach GPU', detail: err.message });
  }
});

module.exports = router;
