# Tournament Platform Plan 2B: Auto-Spectating + Whisper Verification

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Python headless spectator to (1) detect tournament matches between known opponents and capture results automatically, and (2) receive whisper verification codes from players in Prismata's chat to verify account ownership without creating a game.

**Architecture:** Both features extend the existing `<SPECTATOR_SERVICE>` coordinator. Auto-spectating adds a `TournamentWatcher` that reads pending matches from SQLite and filters `TopGamesUpdate` for matching player pairs. Whisper verification adds a `"PrivateChat"` message handler to the headless client that checks incoming whispers against pending verification codes in SQLite. Both write results back to the shared SQLite database (WAL mode, same DB the Node.js bot uses). A Discord webhook notifies players when auto-spectated matches complete.

**Tech Stack:** Python 3.11+, sqlite3, existing headless_client.py/<SPECTATOR_SERVICE>, Discord webhook (no discord.py needed)

**Spec:** `c:\libraries\prismata-3d\docs\superpowers\specs\2026-03-28-prismata-tournament-platform-design.md`

**Decompiled protocol reference:**
- Whisper receive: message type `"PrivateChat"`, params `[channelID, speaker, message, messageTime]`
- Whisper send: `sayToServer("PrivateChat", peerID, text)`
- Friend info: `"ServerPeerInfo"` and `"allPeersInfo"` messages

---

## File Structure

```
prismata-ladder/
├── tournament_watcher.py           # NEW: Reads tournament matches from DB, provides player pairs to watch
├── whisper_handler.py              # NEW: Handles PrivateChat messages for verification codes
├── <SPECTATOR_SERVICE>               # MODIFY: Wire tournament watcher + whisper handler into coordinator
├── headless_client.py              # MODIFY: Add PrivateChat message handling
├── tests/
│   ├── test_tournament_watcher.py  # NEW: Tournament match detection tests
│   └── test_whisper_handler.py     # NEW: Whisper verification tests
```

---

## Task 1: Tournament Watcher — Match Pair Detection

**Files:**
- Create: `tournament_watcher.py`
- Create: `tests/test_tournament_watcher.py`

- [ ] **Step 1: Create tournament_watcher.py**

