# Tabungan SDN Klagen 1

Sistem tabungan siswa sederhana untuk SDN Klagen 1. Aplikasi pencatatan
setoran dan penarikan tabungan siswa oleh guru, dengan dashboard orang tua
untuk melihat saldo dan riwayat anak.

**Status**: feature-complete, production-ready for pilot use. See
`docs/backup-and-recovery.md` and `docs/architecture.md`.

## Overview

A 22-student school savings app. One teacher records every transaction
(deposit / withdrawal). Each parent logs in to see their own child's
balance and history. Balances are derived from the transaction history —
never stored. Corrections are reversing transactions, not deletes.

## Features

- Teacher workflow: search student → quick amount or custom → save.
  Daily summary on the dashboard, full transaction history with filters.
- Parent workflow: list of children, per-child saldo and totals, history
  grouped by day.
- Withdrawal confirmation modal (native `<dialog>`).
- Correction flow: open transaction → reason → confirm → reverse.
- Inactive-student handling: moved/lulus students keep their history but
  are hidden from operational workflows.
- Single source of truth: balance is `SUM(deposit) - SUM(withdrawal)`;
  every page computes it the same way.
- Immutable transactions: no UPDATE or DELETE policy at the DB level.
- Server-time rendered in `Asia/Jakarta` so teacher and parent always agree
  on the calendar date of a transaction.

Out of scope (intentionally):

- Charts, export to Excel/PDF, notifications, payment gateway, mobile app,
  multi-school, chat, gamification. See `docs/` and the spec for the full
  rationale.

## Architecture

See [`docs/architecture.md`](./docs/architecture.md).

```
Browser → Cloudflare Pages → Astro (SSR) → Supabase (Auth + Postgres + RLS)
```

Astro talks directly to Supabase via `@supabase/supabase-js`. There is no
separate backend service.

## Tech Stack

- **Astro** 7 — UI + SSR routing (`output: 'server'`)
- **TypeScript** — strict
- **Tailwind CSS v4** — via `@tailwindcss/vite`
- **Supabase** — Postgres + Auth + RLS (`@supabase/supabase-js` 2.114)
- **Cloudflare Pages** — hosting (`@astrojs/cloudflare` 14)
- **Bun** 1.4 — package manager + runtime

## Database

Schema is in `supabase/migrations/`, run in order:

| Migration | Sprint | Adds |
|-----------|--------|------|
| `20250903120000_profiles.sql` | 0 | `profiles` table |
| `20250903120001_classes.sql` | 0 | `classes` table |
| `20250903120100_profiles_teacher_read.sql` | 1 | teacher SELECT on profiles |
| `20250903120101_classes_teacher_crud.sql` | 1 | teacher CRUD on classes |
| `20250903120102_students.sql` | 1 | `students` table + parent SELECT |
| `20250903120200_transactions.sql` | 2 | `transactions`, `create_transaction` RPC |
| `20250903120300_corrections.sql` | 5 | `correction_of`, `correct_transaction` RPC, `students.is_active` |

Foreign keys all `ON DELETE RESTRICT` so historical rows survive.

Indexes: `(student_id, created_at desc)`, `(created_at desc)`, `(created_by)`,
`(correction_of)`, `(is_active)`. Plus partial unique
`(correction_of) WHERE correction_of IS NOT NULL`.

Constraints:

- `transactions.amount > 0`
- `transactions.type IN ('deposit','withdrawal')`

RPCs:

- `create_transaction(p_student_id uuid, p_type text, p_amount numeric, p_note text)`
  — `SECURITY INVOKER`, locks student row `FOR UPDATE`, validates balance
  for withdrawals.
- `correct_transaction(p_original_id uuid, p_reason text)` — `SECURITY INVOKER`,
  locks original row `FOR UPDATE`, rejects already-corrected, rejects
  reversal that would push balance negative.

## Authentication

Supabase Auth (email + password). Session is a Supabase cookie attached to
every SSR request. `requireRole(ctx, role)` in `src/lib/supabase.ts` returns:

- `redirect('/login')` if no session.
- `redirect('/')` if role doesn't match.

