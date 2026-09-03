-- Sprint 0: classes table
-- Sprint 0 ships the table + RLS scaffolding only.
-- CRUD UI is intentionally deferred to Sprint 1.

create table if not exists public.classes (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  academic_year text not null,
  created_at timestamptz not null default now()
);

alter table public.classes enable row level security;

-- No policies yet. Sprint 0 keeps access service-role only;
-- teacher-facing CRUD lands in Sprint 1.
