# Tournament Platform Plan 2: Tournament Engine + Show Matches

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full tournament lifecycle and show match system — create tournaments, join, generate brackets, submit results, auto-advance, schedule reminders, handle forfeits and disputes — all via Discord slash commands.

**Architecture:** Extends the Giselle v2 bot from Plan 1 with new commands and libraries. Tournament logic is pure functions in `lib/` (testable without Discord). The scheduler runs on a `setInterval` inside the bot process, checking deadlines every 60 seconds. Single Elimination is the initial bracket format; Swiss/Round Robin/Double Elim are deferred.

**Tech Stack:** Node.js 20+, discord.js v14, better-sqlite3 (existing from Plan 1)

**Spec:** `c:\libraries\prismata-3d\docs\superpowers\specs\2026-03-28-prismata-tournament-platform-design.md`
**Plan 1:** `c:\libraries\prismata-3d\docs\superpowers\plans\2026-03-29-tournament-plan1-bot-foundation.md`

**Related plans:**
- Plan 2B (future): Auto-spectating + whisper verification (Python, protocol discovery needed)
- Plan 2C (future): Export pipeline extension (Python)
- Plan 3: Website Extensions (Discord OAuth, tournament pages, profiles)

**Deferred from this plan:**
- Swiss, Round Robin, Double Elimination formats (Single Elim only for MVP)
- Auto-spectating (Method A result submission — needs Python protocol work)
- Whisper verification (Method A — needs protocol discovery)
- Tournament export to JSON (Python script — Plan 2C)
- Online detection ("both players are online, suggest they play")

---

## File Structure

New and modified files in `<PRISMATA_LADDER_REPO>/bot\`:

```
bot/
├── lib/
│   ├── tournament-db.js        # NEW: Tournament/challenge/dispute DB queries
│   ├── bracket-engine.js       # NEW: Single elimination bracket generation + advancement
│   └── scheduler.js            # NEW: Background loop — reminders, forfeits, auto-confirm
├── commands/
│   ├── tournament.js           # NEW: /tournament create|join|start|status|cancel
│   ├── result.js               # NEW: /result <codes...> — submit match results
│   ├── challenge.js            # NEW: /challenge @user bo3 [time:45] [units:8]
│   ├── dispute.js              # NEW: /dispute — dispute recent match result
│   ├── standings.js            # NEW: /standings [tournament]
│   └── bracket.js              # NEW: /bracket [tournament]
├── __tests__/
│   ├── tournament-db.test.js   # NEW: DB query tests
│   ├── bracket-engine.test.js  # NEW: Bracket generation + advancement tests
│   └── scheduler.test.js       # NEW: Scheduler logic tests
├── index.js                    # MODIFY: Add new commands to loadCommands list
└── deploy-commands.js          # MODIFY: Register new slash commands
```

---

## Task 1: Tournament DB Queries

**Files:**
- Create: `bot/lib/tournament-db.js`
- Create: `bot/__tests__/tournament-db.test.js`

- [ ] **Step 1: Create tournament-db.js**

```javascript
// bot/lib/tournament-db.js
import { getDb } from '../db.js';

// --- Tournament CRUD ---

export function createTournament(name, description, format, rulesJson, createdBy, maxPlayers, registrationDeadline) {
  const db = getDb();
  const result = db.prepare(
    `INSERT INTO tournaments (name, description, format, rules_json, created_by, max_players, registration_deadline)
     VALUES (?, ?, ?, ?, ?, ?, ?)`
  ).run(name, description, format, rulesJson, createdBy, maxPlayers, registrationDeadline);
  return db.prepare('SELECT * FROM tournaments WHERE id = ?').get(result.lastInsertRowid);
}

export function getTournament(id) {
  return getDb().prepare('SELECT * FROM tournaments WHERE id = ?').get(id);
}

export function getTournamentByName(name) {
  return getDb().prepare('SELECT * FROM tournaments WHERE name = ? COLLATE NOCASE').get(name);
}

export function listTournaments(status) {
  if (status) {
    return getDb().prepare('SELECT * FROM tournaments WHERE status = ? ORDER BY created_at DESC').all(status);
  }
  return getDb().prepare("SELECT * FROM tournaments WHERE status IN ('registration', 'active') ORDER BY created_at DESC").all();
}

export function updateTournamentStatus(id, status) {
  getDb().prepare('UPDATE tournaments SET status = ? WHERE id = ?').run(status, id);
}

// --- Tournament Players ---

export function joinTournament(tournamentId, userId) {
  getDb().prepare(
    'INSERT OR IGNORE INTO tournament_players (tournament_id, user_id) VALUES (?, ?)'
  ).run(tournamentId, userId);
}

export function leaveTournament(tournamentId, userId) {
  getDb().prepare(
    'DELETE FROM tournament_players WHERE tournament_id = ? AND user_id = ?'
  ).run(tournamentId, userId);
}

export function getTournamentPlayers(tournamentId) {
  return getDb().prepare(
    `SELECT tp.*, u.discord_id, u.discord_username, u.prismata_username
     FROM tournament_players tp
     JOIN users u ON tp.user_id = u.id
     WHERE tp.tournament_id = ?
     ORDER BY tp.seed`
  ).all(tournamentId);
}

export function getTournamentPlayerCount(tournamentId) {
  return getDb().prepare(
    'SELECT COUNT(*) as count FROM tournament_players WHERE tournament_id = ?'
  ).get(tournamentId).count;
}

export function isPlayerInTournament(tournamentId, userId) {
  return !!getDb().prepare(
    'SELECT 1 FROM tournament_players WHERE tournament_id = ? AND user_id = ?'
  ).get(tournamentId, userId);
}

export function updatePlayerSeed(tournamentId, userId, seed) {
  getDb().prepare(
    'UPDATE tournament_players SET seed = ?, status = ? WHERE tournament_id = ? AND user_id = ?'
  ).run(seed, 'active', tournamentId, userId);
}

export function eliminatePlayer(tournamentId, userId) {
  getDb().prepare(
    "UPDATE tournament_players SET status = 'eliminated' WHERE tournament_id = ? AND user_id = ?"
  ).run(tournamentId, userId);
}

// --- Rounds ---

export function createRound(tournamentId, roundNumber, deadline) {
  const db = getDb();
  const result = db.prepare(
    'INSERT INTO tournament_rounds (tournament_id, round_number, deadline, status) VALUES (?, ?, ?, ?)'
  ).run(tournamentId, roundNumber, deadline, 'active');
  return db.prepare('SELECT * FROM tournament_rounds WHERE id = ?').get(result.lastInsertRowid);
}

export function getRound(id) {
  return getDb().prepare('SELECT * FROM tournament_rounds WHERE id = ?').get(id);
}

export function getActiveRound(tournamentId) {
  return getDb().prepare(
    "SELECT * FROM tournament_rounds WHERE tournament_id = ? AND status = 'active' ORDER BY round_number LIMIT 1"
  ).get(tournamentId);
}

export function completeRound(roundId) {
  getDb().prepare("UPDATE tournament_rounds SET status = 'completed' WHERE id = ?").run(roundId);
}

// --- Matches ---

export function createMatch(tournamentId, roundId, player1Id, player2Id, bestOf, deadline) {
  const db = getDb();
  const result = db.prepare(
    `INSERT INTO tournament_matches (tournament_id, round_id, player1_id, player2_id, best_of, deadline, status)
     VALUES (?, ?, ?, ?, ?, ?, 'pending')`
  ).run(tournamentId, roundId, player1Id, player2Id, bestOf, deadline);
  return db.prepare('SELECT * FROM tournament_matches WHERE id = ?').get(result.lastInsertRowid);
}

export function getMatch(id) {
  return getDb().prepare('SELECT * FROM tournament_matches WHERE id = ?').get(id);
}

export function getMatchesForRound(roundId) {
  return getDb().prepare(
    `SELECT tm.*,
            u1.prismata_username as p1_name, u1.discord_id as p1_discord_id,
            u2.prismata_username as p2_name, u2.discord_id as p2_discord_id
     FROM tournament_matches tm
     JOIN users u1 ON tm.player1_id = u1.id
     LEFT JOIN users u2 ON tm.player2_id = u2.id
     WHERE tm.round_id = ?`
  ).all(roundId);
}

export function getPendingMatchForPlayer(userId) {
  return getDb().prepare(
    `SELECT tm.*, t.name as tournament_name, t.rules_json,
            u1.prismata_username as p1_name, u1.discord_id as p1_discord_id,
            u2.prismata_username as p2_name, u2.discord_id as p2_discord_id
     FROM tournament_matches tm
     JOIN tournaments t ON tm.tournament_id = t.id
     JOIN users u1 ON tm.player1_id = u1.id
     JOIN users u2 ON tm.player2_id = u2.id
     WHERE (tm.player1_id = ? OR tm.player2_id = ?) AND tm.status IN ('pending', 'in_progress')
     ORDER BY tm.deadline ASC LIMIT 1`
  ).get(userId, userId);
}

export function setMatchResult(matchId, winnerId, status) {
  getDb().prepare(
    'UPDATE tournament_matches SET winner_id = ?, status = ? WHERE id = ?'
  ).run(winnerId, status, matchId);
}

export function addMatchGame(matchId, replayCode, winnerId, replayJson) {
  const db = getDb();
  const existing = db.prepare('SELECT COUNT(*) as count FROM match_games WHERE match_id = ?').get(matchId).count;
  const result = db.prepare(
    'INSERT INTO match_games (match_id, replay_code, game_number, winner_id, validated, replay_json) VALUES (?, ?, ?, ?, 1, ?)'
  ).run(matchId, replayCode, existing + 1, winnerId, replayJson);
  return db.prepare('SELECT * FROM match_games WHERE id = ?').get(result.lastInsertRowid);
}

export function getMatchGames(matchId) {
  return getDb().prepare('SELECT * FROM match_games WHERE match_id = ? ORDER BY game_number').all(matchId);
}