Logout via `POST /api/auth/logout` (single Keluar button in Nav).

## Roles

- `teacher` — full read across profiles, students, transactions; insert on
  transactions (with `created_by = auth.uid()` check); insert on students;
  insert on classes. No update or delete anywhere on `transactions`.
- `parent` — read self profile; read own students (subquery on
  `students.parent_id = auth.uid()`); read own students' transactions.
  No write anywhere.

## RLS

All four tables have `enable row level security`. No `USING (true)`. No
policy for `anon`. Full policy table:

| Table | SELECT | INSERT | UPDATE | DELETE |
|-------|--------|--------|--------|--------|
| `profiles` | teacher: all · parent: self | none | none | none |
| `classes` | authenticated | teacher | teacher | teacher |
| `students` | teacher: all · parent: own | teacher | teacher | teacher (no UI) |
| `transactions` | teacher: all · parent: own children | teacher (with check `created_by = auth.uid()`) | none | none |

## Transaction Model

- Deposit: teacher inserts a row with `type='deposit'`.
- Withdrawal: teacher inserts a row with `type='withdrawal'`. RPC checks
  current balance (`SELECT sum(CASE WHEN type='deposit' THEN amount ELSE -amount END) ...`)
  and aborts if withdrawal would push balance below zero.
- Atomicity: both flows go through `create_transaction` RPC, which locks
  the student row with `FOR UPDATE` before reading the balance.
- Confirmation: deposit does not require explicit confirmation; withdrawal
  shows a `<dialog>` showing current saldo, saldo-after, and amount. Submit
  is disabled while in-flight.

## Correction Model

Corrections are **reversing transactions**, not deletes.

```
Original transaction (deposit Rp10.000)
    ↓ teacher clicks "Koreksi"
Correction transaction (withdrawal Rp10.000)
   correction_of = original.id
   correction_reason = "<reason text>"
   corrected_by = teacher.id
   corrected_at = now()
```

The original row stays in the table. The partial unique index on
`correction_of` ensures one correction per original. The
`correct_transaction` RPC also checks balance integrity (a deposit cannot
be reversed once its funds have been withdrawn elsewhere).

UI shows the correction as a regular transaction row labeled "Koreksi" with
a link to the reason.

## Reporting

Reports are server-rendered pages, not a separate feature.

- `/guru/transaksi` — full transaction list with date / student / type
  filters, grouped by day, capped at 500 rows. Teachers see everything.
- `/orangtua/anak/[id]` — child's full history grouped by day.

There is no `/reports` route; reports are the same pages, filtered.

## Local Development

```bash
bun install
cp .env.example .env
# fill in PUBLIC_SUPABASE_URL and PUBLIC_SUPABASE_ANON_KEY

# In a separate Supabase project (or scratch), run migrations:
#   Supabase Dashboard → SQL Editor → paste each file in
#   supabase/migrations/*.sql in order.
# Optional: supabase/seed/dev.sql for sample data (DO NOT run in production).

bun dev                       # http://localhost:4321
bun run build                 # production build → dist/
bun run typecheck             # astro check
```

## Environment Variables

```
PUBLIC_SUPABASE_URL
PUBLIC_SUPABASE_ANON_KEY
```

`.env.example` lists exactly these two. `SUPABASE_SERVICE_ROLE_KEY` is
**never** used in this codebase — RLS is the security boundary, so the
service-role key is not needed.

`.env` is gitignored. `.env.production` and `.env.local` are also
gitignored.

In Cloudflare Pages: Settings → Environment variables, set for Production
and Preview as needed.

## Deployment

Cloudflare Pages.

1. Push to GitHub.
2. Cloudflare Pages → Create application → Connect to Git.
3. Build settings:
   - Build command: `bun run build`
   - Build output: `dist`
4. Environment variables: set the two PUBLIC_* values.
5. Bindings: `SESSION` KV namespace is required for Supabase Auth SSR
   cookie session. Create one in Cloudflare Dashboard → Workers → KV →
   Create namespace, then add it under Settings → Functions → KV
   namespace bindings with the name `SESSION`.