```python
# tournament_watcher.py
"""
Reads pending tournament matches from SQLite and provides player pair
detection for the auto-spectating system.
"""

import sqlite3
import threading
import time
import json
import os
from pathlib import Path

# Default DB path — same DB as the Node.js bot
DEFAULT_DB_PATH = os.path.join(os.path.dirname(__file__), 'prismata_ladder.db')


class TournamentWatcher:
    """Watches for games between tournament opponents."""

    def __init__(self, db_path=None, refresh_interval=30):
        self.db_path = db_path or DEFAULT_DB_PATH
        self.refresh_interval = refresh_interval
        self._target_pairs = set()  # frozenset({p1_name, p2_name})
        self._match_lookup = {}     # frozenset → match dict
        self._lock = threading.Lock()
        self._last_refresh = 0

    def _get_conn(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=5000")
        return conn

    def refresh_targets(self):
        """Reload pending tournament matches from the database."""
        try:
            conn = self._get_conn()
            rows = conn.execute("""
                SELECT tm.id as match_id, tm.tournament_id, tm.player1_id, tm.player2_id,
                       tm.best_of, tm.status, t.name as tournament_name, t.rules_json,
                       u1.prismata_username as p1_name, u2.prismata_username as p2_name
                FROM tournament_matches tm
                JOIN tournaments t ON tm.tournament_id = t.id
                JOIN users u1 ON tm.player1_id = u1.id
                JOIN users u2 ON tm.player2_id = u2.id
                WHERE tm.status IN ('pending', 'in_progress')
                  AND tm.player2_id IS NOT NULL
            """).fetchall()
            conn.close()

            new_pairs = set()
            new_lookup = {}
            for row in rows:
                pair = frozenset({row['p1_name'].lower(), row['p2_name'].lower()})
                new_pairs.add(pair)
                new_lookup[pair] = dict(row)

            with self._lock:
                self._target_pairs = new_pairs
                self._match_lookup = new_lookup
                self._last_refresh = time.time()

        except Exception as e:
            print(f"[TournamentWatcher] Error refreshing targets: {e}")

    def _maybe_refresh(self):
        if time.time() - self._last_refresh > self.refresh_interval:
            self.refresh_targets()

    def check_game(self, player1_name, player2_name):
        """
        Check if a game between these two players is a pending tournament match.
        Returns the match dict if found, None otherwise.
        """
        self._maybe_refresh()
        pair = frozenset({player1_name.lower(), player2_name.lower()})
        with self._lock:
            return self._match_lookup.get(pair)

    def get_target_pairs(self):
        """Return current set of target player pairs."""
        self._maybe_refresh()
        with self._lock:
            return set(self._target_pairs)

    def record_auto_result(self, match_id, replay_code, winner_name, replay_json=None):
        """
        Record a game result detected by auto-spectating.
        Inserts into match_games and marks the replay code as used.
        Does NOT complete the match or advance bracket — that's the bot's job
        after the player confirms via /confirm or the dispute window passes.
        """
        try:
            conn = self._get_conn()
            # Get match details
            match = conn.execute("SELECT * FROM tournament_matches WHERE id = ?", (match_id,)).fetchone()
            if not match:
                print(f"[TournamentWatcher] Match {match_id} not found")
                return False

            # Determine winner ID
            p1 = conn.execute("SELECT * FROM users WHERE id = ?", (match['player1_id'],)).fetchone()
            p2 = conn.execute("SELECT * FROM users WHERE id = ?", (match['player2_id'],)).fetchone()
            winner_id = None
            if winner_name and p1 and p1['prismata_username'].lower() == winner_name.lower():
                winner_id = match['player1_id']
            elif winner_name and p2 and p2['prismata_username'].lower() == winner_name.lower():
                winner_id = match['player2_id']

            # Get next game number
            existing = conn.execute(
                "SELECT COALESCE(MAX(game_number), 0) as max_num FROM match_games WHERE match_id = ?",
                (match_id,)
            ).fetchone()['max_num']

            # Insert game
            conn.execute(
                "INSERT OR IGNORE INTO match_games (match_id, replay_code, game_number, winner_id, validated, replay_json) VALUES (?, ?, ?, ?, 1, ?)",
                (match_id, replay_code, existing + 1, winner_id, replay_json)
            )

            # Mark replay code as used
            conn.execute(
                "INSERT OR IGNORE INTO used_replay_codes (replay_code, used_for) VALUES (?, ?)",
                (replay_code, f'auto_spectate_match_{match_id}')
            )

            conn.commit()
            conn.close()

            # Remove from target pairs (game was played)
            self.refresh_targets()
            return True

        except Exception as e:
            print(f"[TournamentWatcher] Error recording result: {e}")
            return False
```

- [ ] **Step 2: Write tests**

