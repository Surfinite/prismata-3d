# Tournament Platform Plan 3: Website Extensions

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend prismata.live with Discord OAuth login, tournament pages (list, bracket, match detail), show match pages, player profiles, and result submission forms — all consuming the tournament JSON data exported by Plan 2C.

**Architecture:** Discord OAuth uses Next.js API routes for the login/callback/logout flow, storing session data in an HTTP-only cookie (signed JWT). Tournament pages are client-side React components that fetch from `/data/tournaments.json` (static, refreshed every 60s). Result submission uses a new API route that proxies to the Data Box's SQLite (or writes to a shared JSON queue). All pages follow the existing site pattern: `'use client'` components, Tailwind 4 glass-card styling, no SSR.

**Tech Stack:** Next.js 16, React 19, TypeScript, TailwindCSS 4, shadcn/ui, jose (JWT signing)

**Spec:** `c:\libraries\prismata-3d\docs\superpowers\specs\2026-03-28-prismata-tournament-platform-design.md`

**Depends on:** Plan 2C (tournament data in `/data/tournaments.json`)

---

## File Structure

New and modified files in `<PRISMATA_LADDER_REPO>/prismata-ladder-site\`:

```
src/
├── app/
│   ├── api/
│   │   ├── auth/
│   │   │   ├── login/route.ts          # NEW: Discord OAuth redirect
│   │   │   ├── callback/route.ts       # NEW: Discord OAuth callback → set session cookie
│   │   │   ├── logout/route.ts         # NEW: Clear session cookie
│   │   │   └── me/route.ts             # NEW: Return current user from session
│   │   └── result/route.ts             # NEW: Submit replay code for a match (POST)
│   ├── tournaments/
│   │   └── page.tsx                    # NEW: Tournament list
│   ├── tournament/
│   │   └── [id]/
│   │       ├── page.tsx                # NEW: Tournament detail (bracket + standings)
│   │       └── match/
│   │           └── [matchId]/
│   │               └── page.tsx        # NEW: Match detail (replays, result, dispute)
│   ├── matches/
│   │   └── page.tsx                    # NEW: Show matches / challenges list
│   ├── match/
│   │   └── [id]/
│   │       └── page.tsx                # NEW: Challenge detail (series score, replays)
│   ├── profile/
│   │   └── [username]/
│   │       └── page.tsx                # NEW: Player tournament profile
│   ├── login/
│   │   └── page.tsx                    # NEW: Login landing page
│   └── layout.tsx                      # MODIFY: Add nav bar with tournament links + auth
├── lib/
│   ├── auth.ts                         # NEW: JWT session helpers (sign, verify, getSession)
│   └── tournament-types.ts             # NEW: TypeScript types for tournament data
└── components/
    ├── nav.tsx                          # NEW: Global navigation bar
    ├── auth-button.tsx                  # NEW: Login/logout button (client component)
    ├── bracket-view.tsx                 # NEW: Single-elim bracket visualization
    └── result-form.tsx                  # NEW: Replay code submission form
```

---

## Task 1: TypeScript Types for Tournament Data

**Files:**
- Create: `src/lib/tournament-types.ts`

- [ ] **Step 1: Create tournament types**

These match the JSON structure exported by `tournament_export.py` (Plan 2C).

```typescript
// src/lib/tournament-types.ts

export interface TournamentRules {
  time_control: number
  randomizer_count: number
  best_of?: number
  banned_units?: string[]
}

export interface TournamentSummary {
  id: number
  name: string
  description: string | null
  format: string
  rules: TournamentRules
  status: 'registration' | 'active' | 'completed' | 'cancelled'
  player_count: number
  max_players: number | null
  registration_deadline: string | null
  created_by: string | null
  created_at: string
}

export interface TournamentPlayer {
  username: string
  discord_username: string
  seed: number | null
  status: 'registered' | 'active' | 'eliminated' | 'withdrawn'
  tournament_rating: number | null
}

export interface MatchGame {
  replay_code: string
  game_number: number
  winner: string | null
}

export interface TournamentMatch {
  id: number
  player1: string | null
  player2: string | null
  winner: string | null
  status: 'pending' | 'in_progress' | 'completed' | 'disputed' | 'forfeited'
  best_of: number
  deadline: string | null
  games: MatchGame[]
}

export interface TournamentRound {
  round_number: number
  status: 'pending' | 'active' | 'completed'
  deadline: string | null
  matches: TournamentMatch[]
}

export interface StandingsEntry {
  username: string
  wins: number
  losses: number
  status: 'registered' | 'active' | 'eliminated' | 'withdrawn'
}

export interface TournamentDetail {
  id: number
  name: string
  description: string | null
  format: string
  rules: TournamentRules
  status: string
  created_at: string
  players: TournamentPlayer[]
  rounds: TournamentRound[]
  standings: StandingsEntry[]
}

export interface ChallengeGame {
  replay_code: string
  game_number: number
  winner: string | null
}

export interface Challenge {
  id: number
  challenger: string
  challenged: string
  best_of: number
  rules: TournamentRules
  status: 'pending' | 'accepted' | 'declined' | 'in_progress' | 'completed'
  score: string
  created_at: string
  games: ChallengeGame[]
}

