# Tournament Formats: Double Elimination + Round Robin

## Overview

Extend the tournament platform to support Double Elimination and Round Robin formats alongside the existing Single Elimination. The bracket engine, Discord bot commands, database, tournament export, and website all need format-aware logic.

## Formats

### Double Elimination

Players start in a winners bracket (identical structure to single elim). Losing a match drops you to the losers bracket instead of eliminating you. Lose twice and you're out.

**Structure:**
- **Winners bracket**: standard single-elim tree with byes for non-power-of-2 counts
- **Losers bracket**: losers from each winners bracket round feed in. Losers bracket has roughly twice as many rounds as winners bracket (alternating "drop-down" rounds where WB losers enter, and "reduction" rounds within LB)
- **Grand Final**: winners bracket champion vs losers bracket champion
- **Grand Final advantage**: configurable per tournament. When enabled, the LB champion must beat the WB champion twice (two separate matches). When disabled, single match decides it.

**Bracket advancement:**
- When a WB match completes: winner advances in WB, loser moves to the corresponding LB round
- When a LB match completes: winner advances in LB, loser is eliminated
- When WB final completes: winner goes to Grand Final as WB champion
- When LB final completes: winner goes to Grand Final as LB champion
- Grand Final (with advantage): if LB champion wins the first match, a reset match is played. If WB champion wins, tournament is over.
- Grand Final (without advantage): single match, winner takes the tournament.

**Player status tracking:**
- `active` — still in winners bracket
- `losers_bracket` — dropped to losers bracket (new status value)
- `eliminated` — lost twice
- The `tournament_players.status` field needs the new `losers_bracket` value.

**Seeding and byes:** Same as single elim — random shuffle, byes for non-power-of-2 counts in the winners bracket round 1. The losers bracket does not use pre-assigned byes; odd player counts are handled through the reduction round mechanism.

### Round Robin

Every player plays every other player. All matches are generated at tournament start and can be completed in any order.

**Structure:**
- N players → N×(N-1)/2 matches, all created at tournament start
- Single round in the database (round 1), all matches belong to it
- No per-round deadlines — the tournament has one overall deadline
- Maximum 12 players (66 matches). The `/create` command enforces this when format is `round_robin`.

**Standings calculation:**
- Primary ranking: total match wins (descending)
- Tiebreaker 1: head-to-head result between tied players
- Tiebreaker 2: game differential (total games won minus total games lost across all matches)
- If still tied after both tiebreakers: shared placement

**Completion:** Tournament completes when all matches have status `completed` or `forfeited`. No bracket advancement needed — just compute final standings.

**Dropouts:** All remaining unplayed matches for the dropped player are marked as forfeits. Opponents get the win. Completed results stand.

## Database Changes

### Modified tables

**`tournament_players.status`**: Add `losers_bracket` as a valid value (currently: `registered`, `active`, `eliminated`).

### New columns

**`tournament_matches.bracket`**: String column, nullable. Values:
- `'winners'` — match is in the winners bracket (double elim)
- `'losers'` — match is in the losers bracket (double elim)
- `'grand_final'` — grand final match (double elim)
- `NULL` — not applicable (single elim, round robin)

**`tournaments.rules_json`**: The existing JSON field gains a new optional key:
- `grandFinalAdvantage`: boolean (default `true`). Only meaningful for `double_elim`.

### No new tables needed

The existing schema (tournaments, tournament_players, tournament_rounds, tournament_matches, match_games) handles both formats. Round robin uses a single round with all matches. Double elim uses multiple rounds across both brackets, distinguished by `tournament_matches.bracket`.

## Bracket Engine Changes

### File: `bot/lib/bracket-engine.js`

**New exports:**

`generateDoubleElimBracket(players)` — Returns an object describing the full bracket:
```js
{
  winnersRound1: [{ player1_id, player2_id, bracket: 'winners' }, ...],
  // Losers bracket rounds are created dynamically as WB matches complete
}
```
Only winners bracket round 1 is created at tournament start. Losers bracket matches are created as players drop down, since the specific matchups depend on results.

`generateRoundRobinMatches(players)` — Returns all pairings:
```js
[{ player1_id, player2_id }, ...]  // N*(N-1)/2 matches
```

**Modified exports:**

`tryAdvanceBracket(client, tournamentId)` — Currently only handles single elim. Add format dispatch:
- `single_elim`: existing logic (unchanged)
- `double_elim`: check if WB round is complete → create next WB round + feed losers into LB. Check if LB round is complete → advance LB. Check if Grand Final is needed/complete.
- `round_robin`: check if all matches are complete → compute standings, mark tournament complete.

