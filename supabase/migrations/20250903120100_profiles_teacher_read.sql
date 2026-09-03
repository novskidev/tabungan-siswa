-- Sprint 1: extend profiles RLS.
-- NOTE: the original version used `EXISTS (SELECT FROM profiles ...)` inside the
-- policy, which recurses into the same policy (infinite loop → login redirect
-- loop). Replaced with self-only SELECT; teacher reads all profiles via the
-- teacher CRUD path, not a recursive policy.

drop policy if exists "profiles_select_own" on public.profiles;

create policy "profiles_select_self_or_teacher"
  on public.profiles
  for select
  to authenticated
  using ((select auth.uid()) = id);
