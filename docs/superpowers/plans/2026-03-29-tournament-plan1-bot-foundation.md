# Tournament Platform Plan 1: Discord Bot + Database Foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Working Giselle v2 Discord bot with legacy features, tournament database schema, replay validation library, and account verification — all running on the Data Box alongside the existing spectator infrastructure.

**Architecture:** The bot is a Node.js app living in the `prismata-ladder` repo alongside the existing Python backend. It uses `better-sqlite3` for direct SQLite access (WAL mode handles concurrent reads/writes with the Python export scripts). Slash commands replace the old message-based detection for new features, while legacy replay/unit detection continues via message events.

**Tech Stack:** Node.js 20+, discord.js v14, better-sqlite3, zlib (built-in), node:http (built-in)

**Spec:** `c:\libraries\prismata-3d\docs\superpowers\specs\2026-03-28-prismata-tournament-platform-design.md`

**Related plans:**
- Plan 2: Tournament Engine (bracket lifecycle, scheduling, nagging, show matches)
- Plan 3: Website Extensions (Discord OAuth, tournament pages, profiles)

---

## File Structure

All new files live in `<PRISMATA_LADDER_REPO>/bot\`:

```
prismata-ladder/
├── bot/                              # Giselle v2 Discord bot (NEW)
│   ├── package.json                  # Bot dependencies
│   ├── index.js                      # Entry point: client setup, event routing
│   ├── deploy-commands.js            # One-shot script to register slash commands
│   ├── db.js                         # SQLite connection + schema migration
│   ├── schema.sql                    # Tournament tables (CREATE IF NOT EXISTS)
│   ├── config.js                     # Configuration from environment variables
│   ├── lib/
│   │   ├── replay-fetcher.js         # Fetch + gunzip replays from S3
│   │   └── replay-validator.js       # Validate replay against tournament/verification rules
│   ├── handlers/
│   │   ├── replay-embed.js           # Legacy: detect replay codes in messages, post embed
│   │   └── unit-embed.js             # Legacy: detect [[Unit]] in messages, post embed
│   ├── commands/
│   │   ├── verify.js                 # /verify — account verification (Method B: challenge replay)
│   │   └── profile.js                # /profile — player stats and tournament history
│   └── __tests__/
│       ├── replay-fetcher.test.js    # Tests for S3 fetch + gunzip
│       ├── replay-validator.test.js  # Tests for validation logic
│       └── db.test.js                # Tests for schema creation + queries
├── tournament_export.py              # Export tournament data to JSON (NEW, Plan 2)
└── (existing files unchanged)
```

**Modified files:**
- `prismata-ladder/aws/deploy_spectator.sh` — add bot deployment alongside Python services

---

## Task 1: Bot Package Setup

**Files:**
- Create: `bot/package.json`
- Create: `bot/.gitignore`

- [ ] **Step 1: Create package.json**

```json
{
  "name": "giselle-v2",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "description": "Prismata tournament Discord bot",
  "main": "index.js",
  "scripts": {
    "start": "node index.js",
    "deploy-commands": "node deploy-commands.js",
    "test": "node --test __tests__/*.test.js"
  },
  "dependencies": {
    "better-sqlite3": "^11.0.0",
    "discord.js": "^14.16.0"
  }
}
```

- [ ] **Step 2: Create .gitignore**

```
node_modules/
bot.env
```

- [ ] **Step 3: Install dependencies**

Run: `cd <PRISMATA_LADDER_REPO>/bot && npm install`
Expected: `node_modules/` created with discord.js v14 and better-sqlite3

- [ ] **Step 4: Commit**

```bash
cd <PRISMATA_LADDER_REPO>
git add bot/package.json bot/package-lock.json bot/.gitignore
git commit -m "feat(bot): scaffold Giselle v2 package with discord.js v14"
```

---

## Task 2: Configuration

**Files:**
- Create: `bot/config.js`
- Create: `bot/bot.env.example`

- [ ] **Step 1: Create config module**

```javascript
// bot/config.js
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Load .env file if present (production: set env vars directly)
const envPath = resolve(__dirname, 'bot.env');
if (existsSync(envPath)) {
  for (const line of readFileSync(envPath, 'utf-8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq);
    const val = trimmed.slice(eq + 1);
    if (!process.env[key]) process.env[key] = val;
  }
}

function required(key) {
  const val = process.env[key];
  if (!val) throw new Error(`Missing required env var: ${key}`);
  return val;
}

export const config = {
  discordToken: required('DISCORD_TOKEN'),
  clientId: required('DISCORD_CLIENT_ID'),
  guildId: process.env.DISCORD_GUILD_ID || null, // optional: restrict commands to one server
  dbPath: process.env.DB_PATH || resolve(__dirname, '..', 'prismata_ladder.db'),
  replayBaseUrl: process.env.REPLAY_BASE_URL || 'http://saved-games-alpha.s3-website-us-east-1.amazonaws.com',
  opsWebhookUrl: process.env.OPS_WEBHOOK_URL || null, // #prismata-ops webhook
};
```

- [ ] **Step 2: Create example env file**

```bash
# bot/bot.env.example
DISCORD_TOKEN=your-bot-token-here
DISCORD_CLIENT_ID=your-client-id-here
DISCORD_GUILD_ID=optional-guild-id-for-dev
DB_PATH=../prismata_ladder.db
```

- [ ] **Step 3: Commit**

```bash
git add bot/config.js bot/bot.env.example
git commit -m "feat(bot): add configuration from environment variables"
```

---

## Task 3: Database Schema + Connection

**Files:**
- Create: `bot/schema.sql`
- Create: `bot/db.js`
- Create: `bot/__tests__/db.test.js`

- [ ] **Step 1: Create schema.sql**

This contains only the NEW tournament tables. The existing `players`, `games`, `events`, `replay_of_day`, `replays` tables are untouched.

```sql
-- bot/schema.sql
-- Tournament platform tables (added alongside existing ladder tables)

CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    discord_id TEXT UNIQUE NOT NULL,
    discord_username TEXT NOT NULL,
    prismata_username TEXT UNIQUE,
    verified INTEGER DEFAULT 0,
    role TEXT DEFAULT 'player',
    tournament_rating REAL,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS verification_challenges (
    id INTEGER PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    claimed_username TEXT NOT NULL,
    challenge_bot TEXT NOT NULL,
    challenge_time_control INTEGER NOT NULL,
    challenge_randomizer_count INTEGER NOT NULL,
    replay_code TEXT,
    status TEXT DEFAULT 'pending',
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS tournaments (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    format TEXT NOT NULL,
    rules_json TEXT NOT NULL,
    status TEXT DEFAULT 'registration',
    created_by INTEGER REFERENCES users(id),
    max_players INTEGER,
    registration_deadline TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS tournament_players (
    tournament_id INTEGER REFERENCES tournaments(id),
    user_id INTEGER REFERENCES users(id),
    seed INTEGER,
    status TEXT DEFAULT 'registered',
    PRIMARY KEY (tournament_id, user_id)
);

CREATE TABLE IF NOT EXISTS tournament_rounds (
    id INTEGER PRIMARY KEY,
    tournament_id INTEGER REFERENCES tournaments(id),
    round_number INTEGER NOT NULL,
    deadline TEXT,
    status TEXT DEFAULT 'pending'
);

CREATE TABLE IF NOT EXISTS tournament_matches (
    id INTEGER PRIMARY KEY,
    tournament_id INTEGER REFERENCES tournaments(id),
    round_id INTEGER REFERENCES tournament_rounds(id),
    player1_id INTEGER REFERENCES users(id),
    player2_id INTEGER REFERENCES users(id),
    winner_id INTEGER REFERENCES users(id),
    status TEXT DEFAULT 'pending',
    best_of INTEGER DEFAULT 1,
    deadline TEXT
);

CREATE TABLE IF NOT EXISTS match_games (
    id INTEGER PRIMARY KEY,
    match_id INTEGER REFERENCES tournament_matches(id),
    replay_code TEXT UNIQUE NOT NULL,
    game_number INTEGER,
    winner_id INTEGER REFERENCES users(id),
    validated INTEGER DEFAULT 0,
    replay_json TEXT
);

CREATE TABLE IF NOT EXISTS challenges (
    id INTEGER PRIMARY KEY,
    challenger_id INTEGER REFERENCES users(id),
    challenged_id INTEGER REFERENCES users(id),
    best_of INTEGER DEFAULT 3,
    rules_json TEXT,
    status TEXT DEFAULT 'pending',
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS challenge_games (
    id INTEGER PRIMARY KEY,
    challenge_id INTEGER REFERENCES challenges(id),
    replay_code TEXT UNIQUE NOT NULL,
    game_number INTEGER,
    winner_id INTEGER REFERENCES users(id),
    validated INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS disputes (
    id INTEGER PRIMARY KEY,
    match_id INTEGER REFERENCES tournament_matches(id),
    challenge_id INTEGER REFERENCES challenges(id),
    raised_by INTEGER REFERENCES users(id),
    reason TEXT,
    resolved_by INTEGER REFERENCES users(id),
    resolution TEXT,
    status TEXT DEFAULT 'open',
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS used_replay_codes (
    replay_code TEXT PRIMARY KEY,
    used_for TEXT NOT NULL,
    used_at TEXT DEFAULT (datetime('now'))
);
```

- [ ] **Step 2: Create db.js**

```javascript
// bot/db.js
import Database from 'better-sqlite3';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { config } from './config.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SCHEMA_PATH = resolve(__dirname, 'schema.sql');

let _db = null;

export function getDb() {
  if (_db) return _db;

  _db = new Database(config.dbPath);
  _db.pragma('journal_mode = WAL');
  _db.pragma('busy_timeout = 30000');
  _db.pragma('synchronous = NORMAL');

  // Run tournament schema migration (CREATE IF NOT EXISTS is safe to re-run)
  const schema = readFileSync(SCHEMA_PATH, 'utf-8');
  _db.exec(schema);

  return _db;
}

export function closeDb() {
  if (_db) {
    _db.close();
    _db = null;
  }
}

// --- User queries ---

export function findOrCreateUser(discordId, discordUsername) {
  const db = getDb();
  const existing = db.prepare('SELECT * FROM users WHERE discord_id = ?').get(discordId);
  if (existing) {
    // Update username if changed
    if (existing.discord_username !== discordUsername) {
      db.prepare('UPDATE users SET discord_username = ? WHERE id = ?').run(discordUsername, existing.id);
    }
    return { ...existing, discord_username: discordUsername };
  }
  const result = db.prepare(
    'INSERT INTO users (discord_id, discord_username) VALUES (?, ?)'
  ).run(discordId, discordUsername);
  return db.prepare('SELECT * FROM users WHERE id = ?').get(result.lastInsertRowid);
}

export function getUserByDiscordId(discordId) {
  return getDb().prepare('SELECT * FROM users WHERE discord_id = ?').get(discordId);
}

export function getUserByPrismataName(name) {
  return getDb().prepare('SELECT * FROM users WHERE prismata_username = ? COLLATE NOCASE').get(name);
}

export function verifyUser(userId, prismataUsername) {
  getDb().prepare(
    'UPDATE users SET prismata_username = ?, verified = 1 WHERE id = ?'
  ).run(prismataUsername, userId);
}

// --- Verification challenge queries ---

export function createVerificationChallenge(userId, claimedUsername, bot, timeControl, randomizerCount) {
  const db = getDb();
  // Expire any pending challenges for this user
  db.prepare(
    "UPDATE verification_challenges SET status = 'expired' WHERE user_id = ? AND status = 'pending'"
  ).run(userId);
  const result = db.prepare(
    'INSERT INTO verification_challenges (user_id, claimed_username, challenge_bot, challenge_time_control, challenge_randomizer_count) VALUES (?, ?, ?, ?, ?)'
  ).run(userId, claimedUsername, bot, timeControl, randomizerCount);
  return db.prepare('SELECT * FROM verification_challenges WHERE id = ?').get(result.lastInsertRowid);
}

export function getPendingChallenge(userId) {
  return getDb().prepare(
    "SELECT * FROM verification_challenges WHERE user_id = ? AND status = 'pending' ORDER BY created_at DESC LIMIT 1"
  ).get(userId);
}

export function completeChallenge(challengeId, replayCode) {
  getDb().prepare(
    "UPDATE verification_challenges SET status = 'verified', replay_code = ? WHERE id = ?"
  ).run(replayCode, challengeId);
}

// --- Replay deduplication ---

export function isReplayCodeUsed(replayCode) {
  return !!getDb().prepare('SELECT 1 FROM used_replay_codes WHERE replay_code = ?').get(replayCode);
}

export function markReplayCodeUsed(replayCode, usedFor) {
  getDb().prepare(
    'INSERT OR IGNORE INTO used_replay_codes (replay_code, used_for) VALUES (?, ?)'
  ).run(replayCode, usedFor);
}
```

- [ ] **Step 3: Write test**

```javascript
// bot/__tests__/db.test.js
import { describe, it, before, after } from 'node:test';
import assert from 'node:assert';
import Database from 'better-sqlite3';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SCHEMA_PATH = resolve(__dirname, '..', 'schema.sql');

describe('Tournament schema', () => {
  let db;

  before(() => {
    db = new Database(':memory:');
    db.pragma('journal_mode = WAL');
    const schema = readFileSync(SCHEMA_PATH, 'utf-8');
    db.exec(schema);
  });

  after(() => db.close());

  it('creates all tournament tables', () => {
    const tables = db.prepare(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
    ).all().map(r => r.name);

    assert.ok(tables.includes('users'));
    assert.ok(tables.includes('verification_challenges'));
    assert.ok(tables.includes('tournaments'));
    assert.ok(tables.includes('tournament_players'));
    assert.ok(tables.includes('tournament_rounds'));
    assert.ok(tables.includes('tournament_matches'));
    assert.ok(tables.includes('match_games'));
    assert.ok(tables.includes('challenges'));
    assert.ok(tables.includes('challenge_games'));
    assert.ok(tables.includes('disputes'));
    assert.ok(tables.includes('used_replay_codes'));
  });

  it('inserts and retrieves a user', () => {
    db.prepare('INSERT INTO users (discord_id, discord_username) VALUES (?, ?)').run('123', 'TestUser');
    const user = db.prepare('SELECT * FROM users WHERE discord_id = ?').get('123');
    assert.equal(user.discord_username, 'TestUser');
    assert.equal(user.verified, 0);
    assert.equal(user.role, 'player');
  });

  it('enforces unique discord_id', () => {
    assert.throws(() => {
      db.prepare('INSERT INTO users (discord_id, discord_username) VALUES (?, ?)').run('123', 'Duplicate');
    });
  });

  it('enforces unique replay codes in match_games', () => {
    db.prepare('INSERT INTO match_games (replay_code) VALUES (?)').run('ABCDE-FGHIJ');
    assert.throws(() => {
      db.prepare('INSERT INTO match_games (replay_code) VALUES (?)').run('ABCDE-FGHIJ');
    });
  });

  it('tracks used replay codes', () => {
    db.prepare("INSERT INTO used_replay_codes (replay_code, used_for) VALUES (?, ?)").run('XXXXX-YYYYY', 'verification');
    const row = db.prepare('SELECT * FROM used_replay_codes WHERE replay_code = ?').get('XXXXX-YYYYY');
    assert.equal(row.used_for, 'verification');
  });

  it('schema is idempotent (safe to re-run)', () => {
    const schema = readFileSync(SCHEMA_PATH, 'utf-8');
    assert.doesNotThrow(() => db.exec(schema));
  });
});
```

- [ ] **Step 4: Run tests**

Run: `cd <PRISMATA_LADDER_REPO>/bot && npm test`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add bot/schema.sql bot/db.js bot/__tests__/db.test.js
git commit -m "feat(bot): add tournament database schema and connection layer"
```

---

## Task 4: Replay Fetcher Library

**Files:**
- Create: `bot/lib/replay-fetcher.js`
- Create: `bot/__tests__/replay-fetcher.test.js`

- [ ] **Step 1: Create replay fetcher**

```javascript
// bot/lib/replay-fetcher.js
import { get } from 'node:http';
import { gunzipSync } from 'node:zlib';
import { config } from '../config.js';

/**
 * Fetch and parse a replay from S3 by code.
 * @param {string} code - Replay code (e.g., "j0EiR-fZMFh")
 * @returns {Promise<object>} Parsed replay JSON
 * @throws {Error} With .code property: 'NOT_FOUND', 'NETWORK_ERROR', 'INVALID_DATA'
 */
export function fetchReplay(code) {
  const encoded = encodeURIComponent(code);
  const url = `${config.replayBaseUrl}/${encoded}.json.gz`;

  return new Promise((resolve, reject) => {
    get(url, (res) => {
      if (res.statusCode === 404 || res.statusCode === 403) {
        const err = new Error(`Replay not found: ${code}`);
        err.code = 'NOT_FOUND';
        res.resume(); // drain response
        return reject(err);
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        const err = new Error(`HTTP ${res.statusCode} fetching replay: ${code}`);
        err.code = 'NETWORK_ERROR';
        res.resume();
        return reject(err);
      }

      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => {
        try {
          const compressed = Buffer.concat(chunks);
          const json = gunzipSync(compressed).toString('utf-8');
          resolve(JSON.parse(json));
        } catch (e) {
          const err = new Error(`Failed to parse replay data: ${code} — ${e.message}`);
          err.code = 'INVALID_DATA';
          reject(err);
        }
      });
      res.on('error', (e) => {
        const err = new Error(`Network error fetching replay: ${code} — ${e.message}`);
        err.code = 'NETWORK_ERROR';
        reject(err);
      });
    }).on('error', (e) => {
      const err = new Error(`Connection error: ${code} — ${e.message}`);
      err.code = 'NETWORK_ERROR';
      reject(err);
    });
  });
}

/**
 * Extract key metadata from a replay for display (embeds, profiles).
 * @param {object} replay - Parsed replay JSON
 * @returns {object} Extracted metadata
 */
export function extractReplayMeta(replay) {
  const p1 = replay.playerInfo?.[0] || {};
  const p2 = replay.playerInfo?.[1] || {};
  const ratings = replay.ratingInfo?.initialRatings || [];

  const formatMap = { 200: 'Ranked', 201: 'Custom', 202: 'Custom', 203: 'Event', 204: 'Casual' };
  const gameType = formatMap[replay.format] || 'Unknown';

  const timeInfo = replay.timeInfo?.playerTime?.[0];
  const timeControl = (timeInfo && timeInfo.initial < 999999) ? timeInfo.initial : null;

  const randomizer = replay.deckInfo?.randomizer?.[0] || [];

  return {
    code: replay.code,
    p1Name: p1.displayName || 'Unknown',
    p2Name: p2.displayName || 'Unknown',
    p1Bot: p1.bot || '',
    p2Bot: p2.bot || '',
    p1Rating: ratings[0]?.displayRating || null,
    p2Rating: ratings[1]?.displayRating || null,
    p1Tier: ratings[0]?.tier ?? null,
    p2Tier: ratings[1]?.tier ?? null,
    result: replay.result, // 0 = P1 wins, 1 = P2 wins, 2 = draw
    gameType,
    format: replay.format,
    timeControl,
    randomizer,
    randomizerCount: randomizer.length,
    startTime: replay.startTime ? new Date(replay.startTime * 1000) : null,
  };
}
```

- [ ] **Step 2: Write test (using a real replay fetch)**

```javascript
// bot/__tests__/replay-fetcher.test.js
import { describe, it } from 'node:test';
import assert from 'node:assert';
import { fetchReplay, extractReplayMeta } from '../lib/replay-fetcher.js';

// Set required env vars for config
process.env.DISCORD_TOKEN = 'test';
process.env.DISCORD_CLIENT_ID = 'test';

describe('replay-fetcher', () => {
  it('fetches and parses a real replay from S3', async () => {
    const replay = await fetchReplay('j0EiR-fZMFh');
    assert.equal(replay.code, 'j0EiR-fZMFh');
    assert.ok(replay.playerInfo);
    assert.ok(replay.timeInfo);
    assert.ok(replay.deckInfo);
    assert.equal(replay.playerInfo[0].displayName, 'Surfinite');
  });

  it('returns NOT_FOUND for invalid codes', async () => {
    await assert.rejects(
      () => fetchReplay('ZZZZZ-ZZZZZ'),
      (err) => err.code === 'NOT_FOUND'
    );
  });

  it('extracts metadata correctly', async () => {
    const replay = await fetchReplay('j0EiR-fZMFh');
    const meta = extractReplayMeta(replay);

    assert.equal(meta.p1Name, 'Surfinite');
    assert.equal(meta.p2Bot, 'MediumAI');
    assert.equal(meta.format, 201);
    assert.equal(meta.timeControl, 999);
    assert.equal(meta.randomizerCount, 4);
    assert.equal(meta.result, 1); // P2 (bot) won (Surfinite resigned)
  });
});
```

- [ ] **Step 3: Run tests**

Run: `cd <PRISMATA_LADDER_REPO>/bot && npm test`
Expected: All tests pass (requires internet for S3 fetch)

- [ ] **Step 4: Commit**

```bash
git add bot/lib/replay-fetcher.js bot/__tests__/replay-fetcher.test.js
git commit -m "feat(bot): add replay fetcher library with S3 download + metadata extraction"
```

---

## Task 5: Replay Validator Library

**Files:**
- Create: `bot/lib/replay-validator.js`
- Create: `bot/__tests__/replay-validator.test.js`

- [ ] **Step 1: Create replay validator**

```javascript
// bot/lib/replay-validator.js

/**
 * Bot type display name to internal name mapping.
 * Maps what the user sees in Prismata's UI to the `bot` field in replay JSON.
 */
export const BOT_TYPES = {
  'Pacifist Bot': 'PacifistAI',
  'Wacky Bot': 'RandomAI',
  'Basic Bot': 'EasyAI',
  'Adept Bot': 'MediumAI',
  'Expert Bot': 'HardAI',
  'Fearless Bot': 'SteelAI',
  'Master Bot (3s)': 'MasterBot3s',
  'Master Bot (7s)': 'MasterBot7s',
};

// Reverse map: internal name -> display name
export const BOT_DISPLAY_NAMES = Object.fromEntries(
  Object.entries(BOT_TYPES).map(([display, internal]) => [internal, display])
);

/**
 * Validate a replay for account verification (Method B: Challenge Replay).
 * @param {object} replay - Parsed replay JSON
 * @param {object} challenge - { prismataUsername, botType, timeControl, randomizerCount }
 * @returns {{ valid: boolean, error?: string }}
 */
export function validateVerificationReplay(replay, challenge) {
  const p1 = replay.playerInfo?.[0];
  const p2 = replay.playerInfo?.[1];
  if (!p1 || !p2) return { valid: false, error: 'Replay missing player info' };

  // Check player name appears in either slot
  const p1IsUser = p1.displayName?.toLowerCase() === challenge.prismataUsername.toLowerCase();
  const p2IsUser = p2.displayName?.toLowerCase() === challenge.prismataUsername.toLowerCase();
  if (!p1IsUser && !p2IsUser) {
    return { valid: false, error: `Player "${challenge.prismataUsername}" not found in replay. Players: ${p1.displayName}, ${p2.displayName}` };
  }

  // Check the OTHER player is the correct bot
  const botPlayer = p1IsUser ? p2 : p1;
  if (botPlayer.bot !== challenge.botType) {
    const expectedName = BOT_DISPLAY_NAMES[challenge.botType] || challenge.botType;
    const actualName = BOT_DISPLAY_NAMES[botPlayer.bot] || botPlayer.bot || 'human';
    return { valid: false, error: `Wrong opponent. Expected: ${expectedName}, got: ${actualName}` };
  }

  // Check time control
  const timeControl = replay.timeInfo?.playerTime?.[0]?.initial;
  if (timeControl !== challenge.timeControl) {
    return { valid: false, error: `Wrong time control. Expected: ${challenge.timeControl}s, got: ${timeControl}s` };
  }

  // Check randomizer count
  const randomizer = replay.deckInfo?.randomizer?.[0] || [];
  if (randomizer.length !== challenge.randomizerCount) {
    return { valid: false, error: `Wrong randomizer count. Expected: Base +${challenge.randomizerCount}, got: Base +${randomizer.length}` };
  }

  // Check recency (within 1 hour)
  const startTime = replay.startTime;
  const oneHourAgo = (Date.now() / 1000) - 3600;
  if (startTime && startTime < oneHourAgo) {
    return { valid: false, error: 'Replay is too old. Must be played within the last hour.' };
  }

  // Check format (custom/bot game)
  if (replay.format !== 201 && replay.format !== 202) {
    return { valid: false, error: `Wrong game type. Expected custom game, got format ${replay.format}` };
  }

  return { valid: true };
}

/**
 * Validate a replay for a tournament/challenge match (Method B: Manual Replay Submission).
 * @param {object} replay - Parsed replay JSON
 * @param {object} rules - { player1Name, player2Name, timeControl, randomizerCount, assignedAfter (unix timestamp) }
 * @returns {{ valid: boolean, error?: string, winnerName?: string }}
 */
export function validateMatchReplay(replay, rules) {
  const p1 = replay.playerInfo?.[0];
  const p2 = replay.playerInfo?.[1];
  if (!p1 || !p2) return { valid: false, error: 'Replay missing player info' };

  // Check both expected players are in the replay (either order)
  const names = [p1.displayName?.toLowerCase(), p2.displayName?.toLowerCase()];
  const expected = [rules.player1Name.toLowerCase(), rules.player2Name.toLowerCase()];
  const hasP1 = names.includes(expected[0]);
  const hasP2 = names.includes(expected[1]);
  if (!hasP1 || !hasP2) {
    return { valid: false, error: `Expected players: ${rules.player1Name} vs ${rules.player2Name}. Got: ${p1.displayName} vs ${p2.displayName}` };
  }

  // Check time control
  const timeControl = replay.timeInfo?.playerTime?.[0]?.initial;
  if (rules.timeControl != null && timeControl !== rules.timeControl) {
    return { valid: false, error: `Wrong time control. Expected: ${rules.timeControl}s, got: ${timeControl}s` };
  }

  // Check randomizer count
  const randomizer = replay.deckInfo?.randomizer?.[0] || [];
  if (rules.randomizerCount != null && randomizer.length !== rules.randomizerCount) {
    return { valid: false, error: `Wrong randomizer count. Expected: Base +${rules.randomizerCount}, got: Base +${randomizer.length}` };
  }

  // Check format (should be custom game between humans)
  if (replay.format !== 201 && replay.format !== 202) {
    return { valid: false, error: `Wrong game type. Expected custom game, got format ${replay.format}` };
  }

  // Check timestamp (must be after match was assigned)
  if (rules.assignedAfter && replay.startTime && replay.startTime < rules.assignedAfter) {
    return { valid: false, error: 'Replay is from before this match was assigned' };
  }

  // Determine winner
  let winnerName = null;
  if (replay.result === 0) winnerName = p1.displayName;
  else if (replay.result === 1) winnerName = p2.displayName;
  // result === 2 is a draw

  return { valid: true, winnerName };
}
```

- [ ] **Step 2: Write tests**

```javascript
// bot/__tests__/replay-validator.test.js
import { describe, it } from 'node:test';
import assert from 'node:assert';
import { validateVerificationReplay, validateMatchReplay } from '../lib/replay-validator.js';

describe('validateVerificationReplay', () => {
  const baseReplay = {
    playerInfo: [
      { displayName: 'TestPlayer', bot: '' },
      { displayName: 'Adept Bot', bot: 'MediumAI' },
    ],
    timeInfo: { playerTime: [{ initial: 347 }, { initial: 1000000 }] },
    deckInfo: { randomizer: [['A', 'B', 'C', 'D', 'E', 'F'], ['A', 'B', 'C', 'D', 'E', 'F']] },
    startTime: Date.now() / 1000 - 60, // 1 minute ago
    format: 201,
  };

  const challenge = {
    prismataUsername: 'TestPlayer',
    botType: 'MediumAI',
    timeControl: 347,
    randomizerCount: 6,
  };

  it('accepts a valid verification replay', () => {
    const result = validateVerificationReplay(baseReplay, challenge);
    assert.deepStrictEqual(result, { valid: true });
  });

  it('rejects wrong player name', () => {
    const result = validateVerificationReplay(baseReplay, { ...challenge, prismataUsername: 'WrongName' });
    assert.equal(result.valid, false);
    assert.ok(result.error.includes('not found'));
  });

  it('rejects wrong bot type', () => {
    const result = validateVerificationReplay(baseReplay, { ...challenge, botType: 'HardAI' });
    assert.equal(result.valid, false);
    assert.ok(result.error.includes('Wrong opponent'));
  });

  it('rejects wrong time control', () => {
    const result = validateVerificationReplay(baseReplay, { ...challenge, timeControl: 500 });
    assert.equal(result.valid, false);
    assert.ok(result.error.includes('time control'));
  });

  it('rejects wrong randomizer count', () => {
    const result = validateVerificationReplay(baseReplay, { ...challenge, randomizerCount: 8 });
    assert.equal(result.valid, false);
    assert.ok(result.error.includes('randomizer'));
  });

  it('rejects stale replay', () => {
    const stale = { ...baseReplay, startTime: Date.now() / 1000 - 7200 }; // 2 hours ago
    const result = validateVerificationReplay(stale, challenge);
    assert.equal(result.valid, false);
    assert.ok(result.error.includes('too old'));
  });

  it('accepts player in either slot', () => {
    const swapped = {
      ...baseReplay,
      playerInfo: [
        { displayName: 'Adept Bot', bot: 'MediumAI' },
        { displayName: 'TestPlayer', bot: '' },
      ],
    };
    const result = validateVerificationReplay(swapped, challenge);
    assert.deepStrictEqual(result, { valid: true });
  });

  it('is case-insensitive for player names', () => {
    const result = validateVerificationReplay(baseReplay, { ...challenge, prismataUsername: 'testplayer' });
    assert.deepStrictEqual(result, { valid: true });
  });
});

describe('validateMatchReplay', () => {
  const baseReplay = {
    playerInfo: [
      { displayName: 'Alice', bot: '' },
      { displayName: 'Bob', bot: '' },
    ],
    timeInfo: { playerTime: [{ initial: 45 }, { initial: 45 }] },
    deckInfo: { randomizer: [['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'], ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']] },
    startTime: Date.now() / 1000 - 60,
    format: 201,
    result: 0, // Alice wins
  };

  const rules = {
    player1Name: 'Alice',
    player2Name: 'Bob',
    timeControl: 45,
    randomizerCount: 8,
    assignedAfter: Date.now() / 1000 - 3600,
  };

  it('accepts a valid match replay and identifies winner', () => {
    const result = validateMatchReplay(baseReplay, rules);
    assert.equal(result.valid, true);
    assert.equal(result.winnerName, 'Alice');
  });

  it('accepts players in either order', () => {
    const swapped = {
      ...baseReplay,
      playerInfo: [
        { displayName: 'Bob', bot: '' },
        { displayName: 'Alice', bot: '' },
      ],
      result: 1, // playerInfo[1] = Alice wins
    };
    const result = validateMatchReplay(swapped, rules);
    assert.equal(result.valid, true);
    assert.equal(result.winnerName, 'Alice');
  });

  it('rejects wrong players', () => {
    const result = validateMatchReplay(baseReplay, { ...rules, player1Name: 'Charlie' });
    assert.equal(result.valid, false);
  });

  it('rejects replay from before match assignment', () => {
    const old = { ...baseReplay, startTime: Date.now() / 1000 - 7200 };
    const result = validateMatchReplay(old, { ...rules, assignedAfter: Date.now() / 1000 - 3600 });
    assert.equal(result.valid, false);
    assert.ok(result.error.includes('before this match'));
  });
});
```

- [ ] **Step 3: Run tests**

Run: `cd <PRISMATA_LADDER_REPO>/bot && npm test`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add bot/lib/replay-validator.js bot/__tests__/replay-validator.test.js
git commit -m "feat(bot): add replay validator for verification and match validation"
```

---

## Task 6: Bot Entry Point + Client Setup

**Files:**
- Create: `bot/index.js`

- [ ] **Step 1: Create bot entry point**

```javascript
// bot/index.js
import { Client, GatewayIntentBits, Events, Collection } from 'discord.js';
import { config } from './config.js';
import { getDb, closeDb } from './db.js';
import { handleReplayEmbed } from './handlers/replay-embed.js';
import { handleUnitEmbed } from './handlers/unit-embed.js';

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.GuildPresences,
    GatewayIntentBits.MessageContent,
    GatewayIntentBits.DirectMessages,
  ],
});

// Command collection (populated by command files)
client.commands = new Collection();

// --- Load commands ---
async function loadCommands() {
  const commandFiles = ['verify', 'profile'];
  for (const name of commandFiles) {
    try {
      const mod = await import(`./commands/${name}.js`);
      client.commands.set(mod.data.name, mod);
    } catch (e) {
      console.error(`Failed to load command ${name}:`, e.message);
    }
  }
}

// --- Event handlers ---

client.once(Events.ClientReady, (c) => {
  console.log(`Giselle v2 ready as ${c.user.tag}`);
  // Initialize database (creates tournament tables if needed)
  getDb();
});

client.on(Events.InteractionCreate, async (interaction) => {
  if (interaction.isChatInputCommand()) {
    const command = client.commands.get(interaction.commandName);
    if (!command) return;
    try {
      await command.execute(interaction);
    } catch (error) {
      console.error(`Error executing /${interaction.commandName}:`, error);
      const reply = { content: 'Something went wrong executing that command.', ephemeral: true };
      if (interaction.replied || interaction.deferred) {
        await interaction.followUp(reply).catch(() => {});
      } else {
        await interaction.reply(reply).catch(() => {});
      }
    }
  }
});

// Legacy message-based detection (replay codes and [[unit]] syntax)
client.on(Events.MessageCreate, async (message) => {
  if (message.author.bot || message.system) return;
  // Run both handlers (they check independently)
  await handleReplayEmbed(message).catch(e => console.error('Replay embed error:', e));
  await handleUnitEmbed(message).catch(e => console.error('Unit embed error:', e));
});

// --- Shutdown ---
process.on('SIGINT', () => {
  console.log('Shutting down...');
  closeDb();
  client.destroy();
  process.exit(0);
});

process.on('SIGTERM', () => {
  console.log('Shutting down...');
  closeDb();
  client.destroy();
  process.exit(0);
});

// --- Start ---
await loadCommands();
client.login(config.discordToken);
```

- [ ] **Step 2: Commit**

```bash
git add bot/index.js
git commit -m "feat(bot): add entry point with command loading and legacy message handling"
```

---

## Task 7: Legacy Replay Embed Handler

Port the existing replay code detection from `prismata-discord-bot/replay.js` to the new bot.

**Files:**
- Create: `bot/handlers/replay-embed.js`

- [ ] **Step 1: Create replay embed handler**

```javascript
// bot/handlers/replay-embed.js
import { EmbedBuilder } from 'discord.js';
import { fetchReplay, extractReplayMeta } from '../lib/replay-fetcher.js';

const REPLAY_CODE_RE = /(?:^|[\s(]|(?:[?&]r=))([a-zA-Z0-9@+]{5}-[a-zA-Z0-9@+]{5})(?:[\s,.)&]|$)/g;
const MAX_PER_MESSAGE = 3;
const PLAY_URL = 'https://play.prismata.net/?r=';

// Per-channel duplicate tracking
const recentCodes = new Map(); // channelId -> Map<code, timestamp>
const DUPLICATE_WINDOW_MS = 60_000;

function cleanupRecent(channelId) {
  const codes = recentCodes.get(channelId);
  if (!codes) return;
  const cutoff = Date.now() - DUPLICATE_WINDOW_MS;
  for (const [code, ts] of codes) {
    if (ts < cutoff) codes.delete(code);
  }
  if (codes.size === 0) recentCodes.delete(channelId);
}

function isDuplicate(channelId, code) {
  cleanupRecent(channelId);
  const codes = recentCodes.get(channelId);
  if (codes?.has(code)) return true;
  if (!codes) recentCodes.set(channelId, new Map());
  recentCodes.get(channelId).set(code, Date.now());
  return false;
}

function formatRating(rating, tier) {
  if (tier == null || tier < 1) return '-';
  if (tier >= 10) return rating != null ? Math.round(rating).toString() : '-';
  const tierNames = ['', 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX'];
  return `Tier ${tierNames[tier] || tier}`;
}

function buildEmbed(meta) {
  const embed = new EmbedBuilder()
    .setColor(0x3498db)
    .setTitle(meta.code)
    .setURL(`${PLAY_URL}${encodeURIComponent(meta.code)}`);

  const p1Rating = formatRating(meta.p1Rating, meta.p1Tier);
  const p2Rating = formatRating(meta.p2Rating, meta.p2Tier);

  const p1Label = meta.p1Bot ? `${meta.p1Name} (Bot)` : meta.p1Name;
  const p2Label = meta.p2Bot ? `${meta.p2Name} (Bot)` : meta.p2Name;

  embed.addFields(
    { name: p1Label, value: p1Rating, inline: true },
    { name: 'vs', value: '\u200b', inline: true },
    { name: p2Label, value: p2Rating, inline: true },
  );

  const details = [];
  details.push(meta.gameType);
  if (meta.timeControl) details.push(`${meta.timeControl}s`);
  if (meta.randomizer.length > 0) {
    details.push(`Base +${meta.randomizerCount}: ${meta.randomizer.join(', ')}`);
  }
  embed.setDescription(details.join(' · '));

  if (meta.startTime) {
    embed.setTimestamp(meta.startTime);
  }

  return embed;
}

export async function handleReplayEmbed(message) {
  const matches = [...message.content.matchAll(REPLAY_CODE_RE)];
  if (matches.length === 0) return;

  const codes = matches
    .map(m => m[1])
    .filter(code => !isDuplicate(message.channelId, code))
    .slice(0, MAX_PER_MESSAGE);

  for (const code of codes) {
    try {
      const replay = await fetchReplay(code);
      const meta = extractReplayMeta(replay);
      const embed = buildEmbed(meta);
      await message.channel.send({ embeds: [embed] });
    } catch (e) {
      if (e.code === 'NOT_FOUND') {
        // Silently ignore — could be a false positive from regex
      } else {
        console.error(`Failed to fetch replay ${code}:`, e.message);
      }
    }
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add bot/handlers/replay-embed.js
git commit -m "feat(bot): port legacy replay code detection with embeds"
```

---

## Task 8: Legacy Unit Embed Handler

**Files:**
- Create: `bot/handlers/unit-embed.js`

- [ ] **Step 1: Create unit embed handler**

Uses the existing unit data from the prismata-discord-bot. The unit data can be loaded from `prismata-ladder-site/src/data/units.ts` or a static JSON file. For now, uses a simplified approach matching `[[Unit Name]]` syntax.

```javascript
// bot/handlers/unit-embed.js
import { EmbedBuilder } from 'discord.js';
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const UNIT_TAG_RE = /\[\[([\w ]+)\]\]/g;
const MAX_PER_MESSAGE = 2;
const WIKI_URL = 'https://prismata.fandom.com/wiki/';
const IMAGE_URL = 'https://s3.amazonaws.com/lunarch_blog/Units/Random+Set/';

// Per-channel duplicate tracking
const recentUnits = new Map();
const DUPLICATE_WINDOW_MS = 60_000;

// Load unit data (try units.json in bot dir, fall back to empty)
let unitData = {};
const unitsPath = resolve(__dirname, '..', 'units.json');
if (existsSync(unitsPath)) {
  try {
    unitData = JSON.parse(readFileSync(unitsPath, 'utf-8'));
  } catch (e) {
    console.warn('Failed to load units.json:', e.message);
  }
}

// Build alias map: uppercase name -> unit object
const aliases = new Map();
for (const unit of Object.values(unitData)) {
  if (unit.name) {
    aliases.set(unit.name.toUpperCase(), unit);
  }
}

function isDuplicate(channelId, unitName) {
  const key = `${channelId}:${unitName.toUpperCase()}`;
  const now = Date.now();
  const last = recentUnits.get(key);
  if (last && now - last < DUPLICATE_WINDOW_MS) return true;
  recentUnits.set(key, now);
  return false;
}

export async function handleUnitEmbed(message) {
  if (aliases.size === 0) return; // No unit data loaded

  const matches = [...message.content.matchAll(UNIT_TAG_RE)];
  if (matches.length === 0) return;

  let count = 0;
  for (const match of matches) {
    if (count >= MAX_PER_MESSAGE) break;
    const query = match[1].trim().toUpperCase();
    const unit = aliases.get(query);
    if (!unit) continue;
    if (isDuplicate(message.channelId, unit.name)) continue;

    const embed = new EmbedBuilder()
      .setColor(0x3498db)
      .setTitle(unit.name)
      .setURL(`${WIKI_URL}${encodeURIComponent(unit.name)}`)
      .setImage(`${IMAGE_URL}${encodeURIComponent(unit.name)}.png`);

    if (unit.supply != null) {
      embed.setFooter({ text: `Supply: ${unit.supply}` });
    }

    await message.channel.send({ embeds: [embed] }).catch(e => {
      console.error(`Failed to send unit embed for ${unit.name}:`, e.message);
    });
    count++;
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add bot/handlers/unit-embed.js
git commit -m "feat(bot): port legacy [[Unit]] detection with embeds"
```

---

## Task 9: Slash Command Registration

**Files:**
- Create: `bot/deploy-commands.js`

- [ ] **Step 1: Create command deployment script**

```javascript
// bot/deploy-commands.js
import { REST, Routes, SlashCommandBuilder } from 'discord.js';
import { config } from './config.js';

const commands = [
  new SlashCommandBuilder()
    .setName('verify')
    .setDescription('Verify your Prismata account')
    .addSubcommand(sub =>
      sub.setName('start')
        .setDescription('Generate a verification challenge')
        .addStringOption(opt =>
          opt.setName('username')
            .setDescription('Your Prismata username')
            .setRequired(true)
        )
    )
    .addSubcommand(sub =>
      sub.setName('submit')
        .setDescription('Submit a verification replay code')
        .addStringOption(opt =>
          opt.setName('code')
            .setDescription('Replay code (XXXXX-XXXXX)')
            .setRequired(true)
        )
    ),

  new SlashCommandBuilder()
    .setName('profile')
    .setDescription('View a player profile')
    .addUserOption(opt =>
      opt.setName('user')
        .setDescription('Discord user (defaults to yourself)')
        .setRequired(false)
    ),
];

const rest = new REST().setToken(config.discordToken);

try {
  console.log(`Registering ${commands.length} commands...`);

  if (config.guildId) {
    // Dev: guild-specific (instant)
    await rest.put(
      Routes.applicationGuildCommands(config.clientId, config.guildId),
      { body: commands.map(c => c.toJSON()) },
    );
    console.log(`Registered to guild ${config.guildId}`);
  } else {
    // Prod: global (takes up to 1 hour to propagate)
    await rest.put(
      Routes.applicationCommands(config.clientId),
      { body: commands.map(c => c.toJSON()) },
    );
    console.log('Registered globally');
  }
} catch (error) {
  console.error('Failed to register commands:', error);
  process.exit(1);
}
```

- [ ] **Step 2: Commit**

```bash
git add bot/deploy-commands.js
git commit -m "feat(bot): add slash command registration script"
```

---

## Task 10: /verify Command (Method B: Challenge Replay)

**Files:**
- Create: `bot/commands/verify.js`

- [ ] **Step 1: Create verify command**

```javascript
// bot/commands/verify.js
import { SlashCommandBuilder, EmbedBuilder } from 'discord.js';
import {
  findOrCreateUser, getUserByDiscordId, getPendingChallenge,
  createVerificationChallenge, completeChallenge, verifyUser,
  isReplayCodeUsed, markReplayCodeUsed, getUserByPrismataName,
} from '../db.js';
import { fetchReplay } from '../lib/replay-fetcher.js';
import { validateVerificationReplay, BOT_TYPES, BOT_DISPLAY_NAMES } from '../lib/replay-validator.js';

export const data = new SlashCommandBuilder()
  .setName('verify')
  .setDescription('Verify your Prismata account')
  .addSubcommand(sub =>
    sub.setName('start')
      .setDescription('Generate a verification challenge')
      .addStringOption(opt =>
        opt.setName('username')
          .setDescription('Your Prismata username')
          .setRequired(true)
      )
  )
  .addSubcommand(sub =>
    sub.setName('submit')
      .setDescription('Submit a verification replay code')
      .addStringOption(opt =>
        opt.setName('code')
          .setDescription('Replay code (XXXXX-XXXXX)')
          .setRequired(true)
      )
  );

// Bot types available for verification challenges (exclude Master Bots — too slow)
const CHALLENGE_BOTS = ['PacifistAI', 'RandomAI', 'EasyAI', 'MediumAI', 'HardAI', 'SteelAI'];

function randomInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function generateChallenge() {
  const botType = CHALLENGE_BOTS[randomInt(0, CHALLENGE_BOTS.length - 1)];
  const timeControl = randomInt(10, 999);
  const randomizerCount = randomInt(1, 11);
  return { botType, timeControl, randomizerCount };
}

export async function execute(interaction) {
  const sub = interaction.options.getSubcommand();

  if (sub === 'start') {
    const prismataUsername = interaction.options.getString('username');

    // Check if this Prismata name is already claimed
    const existing = getUserByPrismataName(prismataUsername);
    if (existing && existing.discord_id !== interaction.user.id) {
      return interaction.reply({
        content: `The Prismata account "${prismataUsername}" is already verified by another user.`,
        ephemeral: true,
      });
    }

    // Check if this Discord user is already verified
    const user = findOrCreateUser(interaction.user.id, interaction.user.username);
    if (user.verified) {
      return interaction.reply({
        content: `You're already verified as **${user.prismata_username}**.`,
        ephemeral: true,
      });
    }

    // Generate challenge
    const { botType, timeControl, randomizerCount } = generateChallenge();
    createVerificationChallenge(user.id, prismataUsername, botType, timeControl, randomizerCount);

    const botDisplayName = BOT_DISPLAY_NAMES[botType] || botType;

    const embed = new EmbedBuilder()
      .setColor(0x00b894)
      .setTitle('Prismata Account Verification')
      .setDescription(`To verify you own **${prismataUsername}**, create a custom game with these exact settings:`)
      .addFields(
        { name: 'Opponent', value: botDisplayName, inline: true },
        { name: 'Time Control', value: `${timeControl} seconds`, inline: true },
        { name: 'Random Units', value: `Base +${randomizerCount}`, inline: true },
      )
      .setFooter({ text: 'You can resign immediately. Then use /verify submit with the replay code.' });

    return interaction.reply({ embeds: [embed], ephemeral: true });
  }

  if (sub === 'submit') {
    const code = interaction.options.getString('code').trim();

    // Validate code format
    if (!/^[a-zA-Z0-9@+]{5}-[a-zA-Z0-9@+]{5}$/.test(code)) {
      return interaction.reply({ content: 'Invalid replay code format. Expected: XXXXX-XXXXX', ephemeral: true });
    }

    const user = getUserByDiscordId(interaction.user.id);
    if (!user) {
      return interaction.reply({ content: 'Please run `/verify start` first.', ephemeral: true });
    }
    if (user.verified) {
      return interaction.reply({ content: `You're already verified as **${user.prismata_username}**.`, ephemeral: true });
    }

    const challenge = getPendingChallenge(user.id);
    if (!challenge) {
      return interaction.reply({ content: 'No pending challenge found. Run `/verify start` to generate one.', ephemeral: true });
    }

    // Check replay code not already used
    if (isReplayCodeUsed(code)) {
      return interaction.reply({ content: 'This replay code has already been used.', ephemeral: true });
    }

    await interaction.deferReply({ ephemeral: true });

    // Fetch and validate replay
    let replay;
    try {
      replay = await fetchReplay(code);
    } catch (e) {
      if (e.code === 'NOT_FOUND') {
        return interaction.editReply('Replay not found. Check the code and try again.');
      }
      return interaction.editReply(`Failed to fetch replay: ${e.message}`);
    }

    // Validate the replay player name matches what they claimed in /verify start
    const prismataUsername = challenge.claimed_username;

    const result = validateVerificationReplay(replay, {
      prismataUsername,
      botType: challenge.challenge_bot,
      timeControl: challenge.challenge_time_control,
      randomizerCount: challenge.challenge_randomizer_count,
    });

    if (!result.valid) {
      return interaction.editReply(`Verification failed: ${result.error}`);
    }

    // Check if this Prismata name is already taken (race condition check)
    const existingUser = getUserByPrismataName(prismataUsername);
    if (existingUser && existingUser.id !== user.id) {
      return interaction.editReply(`The Prismata account "${prismataUsername}" was just verified by another user.`);
    }

    // Success! Bind account
    verifyUser(user.id, prismataUsername);
    completeChallenge(challenge.id, code);
    markReplayCodeUsed(code, 'verification');

    const embed = new EmbedBuilder()
      .setColor(0x00b894)
      .setTitle('Account Verified!')
      .setDescription(`Your Discord account is now linked to Prismata account **${prismataUsername}**.`)
      .setFooter({ text: 'You can now join tournaments and challenge other players.' });

    return interaction.editReply({ embeds: [embed] });
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add bot/commands/verify.js
git commit -m "feat(bot): add /verify command for account verification (Method B)"
```

---

## Task 11: /profile Command

**Files:**
- Create: `bot/commands/profile.js`

- [ ] **Step 1: Create profile command**

```javascript
// bot/commands/profile.js
import { SlashCommandBuilder, EmbedBuilder } from 'discord.js';
import { getUserByDiscordId } from '../db.js';

export const data = new SlashCommandBuilder()
  .setName('profile')
  .setDescription('View a player profile')
  .addUserOption(opt =>
    opt.setName('user')
      .setDescription('Discord user (defaults to yourself)')
      .setRequired(false)
  );

export async function execute(interaction) {
  const targetUser = interaction.options.getUser('user') || interaction.user;
  const user = getUserByDiscordId(targetUser.id);

  if (!user) {
    return interaction.reply({
      content: targetUser.id === interaction.user.id
        ? "You haven't registered yet. Use `/verify start` to link your Prismata account."
        : `${targetUser.username} hasn't registered yet.`,
      ephemeral: true,
    });
  }

  const db = (await import('../db.js')).getDb();

  // Count tournament participations
  const tournamentCount = db.prepare(
    'SELECT COUNT(*) as count FROM tournament_players WHERE user_id = ?'
  ).get(user.id)?.count || 0;

  // Count completed matches (tournaments + challenges)
  const tournamentMatches = db.prepare(
    "SELECT COUNT(*) as count FROM tournament_matches WHERE (player1_id = ? OR player2_id = ?) AND status = 'completed'"
  ).get(user.id, user.id)?.count || 0;

  const challengeMatches = db.prepare(
    "SELECT COUNT(*) as count FROM challenges WHERE (challenger_id = ? OR challenged_id = ?) AND status = 'completed'"
  ).get(user.id, user.id)?.count || 0;

  // Count wins
  const tournamentWins = db.prepare(
    "SELECT COUNT(*) as count FROM tournament_matches WHERE winner_id = ? AND status = 'completed'"
  ).get(user.id)?.count || 0;

  // Ladder stats (from existing players table)
  const ladderPlayer = user.prismata_username
    ? db.prepare('SELECT * FROM players WHERE display_name = ? COLLATE NOCASE').get(user.prismata_username)
    : null;

  const embed = new EmbedBuilder()
    .setColor(user.verified ? 0x00b894 : 0x636e72)
    .setTitle(`${targetUser.username}'s Profile`)
    .setThumbnail(targetUser.displayAvatarURL());

  if (user.verified) {
    embed.addFields({ name: 'Prismata', value: user.prismata_username, inline: true });
  } else {
    embed.addFields({ name: 'Status', value: 'Not verified', inline: true });
  }

  embed.addFields({ name: 'Role', value: user.role, inline: true });

  if (user.tournament_rating != null) {
    embed.addFields({ name: 'Tournament Rating', value: Math.round(user.tournament_rating).toString(), inline: true });
  }

  if (ladderPlayer) {
    const ladderElo = ladderPlayer.current_elo != null ? Math.round(ladderPlayer.current_elo).toString() : '-';
    const ladderRecord = `${ladderPlayer.wins}W / ${ladderPlayer.losses}L`;
    embed.addFields(
      { name: 'Ladder ELO', value: ladderElo, inline: true },
      { name: 'Ladder Record', value: ladderRecord, inline: true },
    );
  }

  const totalMatches = tournamentMatches + challengeMatches;
  if (totalMatches > 0 || tournamentCount > 0) {
    embed.addFields(
      { name: 'Tournaments', value: tournamentCount.toString(), inline: true },
      { name: 'Matches', value: `${totalMatches} (${tournamentWins}W)`, inline: true },
    );
  }

  return interaction.reply({ embeds: [embed] });
}
```

- [ ] **Step 2: Commit**

```bash
git add bot/commands/profile.js
git commit -m "feat(bot): add /profile command showing player stats"
```

---

## Task 12: Monitoring — Resource Alerts

**Files:**
- Create: `bot/lib/monitor.js`

- [ ] **Step 1: Create monitoring module**

This runs on a setInterval inside the bot, checks system resources, and posts to #prismata-ops via webhook.

```javascript
// bot/lib/monitor.js
import { execSync } from 'node:child_process';
import { request } from 'node:https';
import { config } from '../config.js';

const CHECK_INTERVAL_MS = 5 * 60 * 1000; // 5 minutes
const MEMORY_THRESHOLD = 0.80; // 80%
const DISK_THRESHOLD = 0.90; // 90%

let lastAlertTime = 0;
const ALERT_COOLDOWN_MS = 30 * 60 * 1000; // Don't spam — 30 min cooldown

function getMemoryUsage() {
  try {
    const output = execSync("free -m | grep Mem", { encoding: 'utf-8' });
    const parts = output.trim().split(/\s+/);
    const total = parseInt(parts[1], 10);
    const used = parseInt(parts[2], 10);
    return { total, used, percent: used / total };
  } catch {
    return null;
  }
}

function getDiskUsage() {
  try {
    const output = execSync("df -h / | tail -1", { encoding: 'utf-8' });
    const parts = output.trim().split(/\s+/);
    const percent = parseInt(parts[4], 10) / 100;
    return { percent };
  } catch {
    return null;
  }
}

function sendWebhookAlert(message) {
  if (!config.opsWebhookUrl) return;

  const url = new URL(config.opsWebhookUrl);
  const body = JSON.stringify({ content: `⚠️ **Data Box Alert:** ${message}` });

  const req = request(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  });
  req.on('error', (e) => console.error('Webhook alert failed:', e.message));
  req.write(body);
  req.end();
}

function checkResources() {
  const now = Date.now();
  if (now - lastAlertTime < ALERT_COOLDOWN_MS) return;

  const alerts = [];

  const mem = getMemoryUsage();
  if (mem && mem.percent > MEMORY_THRESHOLD) {
    alerts.push(`Memory at ${Math.round(mem.percent * 100)}% (${mem.used}MB / ${mem.total}MB)`);
  }

  const disk = getDiskUsage();
  if (disk && disk.percent > DISK_THRESHOLD) {
    alerts.push(`Disk at ${Math.round(disk.percent * 100)}%`);
  }

  if (alerts.length > 0) {
    lastAlertTime = now;
    sendWebhookAlert(alerts.join('. '));
    console.warn('Resource alert:', alerts.join('. '));
  }
}

export function startMonitoring() {
  // Only monitor on Linux (Data Box)
  if (process.platform !== 'linux') {
    console.log('Monitoring skipped (not Linux)');
    return;
  }
  console.log('Starting resource monitoring (5min interval)');
  setInterval(checkResources, CHECK_INTERVAL_MS);
  // Run once immediately
  checkResources();
}
```

- [ ] **Step 2: Wire monitoring into bot entry point**

Add to `bot/index.js`, after the `ClientReady` event:

```javascript
import { startMonitoring } from './lib/monitor.js';
```

And inside the `ClientReady` handler, add:

```javascript
  startMonitoring();
```

- [ ] **Step 3: Commit**

```bash
git add bot/lib/monitor.js bot/index.js
git commit -m "feat(bot): add resource monitoring with #prismata-ops webhook alerts"
```

---

## Task 13: Integration Test — Full Bot Startup

- [ ] **Step 1: Verify the bot starts without errors (requires real token)**

This is a manual test. Create `bot/bot.env` with real credentials:

```bash
cd <PRISMATA_LADDER_REPO>/bot
cp bot.env.example bot.env
# Edit bot.env with real DISCORD_TOKEN and DISCORD_CLIENT_ID
```

Run: `cd <PRISMATA_LADDER_REPO>/bot && node index.js`
Expected: "Giselle v2 ready as Giselle#XXXX" (or whatever the bot's tag is)

- [ ] **Step 2: Register commands**

Run: `cd <PRISMATA_LADDER_REPO>/bot && node deploy-commands.js`
Expected: "Registered to guild XXXXX" (or "Registered globally")

- [ ] **Step 3: Test slash commands in Discord**

In Discord, test:
- `/verify start username:TestName` — should show verification challenge embed
- `/profile` — should show profile (unverified)
- Post a replay code like `j0EiR-fZMFh` in chat — should show replay embed
- Post `[[Tarsier]]` — should show unit embed (if units.json is present)

- [ ] **Step 4: Run all unit tests**

Run: `cd <PRISMATA_LADDER_REPO>/bot && npm test`
Expected: All tests pass

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "feat(bot): Giselle v2 foundation complete — ready for tournament engine (Plan 2)"
```

---

## Summary

After completing Plan 1, you have:

- **Giselle v2** running on discord.js v14 with slash commands
- **Tournament database schema** added to existing SQLite (all tables, safe migrations)
- **Replay fetcher** that downloads and parses replays from S3
- **Replay validator** for both verification and match validation
- **Account verification** via `/verify` (Method B: challenge replay)
- **Player profiles** via `/profile` (shows ladder stats + tournament data)
- **Legacy features** preserved (replay embeds, unit embeds)
- **Resource monitoring** with #prismata-ops alerts

**Next:** Plan 2 adds tournament lifecycle commands, bracket engine, scheduling, nagging, show matches, and auto-spectating.
