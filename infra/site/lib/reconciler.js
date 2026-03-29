'use strict';

const { EC2Client, DescribeInstancesCommand, RunInstancesCommand } = require('@aws-sdk/client-ec2');
const db = require('./db');
const discord = require('./discord');

const REGION = process.env.AWS_REGION || 'us-east-1';
const ec2 = new EC2Client({ region: REGION });

const LAUNCH_TEMPLATE = 'prismata-3d-gen';
const TAG_KEY = 'Project';
const TAG_VALUE = 'prismata-3d-gen';
const SPOT_MAX_PRICE = '0.80';
const LAUNCH_TIMEOUT_MS = 5 * 60 * 1000; // 5 minutes
const HEALTH_CHECK_TIMEOUT_MS = 5000;

let reconcilerInterval = null;
let tickInProgress = false;

function start() {
  if (reconcilerInterval) return;
  console.log('[reconciler] Starting reconciler loop (5s interval)');
  reconcilerInterval = setInterval(tick, 5000);
  // Run first tick immediately
  tick();
}

function stop() {
  if (reconcilerInterval) {
    clearInterval(reconcilerInterval);
    reconcilerInterval = null;
  }
}

async function tick() {
  if (tickInProgress) return; // Prevent overlapping ticks
  tickInProgress = true;
  try {
    await reconcile();
  } catch (err) {
    console.error('[reconciler] Tick error:', err.message);
  } finally {
    tickInProgress = false;
  }
}

async function reconcile() {
  // 1. Expire stale requests and sessions
  const expiredRequests = db.expireStaleRequests();
  const expiredSessions = db.expireStaleSessions();
  if (expiredRequests > 0) console.log(`[reconciler] Expired ${expiredRequests} stale request(s)`);
  if (expiredSessions > 0) console.log(`[reconciler] Expired ${expiredSessions} stale session(s)`);

  // 2. Clean stale client assignments
  db.cleanStaleClientAssignments();

  // 3. Check for pending requests that need Discord polling
  await checkPendingRequests();

  // 4. Get active session
  const session = db.getActiveSession();

  // 5. Query EC2 for running instances
  const ec2Instances = await describeGpuInstances();

  // 6. Sync DB state with EC2 reality
  await syncInstanceState(ec2Instances, session);

  // 7. Health-check running GPUs
  await healthCheckInstances();

  // 8. Reconcile desired vs actual state (demand-based: only if wake requested)
  if (session) {
    await reconcileDesiredState(session);
  }
}

// ── Discord polling for pending requests ──

async function checkPendingRequests() {
  const req = db.getPendingRequest();
  if (!req) return;
  if (!req.discord_message_id || !req.discord_channel_id) return;

  const result = await discord.checkReactions(req.discord_channel_id, req.discord_message_id);
  if (result === 'approved') {
    console.log(`[reconciler] Request ${req.id} approved via Discord`);
    const session = db.approveRequest(req.id, 'discord_reaction');
    console.log(`[reconciler] Session ${session.id} created, expires ${db.epochToIso(session.expires_at)}, wake_requested_at set`);
  } else if (result === 'denied') {
    console.log(`[reconciler] Request ${req.id} denied via Discord`);
    db.denyRequest(req.id);
  }
}

// ── EC2 instance discovery ──

async function describeGpuInstances() {
  try {
    const resp = await ec2.send(new DescribeInstancesCommand({
      Filters: [
        { Name: `tag:${TAG_KEY}`, Values: [TAG_VALUE] },
        { Name: 'instance-state-name', Values: ['pending', 'running'] },
      ],
    }));
    const instances = [];
    for (const res of resp.Reservations || []) {
      for (const inst of res.Instances || []) {
        if (['pending', 'running'].includes(inst.State.Name)) {
          // Extract Slot and SessionId tags for rediscovery on restart
          const tags = {};
          for (const tag of inst.Tags || []) {
            tags[tag.Key] = tag.Value;
          }
          instances.push({
            instanceId: inst.InstanceId,
            state: inst.State.Name,
            privateIp: inst.PrivateIpAddress || null,
            launchTime: inst.LaunchTime,
            lifecycle: inst.InstanceLifecycle || 'on-demand',
            slot: tags['Slot'] || null,
            sessionId: tags['SessionId'] ? parseInt(tags['SessionId']) : null,
          });
        }
      }
    }
    return instances;
  } catch (err) {
    console.error('[reconciler] EC2 describe error:', err.message);
    return [];
  }
}