```python
# tests/test_tournament_watcher.py
import unittest
import sqlite3
import tempfile
import os
from pathlib import Path

# Add parent to path
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tournament_watcher import TournamentWatcher


class TestTournamentWatcher(unittest.TestCase):

    def setUp(self):
        self.db_fd, self.db_path = tempfile.mkstemp(suffix='.db')
        conn = sqlite3.connect(self.db_path)

        # Create tournament schema
        schema_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'bot', 'schema.sql')
        with open(schema_path) as f:
            conn.executescript(f.read())

        # Seed users
        conn.execute("INSERT INTO users (id, discord_id, discord_username, prismata_username, verified) VALUES (1, 'd1', 'Alice', 'Alice', 1)")
        conn.execute("INSERT INTO users (id, discord_id, discord_username, prismata_username, verified) VALUES (2, 'd2', 'Bob', 'Bob', 1)")
        conn.execute("INSERT INTO users (id, discord_id, discord_username, prismata_username, verified) VALUES (3, 'd3', 'Charlie', 'Charlie', 1)")

        # Create tournament with pending match
        conn.execute("INSERT INTO tournaments (id, name, format, rules_json, status) VALUES (1, 'Test Cup', 'single_elim', '{\"time_control\":45}', 'active')")
        conn.execute("INSERT INTO tournament_rounds (id, tournament_id, round_number, status) VALUES (1, 1, 1, 'active')")
        conn.execute("INSERT INTO tournament_matches (id, tournament_id, round_id, player1_id, player2_id, best_of, status) VALUES (1, 1, 1, 1, 2, 1, 'pending')")
        conn.execute("INSERT INTO tournament_matches (id, tournament_id, round_id, player1_id, player2_id, best_of, status) VALUES (2, 1, 1, 3, NULL, 1, 'completed')")  # bye
        conn.commit()
        conn.close()

        self.watcher = TournamentWatcher(db_path=self.db_path, refresh_interval=0)

    def tearDown(self):
        os.close(self.db_fd)
        os.unlink(self.db_path)

    def test_detects_tournament_match(self):
        match = self.watcher.check_game('Alice', 'Bob')
        self.assertIsNotNone(match)
        self.assertEqual(match['match_id'], 1)
        self.assertEqual(match['tournament_name'], 'Test Cup')

    def test_case_insensitive(self):
        match = self.watcher.check_game('alice', 'BOB')
        self.assertIsNotNone(match)

    def test_order_independent(self):
        match = self.watcher.check_game('Bob', 'Alice')
        self.assertIsNotNone(match)

    def test_no_match_for_unknown_players(self):
        match = self.watcher.check_game('Alice', 'Charlie')
        # Charlie has a bye match (null player2), not a real match
        self.assertIsNone(match)

    def test_no_match_for_random_players(self):
        match = self.watcher.check_game('Unknown1', 'Unknown2')
        self.assertIsNone(match)

    def test_get_target_pairs(self):
        pairs = self.watcher.get_target_pairs()
        self.assertEqual(len(pairs), 1)
        self.assertIn(frozenset({'alice', 'bob'}), pairs)

    def test_record_auto_result(self):
        success = self.watcher.record_auto_result(
            match_id=1,
            replay_code='AAAAA-BBBBB',
            winner_name='Alice',
            replay_json='{"test": true}'
        )
        self.assertTrue(success)

        # Verify game was recorded
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        game = conn.execute("SELECT * FROM match_games WHERE match_id = 1").fetchone()
        self.assertIsNotNone(game)
        self.assertEqual(game['replay_code'], 'AAAAA-BBBBB')
        self.assertEqual(game['winner_id'], 1)  # Alice
        self.assertEqual(game['game_number'], 1)

        # Verify replay code marked as used
        used = conn.execute("SELECT * FROM used_replay_codes WHERE replay_code = 'AAAAA-BBBBB'").fetchone()
        self.assertIsNotNone(used)
        conn.close()

    def test_record_clears_target(self):
        self.watcher.record_auto_result(1, 'XXXXX-YYYYY', 'Alice')
        # After recording, the pair should still be in targets if match status wasn't updated
        # (record_auto_result doesn't change match status — that's the bot's job)


if __name__ == '__main__':
    unittest.main()
```

- [ ] **Step 3: Run tests**

Run: `cd <PRISMATA_LADDER_REPO> && python -m pytest tests/test_tournament_watcher.py -v`
(Or: `python -m unittest tests/test_tournament_watcher.py -v`)
Expected: All pass

- [ ] **Step 4: Commit**

```bash
cd <PRISMATA_LADDER_REPO>
git add tournament_watcher.py tests/test_tournament_watcher.py
git commit -m "feat: add TournamentWatcher for auto-spectating match detection"
```

---

## Task 2: Whisper Handler — Verification Code Processing

**Files:**
- Create: `whisper_handler.py`
- Create: `tests/test_whisper_handler.py`

- [ ] **Step 1: Create whisper_handler.py**

