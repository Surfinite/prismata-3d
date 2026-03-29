'use strict';

const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');

const REGION = process.env.AWS_REGION || 'us-east-1';
const ssm = new SSMClient({ region: REGION });

// Cache SSM values
let discordWebhookUrl = null;
let discordBotToken = null;
let discordChannelId = null;

async function getSSMParam(name) {
  try {
    const resp = await ssm.send(new GetParameterCommand({
      Name: name,
      WithDecryption: true,
    }));
    return resp.Parameter.Value;
  } catch (err) {
    console.error(`[discord] Failed to get SSM param ${name}:`, err.message);
    return null;
  }
}

async function ensureConfig() {
  if (!discordWebhookUrl) {
    discordWebhookUrl = await getSSMParam('/prismata-3d/discord-webhook-url');
  }
  if (!discordBotToken) {
    discordBotToken = await getSSMParam('/prismata-3d/discord-bot-token');
  }
  if (!discordChannelId) {
    discordChannelId = await getSSMParam('/prismata-3d/discord-channel-id');
  }
}

/**
 * Send an access request notification to Discord via webhook.
 * Returns the message ID so we can poll for reactions.
 * Throws on failure so the caller can roll back.
 */
async function sendAccessRequest(requestId, requesterIp) {
  await ensureConfig();
  if (!discordWebhookUrl) {
    throw new Error('No Discord webhook URL configured');
  }

  // Use webhook with ?wait=true to get the message object back
  const webhookWaitUrl = discordWebhookUrl.includes('?')
    ? `${discordWebhookUrl}&wait=true`
    : `${discordWebhookUrl}?wait=true`;

  const body = {
    content: `**Fabrication Terminal Access Request** (ID: ${requestId})\n` +
      `IP: \`${requesterIp}\`\n` +
      `React with ✅ to approve or ❌ to deny.\n` +
      `Expires in 1 hour.\n` +
      `<@292290258777800704>`,  // @Surfinite user ID
    allowed_mentions: { users: ['292290258777800704'] },
  };

  const resp = await fetch(webhookWaitUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });

  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`Discord webhook failed ${resp.status}: ${text}`);
  }

  const msg = await resp.json();
  // Use webhook's channel_id, fall back to SSM-configured channel (Fix H)
  return { messageId: msg.id, channelId: msg.channel_id || discordChannelId };
}

/**
 * Check if the request message has a ✅ or ❌ reaction from the owner.
 * Uses the Discord bot token to read reactions.
 * Returns: 'approved' | 'denied' | null
 */
async function checkReactions(channelId, messageId) {
  await ensureConfig();
  if (!discordBotToken || !channelId || !messageId) return null;

  const OWNER_ID = '292290258777800704'; // Surfinite's Discord user ID

  // Check for ✅ reaction
  try {
    const approveResp = await fetch(
      `https://discord.com/api/v10/channels/${channelId}/messages/${messageId}/reactions/${encodeURIComponent('✅')}`,
      { headers: { Authorization: `Bot ${discordBotToken}` } }
    );
    if (approveResp.ok) {
      const users = await approveResp.json();
      if (users.some(u => u.id === OWNER_ID)) {
        return 'approved';
      }
    }
  } catch (err) {
    console.error('[discord] Reaction check (approve) error:', err.message);
  }

  // Check for ❌ reaction
  try {
    const denyResp = await fetch(
      `https://discord.com/api/v10/channels/${channelId}/messages/${messageId}/reactions/${encodeURIComponent('❌')}`,
      { headers: { Authorization: `Bot ${discordBotToken}` } }
    );
    if (denyResp.ok) {
      const users = await denyResp.json();
      if (users.some(u => u.id === OWNER_ID)) {
        return 'denied';
      }
    }
  } catch (err) {
    console.error('[discord] Reaction check (deny) error:', err.message);
  }

  return null;
}

module.exports = {
  sendAccessRequest,
  checkReactions,
};
