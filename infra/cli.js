#!/usr/bin/env node
'use strict';

/**
 * CLI admin tool for the Fabrication Terminal.
 * Talks to the site box API over HTTPS.
 *
 * Usage:
 *   node infra/cli.js create-session --hours 24
 *   node infra/cli.js status
 *   node infra/cli.js revoke
 *   node infra/cli.js launch-gpu
 */

const API_BASE = 'https://fabricate.prismata.live';

const [,, command, ...args] = process.argv;

async function main() {
  switch (command) {
    case 'create-session': return await createSession();
    case 'status': return await getStatus();
    case 'revoke': return await revokeSession();
    case 'launch-gpu': return await launchGpu();
    default:
      console.log('Usage: node infra/cli.js <command>');
      console.log('Commands:');
      console.log('  create-session --hours <N>  Create a session directly (bypasses Discord)');
      console.log('  status                      Show current status');
      console.log('  revoke                      Revoke active session (GPU dies on next idle timeout)');
      console.log('  launch-gpu                  Force-launch a GPU (sets wake flag + launches)');
      process.exit(1);
  }
}

async function createSession() {
  let hours = 24;
  const hoursIdx = args.indexOf('--hours');
  if (hoursIdx !== -1 && args[hoursIdx + 1]) {
    hours = parseInt(args[hoursIdx + 1]);
  }

  const resp = await fetch(`${API_BASE}/api/admin/create-session`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Admin-Key': getAdminKey(),
    },
    body: JSON.stringify({ hours }),
  });
  const data = await resp.json();
  console.log(JSON.stringify(data, null, 2));
}

async function getStatus() {
  const resp = await fetch(`${API_BASE}/api/status`);
  const data = await resp.json();
  console.log(JSON.stringify(data, null, 2));
}

async function revokeSession() {
  const resp = await fetch(`${API_BASE}/api/admin/revoke-session`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Admin-Key': getAdminKey(),
    },
  });
  const data = await resp.json();
  console.log(JSON.stringify(data, null, 2));
}

async function launchGpu() {
  const resp = await fetch(`${API_BASE}/api/admin/launch-gpu`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Admin-Key': getAdminKey(),
    },
  });
  const data = await resp.json();
  console.log(JSON.stringify(data, null, 2));
}

function getAdminKey() {
  const key = process.env.FABRICATE_ADMIN_KEY;
  if (!key) {
    console.error('Set FABRICATE_ADMIN_KEY environment variable');
    process.exit(1);
  }
  return key;
}

main().catch(err => {
  console.error('Error:', err.message);
  process.exit(1);
});