export function getMatchesByTournament(tournamentId) {
  return getDb().prepare(
    `SELECT tm.*, tr.round_number,
            u1.prismata_username as p1_name, u2.prismata_username as p2_name,
            uw.prismata_username as winner_name
     FROM tournament_matches tm
     JOIN tournament_rounds tr ON tm.round_id = tr.id
     LEFT JOIN users u1 ON tm.player1_id = u1.id
     LEFT JOIN users u2 ON tm.player2_id = u2.id
     LEFT JOIN users uw ON tm.winner_id = uw.id
     WHERE tm.tournament_id = ?
     ORDER BY tr.round_number, tm.id`
  ).all(tournamentId);
}

// --- Challenges ---

export function createChallenge(challengerId, challengedId, bestOf, rulesJson) {
  const db = getDb();
  const result = db.prepare(
    'INSERT INTO challenges (challenger_id, challenged_id, best_of, rules_json) VALUES (?, ?, ?, ?)'
  ).run(challengerId, challengedId, bestOf, rulesJson);
  return db.prepare('SELECT * FROM challenges WHERE id = ?').get(result.lastInsertRowid);
}

export function getChallenge(id) {
  return getDb().prepare('SELECT * FROM challenges WHERE id = ?').get(id);
}

export function getPendingChallengeForUser(userId) {
  return getDb().prepare(
    `SELECT c.*,
            u1.prismata_username as challenger_name, u1.discord_id as challenger_discord_id,
            u2.prismata_username as challenged_name, u2.discord_id as challenged_discord_id
     FROM challenges c
     JOIN users u1 ON c.challenger_id = u1.id
     JOIN users u2 ON c.challenged_id = u2.id
     WHERE (c.challenger_id = ? OR c.challenged_id = ?) AND c.status IN ('pending', 'accepted', 'in_progress')
     ORDER BY c.created_at DESC LIMIT 1`
  ).get(userId, userId);
}

export function updateChallengeStatus(id, status) {
  getDb().prepare('UPDATE challenges SET status = ? WHERE id = ?').run(status, id);
}

export function addChallengeGame(challengeId, replayCode, winnerId) {
  const db = getDb();
  const existing = db.prepare('SELECT COUNT(*) as count FROM challenge_games WHERE challenge_id = ?').get(challengeId).count;
  db.prepare(
    'INSERT INTO challenge_games (challenge_id, replay_code, game_number, winner_id, validated) VALUES (?, ?, ?, ?, 1)'
  ).run(challengeId, replayCode, existing + 1, winnerId);
}

export function getChallengeGames(challengeId) {
  return getDb().prepare('SELECT * FROM challenge_games WHERE challenge_id = ? ORDER BY game_number').all(challengeId);
}

// --- Disputes ---

export function createDispute(matchId, challengeId, raisedBy, reason) {
  const db = getDb();
  const result = db.prepare(
    'INSERT INTO disputes (match_id, challenge_id, raised_by, reason) VALUES (?, ?, ?, ?)'
  ).run(matchId, challengeId, raisedBy, reason);
  // Mark the match/challenge as disputed
  if (matchId) {
    db.prepare("UPDATE tournament_matches SET status = 'disputed' WHERE id = ?").run(matchId);
  }
  return db.prepare('SELECT * FROM disputes WHERE id = ?').get(result.lastInsertRowid);
}

export function getOpenDisputes() {
  return getDb().prepare("SELECT * FROM disputes WHERE status = 'open' ORDER BY created_at").all();
}

export function resolveDispute(disputeId, resolvedBy, resolution) {
  getDb().prepare(
    "UPDATE disputes SET resolved_by = ?, resolution = ?, status = 'resolved' WHERE id = ?"
  ).run(resolvedBy, resolution, disputeId);
}

// --- Helpers ---

export function getOverdueMatches(now) {
  return getDb().prepare(
    `SELECT tm.*, t.name as tournament_name,
            u1.discord_id as p1_discord_id, u2.discord_id as p2_discord_id,
            u1.prismata_username as p1_name, u2.prismata_username as p2_name
     FROM tournament_matches tm
     JOIN tournaments t ON tm.tournament_id = t.id
     JOIN users u1 ON tm.player1_id = u1.id
     JOIN users u2 ON tm.player2_id = u2.id
     WHERE tm.status IN ('pending', 'in_progress') AND tm.deadline < ?`
  ).all(now);
}

export function getMatchesNeedingReminder(nowIso, thresholdPercent) {
  // Returns matches where elapsed time > thresholdPercent of total time
  // This is complex with SQLite date math, so we'll compute in JS
  return getDb().prepare(
    `SELECT tm.*, t.name as tournament_name, t.rules_json,
            tr.deadline as round_deadline,
            u1.discord_id as p1_discord_id, u2.discord_id as p2_discord_id,
            u1.prismata_username as p1_name, u2.prismata_username as p2_name
     FROM tournament_matches tm
     JOIN tournaments t ON tm.tournament_id = t.id
     JOIN tournament_rounds tr ON tm.round_id = tr.id
     JOIN users u1 ON tm.player1_id = u1.id
     JOIN users u2 ON tm.player2_id = u2.id
     WHERE tm.status IN ('pending', 'in_progress')`
  ).all();
}

```

- [ ] **Step 2: Write tests**

```javascript
// bot/__tests__/tournament-db.test.js
import { describe, it, before, after } from 'node:test';
import assert from 'node:assert';
import Database from 'better-sqlite3';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

// We test DB functions by creating an in-memory DB and calling the functions directly.
// Since tournament-db.js imports getDb() from db.js (which uses config), we test the
// SQL logic directly with our own in-memory connection instead.

describe('Tournament DB queries', () => {
  let db;

  before(() => {
    db = new Database(':memory:');
    const schema = readFileSync(resolve(__dirname, '..', 'schema.sql'), 'utf-8');
    db.exec(schema);

    // Seed test users
    db.prepare('INSERT INTO users (id, discord_id, discord_username, prismata_username, verified) VALUES (?, ?, ?, ?, 1)').run(1, 'discord_1', 'Alice', 'Alice', 1);
    db.prepare('INSERT INTO users (id, discord_id, discord_username, prismata_username, verified) VALUES (?, ?, ?, ?, 1)').run(2, 'discord_2', 'Bob', 'Bob', 1);
    db.prepare('INSERT INTO users (id, discord_id, discord_username, prismata_username, verified) VALUES (?, ?, ?, ?, 1)').run(3, 'discord_3', 'Charlie', 'Charlie', 1);
    db.prepare('INSERT INTO users (id, discord_id, discord_username, prismata_username, verified) VALUES (?, ?, ?, ?, 1)').run(4, 'discord_4', 'Diana', 'Diana', 1);
  });

  after(() => db.close());

  it('creates a tournament', () => {
    const result = db.prepare(
      "INSERT INTO tournaments (name, format, rules_json, created_by) VALUES (?, ?, ?, ?)"
    ).run('Test Cup', 'single_elim', '{"time_control":45,"randomizer_count":8}', 1);
    const t = db.prepare('SELECT * FROM tournaments WHERE id = ?').get(result.lastInsertRowid);
    assert.equal(t.name, 'Test Cup');
    assert.equal(t.status, 'registration');
  });

  it('manages tournament players', () => {
    db.prepare('INSERT OR IGNORE INTO tournament_players (tournament_id, user_id) VALUES (?, ?)').run(1, 1);
    db.prepare('INSERT OR IGNORE INTO tournament_players (tournament_id, user_id) VALUES (?, ?)').run(1, 2);
    db.prepare('INSERT OR IGNORE INTO tournament_players (tournament_id, user_id) VALUES (?, ?)').run(1, 3);
    db.prepare('INSERT OR IGNORE INTO tournament_players (tournament_id, user_id) VALUES (?, ?)').run(1, 4);

    const count = db.prepare('SELECT COUNT(*) as count FROM tournament_players WHERE tournament_id = 1').get().count;
    assert.equal(count, 4);
  });

  it('creates rounds and matches', () => {
    const round = db.prepare(
      "INSERT INTO tournament_rounds (tournament_id, round_number, deadline, status) VALUES (?, ?, ?, 'active')"
    ).run(1, 1, '2026-04-01T00:00:00Z');

    db.prepare(
      "INSERT INTO tournament_matches (tournament_id, round_id, player1_id, player2_id, best_of, deadline, status) VALUES (?, ?, ?, ?, ?, ?, 'pending')"
    ).run(1, round.lastInsertRowid, 1, 2, 1, '2026-04-01T00:00:00Z');
    db.prepare(
      "INSERT INTO tournament_matches (tournament_id, round_id, player1_id, player2_id, best_of, deadline, status) VALUES (?, ?, ?, ?, ?, ?, 'pending')"
    ).run(1, round.lastInsertRowid, 3, 4, 1, '2026-04-01T00:00:00Z');

    const matches = db.prepare(
      `SELECT tm.*, u1.prismata_username as p1_name, u2.prismata_username as p2_name
       FROM tournament_matches tm
       JOIN users u1 ON tm.player1_id = u1.id JOIN users u2 ON tm.player2_id = u2.id
       WHERE tm.round_id = ?`
    ).all(round.lastInsertRowid);

    assert.equal(matches.length, 2);
    assert.equal(matches[0].p1_name, 'Alice');
    assert.equal(matches[0].p2_name, 'Bob');
  });

  it('records match results', () => {
    db.prepare("UPDATE tournament_matches SET winner_id = 1, status = 'completed' WHERE id = 1").run();
    const match = db.prepare('SELECT * FROM tournament_matches WHERE id = 1').get();
    assert.equal(match.winner_id, 1);
    assert.equal(match.status, 'completed');
  });

  it('records match games with replay codes', () => {
    db.prepare(
      "INSERT INTO match_games (match_id, replay_code, game_number, winner_id, validated) VALUES (?, ?, ?, ?, 1)"
    ).run(1, 'AAAAA-BBBBB', 1, 1);

    const games = db.prepare('SELECT * FROM match_games WHERE match_id = 1').all();
    assert.equal(games.length, 1);
    assert.equal(games[0].replay_code, 'AAAAA-BBBBB');
  });

  it('manages challenges', () => {
    const result = db.prepare(
      "INSERT INTO challenges (challenger_id, challenged_id, best_of, rules_json) VALUES (?, ?, ?, ?)"
    ).run(1, 2, 3, '{"time_control":45}');

    const challenge = db.prepare('SELECT * FROM challenges WHERE id = ?').get(result.lastInsertRowid);
    assert.equal(challenge.status, 'pending');
    assert.equal(challenge.best_of, 3);
  });

  it('creates and resolves disputes', () => {
    db.prepare('INSERT INTO disputes (match_id, raised_by, reason) VALUES (?, ?, ?)').run(1, 2, 'Wrong replay');
    const dispute = db.prepare("SELECT * FROM disputes WHERE match_id = 1 AND status = 'open'").get();
    assert.ok(dispute);
    assert.equal(dispute.reason, 'Wrong replay');

    db.prepare("UPDATE disputes SET resolved_by = 1, resolution = 'Replay confirmed valid', status = 'resolved' WHERE id = ?").run(dispute.id);
    const resolved = db.prepare('SELECT * FROM disputes WHERE id = ?').get(dispute.id);
    assert.equal(resolved.status, 'resolved');
  });
});
```

- [ ] **Step 3: Run tests**

Run: `cd <PRISMATA_LADDER_REPO>/bot && npm test`
Expected: All tests pass (existing 21 + new tournament DB tests)

- [ ] **Step 4: Commit**

```bash
cd <PRISMATA_LADDER_REPO>
git add bot/lib/tournament-db.js bot/__tests__/tournament-db.test.js
git commit -m "feat(bot): add tournament database query layer"
```

---

## Task 2: Bracket Engine (Single Elimination)

**Files:**
- Create: `bot/lib/bracket-engine.js`
- Create: `bot/__tests__/bracket-engine.test.js`

- [ ] **Step 1: Create bracket engine**

```javascript
// bot/lib/bracket-engine.js