// ── Sync DB with EC2 reality ──

async function syncInstanceState(ec2Instances, session) {
  const dbInstances = db.getGpuInstances(); // launching + ready
  const ec2Ids = new Set(ec2Instances.map(i => i.instanceId));
  const dbIds = new Set(dbInstances.map(i => i.instance_id));

  // Instance in DB but not in EC2 → mark gone
  for (const dbInst of dbInstances) {
    if (!ec2Ids.has(dbInst.instance_id)) {
      console.log(`[reconciler] Instance ${dbInst.instance_id} not in EC2, marking gone`);
      db.markGpuGone(dbInst.instance_id);
      // If this was a launching instance, clear the launch lock
      if (dbInst.status === 'launching') {
        db.setLaunchLock(false);
        db.setLaunchCooldown();
      }
    }
  }

  // Instance in EC2 but not in DB → register it (discovered instance)
  // Uses Slot and SessionId tags from EC2 for accurate rediscovery on site box restart
  for (const ec2Inst of ec2Instances) {
    if (!dbIds.has(ec2Inst.instanceId)) {
      const slot = ec2Inst.slot || 'A'; // Phase 3: always slot A (Fix B)
      const sessId = ec2Inst.sessionId || session?.id || null;
      console.log(`[reconciler] Discovered instance ${ec2Inst.instanceId} (slot=${slot}, session=${sessId}), registering`);
      db.registerGpuInstance(ec2Inst.instanceId, slot, sessId);
      if (ec2Inst.privateIp) {
        // Try a quick health check
        const healthy = await healthCheck(ec2Inst.privateIp);
        if (healthy) {
          db.markGpuReady(ec2Inst.instanceId, ec2Inst.privateIp);
        }
      }
    }
  }

  // Update private IPs for launching instances that now have one
  for (const ec2Inst of ec2Instances) {
    if (dbIds.has(ec2Inst.instanceId)) {
      const dbInst = dbInstances.find(i => i.instance_id === ec2Inst.instanceId);
      if (dbInst && dbInst.status === 'launching' && !dbInst.private_ip && ec2Inst.privateIp) {
        // IP available but not yet marked ready — store it for next health check
        db.getDb().prepare('UPDATE gpu_instances SET private_ip = ? WHERE instance_id = ?')
          .run(ec2Inst.privateIp, ec2Inst.instanceId);
      }
    }
  }
}

// ── Health checks ──

async function healthCheck(privateIp) {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), HEALTH_CHECK_TIMEOUT_MS);
    const resp = await fetch(`http://${privateIp}:8188/system_stats`, {
      signal: controller.signal,
    });
    clearTimeout(timeout);
    return resp.ok;
  } catch {
    return false;
  }
}