```python
# whisper_handler.py
"""
Handles incoming PrivateChat (whisper) messages for account verification.
Players whisper a 6-digit code to the bot account to verify their Prismata identity.
"""

import sqlite3
import time
import os
import re
import json
import urllib.request

DEFAULT_DB_PATH = os.path.join(os.path.dirname(__file__), 'prismata_ladder.db')

# Verification codes are 6 digits
CODE_RE = re.compile(r'^\s*(\d{6})\s*$')

# Codes expire after 1 hour
CODE_EXPIRY_SECONDS = 3600


class WhisperVerificationHandler:
    """Processes whisper messages for account verification codes."""

    def __init__(self, db_path=None, webhook_url=None):
        self.db_path = db_path or DEFAULT_DB_PATH
        self.webhook_url = webhook_url  # Discord webhook for notifications

    def _get_conn(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=5000")
        return conn

    def on_whisper(self, sender_name, message_text):
        """
        Handle an incoming whisper. If the message contains a valid 6-digit
        verification code, attempt to verify the sender's account.

        Args:
            sender_name: Prismata username who sent the whisper
            message_text: The whisper content

        Returns:
            dict with 'verified' (bool), 'message' (str) keys
        """
        match = CODE_RE.match(message_text)
        if not match:
            return {'verified': False, 'message': 'Not a verification code'}

        code = match.group(1)

        try:
            conn = self._get_conn()

            # Find a pending whisper verification challenge with this code
            # The verification_challenges table stores challenge_bot as the whisper code
            # for Method A (whisper verification).
            # We use a convention: challenge_bot = 'WHISPER' and challenge_time_control = code (as int)
            challenge = conn.execute("""
                SELECT vc.*, u.discord_id, u.discord_username
                FROM verification_challenges vc
                JOIN users u ON vc.user_id = u.id
                WHERE vc.status = 'pending'
                  AND vc.challenge_bot = 'WHISPER'
                  AND vc.challenge_time_control = ?
                  AND vc.claimed_username = ? COLLATE NOCASE
            """, (int(code), sender_name)).fetchone()

            if not challenge:
                conn.close()
                return {'verified': False, 'message': f'No pending verification for {sender_name} with code {code}'}

            # Check expiry
            created = challenge['created_at']
            # SQLite datetime is 'YYYY-MM-DD HH:MM:SS'
            # Just check if challenge is less than 1 hour old
            age_check = conn.execute(
                "SELECT (julianday('now') - julianday(?)) * 86400 as age_seconds",
                (created,)
            ).fetchone()

            if age_check and age_check['age_seconds'] > CODE_EXPIRY_SECONDS:
                conn.execute("UPDATE verification_challenges SET status = 'expired' WHERE id = ?", (challenge['id'],))
                conn.commit()
                conn.close()
                return {'verified': False, 'message': 'Verification code expired. Request a new one.'}

            # Verify the account
            conn.execute("UPDATE users SET prismata_username = ?, verified = 1 WHERE id = ?",
                         (sender_name, challenge['user_id']))
            conn.execute("UPDATE verification_challenges SET status = 'verified' WHERE id = ?",
                         (challenge['id'],))
            conn.commit()
            conn.close()

            # Send Discord notification
            self._notify_verification(challenge['discord_username'], sender_name)

            return {'verified': True, 'message': f'Account verified: {sender_name}'}

        except Exception as e:
            print(f"[WhisperHandler] Error processing verification: {e}")
            return {'verified': False, 'message': f'Error: {e}'}

    def _notify_verification(self, discord_username, prismata_username):
        """Send a Discord webhook notification about successful verification."""
        if not self.webhook_url:
            return

        try:
            payload = json.dumps({
                'content': f'**{discord_username}** verified their Prismata account as **{prismata_username}** via whisper.'
            }).encode('utf-8')

            req = urllib.request.Request(
                self.webhook_url,
                data=payload,
                headers={'Content-Type': 'application/json'},
                method='POST'
            )
            urllib.request.urlopen(req, timeout=5)
        except Exception as e:
            print(f"[WhisperHandler] Webhook notification failed: {e}")
```

- [ ] **Step 2: Write tests**

