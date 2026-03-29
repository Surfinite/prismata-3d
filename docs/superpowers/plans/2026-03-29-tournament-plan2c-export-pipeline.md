# Tournament Platform Plan 2C: Tournament Export Pipeline

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Python export pipeline to include tournament data (active tournaments, brackets, match results, standings, challenges) in the JSON exports consumed by the prismata.live website.

**Architecture:** Add a `tournament_export.py` module that reads from the tournament SQLite tables (written by the Node.js bot) and produces a tournament data structure. Wire this into the existing `export_site_data.py` pipeline so tournament data is exported alongside ladder data every 60 seconds. The website will read this data from the same `api.json` file (or a separate `tournaments.json`).

**Tech Stack:** Python 3.11+, sqlite3, existing export_site_data.py pipeline

**Spec:** `c:\libraries\prismata-3d\docs\superpowers\specs\2026-03-28-prismata-tournament-platform-design.md`

---

## File Structure

```
prismata-ladder/
├── tournament_export.py            # NEW: Export tournament data to JSON
├── export_site_data.py             # MODIFY: Call tournament export and include in output
├── tests/
│   └── test_tournament_export.py   # NEW: Tournament export tests
```

---

## Task 1: Tournament Export Module

**Files:**
- Create: `tournament_export.py`
- Create: `tests/test_tournament_export.py`

- [ ] **Step 1: Create tournament_export.py**

