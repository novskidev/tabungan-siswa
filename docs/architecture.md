# Architecture

```
┌──────────────────────────────────────────┐
│              Browser                     │
│  Teacher ─┐   ┌─ Parent (anonymous, PIN)  │
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
   │   ├── Auth (teacher only) │
   │   ├── PostgreSQL          │
   │   └── RLS                 │
   └─────────────────────────┘
                ▲
                │ atomic RPC: create_transaction, correct_transaction,
                │   create_student, reset_student_pin
                │ anon-safe RPC: get_active_students, verify_student_pin,
                │   get_student_history
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
- **Supabase Auth** — teacher + master email/password sign-in. Sessions are
  JWT-bearing cookies. The cookie is sent on every request; Supabase
  resolves it into `auth.uid()` inside PostgreSQL for RLS. Parents never
  log in — they open `/siswa/[public_code]` and enter a 4-digit PIN.
- **Roles** — `teacher` (operasional tabungan) dan `master` (Novski: semua
  hak teacher + kelola guru di `/master` + profil di `/master/profil`).
  Master menambah guru via Supabase `signUp` (anon key, tanpa service key),
  reset password guru via `resetPasswordForEmail` (link ke `/ganti-password`),
  ganti password sendiri via `auth.updateUser`. Daftar guru via
  `SECURITY DEFINER` `list_teachers()` — `profiles` SELECT tetap self-only
  supaya tidak ada login loop.
- **PostgreSQL** — single source of truth. Schema is in
  `supabase/migrations/`. Tables: `profiles` (teacher-only), `students`
  (`class_name`, `public_code`, bcrypt `pin_hash`), `transactions`.
  Teacher RPCs: `create_transaction`, `correct_transaction`,
  `create_student`, `reset_student_pin`, `reset_student_balance`,
  `delete_student`. Master RPCs: `list_teachers`, `create_teacher_profile`,
  `lookup_teacher_email`. Anon-safe RPCs:
  `get_active_students`, `verify_student_pin`, `get_student_history`.
- **RLS** — authorization boundary. Every table has RLS enabled. Teacher
  INSERT is gated by `created_by = auth.uid()`. No `USING (true)` anywhere.
  No table policy for the `anon` role — anonymous parents reach data only
  through the three `SECURITY DEFINER` RPCs, which verify the PIN
  (`extensions.crypt`) before returning anything.

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

### Parent views history (anonymous, PIN-gated)

```
Parent opens / → picks child name → /siswa/[public_code]
        ↓
POST PIN (no client-side fetch)
        ↓
Astro: rpc verify_student_pin(p_code, p_pin)
  → bcrypt check inside SECURITY DEFINER function;
    wrong PIN returns zero rows (generic "PIN salah" message)
        ↓
Astro: rpc get_student_history(p_code, p_pin) (same PIN re-verified)
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
- `/siswa/[public_code]` — saldo header + total setoran/penarikan (PIN-gated)

Teacher page and public PIN page therefore see identical saldo for the same
student. This
is verified by `supabase/queries/balance-reconciliation.sql`.

## Single source of truth: time

Database stores `timestamptz` (UTC). All display goes through
`APP_TZ = 'Asia/Jakarta'` formatters in `src/lib/transactions.ts`:

- `formatTimeShort` — `HH:MM`
- `formatDateLong` — `12 Januari 2026`
- `formatTimestamp` — both
- `dayKey` / `dayLabel` — calendar-day grouping pinned to Asia/Jakarta
  (so "Hari Ini" / "Kemarin" agree between teacher and public PIN views).

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