export interface TournamentData {
  tournaments: TournamentSummary[]
  tournament_details: Record<number, TournamentDetail>
  challenges: Challenge[]
}

export interface SessionUser {
  discord_id: string
  discord_username: string
  avatar: string | null
  prismata_username: string | null
  verified: boolean
  role: string
}
```

- [ ] **Step 2: Commit**

```bash
cd <PRISMATA_LADDER_REPO>
git add prismata-ladder-site/src/lib/tournament-types.ts
git commit -m "feat(site): add TypeScript types for tournament data"
```

---

## Task 2: Auth Library (JWT Sessions)

**Files:**
- Create: `src/lib/auth.ts`

- [ ] **Step 1: Install jose**

```bash
cd <PRISMATA_LADDER_REPO>/prismata-ladder-site && npm install jose
```

- [ ] **Step 2: Create auth helpers**

```typescript
// src/lib/auth.ts
import { SignJWT, jwtVerify } from 'jose'
import { cookies } from 'next/headers'
import type { SessionUser } from './tournament-types'

const SESSION_COOKIE = 'prismata_session'
const SECRET = new TextEncoder().encode(
  process.env.SESSION_SECRET || 'dev-secret-change-in-production'
)

export async function createSession(user: SessionUser): Promise<string> {
  const token = await new SignJWT({ user })
    .setProtectedHeader({ alg: 'HS256' })
    .setExpirationTime('7d')
    .sign(SECRET)
  return token
}

export async function getSession(): Promise<SessionUser | null> {
  const cookieStore = await cookies()
  const token = cookieStore.get(SESSION_COOKIE)?.value
  if (!token) return null

  try {
    const { payload } = await jwtVerify(token, SECRET)
    return (payload as { user: SessionUser }).user
  } catch {
    return null
  }
}

export function sessionCookieOptions() {
  return {
    name: SESSION_COOKIE,
    httpOnly: true,
    secure: process.env.NODE_ENV === 'production',
    sameSite: 'lax' as const,
    path: '/',
    maxAge: 7 * 24 * 60 * 60, // 7 days
  }
}

export { SESSION_COOKIE }
```

- [ ] **Step 3: Add env vars to .env.example**

Add to the existing `.env.example` (or create if it doesn't exist):

```
DISCORD_CLIENT_ID=your-discord-client-id
DISCORD_CLIENT_SECRET=your-discord-client-secret
DISCORD_REDIRECT_URI=http://localhost:3000/api/auth/callback
SESSION_SECRET=generate-a-random-32-char-string
```

- [ ] **Step 4: Commit**

```bash
git add prismata-ladder-site/src/lib/auth.ts prismata-ladder-site/package.json prismata-ladder-site/package-lock.json
git commit -m "feat(site): add JWT session library for Discord OAuth"
```

---

## Task 3: Discord OAuth API Routes

**Files:**
- Create: `src/app/api/auth/login/route.ts`
- Create: `src/app/api/auth/callback/route.ts`
- Create: `src/app/api/auth/logout/route.ts`
- Create: `src/app/api/auth/me/route.ts`

- [ ] **Step 1: Create login route**

```typescript
// src/app/api/auth/login/route.ts
import { NextResponse } from 'next/server'

export async function GET() {
  const clientId = process.env.DISCORD_CLIENT_ID
  const redirectUri = process.env.DISCORD_REDIRECT_URI || 'http://localhost:3000/api/auth/callback'

  const params = new URLSearchParams({
    client_id: clientId!,
    redirect_uri: redirectUri,
    response_type: 'code',
    scope: 'identify',
  })

  return NextResponse.redirect(`https://discord.com/api/oauth2/authorize?${params}`)
}
```

- [ ] **Step 2: Create callback route**

```typescript
// src/app/api/auth/callback/route.ts
import { NextRequest, NextResponse } from 'next/server'
import { createSession, sessionCookieOptions, SESSION_COOKIE } from '@/lib/auth'
import type { SessionUser } from '@/lib/tournament-types'

export async function GET(request: NextRequest) {
  const code = request.nextUrl.searchParams.get('code')
  if (!code) {
    return NextResponse.redirect(new URL('/login?error=no_code', request.url))
  }

  try {
    // Exchange code for access token
    const tokenRes = await fetch('https://discord.com/api/oauth2/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: process.env.DISCORD_CLIENT_ID!,
        client_secret: process.env.DISCORD_CLIENT_SECRET!,
        grant_type: 'authorization_code',
        code,
        redirect_uri: process.env.DISCORD_REDIRECT_URI || 'http://localhost:3000/api/auth/callback',
      }),
    })

    if (!tokenRes.ok) {
      return NextResponse.redirect(new URL('/login?error=token_failed', request.url))
    }

    const tokenData = await tokenRes.json()

    // Get Discord user info
    const userRes = await fetch('https://discord.com/api/users/@me', {
      headers: { Authorization: `Bearer ${tokenData.access_token}` },
    })

    if (!userRes.ok) {
      return NextResponse.redirect(new URL('/login?error=user_failed', request.url))
    }

    const discordUser = await userRes.json()

    // Build session user — prismata_username and verified status come from
    // the tournaments.json data or a future API, not from Discord
    const sessionUser: SessionUser = {
      discord_id: discordUser.id,
      discord_username: discordUser.username,
      avatar: discordUser.avatar
        ? `https://cdn.discordapp.com/avatars/${discordUser.id}/${discordUser.avatar}.png`
        : null,
      prismata_username: null, // Will be set after verification
      verified: false,
      role: 'player',
    }

    const token = await createSession(sessionUser)
    const response = NextResponse.redirect(new URL('/', request.url))
    response.cookies.set(SESSION_COOKIE, token, sessionCookieOptions())
    return response
  } catch (error) {
    console.error('OAuth callback error:', error)
    return NextResponse.redirect(new URL('/login?error=unknown', request.url))
  }
}
```

- [ ] **Step 3: Create logout route**

```typescript
// src/app/api/auth/logout/route.ts
import { NextResponse } from 'next/server'
import { SESSION_COOKIE } from '@/lib/auth'

