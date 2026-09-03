# Architecture

```
┌──────────────────────────────────────────┐
│              Browser                     │
│  Teacher ─┐   ┌─ Parent                  │
└───────────┼───┼─────────────────────────┘
            │   │
            ▼   ▼
   ┌─────────────────────────┐
   │   Cloudflare Pages      │
   │   (static + SSR)        │
   └────────────┬────────────┘
                │
                ▼
   ┌─────────────────────────┐
   │   Astro                 │
   │   (SSR routes + APIs)   │
   └────────────┬────────────┘
                │ supabase-js (anon key)
                ▼
   ┌─────────────────────────┐
   │   Supabase              │
   │   ├── Auth (email+pwd)  │
   │   ├── PostgreSQL        │
   │   └── RLS               │
   └─────────────────────────┘
                ▲
                │ atomic RPC: create_transaction, correct_transaction
                │ read: getStudentBalance, getDailySummary, getStudentTransactions
```

## Layer responsibilities

- **Browser** — thin client. Astro ships zero JS by default; only the forms on
  `/guru` and the correction page ship ~3 KB of vanilla JS for submit-disable
  and confirmation dialogs. No hydration of state.
- **Cloudflare Pages** — hosts the Astro `output: 'server'` build. SSR routes
  are rendered on the edge; static assets (`/_astro/*`) are immutable and
  CDN-cached with long max-age.
- **Astro** — owns the entire application. Pages call Supabase directly
  through `@supabase/supabase-js`. Auth is read via the Supabase cookie
  attached to every request.
- **Supabase Auth** — email/password sign-in. Sessions are JWT-bearing
  cookies. The cookie is sent on every request; Supabase resolves it into
  `auth.uid()` inside PostgreSQL for RLS.
- **PostgreSQL** — single source of truth. Schema is in
  `supabase/migrations/`. Tables: `profiles`, `classes`, `students`,
  `transactions`. RPCs: `create_transaction`, `correct_transaction`.
- **RLS** — authorization boundary. Every table has RLS enabled. Parent
  SELECT on `transactions` is gated through a subquery on `students`. Teacher
  INSERT is gated by `created_by = auth.uid()`. No `USING (true)` anywhere.
  No policy for the `anon` role.

## Data flow

### Teacher records a deposit

```
Teacher fills form on /guru
        ↓
POST /guru (no client-side fetch)
        ↓
Astro: createTransaction(ctx, { studentId, type:'deposit', amount, note })
        ↓
Supabase RPC: create_transaction(...)
        ├─ LOCK student row (FOR UPDATE)
        ├─ INSERT transaction row
        └─ return row
        ↓
Astro: redirect 302 → /guru?saved=ID&type=deposit&amount=10000&balance=...
        ↓
Browser renders /guru with success banner
```

### Parent views history

```
Parent opens /orangtua/anak/[id]
        ↓
Astro: requireRole(ctx, 'parent') → 302 /login if anonymous
        ↓
SELECT students WHERE parent_id = auth.uid() (RLS enforces)
        ↓
SELECT transactions WHERE student_id IN (...) (RLS enforces)
        ↓
Astro renders saldo + totals + grouped history
```

## Single source of truth: balance

`balance = SUM(deposit) - SUM(withdrawal)` — derived, never stored.

The same `getStudentBalance()` helper in `src/lib/transactions.ts` is called
by:

- `/guru` — daily summary, selected-student card, daily summary cards
- `/guru/siswa/[id]` — saldo header
- `/guru/siswa` — saldo column
- `/guru/transaksi` — totals for filtered range
- `/orangtua` — saldo per anak
- `/orangtua/anak/[id]` — saldo header + total setoran/penarikan

Teacher and parent therefore see identical saldo for the same student. This
is verified by `supabase/queries/balance-reconciliation.sql`.

## Single source of truth: time

Database stores `timestamptz` (UTC). All display goes through
`APP_TZ = 'Asia/Jakarta'` formatters in `src/lib/transactions.ts`:

- `formatTimeShort` — `HH:MM`
- `formatDateLong` — `12 Januari 2026`
- `formatTimestamp` — both
- `dayKey` / `dayLabel` — calendar-day grouping pinned to Asia/Jakarta
  (so "Hari Ini" / "Kemarin" agree between teacher and parent views).

SSR runs on Cloudflare Workers whose `Date` is UTC. Pinning the formatter to
WIB keeps the two sides consistent.

## Money

- Storage: `numeric(12, 0)` — exact, no float drift, up to Rp 999,999,999,999.
- Display: `Intl.NumberFormat('id-ID', { style:'currency', currency:'IDR' })`
  — single formatter, used everywhere. No string concatenation, no
  `toLocaleString` second-formatter.

## Correction

A correction is **not a delete**. It is a new transaction row whose
`type` is the opposite of the original, with `correction_of` linking back
to the original row. The original row stays in the table with all of its
audit fields; the correction row carries `correction_reason`,
`corrected_by`, `corrected_at`. The unique partial index
`(correction_of) WHERE correction_of IS NOT NULL` ensures at most one
correction per original.

Database invariant enforced inside `correct_transaction`:

- The original exists.
- It has not already been corrected.
- The reversal would not push the student's balance below zero.
- The reason is non-empty.

All checks run inside one transaction with a `FOR UPDATE` lock on the
student row.

## Why no backend service

- Supabase RLS is the authorization boundary; moving that boundary behind
  another service would just be a re-implementation.
- `@supabase/supabase-js` runs in Cloudflare Workers without modification.
- Astro's `output: 'server'` gives us SSR with no cold-start penalty worth
  mentioning.
- A separate backend would add another deploy target, another set of secrets,
  another queueing layer — none of which this app needs at 22 students.