```python
# tournament_export.py
"""
Export tournament data from SQLite to JSON for the prismata.live website.
Reads from tournament tables written by the Giselle v2 Discord bot.
"""

import sqlite3
import json
import os
from pathlib import Path

DEFAULT_DB_PATH = os.path.join(os.path.dirname(__file__), 'prismata_ladder.db')


def get_conn(db_path=None):
    conn = sqlite3.connect(db_path or DEFAULT_DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    return conn


def export_tournaments(conn):
    """Export all non-cancelled tournaments with player counts."""
    rows = conn.execute("""
        SELECT t.*,
               (SELECT COUNT(*) FROM tournament_players tp WHERE tp.tournament_id = t.id) as player_count,
               u.prismata_username as created_by_name
        FROM tournaments t
        LEFT JOIN users u ON t.created_by = u.id
        WHERE t.status != 'cancelled'
        ORDER BY
            CASE t.status
                WHEN 'active' THEN 0
                WHEN 'registration' THEN 1
                WHEN 'completed' THEN 2
            END,
            t.created_at DESC
    """).fetchall()

    return [
        {
            'id': r['id'],
            'name': r['name'],
            'description': r['description'],
            'format': r['format'],
            'rules': json.loads(r['rules_json']) if r['rules_json'] else {},
            'status': r['status'],
            'player_count': r['player_count'],
            'max_players': r['max_players'],
            'registration_deadline': r['registration_deadline'],
            'created_by': r['created_by_name'],
            'created_at': r['created_at'],
        }
        for r in rows
    ]


def export_tournament_detail(conn, tournament_id):
    """Export full tournament detail including players, rounds, matches."""
    tournament = conn.execute("SELECT * FROM tournaments WHERE id = ?", (tournament_id,)).fetchone()
    if not tournament:
        return None

    # Players
    players = conn.execute("""
        SELECT tp.seed, tp.status as player_status,
               u.id as user_id, u.prismata_username, u.discord_username, u.tournament_rating
        FROM tournament_players tp
        JOIN users u ON tp.user_id = u.id
        WHERE tp.tournament_id = ?
        ORDER BY tp.seed
    """, (tournament_id,)).fetchall()

    # Rounds and matches
    rounds_data = []
    rounds = conn.execute("""
        SELECT * FROM tournament_rounds
        WHERE tournament_id = ?
        ORDER BY round_number
    """, (tournament_id,)).fetchall()

    for rnd in rounds:
        matches = conn.execute("""
            SELECT tm.*,
                   u1.prismata_username as p1_name,
                   u2.prismata_username as p2_name,
                   uw.prismata_username as winner_name
            FROM tournament_matches tm
            LEFT JOIN users u1 ON tm.player1_id = u1.id
            LEFT JOIN users u2 ON tm.player2_id = u2.id
            LEFT JOIN users uw ON tm.winner_id = uw.id
            WHERE tm.round_id = ?
            ORDER BY tm.id
        """, (rnd['id'],)).fetchall()

        match_list = []
        for m in matches:
            # Get games for this match
            games = conn.execute("""
                SELECT mg.replay_code, mg.game_number,
                       uw.prismata_username as game_winner
                FROM match_games mg
                LEFT JOIN users uw ON mg.winner_id = uw.id
                WHERE mg.match_id = ?
                ORDER BY mg.game_number
            """, (m['id'],)).fetchall()

            match_list.append({
                'id': m['id'],
                'player1': m['p1_name'],
                'player2': m['p2_name'],
                'winner': m['winner_name'],
                'status': m['status'],
                'best_of': m['best_of'],
                'deadline': m['deadline'],
                'games': [
                    {
                        'replay_code': g['replay_code'],
                        'game_number': g['game_number'],
                        'winner': g['game_winner'],
                    }
                    for g in games
                ],
            })

        rounds_data.append({
            'round_number': rnd['round_number'],
            'status': rnd['status'],
            'deadline': rnd['deadline'],
            'matches': match_list,
        })

    return {
        'id': tournament['id'],
        'name': tournament['name'],
        'description': tournament['description'],
        'format': tournament['format'],
        'rules': json.loads(tournament['rules_json']) if tournament['rules_json'] else {},
        'status': tournament['status'],
        'created_at': tournament['created_at'],
        'players': [
            {
                'username': p['prismata_username'],
                'discord_username': p['discord_username'],
                'seed': p['seed'],
                'status': p['player_status'],
                'tournament_rating': p['tournament_rating'],
            }
            for p in players
        ],
        'rounds': rounds_data,
    }


def export_standings(conn, tournament_id):
    """Export W/L standings for a tournament."""
    players = conn.execute("""
        SELECT tp.status as player_status,
               u.id as user_id, u.prismata_username
        FROM tournament_players tp
        JOIN users u ON tp.user_id = u.id
        WHERE tp.tournament_id = ?
    """, (tournament_id,)).fetchall()

    stats = {}
    for p in players:
        stats[p['user_id']] = {
            'username': p['prismata_username'],
            'wins': 0,
            'losses': 0,
            'status': p['player_status'],
        }

    matches = conn.execute("""
        SELECT * FROM tournament_matches
        WHERE tournament_id = ? AND status IN ('completed', 'forfeited')
    """, (tournament_id,)).fetchall()

    for m in matches:
        if m['winner_id'] and m['winner_id'] in stats:
            stats[m['winner_id']]['wins'] += 1
        loser_id = m['player1_id'] if m['winner_id'] == m['player2_id'] else m['player2_id']
        if loser_id and loser_id in stats:
            stats[loser_id]['losses'] += 1

    result = sorted(stats.values(), key=lambda s: (-s['wins'], s['losses']))
    return result


def export_recent_challenges(conn, limit=20):
    """Export recent show matches/challenges."""
    rows = conn.execute("""
        SELECT c.*,
               u1.prismata_username as challenger_name,
               u2.prismata_username as challenged_name
        FROM challenges c
        JOIN users u1 ON c.challenger_id = u1.id
        JOIN users u2 ON c.challenged_id = u2.id
        WHERE c.status IN ('in_progress', 'completed')
        ORDER BY c.created_at DESC
        LIMIT ?
    """, (limit,)).fetchall()

    result = []
    for r in rows:
        games = conn.execute("""
            SELECT cg.replay_code, cg.game_number,
                   uw.prismata_username as game_winner
            FROM challenge_games cg
            LEFT JOIN users uw ON cg.winner_id = uw.id
            WHERE cg.challenge_id = ?
            ORDER BY cg.game_number
        """, (r['id'],)).fetchall()

        # Tally wins
        challenger_wins = sum(1 for g in games if g['game_winner'] and g['game_winner'].lower() == r['challenger_name'].lower())
        challenged_wins = sum(1 for g in games if g['game_winner'] and g['game_winner'].lower() == r['challenged_name'].lower())

        result.append({
            'id': r['id'],
            'challenger': r['challenger_name'],
            'challenged': r['challenged_name'],
            'best_of': r['best_of'],
            'rules': json.loads(r['rules_json']) if r['rules_json'] else {},
            'status': r['status'],
            'score': f"{challenger_wins}-{challenged_wins}",
            'created_at': r['created_at'],
            'games': [
                {
                    'replay_code': g['replay_code'],
                    'game_number': g['game_number'],
                    'winner': g['game_winner'],
                }
                for g in games
            ],
        })

    return result


def export_all_tournament_data(db_path=None):
    """
    Export all tournament data as a single dict.
    Called by export_site_data.py.
    """
    conn = get_conn(db_path)

    tournaments = export_tournaments(conn)

    # Export detail for active/registration tournaments
    tournament_details = {}
    for t in tournaments:
        if t['status'] in ('active', 'registration'):
            detail = export_tournament_detail(conn, t['id'])
            if detail:
                tournament_details[t['id']] = detail

    challenges = export_recent_challenges(conn)

    conn.close()

    return {
        'tournaments': tournaments,
        'tournament_details': tournament_details,
        'challenges': challenges,
    }
```