/**
 * Generate first-round pairings for a single elimination bracket.
 * Players are paired in the order given (caller is responsible for seeding/shuffling).
 * If player count is not a power of 2, some players get byes in round 1.
 *
 * @param {Array<{userId: number}>} players - Array of player objects, pre-ordered by seed
 * @returns {Array<{player1Id: number, player2Id: number|null}>} Pairings (null = bye)
 */
export function generateSingleElimPairings(players) {
  if (players.length < 2) {
    throw new Error('Need at least 2 players for a tournament');
  }

  const ordered = [...players]; // Don't shuffle — caller controls order
  const n = ordered.length;

  // Next power of 2
  const bracketSize = Math.pow(2, Math.ceil(Math.log2(n)));
  const byeCount = bracketSize - n;

  const pairings = [];

  // First `byeCount` players get byes (they advance automatically to round 2)
  // Remaining players are paired
  const byePlayers = ordered.slice(0, byeCount);
  const matchPlayers = ordered.slice(byeCount);

  // Bye pairings
  for (const p of byePlayers) {
    pairings.push({ player1Id: p.userId, player2Id: null });
  }

  // Match pairings
  for (let i = 0; i < matchPlayers.length; i += 2) {
    pairings.push({
      player1Id: matchPlayers[i].userId,
      player2Id: matchPlayers[i + 1].userId,
    });
  }

  return pairings;
}

/**
 * Generate next-round pairings from previous round winners.
 * Winners are paired in order (1v2, 3v4, etc.).
 * Bye winners (from round 1) are included.
 *
 * @param {number[]} winnerIds - IDs of round winners, in bracket order
 * @returns {Array<{player1Id: number, player2Id: number|null}>}
 */
export function generateNextRoundPairings(winnerIds) {
  if (winnerIds.length < 2) {
    return []; // Tournament is over (1 winner)
  }

  const pairings = [];
  for (let i = 0; i < winnerIds.length; i += 2) {
    if (i + 1 < winnerIds.length) {
      pairings.push({ player1Id: winnerIds[i], player2Id: winnerIds[i + 1] });
    } else {
      // Odd number of winners — last one gets a bye
      pairings.push({ player1Id: winnerIds[i], player2Id: null });
    }
  }
  return pairings;
}

/**
 * Calculate the total number of rounds for a single elimination bracket.
 * @param {number} playerCount
 * @returns {number}
 */
export function totalRounds(playerCount) {
  return Math.ceil(Math.log2(playerCount));
}

/**
 * Check if all matches in a round are completed (or forfeited).
 * @param {Array<{status: string}>} matches
 * @returns {boolean}
 */
export function isRoundComplete(matches) {
  return matches.every(m => m.status === 'completed' || m.status === 'forfeited');
}

/**
 * Get the winners from a completed round, preserving bracket order.
 * For byes, the player1 is the winner.
 * @param {Array<{player1_id: number, player2_id: number|null, winner_id: number|null, status: string}>} matches
 * @returns {number[]} Winner IDs in bracket order
 */
export function getRoundWinners(matches) {
  return matches.map(m => {
    if (m.player2_id === null) return m.player1_id; // bye
    if (m.winner_id) return m.winner_id;
    return null; // should not happen for completed rounds
  }).filter(id => id !== null);
}

/**
 * Check if a round is complete and advance the bracket if so.
 * Creates next round matches, handles byes, DMs players.
 * @param {import('discord.js').Client} client - Discord client for DMs
 * @param {number} tournamentId
 */
export async function tryAdvanceBracket(client, tournamentId) {
  // Dynamic imports to avoid circular deps (bracket-engine is a lib, not a command)
  const { getActiveRound, getMatchesForRound, completeRound, createRound, createMatch,
          setMatchResult, getTournament, updateTournamentStatus } = await import('./tournament-db.js');

  const activeRound = getActiveRound(tournamentId);
  if (!activeRound) return;

  const matches = getMatchesForRound(activeRound.id);
  if (!isRoundComplete(matches)) return;

  completeRound(activeRound.id);

  const winners = getRoundWinners(matches);
  if (winners.length <= 1) {
    updateTournamentStatus(tournamentId, 'completed');
    return;
  }

  const nextPairings = generateNextRoundPairings(winners);
  const tournament = getTournament(tournamentId);
  const rules = JSON.parse(tournament.rules_json);
  const deadline = new Date(Date.now() + 48 * 60 * 60 * 1000).toISOString();
  const nextRound = createRound(tournamentId, activeRound.round_number + 1, deadline);

  for (const pairing of nextPairings) {
    const match = createMatch(tournamentId, nextRound.id, pairing.player1Id, pairing.player2Id, rules.best_of || 1, deadline);
    if (pairing.player2Id === null) {
      setMatchResult(match.id, pairing.player1Id, 'completed');
    }
  }

  // DM players about new round matches
  const newMatches = getMatchesForRound(nextRound.id);
  for (const match of newMatches) {
    if (!match.p2_discord_id) continue;
    const dmContent = `Your **${tournament.name}** Round ${activeRound.round_number + 1} match is ready!\n` +
      `**${match.p1_name}** vs **${match.p2_name}**\n` +
      `Deadline: <t:${Math.floor(new Date(deadline).getTime() / 1000)}:R>`;
    try {
      const p1 = await client.users.fetch(match.p1_discord_id);
      await p1.send(dmContent).catch(() => {});
      const p2 = await client.users.fetch(match.p2_discord_id);
      await p2.send(dmContent).catch(() => {});
    } catch { /* DMs may be closed */ }
  }
}
```

- [ ] **Step 2: Write tests**

```javascript
// bot/__tests__/bracket-engine.test.js
import { describe, it } from 'node:test';
import assert from 'node:assert';
import {
  generateSingleElimPairings, generateNextRoundPairings,
  totalRounds, isRoundComplete, getRoundWinners
} from '../lib/bracket-engine.js';

describe('generateSingleElimPairings', () => {
  it('pairs 4 players with no byes', () => {
    const players = [{ userId: 1 }, { userId: 2 }, { userId: 3 }, { userId: 4 }];
    const pairings = generateSingleElimPairings(players);
    assert.equal(pairings.length, 2);
    assert.ok(pairings.every(p => p.player2Id !== null));
    // All 4 players should appear exactly once
    const allIds = pairings.flatMap(p => [p.player1Id, p.player2Id]);
    assert.deepStrictEqual(allIds.sort(), [1, 2, 3, 4]);
  });

  it('gives byes for 3 players (next power of 2 is 4)', () => {
    const players = [{ userId: 1 }, { userId: 2 }, { userId: 3 }];
    const pairings = generateSingleElimPairings(players);
    // 1 bye + 1 match = 2 pairings
    assert.equal(pairings.length, 2);
    const byes = pairings.filter(p => p.player2Id === null);
    assert.equal(byes.length, 1);
  });

  it('gives byes for 5 players (next power of 2 is 8)', () => {
    const players = [1, 2, 3, 4, 5].map(id => ({ userId: id }));
    const pairings = generateSingleElimPairings(players);
    // 3 byes + 1 match = 4 pairings (bracket size 8, 3 byes)
    const byes = pairings.filter(p => p.player2Id === null);
    const matches = pairings.filter(p => p.player2Id !== null);
    assert.equal(byes.length, 3);
    assert.equal(matches.length, 1);
  });

  it('handles 8 players perfectly', () => {
    const players = [1, 2, 3, 4, 5, 6, 7, 8].map(id => ({ userId: id }));
    const pairings = generateSingleElimPairings(players);
    assert.equal(pairings.length, 4);
    assert.ok(pairings.every(p => p.player2Id !== null));
  });

  it('throws for fewer than 2 players', () => {
    assert.throws(() => generateSingleElimPairings([{ userId: 1 }]));
  });
});

describe('generateNextRoundPairings', () => {
  it('pairs 4 winners into 2 matches', () => {
    const pairings = generateNextRoundPairings([1, 2, 3, 4]);
    assert.equal(pairings.length, 2);
    assert.deepStrictEqual(pairings[0], { player1Id: 1, player2Id: 2 });
    assert.deepStrictEqual(pairings[1], { player1Id: 3, player2Id: 4 });
  });

  it('returns empty for 1 winner (tournament over)', () => {
    assert.deepStrictEqual(generateNextRoundPairings([1]), []);
  });

  it('gives bye for odd number of winners', () => {
    const pairings = generateNextRoundPairings([1, 2, 3]);
    assert.equal(pairings.length, 2);
    assert.deepStrictEqual(pairings[1], { player1Id: 3, player2Id: null });
  });
});

describe('totalRounds', () => {
  it('returns correct round counts', () => {
    assert.equal(totalRounds(2), 1);
    assert.equal(totalRounds(4), 2);
    assert.equal(totalRounds(8), 3);
    assert.equal(totalRounds(3), 2);
    assert.equal(totalRounds(5), 3);
    assert.equal(totalRounds(16), 4);
  });
});

