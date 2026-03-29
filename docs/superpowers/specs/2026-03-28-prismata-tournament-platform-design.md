# Prismata Tournament Platform — Design Specification

**Date:** 2026-03-28
**Status:** Draft
**Author:** Surfinite + Claude

## Overview

A tournament and competitive play platform for Prismata, extending the existing prismata.live infrastructure. Players sign up via Discord OAuth, verify their Prismata account through an in-game challenge, and compete in automated tournaments and show matches. Results are verified through tamper-proof replay codes from Prismata's servers.

### Goals

- Website handles 99% of tournament orchestration — signups, brackets, scheduling, results, archival
- Discord bot automates all organizer tasks except dispute resolution
- Zero trust required — no stored credentials, no local agents, no downloads
- Replay codes as the single source of truth for match results
- Extend existing prismata.live infrastructure, not replace it

### Non-Goals

- Automated game launching (shelved — requires stored credentials or local agent)
- Replacing the existing ladder/ELO tracking (passive spectator-based tracking continues as-is)
- Open tournament creation (built in but off by default)

## Architecture

### Infrastructure (extending existing split architecture)

| Component | Current | Added |
|-----------|---------|-------|
| **Data Box** (t4g.micro, ~$6/mo) | 6 spectator bots, SQLite DB, WebSocket broadcast, JSON exports | Tournament engine, replay validator, Discord bot (Giselle v2) |
| **Site Box** (t3.micro spot, ~$2.30/mo) | Next.js frontend (prismata.live), nginx, SSL | Tournament pages, Discord OAuth flow, match/replay archive |
| **S3** | Replays (saved-games-alpha), backups, data exports | No changes |

The Discord bot runs on the Data Box for direct SQLite access — no API layer needed between bot and tournament engine. If memory pressure becomes an issue, upgrade path is t4g.small (2GB RAM, ~$12/mo).

### Data Flow

```
Player submits replay code
  → Discord Bot (/result command) or Website (form)
  → Data Box fetches replay from S3 (saved-games-alpha.s3-website-us-east-1.amazonaws.com/{code}.json.gz)
  → Validates: correct players, correct settings, recent timestamp
  → Extracts winner from replay result field
  → Records result in SQLite, advances bracket
  → Notifies opponent via Discord DM (24hr dispute window)
  → After window: auto-confirms result
  → Export scripts generate JSON → Site Box serves updated standings
```

### Monitoring

- Data Box resource check every 5 minutes (CPU, memory, disk)
- Alert to `#prismata-ops` Discord channel (via webhook) if memory > 80% or disk > 90%
- Existing health monitor extended to check tournament engine + bot process health

## User Identity & Account Binding

### Discord OAuth

- Player clicks "Login with Discord" on prismata.live
- Standard OAuth2 flow returns Discord user ID, username, avatar
- Session stored server-side (cookie-based)

### Prismata Account Verification

After Discord login, the player verifies ownership of their Prismata account. Two methods are available — both will be built, and the preferred method chosen based on which works best in practice.

#### Method A: Whisper Code (In-Game Bot)

1. Player adds a designated bot account ("PrismataLiveBot" or "SignupBot") as a friend in Prismata
2. Site generates a 6-digit verification code and displays it to the player
3. Player whispers the code to the bot account in Prismata's chat
4. `<SPECTATOR_SERVICE>` (already connected with 6 bot accounts) listens for the whisper, matches the code to the pending verification, and confirms

**Pros:** Minimal friction — just type a 6-digit code. No game creation needed.
**Cons:** Requires a bot account to be online and listening. Depends on Prismata's whisper/friend system continuing to work.

#### Method B: Challenge Replay

1. Site generates a challenge with three random parameters:
   - A specific bot opponent (e.g., "Fearless Bot")
   - A specific time control (random number 1-999, e.g., 347 seconds)
   - A specific randomizer unit count (e.g., Base +6)
2. Player creates a custom game in Prismata with these exact settings
3. Player can resign immediately — no turns need to be played
4. Player submits the replay code on the website or via `/verify XXXXX-XXXXX` in Discord