- [ ] **Step 2: Write tests**

```python
# tests/test_tournament_export.py
import unittest
import sqlite3
import tempfile
import os
import json
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tournament_export import (
    export_tournaments, export_tournament_detail,
    export_standings, export_recent_challenges, export_all_tournament_data
)


class TestTournamentExport(unittest.TestCase):

    def setUp(self):
        self.db_fd, self.db_path = tempfile.mkstemp(suffix='.db')
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row

        schema_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'bot', 'schema.sql')
        with open(schema_path) as f:
            conn.executescript(f.read())

        # Seed data
        conn.execute("INSERT INTO users (id, discord_id, discord_username, prismata_username, verified) VALUES (1, 'd1', 'Alice', 'Alice', 1)")
        conn.execute("INSERT INTO users (id, discord_id, discord_username, prismata_username, verified) VALUES (2, 'd2', 'Bob', 'Bob', 1)")
        conn.execute("INSERT INTO users (id, discord_id, discord_username, prismata_username, verified) VALUES (3, 'd3', 'Charlie', 'Charlie', 1)")

        conn.execute("INSERT INTO tournaments (id, name, description, format, rules_json, status, created_by) VALUES (1, 'Weekly Cup', 'Test tournament', 'single_elim', '{\"time_control\":45,\"randomizer_count\":8}', 'active', 1)")
        conn.execute("INSERT INTO tournament_players (tournament_id, user_id, seed, status) VALUES (1, 1, 1, 'active')")
        conn.execute("INSERT INTO tournament_players (tournament_id, user_id, seed, status) VALUES (1, 2, 2, 'active')")
        conn.execute("INSERT INTO tournament_players (tournament_id, user_id, seed, status) VALUES (1, 3, 3, 'eliminated')")

        conn.execute("INSERT INTO tournament_rounds (id, tournament_id, round_number, deadline, status) VALUES (1, 1, 1, '2026-04-01', 'completed')")
        conn.execute("INSERT INTO tournament_matches (id, tournament_id, round_id, player1_id, player2_id, winner_id, best_of, status) VALUES (1, 1, 1, 1, 3, 1, 1, 'completed')")
        conn.execute("INSERT INTO match_games (match_id, replay_code, game_number, winner_id, validated) VALUES (1, 'AAAAA-BBBBB', 1, 1, 1)")

        conn.execute("INSERT INTO tournament_rounds (id, tournament_id, round_number, deadline, status) VALUES (2, 1, 2, '2026-04-03', 'active')")
        conn.execute("INSERT INTO tournament_matches (id, tournament_id, round_id, player1_id, player2_id, best_of, status) VALUES (2, 1, 2, 1, 2, 1, 'pending')")

        # Challenge
        conn.execute("INSERT INTO challenges (id, challenger_id, challenged_id, best_of, rules_json, status) VALUES (1, 1, 2, 3, '{\"time_control\":45}', 'completed')")
        conn.execute("INSERT INTO challenge_games (challenge_id, replay_code, game_number, winner_id) VALUES (1, 'CCCCC-DDDDD', 1, 1)")
        conn.execute("INSERT INTO challenge_games (challenge_id, replay_code, game_number, winner_id) VALUES (1, 'EEEEE-FFFFF', 2, 1)")

        conn.commit()
        self.conn = conn

    def tearDown(self):
        self.conn.close()
        os.close(self.db_fd)
        os.unlink(self.db_path)

    def test_export_tournaments(self):
        result = export_tournaments(self.conn)
        self.assertEqual(len(result), 1)
        t = result[0]
        self.assertEqual(t['name'], 'Weekly Cup')
        self.assertEqual(t['status'], 'active')
        self.assertEqual(t['player_count'], 3)
        self.assertEqual(t['rules']['time_control'], 45)
        self.assertEqual(t['created_by'], 'Alice')

    def test_export_tournament_detail(self):
        detail = export_tournament_detail(self.conn, 1)
        self.assertIsNotNone(detail)
        self.assertEqual(detail['name'], 'Weekly Cup')
        self.assertEqual(len(detail['players']), 3)
        self.assertEqual(len(detail['rounds']), 2)

        # Round 1 should have 1 completed match with a game
        r1 = detail['rounds'][0]
        self.assertEqual(r1['round_number'], 1)
        self.assertEqual(len(r1['matches']), 1)
        self.assertEqual(r1['matches'][0]['winner'], 'Alice')
        self.assertEqual(len(r1['matches'][0]['games']), 1)
        self.assertEqual(r1['matches'][0]['games'][0]['replay_code'], 'AAAAA-BBBBB')

        # Round 2 should have 1 pending match
        r2 = detail['rounds'][1]
        self.assertEqual(r2['matches'][0]['status'], 'pending')

    def test_export_standings(self):
        standings = export_standings(self.conn, 1)
        self.assertEqual(len(standings), 3)
        # Alice should be first (1 win)
        self.assertEqual(standings[0]['username'], 'Alice')
        self.assertEqual(standings[0]['wins'], 1)

    def test_export_recent_challenges(self):
        challenges = export_recent_challenges(self.conn)
        self.assertEqual(len(challenges), 1)
        c = challenges[0]
        self.assertEqual(c['challenger'], 'Alice')
        self.assertEqual(c['challenged'], 'Bob')
        self.assertEqual(c['score'], '2-0')
        self.assertEqual(len(c['games']), 2)

    def test_export_all_tournament_data(self):
        result = export_all_tournament_data(db_path=self.db_path)
        self.assertIn('tournaments', result)
        self.assertIn('tournament_details', result)
        self.assertIn('challenges', result)
        self.assertEqual(len(result['tournaments']), 1)
        self.assertIn(1, result['tournament_details'])

    def test_excludes_cancelled_tournaments(self):
        self.conn.execute("INSERT INTO tournaments (id, name, format, rules_json, status) VALUES (2, 'Cancelled', 'single_elim', '{}', 'cancelled')")
        self.conn.commit()
        result = export_tournaments(self.conn)
        self.assertEqual(len(result), 1)  # Still just the active one


if __name__ == '__main__':
    unittest.main()
```

