# Backup & Recovery

## What is where

| Asset | Location of truth | How to restore |
|-------|------------------|----------------|
| Database schema | `supabase/migrations/` (Git) | Run all `*.sql` files in order on a fresh project |
| Application code | GitHub repo | Re-deploy from `main` |
| Student data | Supabase Postgres (production) | Supabase Dashboard backup (depends on plan) |
| Auth users | Supabase Auth | Same — included in the same backup |
| Secrets | Cloudflare Pages → Environment variables | Re-enter manually |

## Source of truth

- **Schema**: the migrations in this repo are the only authoritative version
  of the schema. No out-of-band SQL has been applied to production.
- **App**: GitHub `main` is what Cloudflare Pages builds from.

## Backup

This project uses Supabase managed Postgres. The exact backup features
available depend on the Supabase plan. **Verify in your dashboard before
treating any plan-level feature as available.**

### Plan-independent

You can always:

1. Export schema via `pg_dump --schema-only` against the connection string
   from Supabase Dashboard → Database → Connection string (Direct).
2. Export data via `pg_dump --data-only` against the same connection.

These work on any plan. They are not automatic — schedule them.

### Free tier

- Daily logical backups (managed by Supabase) for 7 days.
- PITR (point-in-time recovery) is **not** available on Free.
- Manual `pg_dump` is the reliable path on Free.

### Pro tier

- Daily logical backups retained 7 days (Free) / longer on paid plans.
- PITR available (paid add-on). With PITR enabled, you can restore to any
  second within the retention window.

### Recommended for this project

Given the project size (22 students, low write rate):

1. Auth sessions live in `sb-access-token` / `sb-refresh-token` cookies —
   no KV binding needed on Cloudflare Pages.
2. On Free or Pro, schedule a weekly `pg_dump` snapshot via a cron worker,
   Supabase scheduled function, or external cron.
3. Store the dump outside Supabase (e.g., Cloudflare R2, GitHub Actions
   artifact, S3). **Never store the dump in the same Supabase project.**
4. Verify the dump by loading it into a scratch project once a quarter.

## Recovery

The general flow is the same regardless of what broke.

### Scenario A — Cloudflare deployment is broken

```
1. Fix code locally.
2. Push to GitHub main.
3. Cloudflare Pages rebuilds automatically.
4. Verify production URL.
```

If the build is the problem, Cloudflare keeps the previous deployment
live. Trigger a rollback from the dashboard (Deployments → ⋯ → Rollback).

If the schema is the problem, the migration must be fixed first:

```
1. Write a new migration that undoes or corrects the bad migration.
2. Run it manually in the Supabase SQL Editor on the live database.
3. Push the corrected migration to GitHub.
4. Redeploy.
```

Never delete a migration that has already been applied to production.
Add a new one.

### Scenario B — Supabase project is broken

```
1. Create or restore database:
   - Fresh Supabase project, OR
   - Restore from the most recent backup.
2. Run migrations in order:
   for f in supabase/migrations/*.sql; do
     psql "$DB_URL" -f "$f"
   done
3. Restore data:
   psql "$DB_URL" < backup.sql
   (or rely on Supabase's managed restore)
4. Re-create auth users in Supabase Dashboard → Authentication → Users.
   Profile rows are in `public.profiles` — restored by step 3.
5. Set environment variables on Cloudflare Pages:
   - PUBLIC_SUPABASE_URL  → new project URL
   - PUBLIC_SUPABASE_ANON_KEY → new anon key
6. Redeploy.
```

### Scenario C — Credential compromised

```
1. Rotate: Supabase Dashboard → Settings → API → Generate new anon key.
   Old anon key immediately stops working.
2. Update Cloudflare Pages environment variables.
3. Trigger redeploy (or wait for next deploy).
4. If service_role key (which we don't use) was leaked, rotate it too and
   audit SQL logs in Supabase for unauthorized activity.
5. Check Supabase Auth logs for suspicious sign-ins.
```

In this project, only `PUBLIC_SUPABASE_ANON_KEY` is used. Rotating it is
the only credential rotation needed; no `SUPABASE_SERVICE_ROLE_KEY` is in
scope.

### Scenario D — Bad data (wrong correction, wrong deposit, etc.)

Not "recovery" exactly, but covered by Sprint 5's correction feature:

1. Open the transaction on `/guru/transaksi`.
2. Click **Koreksi**.
3. Enter reason, confirm.
4. The correction creates a reverse transaction; original is preserved for
   audit.

The unique partial index on `correction_of` ensures no double-correction.
There is no UI to hard-delete a transaction. If you genuinely need to
delete a row, do it via `psql` as a one-time DBA action and document it.

## Rollback

### App rollback

```
git revert <bad-commit-sha>
git push
# Cloudflare auto-rebuilds with the reverted code.
```

For multi-commit issues, point Cloudflare at the previous deploy from the
dashboard. The previous build artifact is kept.

### Schema rollback

```
DO NOT use `supabase db reset` on production.
```

Migrations are forward-only. To "undo" a migration:

1. Write a new migration that reverses the change (e.g., `DROP COLUMN`,
   re-add constraints, etc.).
2. Test it on a scratch project.
3. Apply it via the Supabase SQL Editor with `--single-transaction` if it
   has DDL.

For data: use `correct_transaction` or a one-time `UPDATE` if the
correction mechanism doesn't apply.

## Verified before go-live

Before declaring the project production-ready, confirm:

- [ ] All migrations applied (count them: `ls supabase/migrations/*.sql | wc -l`
      on the project; run the same query against production via
      `select count(*) from supabase_migrations.schema_migrations;` if the
      project uses the Supabase CLI).
- [ ] Cloudflare Pages build is green.
- [ ] Smoke test passes against the production URL (login → deposit →
      balance).
- [ ] `.env` is not committed (check `git ls-files .env`).
- [ ] No `service_role` reference in source (grep).
- [ ] Backup destination is configured and reachable.

## Disaster checklist

If everything is on fire:

```
1. Check Cloudflare Pages status: status page + dashboard.
2. Check Supabase status: status page + dashboard.
3. If both up but app is broken → app issue → revert last deploy.
4. If Supabase is down → wait, or fall back to a read-only maintenance page.
5. After resolution, post-mortem: what broke, why, what changes so it
   doesn't recur.
```