Verification checks against the replay JSON:
- One of `playerInfo[0].displayName` or `playerInfo[1].displayName` matches claimed Prismata username
- The other player's `bot` field matches the specified bot type (e.g., "MediumAI" for Adept Bot)
- `timeInfo.playerTime[0].initial` matches the challenge time control value (this is the initial time setting, stable regardless of turns played)
- `deckInfo.randomizer[0].length` matches the required randomizer count (note: `randomizer` is a 2D array `[[...cards...], [...cards...]]`, one per player; both are always identical)
- `startTime` is recent (within 1 hour)
- `format` = 201 (custom/bot game; ranked = 200)
- Replay code has not been used in a previous verification or match (deduplication check)

**Pros:** Fully independent — no bot account needed online. Tamper-proof via Prismata's servers.
**Cons:** More steps for the user (configure 3 settings, create game, resign, submit code).

Binding is permanent once verified (Discord ID to Prismata username).

### Roles

- **Player** — default after verification. Can join tournaments, submit results, issue challenges.
- **Organizer** — can create/manage tournaments, resolve disputes. Granted by admin.
- **Admin** — full access including infrastructure. Initially just Surfinite.

## Tournament System

### Tournament Creation (by Organizer or Admin)

- **Name** and description
- **Format**: Swiss, Round Robin, Single Elimination, Double Elimination, or combination (e.g., Swiss group stage into Single Elimination playoffs)
- **Rules**:
  - Time control (seconds per turn)
  - Randomizer unit count (Base +N)
  - Banned units (optional list)
- **Schedule**:
  - Registration deadline
  - Round deadlines (e.g., "48 hours per round")
  - Tournament start date
- **Capacity**: min/max players, waitlist

### Lifecycle (Fully Bot-Automated)

1. **Registration** — players sign up via `/tournament join <name>` or website. Bot confirms eligibility (verified account required).
2. **Seeding** — when registration closes, bot seeds bracket. Random initially; tournament rating-based later.
3. **Round start** — bot DMs both players: "Your Round N match vs @opponent is ready. Settings: [time control]s, Base +[N]. Deadline: [date]."
4. **Nagging** — bot follows up via DM:
   - At 50% of deadline: friendly reminder
   - At 75% of deadline: firmer reminder
   - At 90% of deadline: forfeit warning