describe('isRoundComplete', () => {
  it('returns true when all matches completed or forfeited', () => {
    assert.ok(isRoundComplete([
      { status: 'completed' },
      { status: 'forfeited' },
      { status: 'completed' },
    ]));
  });

  it('returns false with pending matches', () => {
    assert.ok(!isRoundComplete([
      { status: 'completed' },
      { status: 'pending' },
    ]));
  });
});

describe('getRoundWinners', () => {
  it('extracts winners preserving order', () => {
    const matches = [
      { player1_id: 1, player2_id: 2, winner_id: 1, status: 'completed' },
      { player1_id: 3, player2_id: null, winner_id: null, status: 'completed' }, // bye
      { player1_id: 5, player2_id: 6, winner_id: 6, status: 'completed' },
    ];
    assert.deepStrictEqual(getRoundWinners(matches), [1, 3, 6]);
  });
});
```

- [ ] **Step 3: Run tests**

Run: `cd <PRISMATA_LADDER_REPO>/bot && npm test`
Expected: All pass

- [ ] **Step 4: Commit**

```bash
git add bot/lib/bracket-engine.js bot/__tests__/bracket-engine.test.js
git commit -m "feat(bot): add single elimination bracket engine"
```

---

## Task 3: /tournament Command

**Files:**
- Create: `bot/commands/tournament.js`

- [ ] **Step 1: Create tournament command with subcommands**

```javascript
// bot/commands/tournament.js
import { SlashCommandBuilder, EmbedBuilder, ModalBuilder, TextInputBuilder, TextInputStyle, ActionRowBuilder } from 'discord.js';
import { getUserByDiscordId } from '../db.js';
import {
  createTournament, getTournamentByName, listTournaments, updateTournamentStatus,
  joinTournament, leaveTournament, getTournamentPlayers, getTournamentPlayerCount,
  isPlayerInTournament, updatePlayerSeed, createRound, createMatch, getActiveRound,
  getMatchesForRound, getMatchesByTournament, setMatchResult, eliminatePlayer,
} from '../lib/tournament-db.js';
import { generateSingleElimPairings, totalRounds } from '../lib/bracket-engine.js';

export const data = new SlashCommandBuilder()
  .setName('tournament')
  .setDescription('Tournament management')
  .addSubcommand(sub =>
    sub.setName('create')
      .setDescription('Create a new tournament (organizer only)')
      .addStringOption(opt => opt.setName('name').setDescription('Tournament name').setRequired(true))
      .addIntegerOption(opt => opt.setName('time').setDescription('Time control in seconds (default: 45)'))
      .addIntegerOption(opt => opt.setName('units').setDescription('Random unit count (default: 8)'))
      .addIntegerOption(opt => opt.setName('best_of').setDescription('Best of N per match (default: 1)'))
      .addIntegerOption(opt => opt.setName('max_players').setDescription('Maximum players'))
      .addStringOption(opt => opt.setName('deadline').setDescription('Registration deadline (e.g., "2026-04-01")'))
      .addStringOption(opt => opt.setName('description').setDescription('Tournament description'))
  )
  .addSubcommand(sub =>
    sub.setName('join')
      .setDescription('Join a tournament')
      .addStringOption(opt => opt.setName('name').setDescription('Tournament name').setRequired(true))
  )
  .addSubcommand(sub =>
    sub.setName('leave')
      .setDescription('Leave a tournament (before it starts)')
      .addStringOption(opt => opt.setName('name').setDescription('Tournament name').setRequired(true))
  )
  .addSubcommand(sub =>
    sub.setName('start')
      .setDescription('Start a tournament — close registration and generate bracket (organizer only)')
      .addStringOption(opt => opt.setName('name').setDescription('Tournament name').setRequired(true))
      .addStringOption(opt => opt.setName('round_deadline').setDescription('Hours per round (default: 48)'))
  )
  .addSubcommand(sub =>
    sub.setName('status')
      .setDescription('View tournament status')
      .addStringOption(opt => opt.setName('name').setDescription('Tournament name (omit to list all)'))
  )
  .addSubcommand(sub =>
    sub.setName('cancel')
      .setDescription('Cancel a tournament (organizer only)')
      .addStringOption(opt => opt.setName('name').setDescription('Tournament name').setRequired(true))
  )
  .addSubcommand(sub =>
    sub.setName('forfeit')
      .setDescription('Forfeit a player from a tournament (organizer only)')
      .addStringOption(opt => opt.setName('name').setDescription('Tournament name').setRequired(true))
      .addUserOption(opt => opt.setName('player').setDescription('Player to forfeit').setRequired(true))
  )
  .addSubcommand(sub =>
    sub.setName('resolve')
      .setDescription('Resolve a disputed match (organizer only)')
      .addIntegerOption(opt => opt.setName('match_id').setDescription('Match ID').setRequired(true))
      .addUserOption(opt => opt.setName('winner').setDescription('Winner of the match').setRequired(true))
  );