export async function GET(request: Request) {
  const response = NextResponse.redirect(new URL('/', request.url))
  response.cookies.delete(SESSION_COOKIE)
  return response
}
```

- [ ] **Step 4: Create me route**

```typescript
// src/app/api/auth/me/route.ts
import { NextResponse } from 'next/server'
import { getSession } from '@/lib/auth'

export async function GET() {
  const user = await getSession()
  if (!user) {
    return NextResponse.json({ user: null }, { status: 401 })
  }
  return NextResponse.json({ user })
}
```

- [ ] **Step 5: Commit**

```bash
git add prismata-ladder-site/src/app/api/auth/
git commit -m "feat(site): add Discord OAuth login/callback/logout/me API routes"
```

---

## Task 4: Navigation Bar + Auth Button

**Files:**
- Create: `src/components/nav.tsx`
- Create: `src/components/auth-button.tsx`
- Modify: `src/app/layout.tsx`

- [ ] **Step 1: Create auth button (client component)**

```typescript
// src/components/auth-button.tsx
'use client'

import { useEffect, useState } from 'react'
import type { SessionUser } from '@/lib/tournament-types'

export function AuthButton() {
  const [user, setUser] = useState<SessionUser | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    fetch('/api/auth/me')
      .then(res => res.ok ? res.json() : { user: null })
      .then(data => setUser(data.user))
      .finally(() => setLoading(false))
  }, [])

  if (loading) return null

  if (!user) {
    return (
      <a
        href="/api/auth/login"
        className="px-4 py-2 rounded-lg bg-[#5865F2] hover:bg-[#4752C4] text-white text-sm font-medium transition-colors"
      >
        Login with Discord
      </a>
    )
  }

  return (
    <div className="flex items-center gap-3">
      {user.avatar && (
        <img src={user.avatar} alt="" className="w-8 h-8 rounded-full" />
      )}
      <span className="text-sm text-[#e0f7ff]">{user.discord_username}</span>
      <a
        href="/api/auth/logout"
        className="text-xs text-[#e0f7ff]/60 hover:text-[#e0f7ff] transition-colors"
      >
        Logout
      </a>
    </div>
  )
}
```

- [ ] **Step 2: Create nav bar**

```typescript
// src/components/nav.tsx
'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { AuthButton } from './auth-button'

const links = [
  { href: '/', label: 'Ladder' },
  { href: '/tournaments', label: 'Tournaments' },
  { href: '/matches', label: 'Matches' },
  { href: '/live', label: 'Live' },
  { href: '/stats', label: 'Stats' },
]

export function Nav() {
  const pathname = usePathname()

  return (
    <nav className="sticky top-0 z-50 border-b border-[#00d4ff]/20 bg-[#050d18]/90 backdrop-blur-md">
      <div className="max-w-7xl mx-auto px-4 h-14 flex items-center justify-between">
        <div className="flex items-center gap-6">
          <Link href="/" className="text-lg font-bold text-[#00d4ff]" style={{ fontFamily: 'var(--font-orbitron)' }}>
            prismata.live
          </Link>
          <div className="hidden sm:flex items-center gap-1">
            {links.map(link => (
              <Link
                key={link.href}
                href={link.href}
                className={`px-3 py-1.5 rounded-md text-sm transition-colors ${
                  pathname === link.href
                    ? 'text-[#00d4ff] bg-[#00d4ff]/10'
                    : 'text-[#e0f7ff]/70 hover:text-[#e0f7ff] hover:bg-[#e0f7ff]/5'
                }`}
              >
                {link.label}
              </Link>
            ))}
          </div>
        </div>
        <AuthButton />
      </div>
    </nav>
  )
}
```

- [ ] **Step 3: Add Nav to layout.tsx**

In `src/app/layout.tsx`, import and add the Nav component inside the body, before `{children}`:

```typescript
import { Nav } from '@/components/nav'

// Inside the body tag, before {children}:
<Nav />
{children}
```

- [ ] **Step 4: Commit**

```bash
git add prismata-ladder-site/src/components/nav.tsx prismata-ladder-site/src/components/auth-button.tsx prismata-ladder-site/src/app/layout.tsx
git commit -m "feat(site): add navigation bar with Discord auth button"
```

---

## Task 5: Tournament List Page

**Files:**
- Create: `src/app/tournaments/page.tsx`

- [ ] **Step 1: Create tournament list page**

```typescript
// src/app/tournaments/page.tsx
'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import type { TournamentData, TournamentSummary } from '@/lib/tournament-types'