async function healthCheckInstances() {
  const instances = db.getGpuInstances();

  for (const inst of instances) {
    if (!inst.private_ip) continue;

    const healthy = await healthCheck(inst.private_ip);

    if (inst.status === 'launching' && healthy) {
      console.log(`[reconciler] Instance ${inst.instance_id} is healthy, marking ready`);
      db.markGpuReady(inst.instance_id, inst.private_ip);
      db.resetHealthFailures(inst.instance_id);
      db.setLaunchLock(false);

      // Clear wake_requested_at only AFTER GPU becomes ready, not after RunInstances (Fix C)
      const session = db.getActiveSession();
      if (session && session.wake_requested_at) {
        db.clearWakeRequested(session.id);
      }
    }

    if (inst.status === 'ready' && healthy) {
      // Reset health failure counter on successful check (Fix D)
      db.resetHealthFailures(inst.instance_id);
    }

    if (inst.status === 'ready' && !healthy) {
      // Track consecutive health check failures (Fix D)
      const failures = db.incrementHealthFailures(inst.instance_id);
      console.warn(`[reconciler] Health check failed for ready instance ${inst.instance_id} (${failures}/6)`);
      if (failures >= 6) {
        // 6 consecutive failures (30 seconds at 5s interval) → mark gone
        console.error(`[reconciler] Instance ${inst.instance_id} unhealthy after ${failures} consecutive failures, marking gone`);
        db.markGpuGone(inst.instance_id);
        // If wake is still requested, reconciler will relaunch on next tick
      }
    }
  }

  // Check for launch timeout (Fix C: launch failure detection)
  const lock = db.getLaunchLock();
  if (lock.inProgress && lock.timestamp) {
    const elapsed = Date.now() - lock.timestamp;
    if (elapsed > LAUNCH_TIMEOUT_MS) {
      console.error('[reconciler] Launch timed out after 5 minutes');
      // Mark any launching instances as gone, but leave wake_requested_at so reconciler retries
      const launching = db.getGpuInstances('launching');
      for (const inst of launching) {
        db.markGpuGone(inst.instance_id);
      }
      db.setLaunchLock(false);
      db.setLaunchCooldown();
      // wake_requested_at is intentionally NOT cleared here — allows automatic retry (Fix C)
    }
  }
}

// ── Desired state reconciliation (demand-based) ──

async function reconcileDesiredState(session) {
  const readyGpus = db.getGpuInstances('ready');
  const launchingGpus = db.getGpuInstances('launching');
  const lock = db.getLaunchLock();

  // Demand-based: only launch if wake_requested_at is set
  // Session active + wake requested + no GPU running + no launch in progress → launch GPU
  if (session.wake_requested_at && readyGpus.length === 0 && launchingGpus.length === 0 && !lock.inProgress) {
    if (db.isLaunchCoolingDown()) {
      return; // Respect cooldown
    }
    await launchGpu(session);
  }
}

async function launchGpu(session) {
  // Phase 3: hard-limit to 1 GPU (Fix B)
  if (!db.canLaunchGpu()) {
    console.log('[reconciler] GPU already launching or ready, refusing new launch');
    return;
  }

  const slot = 'A'; // Phase 3: always slot A (Fix B)
  console.log(`[reconciler] Launching GPU instance (slot ${slot}) for session ${session.id}`);
  db.setLaunchLock(true);

  try {
    const resp = await ec2.send(new RunInstancesCommand({
      LaunchTemplate: { LaunchTemplateName: LAUNCH_TEMPLATE },
      MinCount: 1,
      MaxCount: 1,
      InstanceMarketOptions: {
        MarketType: 'spot',
        SpotOptions: {
          MaxPrice: SPOT_MAX_PRICE,
          SpotInstanceType: 'one-time',
          InstanceInterruptionBehavior: 'terminate',
        },
      },
      TagSpecifications: [{
        ResourceType: 'instance',
        Tags: [
          { Key: TAG_KEY, Value: TAG_VALUE },
          { Key: 'Slot', Value: slot },
          { Key: 'SessionId', Value: String(session.id) },
        ],
      }],
    }));

    const instanceId = resp.Instances[0].InstanceId;
    console.log(`[reconciler] Launched instance ${instanceId}`);
    db.registerGpuInstance(instanceId, slot, session.id);

    // wake_requested_at is NOT cleared here — only cleared when GPU becomes ready (Fix C)
  } catch (err) {
    console.error('[reconciler] Launch failed:', err.message);
    db.setLaunchLock(false);
    db.setLaunchCooldown();
  }
}

// ── Public API for CLI force-launch (part of the reconciler module) ──

async function forceLaunch() {
  const session = db.getActiveSession();
  if (!session) throw new Error('No active session');
  const lock = db.getLaunchLock();
  if (lock.inProgress) throw new Error('Launch already in progress');
  // Refuse if any GPU exists (Fix B)
  if (!db.canLaunchGpu()) throw new Error('GPU already launching or ready');
  // Set wake flag and launch
  db.setWakeRequested(session.id);
  await launchGpu(session);
}

module.exports = {
  start,
  stop,
  forceLaunch,
  // Exported for testing/CLI
  describeGpuInstances,
  healthCheck,
};
