-- Sprint 0: profiles table
-- Each profile is linked 1:1 to an auth.users row.

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  role text not null check (role in ('teacher', 'parent')),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Read: a logged-in user can only read their own profile.
create policy "profiles_select_own"
  on public.profiles
  for select
  to authenticated
  using ((select auth.uid()) = id);

-- Update: a logged-in user can only update their own profile.
create policy "profiles_update_own"
  on public.profiles
  for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- Insert is intentionally restricted to the service role / trigger flows.
-- No insert policy for the `authenticated` role keeps user self-signup locked down
-- until a teacher-driven flow is built (Sprint 1+).