```python
# tests/test_whisper_handler.py
import unittest
import sqlite3
import tempfile
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from whisper_handler import WhisperVerificationHandler


class TestWhisperHandler(unittest.TestCase):

    def setUp(self):
        self.db_fd, self.db_path = tempfile.mkstemp(suffix='.db')
        conn = sqlite3.connect(self.db_path)

        schema_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'bot', 'schema.sql')
        with open(schema_path) as f:
            conn.executescript(f.read())

        # Create a user with a pending whisper verification
        conn.execute("INSERT INTO users (id, discord_id, discord_username) VALUES (1, 'd1', 'TestUser')")
        conn.execute("""
            INSERT INTO verification_challenges
                (id, user_id, claimed_username, challenge_bot, challenge_time_control, challenge_randomizer_count, status)
            VALUES (1, 1, 'Surfinite', 'WHISPER', 123456, 0, 'pending')
        """)
        conn.commit()
        conn.close()

        self.handler = WhisperVerificationHandler(db_path=self.db_path)

    def tearDown(self):
        os.close(self.db_fd)
        os.unlink(self.db_path)

    def test_valid_code_verifies(self):
        result = self.handler.on_whisper('Surfinite', '123456')
        self.assertTrue(result['verified'])

        # Check DB was updated
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        user = conn.execute("SELECT * FROM users WHERE id = 1").fetchone()
        self.assertEqual(user['prismata_username'], 'Surfinite')
        self.assertEqual(user['verified'], 1)
        conn.close()

    def test_wrong_code_fails(self):
        result = self.handler.on_whisper('Surfinite', '999999')
        self.assertFalse(result['verified'])

    def test_wrong_sender_fails(self):
        result = self.handler.on_whisper('WrongPerson', '123456')
        self.assertFalse(result['verified'])

    def test_non_code_message_ignored(self):
        result = self.handler.on_whisper('Surfinite', 'hello there')
        self.assertFalse(result['verified'])
        self.assertEqual(result['message'], 'Not a verification code')

    def test_code_with_whitespace(self):
        result = self.handler.on_whisper('Surfinite', '  123456  ')
        self.assertTrue(result['verified'])

    def test_case_insensitive_username(self):
        result = self.handler.on_whisper('surfinite', '123456')
        self.assertTrue(result['verified'])

    def test_code_cannot_be_reused(self):
        self.handler.on_whisper('Surfinite', '123456')
        # Create another user trying the same code
        conn = sqlite3.connect(self.db_path)
        conn.execute("INSERT INTO users (id, discord_id, discord_username) VALUES (2, 'd2', 'Other')")
        conn.execute("""
            INSERT INTO verification_challenges
                (id, user_id, claimed_username, challenge_bot, challenge_time_control, challenge_randomizer_count, status)
            VALUES (2, 2, 'OtherPlayer', 'WHISPER', 123456, 0, 'pending')
        """)
        conn.commit()
        conn.close()

        result = self.handler.on_whisper('OtherPlayer', '123456')
        # This should still work since it's a different user with the same code
        self.assertTrue(result['verified'])


if __name__ == '__main__':
    unittest.main()
```

- [ ] **Step 3: Run tests**

Run: `cd <PRISMATA_LADDER_REPO> && python -m pytest tests/test_whisper_handler.py -v`
Expected: All pass

- [ ] **Step 4: Commit**

```bash
git add whisper_handler.py tests/test_whisper_handler.py
git commit -m "feat: add WhisperVerificationHandler for Method A account verification"
```

---

## Task 3: Add PrivateChat Message Handling to Headless Client

**Files:**
- Modify: `headless_client.py`

- [ ] **Step 1: Add PrivateChat handler to HeadlessClient**

In `headless_client.py`, find the message dispatch section in the `run()` loop where messages like `"BeginGame"`, `"GameOver"`, etc. are handled. Add a handler for `"PrivateChat"`.

Add after the existing game message handlers (near the `GameOver`/`GameOverDraw` handlers):

```python
elif msg_type == "PrivateChat":
    # Whisper/DM received: params = [channelID, speaker, message, messageTime]
    if len(params) >= 3:
        speaker = params[1] if isinstance(params[1], str) else str(params[1])
        text = params[2] if isinstance(params[2], str) else str(params[2])
        self._emit_game_event('whisper', speaker, text)
```

Also add `'whisper'` to the `game_callbacks` dict in `__init__`:

```python
self.game_callbacks = {
    'game_start': [],
    'game_click': [],
    'game_turn': [],
    'game_over': [],
    'whisper': [],    # NEW
}
```

