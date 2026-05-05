# Tournament Platform — Next Features

Continue building the Prismata tournament platform. The core system is deployed and working (single elimination tournaments, Discord bot, replay validation, website). Check memory for `project_tournament_platform.md` for full status.

All code lives in `<PRISMATA_LADDER_REPO>\`. Read the CLAUDE.md there first. The spec is at `c:\libraries\prismata-3d\docs\superpowers\specs\2026-03-28-prismata-tournament-platform-design.md`.

## Features to build (pick one or more)

### 1. Swiss / Round Robin / Double Elimination formats
Currently only Single Elimination works. The bot's tournament engine needs:
- **Swiss**: N rounds, pair players with similar W/L records, no elimination
- **Round Robin**: every player plays every other player
- **Double Elimination**: winners bracket + losers bracket, losers get second chance

Key files: `bot/lib/bracket-engine.js` (generates brackets), `bot/commands/tournament.js` (create/start), `bot/lib/tournament-db.js` (DB queries). The `format` field already exists in the tournaments table — it's stored but only `single_elim` logic is implemented.

The spec has details on combination formats (e.g., Swiss group stage into Single Elim playoffs) but start with standalone formats first.

### 2. Website result submission
Players can only submit replay codes via Discord (`/result`). Add a form on match pages so website users can submit too.

This requires:
- An API route on the website that accepts replay codes
- The API needs to reach the bot's SQLite database on the Data Box (<DATA_BOX_PUBLIC_IP>)
- Options: (a) API proxy that SSHs to Data Box, (b) small HTTP API on the Data Box, (c) shared database
- The replay validation logic is in `bot/lib/replay-validator.js` — would need to be callable from the API
- User must be authenticated (Discord OAuth session) to submit

The match detail pages already exist at `/tournament/[id]/match/[matchId]` and `/match/[id]`.

### 3. Player tournament profile page (`/profile/[username]`)
Show a player's tournament history, match record, challenge history. The data is in the database — just needs:
- A new page at `prismata-ladder-site/src/app/profile/[username]/page.tsx`
- Tournament export extended to include per-player stats
- Link from player names throughout the site

### 4. Online detection — suggest matches
When both players in a pending tournament match are online in Discord, DM them suggesting they play. Needs:
- Presence intent (already enabled: `GatewayIntentBits.GuildPresences` in `bot/index.js`)
- Check in the scheduler loop (60s) for pending matches where both players are online
- Rate limit: don't spam — maybe once per hour per match
- Only suggest, don't nag

### 5. Mobile nav hamburger menu
The site nav bar doesn't collapse on mobile. Need a hamburger menu toggle for small screens. The nav component is at `prismata-ladder-site/src/components/nav.tsx`. This is a straightforward responsive CSS/React task.

## Deploy workflow
After making changes:
1. Run tests: `cd bot && npm test` and `python -m pytest tests/`
2. Deploy bot changes to Data Box via pipe (see CLAUDE.md for syntax)
3. Re-register commands if slash command definitions changed
4. Restart bot: `sudo systemctl restart giselle-bot`
5. For website changes: build locally, upload to staging (see README.md deploy section)