5. **Result submission** — player submits replay code(s) via `/result` or website. Bot validates settings and extracts winner.
6. **Opponent notification** — "Match result submitted: @winner defeated @loser. You have 24 hours to dispute."
7. **Auto-confirmation** — after dispute window with no dispute, result is confirmed.
8. **Bracket advancement** — bot advances winner, generates next round pairings when all matches in the round complete.
9. **Forfeit** — if round deadline passes with no result:
   - Neither player submitted → both forfeit (match was never played)
   - One player submitted valid replays → result is accepted as normal (the game was played, the non-submitter just didn't submit — not a forfeit)
10. **Completion** — bot announces final standings in Discord channel, archives tournament.

### Open Tournament Creation

The system supports open tournament creation (any verified player can create a tournament), but this is disabled by default. Admin can toggle it on when the community is ready.

## Show Matches / Challenges

- Any verified player can `/challenge @player bo3` (or bo1, bo5, bo7)
- Custom rules optional: `/challenge @player bo3 time:45 units:8`
- Defaults to standard settings if not specified
- Challenged player accepts or declines via Discord button
- Same replay submission and validation flow as tournaments
- No ELO/rating impact
- Gets its own page on the website with replay links and series score

## Result Submission & Replay Validation

Two methods are available for recording match results — both will be built, and the preferred method chosen based on which works best in practice.

### Method A: Auto-Spectating (TournamentBot)

A dedicated bot account friends both tournament players and watches for games between them:

1. When a tournament match is assigned, the bot adds both players as friends (if not already)
2. Bot monitors for games between the expected opponents within the round's time window
3. When a game between them is detected, bot spectates and records the result automatically
4. Player types "Confirm" to the bot (or via `/confirm` in Discord) to signal the game is the real tournament match (not a casual friendly)
5. Result auto-recorded — no replay code submission needed

**Pros:** Zero friction for players — just play the game and confirm.
**Cons:** Scales poorly if multiple matches happen simultaneously (limited bot accounts). False positives possible (casual friendlies mistaken for tournament matches). Fails if players have a technical issue and restart.

### Method B: Manual Replay Submission

1. Player submits one or more replay codes:
   - Discord: `/result XXXXX-XXXXX` (single game) or `/result XXXXX-XXXXX YYYYY-YYYYY ZZZZZ-ZZZZZ` (Bo-X series)
   - Website: form on match page
2. System fetches each replay from S3 (`saved-games-alpha.s3-website-us-east-1.amazonaws.com/{code}.json.gz`)
3. Validation checks per replay (**hard reject** if any fail):
   - Both player names in `playerInfo` (check both indices) match the expected match participants
   - `timeInfo.playerTime[0].initial` matches tournament/challenge time control
   - Randomizer count (`deckInfo.randomizer[0].length`) matches rules
   - `format` = 201 (custom game)
   - `startTime` is after the match was assigned (prevents reusing old games)
   - Replay code has not been used in a previous match (deduplication)
4. Extract winner from `result` field (0 = player 1 wins, 1 = player 2 wins). Note: player index in `result` corresponds to `playerInfo` array position, so map player names to indices to determine the winner correctly.
5. For Bo-X series: tally wins across all submitted replays

### Best-of-X Series Handling

Replay codes are treated as an **unordered set**. Submission order does not matter.

- Player submits N replay codes (minimum ceil(X/2) for a Bo-X)
- System validates each independently, tallies wins
- First player to reach majority wins the series
- If second player submits the same set of codes (or subset), auto-confirm
- If second player submits different codes, flag for organizer review
- If only one player submits and opponent doesn't dispute within 24 hours, auto-confirm

### Dispute Flow

- Opponent clicks "Dispute" on website or `/dispute` in Discord within 24-hour window
- Match flagged for organizer review
- Organizer can: view all submitted replays, override result, request a rematch
- Resolution recorded in disputes table

### Edge Cases

- **Wrong replay** (different game): validation catches mismatched players or settings
- **Claiming opponent's loss as a win**: impossible — replay contains objective result
- **Both players submit different code sets**: flagged for organizer review
- **Replay from before match was assigned**: rejected by timestamp check

## Discord Bot (Giselle v2)

### Tech Stack

- discord.js v14+ (rewrite from current v11)
- Node.js
- Slash commands, buttons, modals
- Direct SQLite access (co-located on Data Box)

### Player Commands

| Command | Description |
|---------|-------------|
| `/verify XXXXX-XXXXX` | Submit verification replay code |
| `/tournament list` | Show active/upcoming tournaments |
| `/tournament join <name>` | Register for a tournament |
| `/tournament status <name>` | Your matches and standings |
| `/challenge @player bo3 [time:45] [units:8]` | Issue a show match challenge |
| `/result XXXXX-XXXXX [...]` | Submit replay code(s) for a match |
| `/dispute` | Dispute most recent match result |
| `/standings [tournament]` | Current standings |
| `/bracket [tournament]` | Current bracket |
| `/profile [@player]` | Player stats, tournament rating, match history |

### Organizer Commands

| Command | Description |
|---------|-------------|
| `/tournament create` | Opens modal: name, format, rules, schedule |
| `/tournament start <name>` | Close registration, seed bracket, begin |
| `/tournament cancel <name>` | Cancel a tournament |
| `/tournament forfeit <name> @player` | Manual forfeit |
| `/tournament resolve <name> <match>` | Resolve a dispute |

### Automated Behaviors

- **Match ready**: DM both players with opponent, settings, deadline
- **50% reminder**: "Your match vs @opponent is due in [time]. Don't forget!"
- **75% reminder**: "Your match vs @opponent is due in [time]. Please play soon."
- **90% warning**: "Your match vs @opponent is due in [time]. Match will be forfeited if not played."
- **Result notification**: "Match result submitted: @winner defeated @loser. Dispute within 24 hours if incorrect."
- **Tournament completion**: Announcement in designated channel with final standings
- **Online detection**: If both players in a pending match are online in Discord, suggest they play

### Legacy Features (Preserved)

- Replay code detection in chat messages → rich embed with player names, ratings, deck, result
- `[[Unit Name]]` syntax → unit info embed with stats and image

## Website (prismata.live Extensions)

### New Pages

**Auth:**
- `/login` — Discord OAuth entry point
- `/verify` — account verification challenge page (displays bot, time control, randomizer count to use)
- `/profile/[username]` — player profile: tournament rating, match history, verified Prismata name

**Tournaments:**
- `/tournaments` — list of active, upcoming, and past tournaments
- `/tournament/[id]` — detail page: bracket/standings, schedule, rules, match history
- `/tournament/[id]/match/[id]` — individual match: replays, result, dispute button

**Show Matches:**
- `/matches` — recent and upcoming show matches/challenges
- `/match/[id]` — match detail with replay links and series score

**Result Submission:**
- Replay code input form on match pages (alternative to Discord bot)

### Existing Pages (Unchanged)

- Ladder/ELO tracking (passive, from spectator bots)
- Live spectating
- Player stats, unit winrates

### Data Flow

Same JSON export pattern as existing site:
1. Tournament engine writes to SQLite
2. Export scripts generate JSON (extended to include tournament data)
3. JSON uploaded to S3
4. Site Box syncs from S3 every 60 seconds
5. Next.js serves updated pages

No new API server needed initially. If real-time updates become important (e.g., live bracket updates during a tournament), the existing WebSocket infrastructure can be extended.

## Database Schema

Extending the existing SQLite database with new tables.

### Users & Auth

```sql
CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    discord_id TEXT UNIQUE NOT NULL,
    discord_username TEXT NOT NULL,
    prismata_username TEXT UNIQUE,
    verified INTEGER DEFAULT 0,
    role TEXT DEFAULT 'player',  -- player, organizer, admin
    tournament_rating REAL,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE verification_challenges (
    id INTEGER PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    challenge_bot TEXT NOT NULL,         -- e.g. 'MediumAI' (Adept Bot)
    challenge_time_control INTEGER NOT NULL,  -- e.g. 347
    challenge_randomizer_count INTEGER NOT NULL,  -- e.g. 6
    replay_code TEXT,
    status TEXT DEFAULT 'pending',  -- pending, verified, expired
    created_at TEXT DEFAULT (datetime('now'))
);
```

### Tournaments

```sql
CREATE TABLE tournaments (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    format TEXT NOT NULL,  -- swiss, round_robin, single_elim, double_elim, combination
    rules_json TEXT NOT NULL,  -- {"time_control": 45, "randomizer_count": 8, "banned_units": []}
    status TEXT DEFAULT 'registration',  -- registration, active, completed, cancelled
    created_by INTEGER REFERENCES users(id),
    max_players INTEGER,
    registration_deadline TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE tournament_players (
    tournament_id INTEGER REFERENCES tournaments(id),
    user_id INTEGER REFERENCES users(id),
    seed INTEGER,
    status TEXT DEFAULT 'registered',  -- registered, active, eliminated, withdrawn
    PRIMARY KEY (tournament_id, user_id)
);

CREATE TABLE tournament_rounds (
    id INTEGER PRIMARY KEY,
    tournament_id INTEGER REFERENCES tournaments(id),
    round_number INTEGER NOT NULL,
    deadline TEXT,
    status TEXT DEFAULT 'pending'  -- pending, active, completed
);

CREATE TABLE tournament_matches (
    id INTEGER PRIMARY KEY,
    tournament_id INTEGER REFERENCES tournaments(id),
    round_id INTEGER REFERENCES tournament_rounds(id),
    player1_id INTEGER REFERENCES users(id),
    player2_id INTEGER REFERENCES users(id),
    winner_id INTEGER REFERENCES users(id),
    status TEXT DEFAULT 'pending',  -- pending, in_progress, completed, disputed, forfeited
    best_of INTEGER DEFAULT 1,
    deadline TEXT
);

CREATE TABLE match_games (
    id INTEGER PRIMARY KEY,
    match_id INTEGER REFERENCES tournament_matches(id),
    replay_code TEXT NOT NULL,
    game_number INTEGER,
    winner_id INTEGER REFERENCES users(id),
    validated INTEGER DEFAULT 0,
    replay_json TEXT  -- cached replay data
);
```

### Show Matches / Challenges

```sql
CREATE TABLE challenges (
    id INTEGER PRIMARY KEY,
    challenger_id INTEGER REFERENCES users(id),
    challenged_id INTEGER REFERENCES users(id),
    best_of INTEGER DEFAULT 3,
    rules_json TEXT,  -- {"time_control": 45, "randomizer_count": 8}
    status TEXT DEFAULT 'pending',  -- pending, accepted, declined, in_progress, completed
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE challenge_games (
    id INTEGER PRIMARY KEY,
    challenge_id INTEGER REFERENCES challenges(id),
    replay_code TEXT NOT NULL,
    game_number INTEGER,
    winner_id INTEGER REFERENCES users(id),
    validated INTEGER DEFAULT 0
);
```

### Disputes

```sql
CREATE TABLE disputes (
    id INTEGER PRIMARY KEY,
    match_id INTEGER REFERENCES tournament_matches(id),
    challenge_id INTEGER REFERENCES challenges(id),
    raised_by INTEGER REFERENCES users(id),
    reason TEXT,
    resolved_by INTEGER REFERENCES users(id),
    resolution TEXT,
    status TEXT DEFAULT 'open',  -- open, resolved
    created_at TEXT DEFAULT (datetime('now'))
);
```

## Tournament Rating

Separate from the existing passive ladder ELO. Updated only by tournament and show match results. Initial implementation deferred — not blocking MVP.

Rating system TBD (Elo, Glicko-2, or similar). Will be designed when the platform has enough match data to be meaningful.

## Future Considerations (Not In Scope)

- **Automated game launching** — requires stored credentials or local agent. Revisit if a trust-free mechanism is found.
- **Open tournament creation** — toggle exists but disabled by default. Enable when community is ready.
- **Spectator integration** — live spectating of tournament matches via existing WebSocket infrastructure.
- **Replay viewer embedding** — inline replay viewer on match pages (existing prismata.live replay rendering).
- **Mobile-friendly** — responsive design for tournament pages.
- **API endpoints** — REST API for third-party integrations (other bots, overlays, etc.).

## Replay Data Reference

Replay codes follow the format `XXXXX-XXXXX` (alphanumeric + `@` and `+`).
Regex: `/([a-zA-Z0-9@+]{5}-[a-zA-Z0-9@+]{5})/g`

Replays are fetched from: `http://saved-games-alpha.s3-website-us-east-1.amazonaws.com/{code}.json.gz`

Key fields used for validation:
- `playerInfo[N].displayName` — player names (check both indices, don't assume order)
- `playerInfo[N].bot` — bot type (empty string `""` for humans, e.g., `"MediumAI"` for Adept Bot)
- `result` — 0 = playerInfo[0] wins, 1 = playerInfo[1] wins, 2 = draw
- `timeInfo.playerTime[0].initial` — initial time control setting (stable regardless of turns played)
- `deckInfo.randomizer[0].length` — number of randomizer units (2D array: `[[...cards...], [...cards...]]`, one per player, always identical)
- `startTime` — Unix timestamp of game start
- `format` — 200 = ranked, 201 = custom/bot game

Implementation notes:
- Replay codes containing `+` or `@` must be URL-encoded when fetching from S3 (`+` → `%2B`, `@` → `%40`)
- Store all used replay codes to prevent reuse across verifications and matches
- On process restart, scan for pending dispute windows and resume expiry timers