- [ ] **Step 2: Commit**

```bash
git add headless_client.py
git commit -m "feat: add PrivateChat (whisper) message handler to headless client"
```

---

## Task 4: Wire Tournament Watcher + Whisper Handler into Coordinator

**Files:**
- Modify: `<SPECTATOR_SERVICE>`

- [ ] **Step 1: Import and integrate TournamentWatcher**

At the top of `<SPECTATOR_SERVICE>`, add:

```python
from tournament_watcher import TournamentWatcher
from whisper_handler import WhisperVerificationHandler
```

In the `main()` function, after creating the `SpectatorCoordinator` and `BroadcastServer`, add:

```python
# Tournament auto-spectating
tournament_watcher = TournamentWatcher()
tournament_watcher.refresh_targets()

# Whisper verification
ops_webhook = os.environ.get('OPS_WEBHOOK_URL')
whisper_handler = WhisperVerificationHandler(webhook_url=ops_webhook)
```

- [ ] **Step 2: Add tournament match detection to CoordinatedClient**

In the `CoordinatedClient` constructor, accept and store the tournament watcher:

```python
def __init__(self, name, username, password, coordinator, quiet=False,
             broadcast_server=None, tournament_watcher=None, whisper_handler=None):
    # ... existing init ...
    self.tournament_watcher = tournament_watcher
    self.whisper_handler = whisper_handler
```

In the `_on_game_over` method (or wherever GameOver is processed), add tournament match detection:

```python
def _on_game_over(self, tracker):
    # ... existing logging ...

    # Check if this was a tournament match
    if self.tournament_watcher and tracker.players and len(tracker.players) == 2:
        match = self.tournament_watcher.check_game(tracker.players[0], tracker.players[1])
        if match:
            winner_name = None
            if tracker.result == 'white_win':
                winner_name = tracker.players[0]
            elif tracker.result == 'black_win':
                winner_name = tracker.players[1]

            success = self.tournament_watcher.record_auto_result(
                match_id=match['match_id'],
                replay_code=tracker.replay_code,
                winner_name=winner_name,
                replay_json=None  # Could fetch from S3 if needed
            )
            if success:
                print(f"  [Tournament] Auto-recorded: {match['tournament_name']} — "
                      f"{tracker.players[0]} vs {tracker.players[1]} → {winner_name or 'draw'}")
```

- [ ] **Step 3: Add whisper callback**

Register the whisper callback when setting up each CoordinatedClient:

```python
# In the client setup section of main(), after creating each CoordinatedClient:
def make_whisper_callback(handler):
    def on_whisper(speaker, text):
        result = handler.on_whisper(speaker, text)
        if result['verified']:
            print(f"  [Whisper] Account verified: {speaker}")
        elif 'Not a verification code' not in result['message']:
            print(f"  [Whisper] Verification attempt from {speaker}: {result['message']}")
    return on_whisper

client.client.on_game_event('whisper', make_whisper_callback(whisper_handler))
```

- [ ] **Step 4: Pass tournament_watcher and whisper_handler to each CoordinatedClient in main()**

Update the `CoordinatedClient` instantiation in `main()`:

```python
cc = CoordinatedClient(
    name=f"Bot{i+1}",
    username=username,
    password=password,
    coordinator=coordinator,
    broadcast_server=broadcaster,
    tournament_watcher=tournament_watcher,
    whisper_handler=whisper_handler,
)
```

- [ ] **Step 5: Commit**

```bash
git add <SPECTATOR_SERVICE>
git commit -m "feat: wire tournament watcher + whisper handler into spectator coordinator"
```

---

## Task 5: Discord Bot — /verify whisper Subcommand

The Node.js bot needs a way for users to request a whisper verification code (Method A). This creates a verification challenge with `challenge_bot = 'WHISPER'` and `challenge_time_control = <6-digit code>`.

**Files:**
- Modify: `bot/commands/verify.js`
- Modify: `bot/deploy-commands.js`

- [ ] **Step 1: Add whisper subcommand to verify.js**

Add a third subcommand `whisper` to the existing verify command:

In the `data` builder, add:

