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

// Admin routes are optional (created in a later phase)
let adminRoutes;
try {
  adminRoutes = require('./routes/admin');
} catch (e) {
  adminRoutes = null;
}

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
if (adminRoutes) {
  app.use('/api/admin', adminRoutes);
}

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

  // ── Session enforcement (Fix 3) ──
  // Check for active session before allowing WebSocket connection
  const session = db.getActiveSession();
  if (!session) {
    socket.write('HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\n\r\nNo active session\r\n');
    socket.destroy();
    return;
  }

  // Check for ready GPU
  const readyGpu = db.getReadyGpu();
  if (!readyGpu || !readyGpu.private_ip) {
    socket.write('HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\n\r\nNo ready GPU\r\n');
    socket.destroy();
    return;
  }

  // Require clientId query param (Fix L)
  const clientId = url.searchParams.get('clientId');
  if (!clientId) {
    socket.write('HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nclientId query parameter required\r\n');
    socket.destroy();
    return;
  }

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