export async function execute(interaction) {
  const sub = interaction.options.getSubcommand();
  const user = getUserByDiscordId(interaction.user.id);

  if (sub === 'create') {
    if (!user || (user.role !== 'organizer' && user.role !== 'admin')) {
      return interaction.reply({ content: 'Only organizers can create tournaments.', ephemeral: true });
    }

    const name = interaction.options.getString('name');
    const timeControl = interaction.options.getInteger('time') ?? 45;
    const randomizerCount = interaction.options.getInteger('units') ?? 8;
    const bestOf = interaction.options.getInteger('best_of') ?? 1;
    const maxPlayers = interaction.options.getInteger('max_players') ?? null;
    const deadline = interaction.options.getString('deadline') ?? null;
    const description = interaction.options.getString('description') ?? null;

    if (getTournamentByName(name)) {
      return interaction.reply({ content: `Tournament "${name}" already exists.`, ephemeral: true });
    }

    const rules = JSON.stringify({ time_control: timeControl, randomizer_count: randomizerCount, best_of: bestOf });
    const tournament = createTournament(name, description, 'single_elim', rules, user.id, maxPlayers, deadline);

    const embed = new EmbedBuilder()
      .setColor(0xe17055)
      .setTitle(`Tournament Created: ${name}`)
      .setDescription(description || 'No description')
      .addFields(
        { name: 'Format', value: 'Single Elimination', inline: true },
        { name: 'Time Control', value: `${timeControl}s`, inline: true },
        { name: 'Random Units', value: `Base +${randomizerCount}`, inline: true },
        { name: 'Best Of', value: bestOf.toString(), inline: true },
      );
    if (maxPlayers) embed.addFields({ name: 'Max Players', value: maxPlayers.toString(), inline: true });
    if (deadline) embed.addFields({ name: 'Registration Deadline', value: deadline, inline: true });
    embed.setFooter({ text: `Use /tournament join ${name} to register` });

    return interaction.reply({ embeds: [embed] });
  }

  if (sub === 'join') {
    if (!user?.verified) {
      return interaction.reply({ content: 'You must verify your Prismata account first. Use `/verify start`.', ephemeral: true });
    }

    const name = interaction.options.getString('name');
    const tournament = getTournamentByName(name);
    if (!tournament) return interaction.reply({ content: `Tournament "${name}" not found.`, ephemeral: true });
    if (tournament.status !== 'registration') {
      return interaction.reply({ content: 'This tournament is no longer accepting registrations.', ephemeral: true });
    }

    if (isPlayerInTournament(tournament.id, user.id)) {
      return interaction.reply({ content: "You're already registered.", ephemeral: true });
    }

    if (tournament.max_players) {
      const count = getTournamentPlayerCount(tournament.id);
      if (count >= tournament.max_players) {
        return interaction.reply({ content: 'This tournament is full.', ephemeral: true });
      }
    }

    joinTournament(tournament.id, user.id);
    const count = getTournamentPlayerCount(tournament.id);

    return interaction.reply({
      content: `**${user.prismata_username}** joined **${name}**! (${count} player${count !== 1 ? 's' : ''} registered)`,
    });
  }

  if (sub === 'leave') {
    if (!user) return interaction.reply({ content: 'Not registered.', ephemeral: true });

    const name = interaction.options.getString('name');
    const tournament = getTournamentByName(name);
    if (!tournament) return interaction.reply({ content: `Tournament "${name}" not found.`, ephemeral: true });
    if (tournament.status !== 'registration') {
      return interaction.reply({ content: 'Cannot leave after the tournament has started.', ephemeral: true });
    }

    leaveTournament(tournament.id, user.id);
    return interaction.reply({ content: `You've left **${name}**.`, ephemeral: true });
  }

  if (sub === 'start') {
    if (!user || (user.role !== 'organizer' && user.role !== 'admin')) {
      return interaction.reply({ content: 'Only organizers can start tournaments.', ephemeral: true });
    }

    const name = interaction.options.getString('name');
    const roundHours = parseInt(interaction.options.getString('round_deadline') || '48', 10);
    const tournament = getTournamentByName(name);
    if (!tournament) return interaction.reply({ content: `Tournament "${name}" not found.`, ephemeral: true });
    if (tournament.status !== 'registration') {
      return interaction.reply({ content: 'Tournament has already started or is cancelled.', ephemeral: true });
    }

    const players = getTournamentPlayers(tournament.id);
    if (players.length < 2) {
      return interaction.reply({ content: 'Need at least 2 players to start.', ephemeral: true });
    }

    await interaction.deferReply();

    // Seed players randomly
    const shuffledPlayers = [...players].sort(() => Math.random() - 0.5);
    shuffledPlayers.forEach((p, i) => updatePlayerSeed(tournament.id, p.user_id, i + 1));

    // Generate bracket
    const pairings = generateSingleElimPairings(shuffledPlayers.map(p => ({ userId: p.user_id })));
    const rules = JSON.parse(tournament.rules_json);
    const deadline = new Date(Date.now() + roundHours * 60 * 60 * 1000).toISOString();
    const round = createRound(tournament.id, 1, deadline);

    const matchDescriptions = [];
    for (const pairing of pairings) {
      if (pairing.player2Id === null) {
        // Bye — create match pre-completed
        const match = createMatch(tournament.id, round.id, pairing.player1Id, null, rules.best_of || 1, deadline);
        const byePlayer = players.find(p => p.user_id === pairing.player1Id);
        matchDescriptions.push(`**${byePlayer?.prismata_username}** — bye`);
        // Auto-complete bye match (setMatchResult already imported at top)
        setMatchResult(match.id, pairing.player1Id, 'completed');
      } else {
        createMatch(tournament.id, round.id, pairing.player1Id, pairing.player2Id, rules.best_of || 1, deadline);
        const p1 = players.find(p => p.user_id === pairing.player1Id);
        const p2 = players.find(p => p.user_id === pairing.player2Id);
        matchDescriptions.push(`**${p1?.prismata_username}** vs **${p2?.prismata_username}**`);
      }
    }

    updateTournamentStatus(tournament.id, 'active');

    const numRounds = totalRounds(players.length);
    const embed = new EmbedBuilder()
      .setColor(0x00b894)
      .setTitle(`${name} — Started!`)
      .setDescription(`Single Elimination · ${players.length} players · ${numRounds} rounds`)
      .addFields(
        { name: 'Round 1 Matches', value: matchDescriptions.join('\n') || 'None' },
        { name: 'Deadline', value: `<t:${Math.floor(Date.now() / 1000 + roundHours * 3600)}:R>` },
      )
      .setFooter({ text: `Submit results with /result <replay-code>` });

    // DM all players about their matches
    const matches = getMatchesForRound(round.id);
    for (const match of matches) {
      if (!match.p2_discord_id) continue; // skip byes
      const dmContent = `Your **${name}** Round 1 match is ready!\n` +
        `**${match.p1_name}** vs **${match.p2_name}**\n` +
        `Settings: ${rules.time_control}s, Base +${rules.randomizer_count}\n` +
        `Deadline: <t:${Math.floor(new Date(deadline).getTime() / 1000)}:R>\n` +
        `Submit result: \`/result <replay-code>\``;
      try {
        const p1User = await interaction.client.users.fetch(match.p1_discord_id);
        await p1User.send(dmContent).catch(() => {});
        const p2User = await interaction.client.users.fetch(match.p2_discord_id);
        await p2User.send(dmContent).catch(() => {});
      } catch { /* DMs may be closed */ }
    }

    return interaction.editReply({ embeds: [embed] });
  }

  if (sub === 'status') {
    const name = interaction.options.getString('name');

    if (!name) {
      // List all active/registration tournaments
      const tournaments = listTournaments();
      if (tournaments.length === 0) {
        return interaction.reply({ content: 'No active tournaments.', ephemeral: true });
      }
      const embed = new EmbedBuilder()
        .setColor(0x3498db)
        .setTitle('Tournaments')
        .setDescription(tournaments.map(t => {
          const count = getTournamentPlayerCount(t.id);
          return `**${t.name}** — ${t.status} (${count} players)`;
        }).join('\n'));
      return interaction.reply({ embeds: [embed] });
    }

    const tournament = getTournamentByName(name);
    if (!tournament) return interaction.reply({ content: `Tournament "${name}" not found.`, ephemeral: true });

    const players = getTournamentPlayers(tournament.id);
    const rules = JSON.parse(tournament.rules_json);
    const activeRound = getActiveRound(tournament.id);

    const embed = new EmbedBuilder()
      .setColor(tournament.status === 'active' ? 0x00b894 : 0x3498db)
      .setTitle(tournament.name)
      .setDescription(tournament.description || 'No description')
      .addFields(
        { name: 'Status', value: tournament.status, inline: true },
        { name: 'Format', value: 'Single Elimination', inline: true },
        { name: 'Players', value: players.length.toString(), inline: true },
        { name: 'Settings', value: `${rules.time_control}s · Base +${rules.randomizer_count} · Bo${rules.best_of || 1}`, inline: true },
      );

    if (activeRound) {
      const matches = getMatchesForRound(activeRound.id);
      const matchLines = matches.map(m => {
        const status = m.status === 'completed' ? '✅' : m.status === 'forfeited' ? '❌' : '⏳';
        const winner = m.winner_id ? (m.winner_id === m.player1_id ? m.p1_name : m.p2_name) : '';
        const vs = m.p2_name ? `${m.p1_name} vs ${m.p2_name}` : `${m.p1_name} (bye)`;
        return `${status} ${vs}${winner ? ` → **${winner}**` : ''}`;
      });
      embed.addFields({ name: `Round ${activeRound.round_number}`, value: matchLines.join('\n') || 'No matches' });
    }

    if (tournament.status === 'registration') {
      embed.addFields({
        name: 'Registered Players',
        value: players.map(p => p.prismata_username).join(', ') || 'None',
      });
    }

    return interaction.reply({ embeds: [embed] });
  }

  if (sub === 'cancel') {
    if (!user || (user.role !== 'organizer' && user.role !== 'admin')) {
      return interaction.reply({ content: 'Only organizers can cancel tournaments.', ephemeral: true });
    }

    const name = interaction.options.getString('name');
    const tournament = getTournamentByName(name);
    if (!tournament) return interaction.reply({ content: `Tournament "${name}" not found.`, ephemeral: true });
    if (tournament.status === 'completed' || tournament.status === 'cancelled') {
      return interaction.reply({ content: 'Tournament is already finished or cancelled.', ephemeral: true });
    }

    updateTournamentStatus(tournament.id, 'cancelled');
    return interaction.reply({ content: `Tournament **${name}** has been cancelled.` });
  }

  if (sub === 'forfeit') {
    if (!user || (user.role !== 'organizer' && user.role !== 'admin')) {
      return interaction.reply({ content: 'Only organizers can forfeit players.', ephemeral: true });
    }

    const name = interaction.options.getString('name');
    const playerDiscord = interaction.options.getUser('player');
    const tournament = getTournamentByName(name);
    if (!tournament) return interaction.reply({ content: `Tournament "${name}" not found.`, ephemeral: true });

    const { getUserByDiscordId: getUser } = await import('../db.js');
    const targetUser = getUser(playerDiscord.id);
    if (!targetUser) return interaction.reply({ content: 'Player not found.', ephemeral: true });

    eliminatePlayer(tournament.id, targetUser.id);

    // Find and forfeit their active match
    const { default: Database } = await import('better-sqlite3');
    const db = (await import('../db.js')).getDb();
    const activeMatch = db.prepare(
      "SELECT * FROM tournament_matches WHERE tournament_id = ? AND (player1_id = ? OR player2_id = ?) AND status IN ('pending', 'in_progress')"
    ).get(tournament.id, targetUser.id, targetUser.id);

    if (activeMatch) {
      const winnerId = activeMatch.player1_id === targetUser.id ? activeMatch.player2_id : activeMatch.player1_id;
      setMatchResult(activeMatch.id, winnerId, 'forfeited');
      const { tryAdvanceBracket } = await import('../lib/bracket-engine.js');
      await tryAdvanceBracket(interaction.client, tournament.id);
    }

    return interaction.reply({ content: `**${targetUser.prismata_username}** has been forfeited from **${name}**.` });
  }

  if (sub === 'resolve') {
    if (!user || (user.role !== 'organizer' && user.role !== 'admin')) {
      return interaction.reply({ content: 'Only organizers can resolve disputes.', ephemeral: true });
    }

    const matchId = interaction.options.getInteger('match_id');
    const winnerDiscord = interaction.options.getUser('winner');
    const { getUserByDiscordId: getUser } = await import('../db.js');
    const winnerUser = getUser(winnerDiscord.id);
    if (!winnerUser) return interaction.reply({ content: 'Winner not found.', ephemeral: true });

    const { getMatch, resolveDispute: resolve, getOpenDisputes } = await import('../lib/tournament-db.js');
    const match = getMatch(matchId);
    if (!match) return interaction.reply({ content: 'Match not found.', ephemeral: true });

    // Find open dispute for this match
    const db = (await import('../db.js')).getDb();
    const dispute = db.prepare("SELECT * FROM disputes WHERE match_id = ? AND status = 'open'").get(matchId);
    if (dispute) {
      resolve(dispute.id, user.id, `Resolved by organizer. Winner: ${winnerUser.prismata_username}`);
    }

    setMatchResult(matchId, winnerUser.id, 'completed');
    const loserId = match.player1_id === winnerUser.id ? match.player2_id : match.player1_id;
    if (loserId) eliminatePlayer(match.tournament_id, loserId);

    const { tryAdvanceBracket } = await import('../commands/result.js');
    await tryAdvanceBracket(interaction.client, match.tournament_id);

    return interaction.reply({ content: `Match #${matchId} resolved. **${winnerUser.prismata_username}** wins.` });
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add bot/commands/tournament.js
git commit -m "feat(bot): add /tournament command with create, join, start, status, cancel"
```

---

## Task 4: /result Command

**Files:**
- Create: `bot/commands/result.js`

- [ ] **Step 1: Create result command**

```javascript
// bot/commands/result.js
import { SlashCommandBuilder, EmbedBuilder } from 'discord.js';
import { getUserByDiscordId, isReplayCodeUsed, markReplayCodeUsed } from '../db.js';
import {
  getPendingMatchForPlayer, setMatchResult, addMatchGame, getMatchGames,
  eliminatePlayer, getActiveRound, getMatchesForRound, completeRound,
  createRound, createMatch, getTournament, updateTournamentStatus,
  getPendingChallengeForUser, addChallengeGame, getChallengeGames, updateChallengeStatus,
} from '../lib/tournament-db.js';
import { fetchReplay } from '../lib/replay-fetcher.js';
import { validateMatchReplay } from '../lib/replay-validator.js';
import { tryAdvanceBracket } from '../lib/bracket-engine.js';

export const data = new SlashCommandBuilder()
  .setName('result')
  .setDescription('Submit match result with replay code(s)')
  .addStringOption(opt => opt.setName('code1').setDescription('Replay code').setRequired(true))
  .addStringOption(opt => opt.setName('code2').setDescription('Second replay code (for Bo3+)'))
  .addStringOption(opt => opt.setName('code3').setDescription('Third replay code (for Bo3+)'))
  .addStringOption(opt => opt.setName('code4').setDescription('Fourth replay code (for Bo5+)'))
  .addStringOption(opt => opt.setName('code5').setDescription('Fifth replay code (for Bo5+)'));

const CODE_RE = /^[a-zA-Z0-9@+]{5}-[a-zA-Z0-9@+]{5}$/;

export async function execute(interaction) {
  const user = getUserByDiscordId(interaction.user.id);
  if (!user?.verified) {
    return interaction.reply({ content: 'You must verify your account first. Use `/verify start`.', ephemeral: true });
  }

  // Collect all submitted codes
  const codes = [];
  for (const key of ['code1', 'code2', 'code3', 'code4', 'code5']) {
    const val = interaction.options.getString(key);
    if (val) {
      const trimmed = val.trim();
      if (!CODE_RE.test(trimmed)) {
        return interaction.reply({ content: `Invalid code format: ${trimmed}. Expected: XXXXX-XXXXX`, ephemeral: true });
      }
      codes.push(trimmed);
    }
  }

  // Check for duplicates in submission
  const codeSet = new Set(codes);
  if (codeSet.size !== codes.length) {
    return interaction.reply({ content: 'Duplicate replay codes in submission.', ephemeral: true });
  }

  // Check none are already used
  for (const code of codes) {
    if (isReplayCodeUsed(code)) {
      return interaction.reply({ content: `Replay code ${code} has already been used in another match.`, ephemeral: true });
    }
  }

  // Find the player's active match (tournament or challenge)
  const match = getPendingMatchForPlayer(user.id);
  const challenge = !match ? getPendingChallengeForUser(user.id) : null;

  if (!match && !challenge) {
    return interaction.reply({ content: "You don't have any active matches to submit results for.", ephemeral: true });
  }

  await interaction.deferReply();

  if (match) {
    await handleTournamentResult(interaction, user, match, codes);
  } else {
    await handleChallengeResult(interaction, user, challenge, codes);
  }
}

async function handleTournamentResult(interaction, user, match, codes) {
  const rules = JSON.parse(match.rules_json);
  const bestOf = match.best_of || 1;
  const neededWins = Math.ceil(bestOf / 2);

  // Fetch and validate each replay
  const results = [];
  for (const code of codes) {
    let replay;
    try {
      replay = await fetchReplay(code);
    } catch (e) {
      return interaction.editReply(`Failed to fetch replay ${code}: ${e.code === 'NOT_FOUND' ? 'not found' : e.message}`);
    }

    const validation = validateMatchReplay(replay, {
      player1Name: match.p1_name,
      player2Name: match.p2_name,
      timeControl: rules.time_control,
      randomizerCount: rules.randomizer_count,
      assignedAfter: null, // Could use round start time
    });

    if (!validation.valid) {
      return interaction.editReply(`Replay ${code} rejected: ${validation.error}`);
    }

    results.push({ code, winnerName: validation.winnerName, replay: JSON.stringify(replay) });
  }

  // Record games and tally
  const wins = {};
  for (const r of results) {
    addMatchGame(match.id, r.code, r.winnerName === match.p1_name ? match.player1_id : match.player2_id, r.replay);
    markReplayCodeUsed(r.code, `tournament_match_${match.id}`);
    wins[r.winnerName] = (wins[r.winnerName] || 0) + 1;
  }

  // Check if series is decided
  const allGames = getMatchGames(match.id);
  const totalWins = {};
  for (const g of allGames) {
    const name = g.winner_id === match.player1_id ? match.p1_name : match.p2_name;
    totalWins[name] = (totalWins[name] || 0) + 1;
  }

  const p1Wins = totalWins[match.p1_name] || 0;
  const p2Wins = totalWins[match.p2_name] || 0;

  let seriesWinner = null;
  let seriesWinnerId = null;
  let seriesLoserId = null;
  if (p1Wins >= neededWins) {
    seriesWinner = match.p1_name;
    seriesWinnerId = match.player1_id;
    seriesLoserId = match.player2_id;
  } else if (p2Wins >= neededWins) {
    seriesWinner = match.p2_name;
    seriesWinnerId = match.player2_id;
    seriesLoserId = match.player1_id;
  }

  if (seriesWinner) {
    setMatchResult(match.id, seriesWinnerId, 'completed');
    eliminatePlayer(match.tournament_id, seriesLoserId);

    const embed = new EmbedBuilder()
      .setColor(0x00b894)
      .setTitle(`${match.tournament_name} — Match Result`)
      .setDescription(`**${seriesWinner}** wins! (${p1Wins}-${p2Wins})`)
      .addFields(
        { name: 'Match', value: `${match.p1_name} vs ${match.p2_name}` },
        { name: 'Replays', value: allGames.map(g => g.replay_code).join(', ') },
      );

    await interaction.editReply({ embeds: [embed] });

    // Notify opponent
    const opponentDiscordId = user.id === match.player1_id ? match.p2_discord_id : match.p1_discord_id;
    try {
      const opponent = await interaction.client.users.fetch(opponentDiscordId);
      await opponent.send(
        `Match result submitted for **${match.tournament_name}**: **${seriesWinner}** wins (${p1Wins}-${p2Wins}). ` +
        `Dispute within 24 hours with \`/dispute\` if incorrect.`
      ).catch(() => {});
    } catch { /* DMs may be closed */ }

    // Check if round is complete → advance bracket
    await tryAdvanceBracket(interaction.client, match.tournament_id);
  } else {
    // Series not yet decided
    await interaction.editReply(
      `Game recorded! Series: **${match.p1_name}** ${p1Wins} - ${p2Wins} **${match.p2_name}** ` +
      `(need ${neededWins} wins). Submit more replay codes to continue.`
    );
  }
}

async function handleChallengeResult(interaction, user, challenge, codes) {
  const rules = challenge.rules_json ? JSON.parse(challenge.rules_json) : {};
  const bestOf = challenge.best_of || 3;
  const neededWins = Math.ceil(bestOf / 2);

  for (const code of codes) {
    let replay;
    try {
      replay = await fetchReplay(code);
    } catch (e) {
      return interaction.editReply(`Failed to fetch replay ${code}: ${e.code === 'NOT_FOUND' ? 'not found' : e.message}`);
    }

    const validation = validateMatchReplay(replay, {
      player1Name: challenge.challenger_name,
      player2Name: challenge.challenged_name,
      timeControl: rules.time_control ?? null,
      randomizerCount: rules.randomizer_count ?? null,
    });

    if (!validation.valid) {
      return interaction.editReply(`Replay ${code} rejected: ${validation.error}`);
    }

    const winnerId = validation.winnerName?.toLowerCase() === challenge.challenger_name?.toLowerCase()
      ? challenge.challenger_id : challenge.challenged_id;
    addChallengeGame(challenge.id, code, winnerId);
    markReplayCodeUsed(code, `challenge_${challenge.id}`);
  }

  // Tally
  const allGames = getChallengeGames(challenge.id);
  const wins = { [challenge.challenger_id]: 0, [challenge.challenged_id]: 0 };
  for (const g of allGames) {
    wins[g.winner_id] = (wins[g.winner_id] || 0) + 1;
  }

  const challengerWins = wins[challenge.challenger_id];
  const challengedWins = wins[challenge.challenged_id];

  if (challengerWins >= neededWins || challengedWins >= neededWins) {
    const winnerName = challengerWins >= neededWins ? challenge.challenger_name : challenge.challenged_name;
    updateChallengeStatus(challenge.id, 'completed');

    const embed = new EmbedBuilder()
      .setColor(0x00b894)
      .setTitle('Challenge Complete')
      .setDescription(`**${winnerName}** wins! (${challengerWins}-${challengedWins})`)
      .addFields(
        { name: 'Match', value: `${challenge.challenger_name} vs ${challenge.challenged_name}` },
      );

    return interaction.editReply({ embeds: [embed] });
  }

  await interaction.editReply(
    `Game recorded! Series: **${challenge.challenger_name}** ${challengerWins} - ${challengedWins} **${challenge.challenged_name}** ` +
    `(need ${neededWins} wins).`
  );
}

// tryAdvanceBracket lives in lib/bracket-engine.js (imported at top)
```

- [ ] **Step 2: Commit**

```bash
git add bot/commands/result.js
git commit -m "feat(bot): add /result command with replay validation and bracket advancement"
```

---

## Task 5: /challenge Command

**Files:**
- Create: `bot/commands/challenge.js`

- [ ] **Step 1: Create challenge command**

```javascript
// bot/commands/challenge.js
import { SlashCommandBuilder, EmbedBuilder, ActionRowBuilder, ButtonBuilder, ButtonStyle } from 'discord.js';
import { getUserByDiscordId } from '../db.js';
import { createChallenge, updateChallengeStatus, getPendingChallengeForUser } from '../lib/tournament-db.js';

export const data = new SlashCommandBuilder()
  .setName('challenge')
  .setDescription('Challenge another player to a show match')
  .addUserOption(opt => opt.setName('opponent').setDescription('Who to challenge').setRequired(true))
  .addIntegerOption(opt => opt.setName('best_of').setDescription('Best of N (default: 3)'))
  .addIntegerOption(opt => opt.setName('time').setDescription('Time control in seconds'))
  .addIntegerOption(opt => opt.setName('units').setDescription('Random unit count'));

export async function execute(interaction) {
  const user = getUserByDiscordId(interaction.user.id);
  if (!user?.verified) {
    return interaction.reply({ content: 'You must verify your account first.', ephemeral: true });
  }

  const opponentDiscord = interaction.options.getUser('opponent');
  if (opponentDiscord.id === interaction.user.id) {
    return interaction.reply({ content: "You can't challenge yourself.", ephemeral: true });
  }

  const opponent = getUserByDiscordId(opponentDiscord.id);
  if (!opponent?.verified) {
    return interaction.reply({ content: `${opponentDiscord.username} hasn't verified their Prismata account.`, ephemeral: true });
  }

  // Check for existing pending challenges
  const existingChallenge = getPendingChallengeForUser(user.id);
  if (existingChallenge) {
    return interaction.reply({ content: 'You already have an active challenge. Complete or cancel it first.', ephemeral: true });
  }

  const bestOf = interaction.options.getInteger('best_of') ?? 3;
  const timeControl = interaction.options.getInteger('time') ?? null;
  const units = interaction.options.getInteger('units') ?? null;

  const rules = {};
  if (timeControl) rules.time_control = timeControl;
  if (units) rules.randomizer_count = units;

  const challenge = createChallenge(user.id, opponent.id, bestOf, JSON.stringify(rules));

  const embed = new EmbedBuilder()
    .setColor(0xe17055)
    .setTitle('Challenge Issued!')
    .setDescription(`**${user.prismata_username}** challenges **${opponent.prismata_username}** to a Bo${bestOf}!`)
    .addFields(
      { name: 'Settings', value: [
        timeControl ? `${timeControl}s` : 'Any time',
        units ? `Base +${units}` : 'Any units',
      ].join(' · '), inline: true },
    );

  const row = new ActionRowBuilder().addComponents(
    new ButtonBuilder().setCustomId(`challenge_accept_${challenge.id}`).setLabel('Accept').setStyle(ButtonStyle.Success),
    new ButtonBuilder().setCustomId(`challenge_decline_${challenge.id}`).setLabel('Decline').setStyle(ButtonStyle.Danger),
  );

  await interaction.reply({ embeds: [embed], components: [row] });
}

// Button interaction handler — call this from index.js
export async function handleChallengeButton(interaction) {
  const [, action, challengeIdStr] = interaction.customId.split('_');
  const challengeId = parseInt(challengeIdStr, 10);

  const user = getUserByDiscordId(interaction.user.id);
  if (!user) return interaction.reply({ content: 'Not registered.', ephemeral: true });

  const { getChallenge } = await import('../lib/tournament-db.js');
  const challenge = getChallenge(challengeId);
  if (!challenge) return interaction.reply({ content: 'Challenge not found.', ephemeral: true });

  if (challenge.challenged_id !== user.id) {
    return interaction.reply({ content: "This challenge isn't for you.", ephemeral: true });
  }

  if (challenge.status !== 'pending') {
    return interaction.reply({ content: 'This challenge has already been responded to.', ephemeral: true });
  }

  if (action === 'accept') {
    updateChallengeStatus(challengeId, 'in_progress');
    await interaction.update({
      content: `Challenge accepted! Submit results with \`/result <replay-code>\``,
      embeds: interaction.message.embeds,
      components: [],
    });
  } else {
    updateChallengeStatus(challengeId, 'declined');
    await interaction.update({
      content: 'Challenge declined.',
      embeds: [],
      components: [],
    });
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add bot/commands/challenge.js
git commit -m "feat(bot): add /challenge command with accept/decline buttons"
```

---

## Task 6: /dispute Command

**Files:**
- Create: `bot/commands/dispute.js`

- [ ] **Step 1: Create dispute command**

```javascript
// bot/commands/dispute.js
import { SlashCommandBuilder, EmbedBuilder } from 'discord.js';
import { getUserByDiscordId } from '../db.js';
import { createDispute, getPendingMatchForPlayer } from '../lib/tournament-db.js';

export const data = new SlashCommandBuilder()
  .setName('dispute')
  .setDescription('Dispute a recent match result')
  .addStringOption(opt => opt.setName('reason').setDescription('Reason for dispute'));

export async function execute(interaction) {
  const user = getUserByDiscordId(interaction.user.id);
  if (!user) return interaction.reply({ content: 'Not registered.', ephemeral: true });

  const reason = interaction.options.getString('reason') || 'No reason provided';

  // Find the most recent completed match for this player
  const { getDb } = await import('../db.js');
  const db = getDb();

  const recentMatch = db.prepare(
    `SELECT tm.*, t.name as tournament_name
     FROM tournament_matches tm
     JOIN tournaments t ON tm.tournament_id = t.id
     WHERE (tm.player1_id = ? OR tm.player2_id = ?) AND tm.status = 'completed'
     ORDER BY tm.id DESC LIMIT 1`
  ).get(user.id, user.id);

  if (!recentMatch) {
    return interaction.reply({ content: 'No recent completed match found to dispute.', ephemeral: true });
  }

  // Check if already disputed
  const existingDispute = db.prepare(
    "SELECT 1 FROM disputes WHERE match_id = ? AND status = 'open'"
  ).get(recentMatch.id);

  if (existingDispute) {
    return interaction.reply({ content: 'This match already has an open dispute.', ephemeral: true });
  }

  createDispute(recentMatch.id, null, user.id, reason);

  const embed = new EmbedBuilder()
    .setColor(0xe74c3c)
    .setTitle('Match Disputed')
    .setDescription(`A dispute has been filed for a match in **${recentMatch.tournament_name}**.`)
    .addFields(
      { name: 'Reason', value: reason },
    )
    .setFooter({ text: 'An organizer will review this dispute.' });

  return interaction.reply({ embeds: [embed] });
}
```

- [ ] **Step 2: Commit**

```bash
git add bot/commands/dispute.js
git commit -m "feat(bot): add /dispute command for contesting match results"
```

---

## Task 7: /standings and /bracket Commands

**Files:**
- Create: `bot/commands/standings.js`
- Create: `bot/commands/bracket.js`

- [ ] **Step 1: Create standings command**

```javascript
// bot/commands/standings.js
import { SlashCommandBuilder, EmbedBuilder } from 'discord.js';
import { getTournamentByName, listTournaments, getTournamentPlayers, getMatchesByTournament } from '../lib/tournament-db.js';

export const data = new SlashCommandBuilder()
  .setName('standings')
  .setDescription('View tournament standings')
  .addStringOption(opt => opt.setName('name').setDescription('Tournament name'));

export async function execute(interaction) {
  const name = interaction.options.getString('name');

  if (!name) {
    const tournaments = listTournaments();
    if (tournaments.length === 0) return interaction.reply({ content: 'No active tournaments.', ephemeral: true });
    return interaction.reply({
      content: 'Specify a tournament: ' + tournaments.map(t => `\`${t.name}\``).join(', '),
      ephemeral: true,
    });
  }

  const tournament = getTournamentByName(name);
  if (!tournament) return interaction.reply({ content: `Tournament "${name}" not found.`, ephemeral: true });

  const players = getTournamentPlayers(tournament.id);
  const matches = getMatchesByTournament(tournament.id);

  // Calculate W/L for each player
  const stats = {};
  for (const p of players) {
    stats[p.user_id] = { name: p.prismata_username, wins: 0, losses: 0, status: p.status };
  }

  for (const m of matches) {
    if (m.status !== 'completed' || !m.winner_id) continue;
    if (stats[m.winner_id]) stats[m.winner_id].wins++;
    const loserId = m.winner_id === m.player1_id ? m.player2_id : m.player1_id;
    if (loserId && stats[loserId]) stats[loserId].losses++;
  }

  const sorted = Object.values(stats).sort((a, b) => {
    if (a.status === 'eliminated' && b.status !== 'eliminated') return 1;
    if (b.status === 'eliminated' && a.status !== 'eliminated') return -1;
    return b.wins - a.wins;
  });

  const lines = sorted.map((s, i) => {
    const status = s.status === 'eliminated' ? '❌' : '✅';
    return `${status} **${s.name}** — ${s.wins}W / ${s.losses}L`;
  });

  const embed = new EmbedBuilder()
    .setColor(0x3498db)
    .setTitle(`${tournament.name} — Standings`)
    .setDescription(lines.join('\n') || 'No data yet');

  return interaction.reply({ embeds: [embed] });
}
```

- [ ] **Step 2: Create bracket command**

```javascript
// bot/commands/bracket.js
import { SlashCommandBuilder, EmbedBuilder } from 'discord.js';
import { getTournamentByName, getMatchesByTournament } from '../lib/tournament-db.js';

export const data = new SlashCommandBuilder()
  .setName('bracket')
  .setDescription('View tournament bracket')
  .addStringOption(opt => opt.setName('name').setDescription('Tournament name').setRequired(true));

export async function execute(interaction) {
  const name = interaction.options.getString('name');
  const tournament = getTournamentByName(name);
  if (!tournament) return interaction.reply({ content: `Tournament "${name}" not found.`, ephemeral: true });

  const matches = getMatchesByTournament(tournament.id);
  if (matches.length === 0) {
    return interaction.reply({ content: 'No matches yet — tournament may not have started.', ephemeral: true });
  }

  // Group by round
  const rounds = {};
  for (const m of matches) {
    const rn = m.round_number;
    if (!rounds[rn]) rounds[rn] = [];
    rounds[rn].push(m);
  }

  const embed = new EmbedBuilder()
    .setColor(0x3498db)
    .setTitle(`${tournament.name} — Bracket`);

  for (const [roundNum, roundMatches] of Object.entries(rounds)) {
    const lines = roundMatches.map(m => {
      const p2 = m.p2_name || 'bye';
      const icon = m.status === 'completed' ? '✅' : m.status === 'forfeited' ? '❌' : '⏳';
      const winner = m.winner_name ? ` → **${m.winner_name}**` : '';
      return `${icon} ${m.p1_name} vs ${p2}${winner}`;
    });
    embed.addFields({ name: `Round ${roundNum}`, value: lines.join('\n') });
  }

  return interaction.reply({ embeds: [embed] });
}
```

- [ ] **Step 3: Commit**

```bash
git add bot/commands/standings.js bot/commands/bracket.js
git commit -m "feat(bot): add /standings and /bracket commands"
```

---

## Task 8: Scheduler (Reminders, Forfeits)

**Files:**
- Create: `bot/lib/scheduler.js`

- [ ] **Step 1: Create scheduler**

```javascript
// bot/lib/scheduler.js
import { getOverdueMatches, getMatchesNeedingReminder, setMatchResult, eliminatePlayer } from './tournament-db.js';
import { markReplayCodeUsed } from '../db.js';
import { tryAdvanceBracket } from './bracket-engine.js';

const CHECK_INTERVAL_MS = 60_000; // 1 minute
const REMINDED = new Map(); // matchId -> Set of thresholds already reminded

/**
 * Start the background scheduler.
 * @param {import('discord.js').Client} client - Discord client for sending DMs
 */
export function startScheduler(client) {
  console.log('Starting tournament scheduler (60s interval)');
  setInterval(() => runSchedulerTick(client), CHECK_INTERVAL_MS);
}

async function runSchedulerTick(client) {
  const now = new Date().toISOString();

  // 1. Handle overdue matches (forfeit)
  const overdue = getOverdueMatches(now);
  for (const match of overdue) {
    // Check if any games submitted
    const { getMatchGames } = await import('./tournament-db.js');
    const games = getMatchGames(match.id);

    if (games.length > 0) {
      // Games were submitted — tally wins
      const wins = { [match.player1_id]: 0, [match.player2_id]: 0 };
      for (const g of games) {
        if (g.winner_id) wins[g.winner_id]++;
      }

      if (wins[match.player1_id] !== wins[match.player2_id]) {
        // Clear winner — accept result
        const winnerId = wins[match.player1_id] > wins[match.player2_id] ? match.player1_id : match.player2_id;
        const loserId = winnerId === match.player1_id ? match.player2_id : match.player1_id;
        setMatchResult(match.id, winnerId, 'completed');
        eliminatePlayer(match.tournament_id, loserId);
      } else {
        // Tied series (e.g., 1-1 in Bo3) — flag for organizer review, don't auto-advance
        const { createDispute } = await import('./tournament-db.js');
        createDispute(match.id, null, null, 'Deadline expired with tied series. Organizer must resolve.');
      }
    } else {
      // No games — both forfeit
      setMatchResult(match.id, null, 'forfeited');
      eliminatePlayer(match.tournament_id, match.player1_id);
      eliminatePlayer(match.tournament_id, match.player2_id);
    }

    // DM players
    try {
      const p1 = await client.users.fetch(match.p1_discord_id);
      await p1.send(`Your match in **${match.tournament_name}** (${match.p1_name} vs ${match.p2_name}) has been resolved due to deadline. ${games.length > 0 ? 'Result accepted from submitted replays.' : 'Both players forfeited (no replays submitted).'}`).catch(() => {});
      const p2 = await client.users.fetch(match.p2_discord_id);
      await p2.send(`Your match in **${match.tournament_name}** (${match.p1_name} vs ${match.p2_name}) has been resolved due to deadline. ${games.length > 0 ? 'Result accepted from submitted replays.' : 'Both players forfeited (no replays submitted).'}`).catch(() => {});
    } catch { /* DMs closed */ }

    // Try to advance bracket
    await tryAdvanceBracket(client, match.tournament_id);
  }

  // 2. Send reminders at 50%, 75%, 90% of deadline
  const pending = getMatchesNeedingReminder(now);
  for (const match of pending) {
    if (!match.deadline) continue;

    const roundStart = match.round_deadline
      ? new Date(new Date(match.round_deadline).getTime() - 48 * 60 * 60 * 1000) // approximate round start
      : new Date(match.deadline).getTime() - 48 * 60 * 60 * 1000;

    const deadlineTime = new Date(match.deadline).getTime();
    const nowTime = Date.now();
    const total = deadlineTime - new Date(roundStart).getTime();
    const elapsed = nowTime - new Date(roundStart).getTime();
    const percent = elapsed / total;

    if (!REMINDED.has(match.id)) REMINDED.set(match.id, new Set());
    const sent = REMINDED.get(match.id);

    const thresholds = [
      { pct: 0.50, msg: "Don't forget!" },
      { pct: 0.75, msg: 'Please play soon.' },
      { pct: 0.90, msg: 'Match will be forfeited if not played!' },
    ];

    for (const { pct, msg } of thresholds) {
      if (percent >= pct && !sent.has(pct)) {
        sent.add(pct);
        const timeLeft = `<t:${Math.floor(deadlineTime / 1000)}:R>`;
        const dmContent = `Your match in **${match.tournament_name}** (${match.p1_name} vs ${match.p2_name}) is due ${timeLeft}. ${msg}`;
        try {
          const p1 = await client.users.fetch(match.p1_discord_id);
          await p1.send(dmContent).catch(() => {});
          const p2 = await client.users.fetch(match.p2_discord_id);
          await p2.send(dmContent).catch(() => {});
        } catch { /* DMs closed */ }
      }
    }
  }

  // Clean up REMINDED for completed matches
  for (const [matchId] of REMINDED) {
    const { getMatch } = await import('./tournament-db.js');
    const match = getMatch(matchId);
    if (!match || match.status === 'completed' || match.status === 'forfeited') {
      REMINDED.delete(matchId);
    }
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add bot/lib/scheduler.js
git commit -m "feat(bot): add tournament scheduler for reminders and forfeits"
```

---

## Task 9: Update deploy-commands.js and index.js

**Files:**
- Modify: `bot/deploy-commands.js`
- Modify: `bot/index.js`

- [ ] **Step 1: Update deploy-commands.js with all new commands**

Replace the `commands` array in `bot/deploy-commands.js` to include all new commands. The file must import the `data` export from each command file and use `.toJSON()` on each.

```javascript
// bot/deploy-commands.js
import { REST, Routes } from 'discord.js';
import { config } from './config.js';

// Import command definitions
import { data as verifyData } from './commands/verify.js';
import { data as profileData } from './commands/profile.js';
import { data as tournamentData } from './commands/tournament.js';
import { data as resultData } from './commands/result.js';
import { data as challengeData } from './commands/challenge.js';
import { data as disputeData } from './commands/dispute.js';
import { data as standingsData } from './commands/standings.js';
import { data as bracketData } from './commands/bracket.js';

const commands = [
  verifyData, profileData, tournamentData, resultData,
  challengeData, disputeData, standingsData, bracketData,
].map(c => c.toJSON());

const rest = new REST().setToken(config.discordToken);

try {
  console.log(`Registering ${commands.length} commands...`);

  if (config.guildId) {
    await rest.put(
      Routes.applicationGuildCommands(config.clientId, config.guildId),
      { body: commands },
    );
    console.log(`Registered to guild ${config.guildId}`);
  } else {
    await rest.put(
      Routes.applicationCommands(config.clientId),
      { body: commands },
    );
    console.log('Registered globally');
  }
} catch (error) {
  console.error('Failed to register commands:', error);
  process.exit(1);
}
```

- [ ] **Step 2: Update index.js to load new commands and wire scheduler + buttons**

In `bot/index.js`, update the `loadCommands` function and add button handling + scheduler:

```javascript
// bot/index.js
import { Client, GatewayIntentBits, Events, Collection } from 'discord.js';
import { config } from './config.js';
import { getDb, closeDb } from './db.js';
import { handleReplayEmbed } from './handlers/replay-embed.js';
import { handleUnitEmbed } from './handlers/unit-embed.js';
import { startMonitoring } from './lib/monitor.js';
import { startScheduler } from './lib/scheduler.js';

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.GuildPresences,
    GatewayIntentBits.MessageContent,
    GatewayIntentBits.DirectMessages,
  ],
});

client.commands = new Collection();

async function loadCommands() {
  const commandFiles = ['verify', 'profile', 'tournament', 'result', 'challenge', 'dispute', 'standings', 'bracket'];
  for (const name of commandFiles) {
    try {
      const mod = await import(`./commands/${name}.js`);
      client.commands.set(mod.data.name, mod);
    } catch (e) {
      console.error(`Failed to load command ${name}:`, e.message);
    }
  }
}

client.once(Events.ClientReady, (c) => {
  console.log(`Giselle v2 ready as ${c.user.tag}`);
  getDb();
  startMonitoring();
  startScheduler(client);
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
  } else if (interaction.isButton()) {
    // Handle challenge accept/decline buttons
    if (interaction.customId.startsWith('challenge_')) {
      try {
        const { handleChallengeButton } = await import('./commands/challenge.js');
        await handleChallengeButton(interaction);
      } catch (error) {
        console.error('Error handling button:', error);
        await interaction.reply({ content: 'Something went wrong.', ephemeral: true }).catch(() => {});
      }
    }
  }
});

client.on(Events.MessageCreate, async (message) => {
  if (message.author.bot || message.system) return;
  await handleReplayEmbed(message).catch(e => console.error('Replay embed error:', e));
  await handleUnitEmbed(message).catch(e => console.error('Unit embed error:', e));
});

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

await loadCommands();
client.login(config.discordToken);
```

- [ ] **Step 3: Run all tests**

Run: `cd <PRISMATA_LADDER_REPO>/bot && npm test`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add bot/deploy-commands.js bot/index.js
git commit -m "feat(bot): wire all tournament commands, scheduler, and button handlers into bot"
```

---

## Task 10: Integration Test — Full Tournament Flow

This is a manual verification test. No code to write.

- [ ] **Step 1: Run all unit tests**

Run: `cd <PRISMATA_LADDER_REPO>/bot && npm test`
Expected: All tests pass

- [ ] **Step 2: Verify command registration (requires real token)**

```bash
cd <PRISMATA_LADDER_REPO>/bot
node deploy-commands.js
```
Expected: "Registered 8 commands to guild XXXXX"

- [ ] **Step 3: Start bot and test tournament flow in Discord**

```bash
node index.js
```

Test sequence:
1. `/tournament create name:Test Cup time:45 units:8` — should create tournament
2. `/tournament join name:Test Cup` — join as first player (need 2+ verified users)
3. `/tournament status name:Test Cup` — should show registered players
4. `/tournament start name:Test Cup` — should generate bracket, DM players
5. `/result <replay-code>` — should validate and record result
6. `/standings name:Test Cup` — should show W/L
7. `/bracket name:Test Cup` — should show bracket with results
8. `/challenge @user bo3` — should issue challenge with accept/decline buttons

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat(bot): tournament engine complete — ready for Python integration (Plan 2B)"
```

---

## Summary

After completing Plan 2, you have:

- **Tournament lifecycle** — create, join, start, cancel via `/tournament`
- **Single elimination brackets** — auto-generated, with byes for non-power-of-2 player counts
- **Result submission** — `/result` validates replays against tournament rules, records games, tallies series
- **Bracket advancement** — auto-advances winners, generates next round, DMs players
- **Show matches** — `/challenge` with accept/decline buttons, same result submission flow
- **Disputes** — `/dispute` flags matches for organizer review
- **Standings & bracket** — `/standings` and `/bracket` show tournament state
- **Scheduler** — 60s background loop handles reminders (50%/75%/90%) and forfeit enforcement
- **8 slash commands** registered (up from 2 in Plan 1)

**Deferred to Plan 2B:** Auto-spectating (Python), whisper verification (Python), export pipeline
**Next:** Plan 3 — Website extensions (Discord OAuth, tournament pages)
