'use strict';

const express = require('express');
const db = require('../lib/db');
const reconciler = require('../lib/reconciler');

const router = express.Router();

// Admin key from environment
const ADMIN_KEY = process.env.ADMIN_KEY || '';

function requireAdmin(req, res, next) {
  if (!ADMIN_KEY) {
    return res.status(500).json({ error: 'Admin key not configured on server' });
  }
  const key = req.headers['x-admin-key'];
  if (key !== ADMIN_KEY) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
}

// POST /api/admin/create-session
router.post('/create-session', requireAdmin, (req, res) => {
  const hours = req.body.hours || 24;
  try {
    const session = db.createSessionDirect(hours);
    console.log(`[admin] Session ${session.id} created directly, expires ${db.epochToIso(session.expires_at)}`);
    res.json({ ok: true, session: { ...session, expires_at_iso: db.epochToIso(session.expires_at) } });
  } catch (err) {
    return res.status(409).json({ ok: false, error: err.message });
  }
});

// POST /api/admin/revoke-session
// NOTE: Revoke sets session to 'revoked'. It does NOT immediately terminate the GPU.
// The GPU dies on its next idle timeout (20min watchdog). The reconciler will not
// re-launch a GPU after revoke because there is no active session.
router.post('/revoke-session', requireAdmin, (req, res) => {
  const session = db.getActiveSession();
  if (!session) {
    return res.json({ ok: false, error: 'No active session' });
  }
  db.revokeSession(session.id);
  console.log(`[admin] Session ${session.id} revoked (GPU will die on next idle timeout)`);
  res.json({ ok: true, session_id: session.id, note: 'GPU will terminate on next idle timeout (up to 20min)' });
});

// POST /api/admin/launch-gpu
router.post('/launch-gpu', requireAdmin, async (req, res) => {
  try {
    await reconciler.forceLaunch();
    res.json({ ok: true, message: 'GPU launch initiated' });
  } catch (err) {
    res.status(400).json({ ok: false, error: err.message });
  }
});

module.exports = router;