const STATUS_COLORS: Record<string, string> = {
  registration: 'bg-[#00d4ff]/20 text-[#00d4ff] border-[#00d4ff]/30',
  active: 'bg-[#00ff88]/20 text-[#00ff88] border-[#00ff88]/30',
  completed: 'bg-[#e0f7ff]/10 text-[#e0f7ff]/60 border-[#e0f7ff]/10',
}

export default function TournamentsPage() {
  const [data, setData] = useState<TournamentData | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    fetch('/data/tournaments.json')
      .then(res => res.ok ? res.json() : null)
      .then(setData)
      .finally(() => setLoading(false))
  }, [])

  if (loading) {
    return <div className="min-h-screen bg-[#050d18] flex items-center justify-center text-[#e0f7ff]/50">Loading...</div>
  }

  const tournaments = data?.tournaments || []
  const active = tournaments.filter(t => t.status === 'active')
  const registration = tournaments.filter(t => t.status === 'registration')
  const completed = tournaments.filter(t => t.status === 'completed')

  return (
    <div className="min-h-screen bg-[#050d18] text-[#e0f7ff]">
      <div className="max-w-4xl mx-auto px-4 py-8">
        <h1 className="text-3xl font-bold mb-8" style={{ fontFamily: 'var(--font-orbitron)' }}>
          Tournaments
        </h1>

        {active.length > 0 && (
          <Section title="Active" tournaments={active} />
        )}
        {registration.length > 0 && (
          <Section title="Open for Registration" tournaments={registration} />
        )}
        {completed.length > 0 && (
          <Section title="Completed" tournaments={completed} />
        )}
        {tournaments.length === 0 && (
          <p className="text-[#e0f7ff]/50 text-center py-16">No tournaments yet.</p>
        )}
      </div>
    </div>
  )
}

function Section({ title, tournaments }: { title: string; tournaments: TournamentSummary[] }) {
  return (
    <div className="mb-8">
      <h2 className="text-lg font-semibold mb-4 text-[#e0f7ff]/80">{title}</h2>
      <div className="space-y-3">
        {tournaments.map(t => (
          <TournamentCard key={t.id} tournament={t} />
        ))}
      </div>
    </div>
  )
}

function TournamentCard({ tournament: t }: { tournament: TournamentSummary }) {
  const statusClass = STATUS_COLORS[t.status] || STATUS_COLORS.completed

  return (
    <Link
      href={`/tournament/${t.id}`}
      className="block glass-card rounded-xl p-5 hover:ring-1 hover:ring-[#00d4ff]/30 transition-all"
    >
      <div className="flex items-start justify-between gap-4">
        <div>
          <h3 className="text-lg font-bold">{t.name}</h3>
          {t.description && (
            <p className="text-sm text-[#e0f7ff]/50 mt-1">{t.description}</p>
          )}
          <div className="flex items-center gap-3 mt-2 text-sm text-[#e0f7ff]/60">
            <span>{t.format.replace('_', ' ')}</span>
            <span>·</span>
            <span>{t.rules.time_control}s</span>
            <span>·</span>
            <span>Base +{t.rules.randomizer_count}</span>
            {t.rules.best_of && t.rules.best_of > 1 && (
              <>
                <span>·</span>
                <span>Bo{t.rules.best_of}</span>
              </>
            )}
          </div>
        </div>
        <div className="flex flex-col items-end gap-2">
          <span className={`px-2 py-0.5 rounded text-xs border ${statusClass}`}>
            {t.status}
          </span>
          <span className="text-sm text-[#e0f7ff]/50">
            {t.player_count} player{t.player_count !== 1 ? 's' : ''}
            {t.max_players ? ` / ${t.max_players}` : ''}
          </span>
        </div>
      </div>
    </Link>
  )
}
```

- [ ] **Step 2: Commit**

```bash
git add prismata-ladder-site/src/app/tournaments/page.tsx
git commit -m "feat(site): add tournament list page"
```

---

## Task 6: Tournament Detail Page (Bracket + Standings)

**Files:**
- Create: `src/app/tournament/[id]/page.tsx`
- Create: `src/components/bracket-view.tsx`

- [ ] **Step 1: Create bracket view component**

```typescript
// src/components/bracket-view.tsx
'use client'

import type { TournamentRound, TournamentMatch } from '@/lib/tournament-types'
import Link from 'next/link'

const STATUS_ICON: Record<string, string> = {
  completed: '✅',
  forfeited: '❌',
  disputed: '⚠️',
  pending: '⏳',
  in_progress: '🔵',
}

export function BracketView({ rounds, tournamentId }: { rounds: TournamentRound[]; tournamentId: number }) {
  if (rounds.length === 0) {
    return <p className="text-[#e0f7ff]/50">No matches yet.</p>
  }

  return (
    <div className="space-y-6">
      {rounds.map(round => (
        <div key={round.round_number}>
          <h3 className="text-sm font-semibold text-[#e0f7ff]/60 mb-3">
            Round {round.round_number}
            {round.deadline && (
              <span className="ml-2 text-xs text-[#e0f7ff]/40">
                Deadline: {new Date(round.deadline).toLocaleDateString()}
              </span>
            )}
          </h3>
          <div className="space-y-2">
            {round.matches.map(match => (
              <MatchRow key={match.id} match={match} tournamentId={tournamentId} />
            ))}
          </div>
        </div>
      ))}
    </div>
  )
}

