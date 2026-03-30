'use strict';

const express = require('express');
const db = require('../lib/db');

const router = express.Router();

// GET /api/status — strictly read-only, never triggers side effects
//
// State precedence (Fix P — explicit and ordered):
//   1. No active session → 'browse' (or 'requesting', 'request_expired', 'request_denied', 'session_expired')
//   2. Pending request → 'requesting'
//   3. Active session + GPU ready → 'ready'
//   4. Active session + GPU launching → 'starting'
//   5. Active session + launch cooldown active + no GPU → 'launch_failed'
//   6. Active session + wake requested + no GPU → 'starting' (will launch on next tick)
//   7. Active session + no GPU + no wake → 'gpu_idle' (show Wake GPU button)
router.get('/status', (req, res) => {
  const session = db.getActiveSession();
  const pendingRequest = db.getPendingRequest();
  const latestRequest = db.getLatestRequest();
  const readyGpus = db.getGpuInstances('ready');
  const launchingGpus = db.getGpuInstances('launching');
  const lock = db.getLaunchLock();

  let state, message;

  if (session) {
    const remainingMs = (session.expires_at * 1000) - Date.now();

    // State precedence for active sessions (Fix P):
    // Session expiry is shown by the dedicated frontend countdown — not repeated in messages.
    // 3. GPU ready
    if (readyGpus.length > 0) {
      state = 'ready';
      message = 'GPU online';
    // 4. GPU launching
    } else if (launchingGpus.length > 0 || lock.inProgress) {
      state = 'starting';
      message = 'GPU starting up (~4 min)';
    // 5. Launch cooldown (failed) — checked before wake_requested because cooldown
    //    implies a recent failure even if wake is still set
    } else if (lock.cooldownUntil && Date.now() < lock.cooldownUntil && !session.wake_requested_at) {
      state = 'launch_failed';
      message = 'GPU launch failed — retrying shortly';
    // 6. Wake requested but not yet launched (reconciler will pick up next tick)
    } else if (session.wake_requested_at) {
      state = 'starting';
      message = 'GPU starting up';
    // 7. No GPU, no wake → idle
    } else {
      state = 'gpu_idle';
      message = 'GPU offline — click Wake GPU to start (~4 min)';
    }

    return res.json({
      state,
      message,
      session: {
        id: session.id,
        expires_at: db.epochToIso(session.expires_at),
        remaining_seconds: Math.max(0, Math.floor(remainingMs / 1000)),
      },
      gpu: readyGpus.length > 0 ? {
        instance_id: readyGpus[0].instance_id,
        slot: readyGpus[0].slot,
        ready_at: db.epochToIso(readyGpus[0].ready_at),
      } : null,
    });
  }

  // No active session — check request state
  if (pendingRequest) {
    state = 'requesting';
    message = 'Access requested — waiting for approval...';
    return res.json({
      state,
      message,
      request: {
        id: pendingRequest.id,
        expires_at: db.epochToIso(pendingRequest.expires_at),
      },
      session: null,
      gpu: null,
    });
  }

  // Check if latest request was expired or denied
  if (latestRequest) {
    if (latestRequest.status === 'expired') {
      state = 'request_expired';
      message = 'Request expired. Try again?';
      return res.json({ state, message, session: null, gpu: null });
    }
    if (latestRequest.status === 'denied') {
      state = 'request_denied';
      message = 'Request denied.';
      return res.json({ state, message, session: null, gpu: null });
    }
  }

  // Check for expired session
  const d = db.getDb();
  const lastSession = d.prepare(`
    SELECT * FROM sessions ORDER BY id DESC LIMIT 1
  `).get();
  if (lastSession && (lastSession.status === 'expired' || lastSession.status === 'revoked')) {
    state = 'session_expired';
    message = 'Session expired. Request new access.';
    return res.json({ state, message, session: null, gpu: null });
  }

  // Default: browse mode
  state = 'browse';
  message = 'GPU offline — browse models below';
  res.json({ state, message, session: null, gpu: null });
});

module.exports = router;