- [ ] **Step 3: Run tests**

Run: `cd <PRISMATA_LADDER_REPO> && python -m pytest tests/test_tournament_export.py -v`
Expected: All pass

- [ ] **Step 4: Commit**

```bash
cd <PRISMATA_LADDER_REPO>
git add tournament_export.py tests/test_tournament_export.py
git commit -m "feat: add tournament export module for JSON data pipeline"
```

---

## Task 2: Wire Tournament Export into Existing Pipeline

**Files:**
- Modify: `export_site_data.py`

- [ ] **Step 1: Import tournament export in export_site_data.py**

At the top of `export_site_data.py`, add:

```python
from tournament_export import export_all_tournament_data
```

- [ ] **Step 2: Add tournament data to the export JSON**

In the `export_data()` function, after the existing data assembly (where `data = { "generated_at": ..., "stats": ..., ... }` is built), add:

```python
    # Tournament data (from Node.js bot's SQLite tables)
    try:
        tournament_data = export_all_tournament_data()
        data['tournament'] = tournament_data
    except Exception as e:
        print(f"[export] Warning: tournament export failed: {e}")
        data['tournament'] = {'tournaments': [], 'tournament_details': {}, 'challenges': []}
```

This adds a `tournament` key to the existing `api.json` with tournament lists, bracket details, and challenges. The try/except ensures the existing export doesn't break if tournament tables don't exist yet.

- [ ] **Step 3: Also write tournaments.json separately**

After writing `api.json`, also write tournament data to a separate file for the website to consume independently:

```python
    # Write tournament-specific export (for website tournament pages)
    tournament_json_path = site_data_dir / 'tournaments.json'
    with open(tournament_json_path, 'w') as f:
        json.dump(data.get('tournament', {}), f, separators=(',', ':'))
    upload_json_to_s3(tournament_json_path, 'tournaments.json')
```

Where `site_data_dir` is the path to `prismata-ladder-site/public/data/`.

- [ ] **Step 4: Commit**

```bash
git add export_site_data.py
git commit -m "feat: wire tournament export into 60-second data pipeline"
```

---

## Task 3: Integration Test

- [ ] **Step 1: Run all Python tests**

Run: `cd <PRISMATA_LADDER_REPO> && python -m pytest tests/ -v`
Expected: All pass

- [ ] **Step 2: Run export manually and verify output**

```bash
cd <PRISMATA_LADDER_REPO>
python export_site_data.py
```

Then check `prismata-ladder-site/public/data/api.json` contains a `tournament` key, and `tournaments.json` exists.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: Plan 2C complete — tournament data in export pipeline"
```

---

## Summary

After completing Plan 2C:

- **tournament_export.py** — standalone module exporting tournaments, brackets, match results, standings, and challenges from SQLite
- **export_site_data.py** — now includes tournament data in the 60-second export cycle
- **api.json** — gains a `tournament` key with all tournament data
- **tournaments.json** — separate file for website tournament pages

The website (Plan 3) will read from these exports to render tournament pages, brackets, and match history.