function MatchRow({ match, tournamentId }: { match: TournamentMatch; tournamentId: number }) {
  const icon = STATUS_ICON[match.status] || '⏳'
  const p2Label = match.player2 || 'bye'
  const winnerHighlight = (name: string | null) =>
    match.winner && name?.toLowerCase() === match.winner.toLowerCase()
      ? 'text-[#00ff88] font-bold'
      : ''

  return (
    <Link
      href={`/tournament/${tournamentId}/match/${match.id}`}
      className="flex items-center gap-3 glass-card rounded-lg px-4 py-3 hover:ring-1 hover:ring-[#00d4ff]/30 transition-all text-sm"
    >
      <span>{icon}</span>
      <span className={winnerHighlight(match.player1)}>{match.player1}</span>
      <span className="text-[#e0f7ff]/30">vs</span>
      <span className={`${winnerHighlight(match.player2)} ${!match.player2 ? 'text-[#e0f7ff]/30 italic' : ''}`}>
        {p2Label}
      </span>
      {match.winner && (
        <span className="ml-auto text-xs text-[#00ff88]">→ {match.winner}</span>
      )}
      {match.games.length > 0 && (
        <span className="text-xs text-[#e0f7ff]/40">
          ({match.games.length} game{match.games.length !== 1 ? 's' : ''})
        </span>
      )}
    </Link>
  )
}
```

- [ ] **Step 2: Create tournament detail page**

```typescript
// src/app/tournament/[id]/page.tsx
'use client'

import { useEffect, useState } from 'react'
import { useParams } from 'next/navigation'
import type { TournamentData, TournamentDetail } from '@/lib/tournament-types'
import { BracketView } from '@/components/bracket-view'

