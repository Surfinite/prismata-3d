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