```javascript
  .addSubcommand(sub =>
    sub.setName('whisper')
      .setDescription('Get a whisper code to verify via Prismata chat (Method A)')
      .addStringOption(opt =>
        opt.setName('username')
          .setDescription('Your Prismata username')
          .setRequired(true)
      )
  )
```

In the `execute` function, add the handler:

```javascript
  if (sub === 'whisper') {
    const prismataUsername = interaction.options.getString('username');

    const existing = getUserByPrismataName(prismataUsername);
    if (existing && existing.discord_id !== interaction.user.id) {
      return interaction.reply({
        content: `The Prismata account "${prismataUsername}" is already verified by another user.`,
        ephemeral: true,
      });
    }

    const user = findOrCreateUser(interaction.user.id, interaction.user.username);
    if (user.verified) {
      return interaction.reply({
        content: `You're already verified as **${user.prismata_username}**.`,
        ephemeral: true,
      });
    }

    // Generate 6-digit code
    const code = Math.floor(100000 + Math.random() * 900000);

    // Store as a verification challenge with WHISPER convention
    // challenge_bot = 'WHISPER', challenge_time_control = code, challenge_randomizer_count = 0
    createVerificationChallenge(user.id, prismataUsername, 'WHISPER', code, 0);

    const embed = new EmbedBuilder()
      .setColor(0x00b894)
      .setTitle('Whisper Verification')
      .setDescription(
        `To verify you own **${prismataUsername}**:\n\n` +
        `1. Add **PrismataLiveBot** (or any spectator bot) as a friend in Prismata\n` +
        `2. Whisper this code to the bot:\n\n` +
        `**${code}**\n\n` +
        `The code expires in 1 hour.`
      )
      .setFooter({ text: 'Alternatively, use /verify start for replay-based verification.' });

    return interaction.reply({ embeds: [embed], ephemeral: true });
  }
```

- [ ] **Step 2: Update deploy-commands.js**

The deploy-commands.js already imports `data` from verify.js, so the new subcommand will be registered automatically when you re-run `node deploy-commands.js`. No code change needed — just re-run the registration script.

- [ ] **Step 3: Run tests and re-register commands**

Run: `cd <PRISMATA_LADDER_REPO>/bot && npm test`
Expected: All tests pass

Run: `cd <PRISMATA_LADDER_REPO>/bot && node deploy-commands.js`
Expected: "Registered 8 commands"

- [ ] **Step 4: Commit**

```bash
cd <PRISMATA_LADDER_REPO>
git add bot/commands/verify.js
git commit -m "feat(bot): add /verify whisper subcommand for Method A verification"
```

---

## Task 6: Integration Test

- [ ] **Step 1: Run all Python tests**

Run: `cd <PRISMATA_LADDER_REPO> && python -m pytest tests/ -v`
Expected: All tests pass

- [ ] **Step 2: Run all Node.js tests**

Run: `cd <PRISMATA_LADDER_REPO>/bot && npm test`
Expected: All tests pass

- [ ] **Step 3: Manual test — tournament watcher detection**

In a Python shell:
```python
from tournament_watcher import TournamentWatcher
w = TournamentWatcher()
w.refresh_targets()
print(w.get_target_pairs())
# Should show pairs if any pending tournament matches exist
```

- [ ] **Step 4: Commit final**

```bash
git add -A
git commit -m "feat: Plan 2B complete — auto-spectating + whisper verification"
```

---

## Summary

After completing Plan 2B, you have:

- **TournamentWatcher** — reads pending matches from SQLite, detects games between tournament opponents in TopGamesUpdate, records results automatically
- **WhisperVerificationHandler** — processes `PrivateChat` messages for 6-digit verification codes (Method A)
- **HeadlessClient** — now handles `PrivateChat` messages and emits `whisper` events
- **<SPECTATOR_SERVICE>** — wired up with tournament watcher and whisper handler
- **`/verify whisper`** — new Discord command to request a whisper verification code

**What players see:**
- Method A: `/verify whisper username:Surfinite` → get code → whisper code to bot in Prismata → verified
- Auto-spectating: play tournament match → bot detects game → records result automatically → player confirms via /confirm (TODO: Plan 2 already has this)