export default function TournamentDetailPage() {
  const params = useParams()
  const id = Number(params.id)
  const [tournament, setTournament] = useState<TournamentDetail | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    fetch('/data/tournaments.json')
      .then(res => res.ok ? res.json() : null)
      .then((data: TournamentData | null) => {
        if (data?.tournament_details?.[id]) {
          setTournament(data.tournament_details[id])
        }
      })
      .finally(() => setLoading(false))
  }, [id])

  if (loading) {
    return <div className="min-h-screen bg-[#050d18] flex items-center justify-center text-[#e0f7ff]/50">Loading...</div>
  }

  if (!tournament) {
    return <div className="min-h-screen bg-[#050d18] flex items-center justify-center text-[#e0f7ff]/50">Tournament not found.</div>
  }

  const rules = tournament.rules

  return (
    <div className="min-h-screen bg-[#050d18] text-[#e0f7ff]">
      <div className="max-w-4xl mx-auto px-4 py-8">
        <h1 className="text-3xl font-bold mb-2" style={{ fontFamily: 'var(--font-orbitron)' }}>
          {tournament.name}
        </h1>
        {tournament.description && (
          <p className="text-[#e0f7ff]/50 mb-4">{tournament.description}</p>
        )}

        <div className="flex flex-wrap gap-3 mb-8 text-sm text-[#e0f7ff]/60">
          <span className="px-2 py-0.5 rounded bg-[#e0f7ff]/10">{tournament.format.replace('_', ' ')}</span>
          <span>{rules.time_control}s</span>
          <span>Base +{rules.randomizer_count}</span>
          {rules.best_of && rules.best_of > 1 && <span>Bo{rules.best_of}</span>}
          <span>{tournament.players.length} players</span>
          <span className="capitalize">{tournament.status}</span>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
          {/* Bracket */}
          <div className="lg:col-span-2">
            <h2 className="text-lg font-semibold mb-4">Bracket</h2>
            <BracketView rounds={tournament.rounds} tournamentId={tournament.id} />
          </div>

          {/* Standings */}
          <div>
            <h2 className="text-lg font-semibold mb-4">Standings</h2>
            <div className="glass-card rounded-xl p-4">
              {tournament.standings.length === 0 ? (
                <p className="text-sm text-[#e0f7ff]/50">No results yet.</p>
              ) : (
                <div className="space-y-2">
                  {tournament.standings.map((s, i) => (
                    <div
                      key={s.username}
                      className={`flex items-center justify-between text-sm px-3 py-2 rounded-lg ${
                        s.status === 'eliminated' ? 'opacity-50' : ''
                      }`}
                    >
                      <div className="flex items-center gap-2">
                        <span className="text-[#e0f7ff]/40 w-5">{i + 1}.</span>
                        <span>{s.username}</span>
                        {s.status === 'eliminated' && (
                          <span className="text-xs text-[#ff6b6b]">out</span>
                        )}
                      </div>
                      <span className="text-[#e0f7ff]/60">
                        {s.wins}W / {s.losses}L
                      </span>
                    </div>
                  ))}
                </div>
              )}
            </div>

            {/* Players list (for registration) */}
            {tournament.status === 'registration' && (
              <div className="mt-6">
                <h2 className="text-lg font-semibold mb-4">Registered Players</h2>
                <div className="glass-card rounded-xl p-4 space-y-1">
                  {tournament.players.map(p => (
                    <div key={p.username} className="text-sm text-[#e0f7ff]/70">
                      {p.username}
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}
```

- [ ] **Step 3: Commit**

```bash
git add prismata-ladder-site/src/app/tournament/ prismata-ladder-site/src/components/bracket-view.tsx
git commit -m "feat(site): add tournament detail page with bracket and standings"
```

---

## Task 7: Match Detail Page

**Files:**
- Create: `src/app/tournament/[id]/match/[matchId]/page.tsx`

- [ ] **Step 1: Create match detail page**

```typescript
// src/app/tournament/[id]/match/[matchId]/page.tsx
'use client'

import { useEffect, useState } from 'react'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import type { TournamentData, TournamentMatch } from '@/lib/tournament-types'

export default function MatchDetailPage() {
  const params = useParams()
  const tournamentId = Number(params.id)
  const matchId = Number(params.matchId)
  const [match, setMatch] = useState<TournamentMatch | null>(null)
  const [tournamentName, setTournamentName] = useState('')
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    fetch('/data/tournaments.json')
      .then(res => res.ok ? res.json() : null)
      .then((data: TournamentData | null) => {
        const detail = data?.tournament_details?.[tournamentId]
        if (detail) {
          setTournamentName(detail.name)
          for (const round of detail.rounds) {
            const found = round.matches.find(m => m.id === matchId)
            if (found) { setMatch(found); break }
          }
        }
      })
      .finally(() => setLoading(false))
  }, [tournamentId, matchId])

  if (loading) {
    return <div className="min-h-screen bg-[#050d18] flex items-center justify-center text-[#e0f7ff]/50">Loading...</div>
  }

  if (!match) {
    return <div className="min-h-screen bg-[#050d18] flex items-center justify-center text-[#e0f7ff]/50">Match not found.</div>
  }

  const p1Wins = match.games.filter(g => g.winner?.toLowerCase() === match.player1?.toLowerCase()).length
  const p2Wins = match.games.filter(g => g.winner?.toLowerCase() === match.player2?.toLowerCase()).length

  return (
    <div className="min-h-screen bg-[#050d18] text-[#e0f7ff]">
      <div className="max-w-2xl mx-auto px-4 py-8">
        <Link href={`/tournament/${tournamentId}`} className="text-sm text-[#00d4ff] hover:underline mb-4 block">
          ← {tournamentName}
        </Link>

        <div className="glass-card rounded-xl p-6">
          <div className="text-center mb-6">
            <h1 className="text-2xl font-bold mb-2" style={{ fontFamily: 'var(--font-orbitron)' }}>
              {match.player1 || '?'} vs {match.player2 || 'bye'}
            </h1>
            {match.best_of > 1 && (
              <p className="text-lg text-[#e0f7ff]/70">
                <span className={p1Wins > p2Wins ? 'text-[#00ff88] font-bold' : ''}>{p1Wins}</span>
                <span className="text-[#e0f7ff]/30"> - </span>
                <span className={p2Wins > p1Wins ? 'text-[#00ff88] font-bold' : ''}>{p2Wins}</span>
              </p>
            )}
            {match.winner && (
              <p className="text-[#00ff88] mt-2">Winner: {match.winner}</p>
            )}
            {match.status === 'disputed' && (
              <p className="text-[#ffd700] mt-2">⚠️ Disputed — under organizer review</p>
            )}
          </div>

          {match.games.length > 0 && (
            <div>
              <h2 className="text-sm font-semibold text-[#e0f7ff]/60 mb-3">Games</h2>
              <div className="space-y-2">
                {match.games.map(game => (
                  <Link
                    key={game.replay_code}
                    href={`/replay/${game.replay_code}`}
                    className="flex items-center justify-between glass-card rounded-lg px-4 py-3 hover:ring-1 hover:ring-[#00d4ff]/30 transition-all text-sm"
                  >
                    <span>Game {game.game_number}</span>
                    <span className="text-[#00d4ff] font-mono">{game.replay_code}</span>
                    {game.winner && (
                      <span className="text-[#00ff88]">{game.winner} wins</span>
                    )}
                  </Link>
                ))}
              </div>
            </div>
          )}

          {match.status === 'pending' && (
            <p className="text-center text-[#e0f7ff]/40 mt-6 text-sm">
              Match not yet played. Submit results via <code>/result</code> in Discord.
            </p>
          )}
        </div>
      </div>
    </div>
  )
}
```

- [ ] **Step 2: Commit**

```bash
git add prismata-ladder-site/src/app/tournament/
git commit -m "feat(site): add match detail page with replay links"
```

---

## Task 8: Show Matches Pages

**Files:**
- Create: `src/app/matches/page.tsx`
- Create: `src/app/match/[id]/page.tsx`

- [ ] **Step 1: Create matches list page**

```typescript
// src/app/matches/page.tsx
'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import type { TournamentData, Challenge } from '@/lib/tournament-types'

export default function MatchesPage() {
  const [challenges, setChallenges] = useState<Challenge[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    fetch('/data/tournaments.json')
      .then(res => res.ok ? res.json() : null)
      .then((data: TournamentData | null) => setChallenges(data?.challenges || []))
      .finally(() => setLoading(false))
  }, [])

  if (loading) {
    return <div className="min-h-screen bg-[#050d18] flex items-center justify-center text-[#e0f7ff]/50">Loading...</div>
  }

  return (
    <div className="min-h-screen bg-[#050d18] text-[#e0f7ff]">
      <div className="max-w-4xl mx-auto px-4 py-8">
        <h1 className="text-3xl font-bold mb-8" style={{ fontFamily: 'var(--font-orbitron)' }}>
          Show Matches
        </h1>

        {challenges.length === 0 ? (
          <p className="text-[#e0f7ff]/50 text-center py-16">No show matches yet. Use <code>/challenge</code> in Discord to start one.</p>
        ) : (
          <div className="space-y-3">
            {challenges.map(c => (
              <Link
                key={c.id}
                href={`/match/${c.id}`}
                className="block glass-card rounded-xl p-5 hover:ring-1 hover:ring-[#00d4ff]/30 transition-all"
              >
                <div className="flex items-center justify-between">
                  <div>
                    <span className="font-bold">{c.challenger}</span>
                    <span className="text-[#e0f7ff]/30 mx-2">vs</span>
                    <span className="font-bold">{c.challenged}</span>
                    <span className="ml-3 text-sm text-[#e0f7ff]/50">Bo{c.best_of}</span>
                  </div>
                  <div className="flex items-center gap-3">
                    <span className="text-lg font-mono">{c.score}</span>
                    <span className={`px-2 py-0.5 rounded text-xs ${
                      c.status === 'completed' ? 'bg-[#00ff88]/20 text-[#00ff88]' :
                      c.status === 'in_progress' ? 'bg-[#00d4ff]/20 text-[#00d4ff]' :
                      'bg-[#e0f7ff]/10 text-[#e0f7ff]/60'
                    }`}>
                      {c.status}
                    </span>
                  </div>
                </div>
              </Link>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
```

- [ ] **Step 2: Create challenge detail page**

```typescript
// src/app/match/[id]/page.tsx
'use client'

import { useEffect, useState } from 'react'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import type { TournamentData, Challenge } from '@/lib/tournament-types'

export default function ChallengeDetailPage() {
  const params = useParams()
  const id = Number(params.id)
  const [challenge, setChallenge] = useState<Challenge | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    fetch('/data/tournaments.json')
      .then(res => res.ok ? res.json() : null)
      .then((data: TournamentData | null) => {
        const found = data?.challenges?.find(c => c.id === id)
        setChallenge(found || null)
      })
      .finally(() => setLoading(false))
  }, [id])

  if (loading) {
    return <div className="min-h-screen bg-[#050d18] flex items-center justify-center text-[#e0f7ff]/50">Loading...</div>
  }

  if (!challenge) {
    return <div className="min-h-screen bg-[#050d18] flex items-center justify-center text-[#e0f7ff]/50">Match not found.</div>
  }

  return (
    <div className="min-h-screen bg-[#050d18] text-[#e0f7ff]">
      <div className="max-w-2xl mx-auto px-4 py-8">
        <Link href="/matches" className="text-sm text-[#00d4ff] hover:underline mb-4 block">
          ← Show Matches
        </Link>

        <div className="glass-card rounded-xl p-6">
          <div className="text-center mb-6">
            <h1 className="text-2xl font-bold mb-2" style={{ fontFamily: 'var(--font-orbitron)' }}>
              {challenge.challenger} vs {challenge.challenged}
            </h1>
            <p className="text-3xl font-mono font-bold text-[#00d4ff]">{challenge.score}</p>
            <p className="text-sm text-[#e0f7ff]/50 mt-1">Best of {challenge.best_of}</p>
          </div>

          {challenge.games.length > 0 && (
            <div>
              <h2 className="text-sm font-semibold text-[#e0f7ff]/60 mb-3">Games</h2>
              <div className="space-y-2">
                {challenge.games.map(game => (
                  <Link
                    key={game.replay_code}
                    href={`/replay/${game.replay_code}`}
                    className="flex items-center justify-between glass-card rounded-lg px-4 py-3 hover:ring-1 hover:ring-[#00d4ff]/30 transition-all text-sm"
                  >
                    <span>Game {game.game_number}</span>
                    <span className="text-[#00d4ff] font-mono">{game.replay_code}</span>
                    {game.winner && (
                      <span className="text-[#00ff88]">{game.winner} wins</span>
                    )}
                  </Link>
                ))}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
```

- [ ] **Step 3: Commit**

```bash
git add prismata-ladder-site/src/app/matches/ prismata-ladder-site/src/app/match/
git commit -m "feat(site): add show matches list and detail pages"
```

---

## Task 9: Login Page

**Files:**
- Create: `src/app/login/page.tsx`

- [ ] **Step 1: Create login page**

```typescript
// src/app/login/page.tsx
'use client'

import { useSearchParams } from 'next/navigation'
import { Suspense } from 'react'

function LoginContent() {
  const searchParams = useSearchParams()
  const error = searchParams.get('error')

  return (
    <div className="min-h-screen bg-[#050d18] text-[#e0f7ff] flex items-center justify-center">
      <div className="glass-card rounded-xl p-8 max-w-md w-full text-center">
        <h1 className="text-2xl font-bold mb-4" style={{ fontFamily: 'var(--font-orbitron)' }}>
          Login to Prismata Live
        </h1>
        <p className="text-[#e0f7ff]/60 mb-6">
          Sign in with Discord to join tournaments, challenge players, and submit results.
        </p>

        {error && (
          <div className="mb-4 p-3 rounded-lg bg-[#ff3366]/20 text-[#ff6b6b] text-sm">
            Login failed. Please try again.
          </div>
        )}

        <a
          href="/api/auth/login"
          className="inline-flex items-center gap-2 px-6 py-3 rounded-lg bg-[#5865F2] hover:bg-[#4752C4] text-white font-medium transition-colors"
        >
          <svg width="20" height="20" viewBox="0 0 71 55" fill="currentColor">
            <path d="M60.1 4.9A58.5 58.5 0 0 0 45.4.2a.2.2 0 0 0-.2.1 40.8 40.8 0 0 0-1.8 3.7 54 54 0 0 0-16.2 0A39.2 39.2 0 0 0 25.4.3a.2.2 0 0 0-.2-.1A58.4 58.4 0 0 0 10.5 4.9a.2.2 0 0 0-.1.1C1.5 18.7-.9 32.2.3 45.5v.2a58.7 58.7 0 0 0 17.7 9a.2.2 0 0 0 .3-.1 42 42 0 0 0 3.6-5.9.2.2 0 0 0-.1-.3 38.7 38.7 0 0 1-5.5-2.6.2.2 0 0 1 0-.4l1.1-.9a.2.2 0 0 1 .2 0 41.9 41.9 0 0 0 35.6 0 .2.2 0 0 1 .2 0l1.1.9a.2.2 0 0 1 0 .3 36.3 36.3 0 0 1-5.5 2.7.2.2 0 0 0-.1.3 47.2 47.2 0 0 0 3.6 5.8.2.2 0 0 0 .2.1A58.5 58.5 0 0 0 70.5 45.7v-.2c1.4-15-2.3-28-9.8-39.6a.2.2 0 0 0-.1-.1zM23.7 37.3c-3.4 0-6.3-3.2-6.3-7s2.8-7 6.3-7 6.3 3.1 6.3 7-2.8 7-6.3 7zm23.2 0c-3.4 0-6.3-3.2-6.3-7s2.8-7 6.3-7 6.4 3.1 6.3 7-2.8 7-6.3 7z"/>
          </svg>
          Login with Discord
        </a>

        <p className="text-xs text-[#e0f7ff]/40 mt-4">
          Browsing the ladder and watching replays doesn&apos;t require login.
        </p>
      </div>
    </div>
  )
}

export default function LoginPage() {
  return (
    <Suspense fallback={<div className="min-h-screen bg-[#050d18]" />}>
      <LoginContent />
    </Suspense>
  )
}
```

- [ ] **Step 2: Commit**

```bash
git add prismata-ladder-site/src/app/login/
git commit -m "feat(site): add login page with Discord OAuth button"
```

---

## Task 10: Vercel Config Update + Build Test

**Files:**
- Modify: `prismata-ladder-site/vercel.json`

- [ ] **Step 1: Add no-cache header for tournaments.json**

```json
{
  "source": "/data/tournaments.json",
  "headers": [
    { "key": "Cache-Control", "value": "no-cache, no-store, must-revalidate" }
  ]
}
```

Add this to the `headers` array in `vercel.json`, alongside the existing `api.json` entry.

- [ ] **Step 2: Test build**

```bash
cd <PRISMATA_LADDER_REPO>/prismata-ladder-site && npm run build
```

Expected: Build succeeds with no errors.

- [ ] **Step 3: Run existing tests**

```bash
npm run test
```

Expected: Existing tests pass (new pages are client components, no unit tests needed for them).

- [ ] **Step 4: Commit**

```bash
git add prismata-ladder-site/vercel.json
git commit -m "feat(site): add tournaments.json cache headers + verify build"
```

---

## Summary

After completing Plan 3, prismata.live has:

- **Discord OAuth** — login/logout via API routes, JWT session cookie, auth button in nav
- **Navigation bar** — sticky top nav with links to Ladder, Tournaments, Matches, Live, Stats
- **Tournament list** (`/tournaments`) — active, registration, and completed tournaments
- **Tournament detail** (`/tournament/[id]`) — bracket view with match status icons + standings sidebar
- **Match detail** (`/tournament/[id]/match/[matchId]`) — series score, replay links, dispute status
- **Show matches** (`/matches`, `/match/[id]`) — challenge list and detail pages
- **Login page** (`/login`) — Discord OAuth with error handling
- **TypeScript types** for all tournament data structures

**Not in this plan (future):**
- Player tournament profile page (`/profile/[username]`) — deferred, similar to existing `/players/[name]`
- Account verification page (`/verify`) — verification is Discord-only for now
- Result submission form — results submitted via Discord bot `/result` command
- Mobile-responsive nav (hamburger menu)
