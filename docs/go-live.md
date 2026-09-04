# Go-Live Checklist

Work through these in order before declaring the project production-ready.

## 1. Production environment

- [ ] Production Supabase project exists.
- [ ] All migrations from `supabase/migrations/` have been applied in order.
      Verify by running `supabase_migrations.schema_migrations` (if using CLI)
      or `select count(*) from supabase_migrations.schema_migrations` if exposed.
- [ ] `.env` is not committed. `git ls-files .env` returns nothing.
- [ ] No `service_role` reference in source. `grep -r service_role src/`
      returns nothing.
- [ ] No real student names / NIS / phone numbers / emails in source, seed,
      migrations, or screenshots. Seed uses clearly-fake names.

## 2. Cloudflare Pages

- [ ] Production Cloudflare Pages project created.
- [ ] Connected to GitHub repo.
- [ ] Build settings:
      - Build command: `bun run build`
      - Build output: `dist`
- [ ] Environment variables (Production):
      - `PUBLIC_SUPABASE_URL` = production URL
      - `PUBLIC_SUPABASE_ANON_KEY` = production anon key
- [ ] No KV binding needed (auth uses `sb-access-token` cookies, not KV).

## 3. RLS verified

- [ ] All three tables (`profiles`, `students`, `transactions`) have
      `enable row level security`.
- [ ] No policy uses `USING (true)`.
- [ ] No table policy targets `anon` (parents go through `SECURITY DEFINER`
      RPCs only).
- [ ] `verify_student_pin` with a wrong PIN returns 0 rows; a neighbour's
      `public_code` + wrong PIN cannot read another child's history.
- [ ] Teacher INSERT on `transactions` carries `created_by = auth.uid()`.
- [ ] No UPDATE or DELETE policy exists on `transactions`.
- [ ] Run `supabase/queries/integrity-check.sql`. Expected output: zero rows.

## 4. Data

- [ ] 22 students loaded with `class_name`, `public_code`, and bcrypt
      `pin_hash` (default PIN = first digit of class ×4).
- [ ] Run `supabase/queries/balance-reconciliation.sql`. Compare each
      student's expected balance to:
      - `/guru/siswa/[id]` saldo card
      - `/siswa/[public_code]` saldo header (after entering PIN)
      They must match exactly.

## 5. Accounts

- [ ] Teacher accounts exist in `auth.users` with corresponding
      `public.profiles` rows (`role = 'teacher'`). No parent accounts —
      parents are anonymous via `(public_code, PIN)`.
- [ ] Master account (`novskidev@gmail.com`, `role = 'master'`) exists.
      Verify: `select role from public.profiles` shows `master`.
- [ ] Test teacher sign-in in production via the browser.
- [ ] Test master flow: `/master` tambah guru, `/master/profil` ganti
      password sendiri, kirim link reset ke guru, guru buka link
      `/ganti-password` dan simpan password baru.

## 6. Smoke test against production URL

- [ ] Teacher signs in.
- [ ] Teacher records a deposit of Rp 10.000 on student A.
- [ ] `/guru` shows updated saldo for student A.
- [ ] Parent flow for student A: open `/`, pick the name, enter PIN on
      `/siswa/[public_code]` — shows the same saldo.
- [ ] Wrong PIN is rejected with a generic error; no data leaks.
- [ ] Teacher records a withdrawal of Rp 5.000.
- [ ] Parent re-loads — saldo updated, history shows both rows.
- [ ] Teacher opens one of the transactions, runs Koreksi with a reason.
- [ ] Teacher list shows the correction; original row remains with Koreksi
      badge on its reverse row.
- [ ] Teacher runs `/guru/transaksi` with date = Hari Ini, siswa = A,
      jenis = Setoran. Filter returns expected rows.

## 7. Mobile QA

Test at 375 / 390 / 412px (Chrome DevTools device emulation is fine):

- [ ] Login: form is single-column, all fields visible without horizontal
      scroll.
- [ ] Teacher dashboard: search input is full-width, quick-amount buttons
      wrap cleanly.
- [ ] Withdrawal dialog: dialog fits within viewport, scrollable if needed.
- [ ] Public PIN page: saldo is the most prominent element on the card.
- [ ] Transaction history: rows do not overflow; truncate with ellipsis
      if text is long.
- [ ] Navigation bar: 4 teacher links + Keluar fit on a 375px viewport
      (text only, abbreviated if necessary).

## 8. Desktop QA

Test at 1366 / 1440 / 1920px:

- [ ] Teacher dashboard: 2-column layout (form left, summary right). On
      1920px the form column is not so wide that input boxes look stretched.
- [ ] Transaction list: filters are in a single row on ≥sm.
- [ ] No horizontal overflow at any width.

## 9. Accessibility

- [ ] Tab through `/login`, `/guru`, `/guru/siswa`, `/guru/transaksi`,
      `/`, `/siswa/[public_code]`. Every interactive element
      receives visible focus.
- [ ] Submit a form via keyboard only (no mouse).
- [ ] Open the withdrawal dialog via keyboard, dismiss with Escape, submit.
- [ ] Screen reader announces form labels (manual VoiceOver / NVDA test
      is sufficient).

## 10. Backups

- [ ] Decide on the backup mechanism (Cloudflare R2 + weekly `pg_dump`,
      or Supabase-managed PITR, or both). Document it in
      `docs/backup-and-recovery.md`.
- [ ] Verify a backup by restoring to a scratch project (quarterly).
- [ ] `docs/backup-and-recovery.md` is up to date.

## 11. README

- [ ] `README.md` lists architecture, tech stack, routes, env vars, deploy
      steps, and links to `docs/architecture.md` and
      `docs/backup-and-recovery.md`.
- [ ] No real credentials or production URLs in the README.

## 12. Rollback

- [ ] Latest commit hash recorded.
- [ ] Previous Cloudflare deployment accessible from the dashboard.
- [ ] Team knows the rollback flow: `git revert` + push, or Cloudflare
      dashboard → Deployments → Rollback.

## After go-live

- [ ] Set up monitoring (Cloudflare Pages → Analytics).
- [ ] Set up Supabase email alerts for unusual auth activity (Dashboard →
      Settings → Auth → Email alerts).
- [ ] Schedule a quarterly backup verification.

## Definition of done

All boxes checked. Move the project from "ready for pilot" to "in
production".