6. Save and deploy.

## Backup & Recovery

See [`docs/backup-and-recovery.md`](./docs/backup-and-recovery.md).

Short version:

- Schema is in `supabase/migrations/`. To restore schema on a new
  Supabase project, run them all in order.
- Data lives in Supabase Postgres. Use the Supabase Dashboard's
  backup/export (plan-dependent) or `pg_dump` for cross-project copies.
- App rollback: `git revert` + push; Cloudflare auto-rebuilds.
- Schema rollback: write a new migration that reverses the change.
  Never `db reset` on production.

## Security Notes

- No `SUPABASE_SERVICE_ROLE_KEY` in source, in `.env.example`, or in any
  README or comment. Verified by grep.
- No `USING (true)` policy. Verified by grep.
- No `to anon` policy. Verified by grep.
- Error messages mapped to user-friendly Indonesian; raw Supabase error
  strings never reach the browser.
- Form submit disabled while in-flight; POST-Redirect-GET pattern prevents
  double-submit on refresh.
- Withdrawal + correction both require explicit confirmation.
- Idempotency: `correct_transaction` uses a partial unique index on
  `correction_of` so concurrent double-correction is rejected at DB level.

## Integrity & Reconciliation

- `supabase/queries/integrity-check.sql` — finds students without class,
  students with invalid parent, transactions without student or created_by,
  non-positive amounts, invalid types, orphaned corrections, duplicate
  corrections, orphan profiles. Expected output: zero rows.
- `supabase/queries/balance-reconciliation.sql` — for each student,
  prints `total_deposit`, `total_withdrawal`, `expected_balance`. Compare
  to what `/guru/siswa/[id]` and `/orangtua/anak/[id]` show; they must
  match (single source of truth: `getStudentBalance`).

## Routes

### Public

- `/` — landing
- `/login` — sign in

### Teacher

- `/guru` — operational dashboard (search → quick amount → save + daily
  summary + 10 most recent)
- `/guru/siswa` — list with search + class filter
- `/guru/siswa/new` — create student
- `/guru/siswa/[id]` — detail with saldo, totals, history, Aktifkan/Nonaktifkan
- `/guru/siswa/[id]/edit` — edit student (incl. parent reassignment)
- `/guru/kelas` — class list
- `/guru/transaksi` — transaction list with filters (Tanggal / Siswa / Jenis)
- `/guru/transaksi/[id]/koreksi` — correction form

### Parent

- `/orangtua` — list of children + saldo each
- `/orangtua/anak/[id]` — detail with saldo + totals + history
- `/orangtua/profil` — self profile + Keluar

## Structure

```
.
├── astro.config.mjs
├── package.json
├── bun.lock
├── tsconfig.json
├── .env.example
├── .gitignore
├── docs/
│   ├── architecture.md
│   ├── backup-and-recovery.md
│   └── go-live.md
├── supabase/
│   ├── migrations/                  (run in order)
│   ├── queries/
│   │   ├── integrity-check.sql
│   │   └── balance-reconciliation.sql
│   └── seed/dev.sql                 (dev only)
└── src/
    ├── components/Nav.astro
    ├── layouts/Layout.astro
    ├── middleware.ts               auth gate (Astro middleware)
    ├── lib/
    │   ├── supabase.ts              requireRole, getCurrentUser, getCurrentProfile
    │   ├── transactions.ts          getStudentBalance, createTransaction,
    │   │                             correctTransaction, formatRupiah, formatters
    │   └── quick-amounts.ts
    ├── pages/
    │   ├── api/auth/logout.ts
    │   ├── dashboard.astro          (role router)
    │   ├── index.astro
    │   ├── login.astro
    │   ├── guru/{index,kelas/...}.astro
    │   ├── guru/siswa/{index,new,[id]/...}.astro
    │   ├── guru/transaksi/{index,[id]/koreksi}.astro
    │   └── orangtua/{index,profil,anak/[id]/index}.astro
    ├── styles/global.css
    ├── env.d.ts
    └── types/database.ts
```