`totalRounds(playerCount)` — Currently returns `ceil(log2(n))`. For double elim, the total is roughly `2 * ceil(log2(n)) + 1` (WB rounds + LB rounds + grand final). For round robin, return 1.

### Losers bracket round creation logic

When winners bracket round R completes:
1. Collect losers from WB round R
2. If there's an active losers bracket round, those winners play the new drop-downs (interleaving)
3. If not, the drop-downs play each other

The losers bracket alternates between two types of rounds:
- **Drop-down rounds**: WB losers enter and play against LB survivors from the previous LB round
- **Reduction rounds**: If there are an odd number entering a drop-down round, a reduction round pairs LB players against each other first

This logic is the most complex part of the implementation. The bracket engine should create LB rounds one at a time as WB results come in, not pre-generate the entire structure.

## Discord Bot Changes

### `/create` command

Add format selection:
- New option: `format` (string choice: `single_elim`, `double_elim`, `round_robin`)
- Default: `single_elim` (backwards compatible)
- For `double_elim`: add optional `grand_final_advantage` boolean option (default: true)
- For `round_robin`: enforce max_players ≤ 12 at creation time

### `/start` command

Dispatch on format:
- `single_elim`: existing logic (unchanged)
- `double_elim`: call `generateDoubleElimBracket()`, create WB round 1 matches, set bracket column
- `round_robin`: call `generateRoundRobinMatches()`, create single round with all matches, DM all players their full match list

### `/result` command

No changes needed — result submission is format-agnostic. The `tryAdvanceBracket` call after result validation handles format-specific advancement.

### `/standings` command (new)

Show current standings for round robin tournaments. Not needed for bracket formats (the bracket itself shows progress), but useful for round robin where there's no visual bracket.

Output: ranked list with W/L/game differential, pending match count.

## Tournament Export Changes

### File: Python export scripts

The tournament export to `tournaments.json` needs to include:
- `bracket` field on each match (for double elim)
- `standings` array for round robin tournaments (computed at export time)
- `format`-specific metadata: `grandFinalAdvantage` for double elim

The export already includes format, matches, rounds, and players. The main addition is the `bracket` field on matches and computed standings.

## Website Changes

### Tournament detail page (`/tournament/[id]/page.tsx`)

Switch on `tournament.format`:
- `single_elim`: existing `<BracketView>` (unchanged)
- `double_elim`: new `<DoubleElimBracketView>` component
- `round_robin`: new `<RoundRobinTable>` component

### `<DoubleElimBracketView>` component

Stacked vertical layout:
1. **Winners bracket** at top — reuses existing bracket rendering logic, filtered to `bracket === 'winners'` matches
2. **Losers bracket** below — same rendering, filtered to `bracket === 'losers'`, with red accent color (#ff4444)
3. **Grand Final** at bottom — green accent (#44ff88), shows advantage status if configured

Each section has a labeled header (WINNERS BRACKET / LOSERS BRACKET / GRAND FINAL). Matches within each section are laid out by round, same as the existing single elim bracket view.

### `<RoundRobinTable>` component

Cross table (matrix grid):
- Players on both axes, sorted by current standings rank
- Cells show result: "W 2-1" (green), "L 0-2" (red), "pending" (amber), "—" on diagonal
- Final column: total match wins
- Responsive: horizontal scroll on mobile for tables wider than viewport

### Tournament list page

No changes needed — already shows format badge. The existing "Single Elimination" badge logic just needs the display names for the two new formats.

### Standings sidebar

The existing standings sidebar on the tournament detail page tallies W/L from completed matches. This works for all formats. For round robin, it's the primary ranking display. For double elim, it supplements the bracket view.

## Testing

### Bracket engine unit tests

- Double elim bracket generation: correct number of WB round 1 matches, byes handled
- Losers bracket creation: losers from WB correctly feed into LB rounds
- Grand Final: with and without advantage (reset match logic)
- Round robin: correct number of matches for N players (N=2 through N=12)
- Round robin standings: tiebreaker ordering (head-to-head, then game differential)
- Edge cases: 2-player double elim (just grand final), 2-player round robin (1 match), dropouts mid-tournament

### Integration tests

- Full double elim tournament flow: create → register → start → play all matches → verify winner
- Full round robin flow: create → register → start → submit results → verify standings
- Dropout handling: player drops, remaining matches forfeited, standings updated
- Grand Final advantage toggle: verify reset match is/isn't created based on setting

## Out of scope

- Swiss format (future feature)
- Combination formats (e.g., round robin group stage → single elim playoffs)
- Website result submission (separate feature)
- Seeding based on ladder rating (currently random shuffle, keep it that way)
