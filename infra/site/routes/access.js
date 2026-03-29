'use strict';

const express = require('express');
const db = require('../lib/db');
const discord = require('../lib/discord');

const router = express.Router();

// In-memory rate limit: 1 request per IP per 5 minutes
const rateLimitMap = new Map();
const RATE_LIMIT_MS = 5 * 60 * 1000;

function isRateLimited(ip) {
  const last = rateLimitMap.get(ip);
  if (last && Date.now() - last < RATE_LIMIT_MS) {
    return true;
  }
  return false;
}

function recordRateLimit(ip) {
  rateLimitMap.set(ip, Date.now());
  // Clean old entries every 100 inserts
  if (rateLimitMap.size > 100) {
    const cutoff = Date.now() - RATE_LIMIT_MS;
    for (const [k, v] of rateLimitMap) {
      if (v < cutoff) rateLimitMap.delete(k);
    }
  }
}

// POST /api/request-access
router.post('/request-access', async (req, res) => {
  const ip = req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.ip;

  // Check rate limit
  if (isRateLimited(ip)) {
    const last = rateLimitMap.get(ip);
    const retryAfter = Math.ceil((RATE_LIMIT_MS - (Date.now() - last)) / 1000);
    return res.status(429).json({
      error: 'Rate limited. Try again later.',
      retry_after_seconds: retryAfter,
    });
  }

  // Check if there's already an active session
  const activeSession = db.getActiveSession();
  if (activeSession) {
    return res.json({
      status: 'already_active',
      session: {
        id: activeSession.id,
        expires_at: db.epochToIso(activeSession.expires_at),
      },
    });
  }

  // Check if there's already a pending request
  const pendingRequest = db.getPendingRequest();
  if (pendingRequest) {
    return res.json({
      status: 'already_pending',
      request: {
        id: pendingRequest.id,
        expires_at: db.epochToIso(pendingRequest.expires_at),
      },
    });
  }

  // Create request
  recordRateLimit(ip);
  const request = db.createRequest(ip);

  // Send Discord notification — roll back request on failure
  try {
    const discordResult = await discord.sendAccessRequest(request.id, ip);
    db.updateRequestDiscord(request.id, discordResult.messageId, discordResult.channelId);
  } catch (err) {
    console.error('[access] Discord notification failed for request', request.id, ':', err.message);
    // Roll back: delete the request row so no phantom pending request exists
    db.deleteRequest(request.id);
    return res.status(500).json({
      error: 'Failed to send Discord notification. Please try again.',
    });
  }

  res.json({
    status: 'pending',
    request: {
      id: request.id,
      expires_at: db.epochToIso(request.expires_at),
    },
  });
});

// POST /api/wake-gpu — user clicks "Wake GPU" button to request a GPU launch
router.post('/wake-gpu', (req, res) => {
  const session = db.getActiveSession();
  if (!session) {
    return res.status(403).json({ error: 'No active session' });
  }

  // Check if GPU is already running or launching
  const readyGpus = db.getGpuInstances('ready');
  const launchingGpus = db.getGpuInstances('launching');
  if (readyGpus.length > 0) {
    return res.json({ status: 'already_ready', message: 'GPU is already online' });
  }
  if (launchingGpus.length > 0) {
    return res.json({ status: 'already_launching', message: 'GPU is already starting up' });
  }

  // Set wake flag — reconciler will pick this up on next tick
  db.setWakeRequested(session.id);
  console.log(`[access] Wake GPU requested for session ${session.id}`);

  res.json({ status: 'wake_requested', message: 'GPU launch requested — starting up (~4 min)' });
});

module.exports = router;
