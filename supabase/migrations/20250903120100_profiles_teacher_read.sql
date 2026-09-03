-- Sprint 1: extend profiles RLS so teachers can read all profiles.
-- Sprint 0 had self-only SELECT; Sprint 1 needs parent lookup for assignment.

drop policy if exists "profiles_select_own" on public.profiles;

create policy "profiles_select_self_or_teacher"
  on public.profiles
  for select
  to authenticated
  using (
    auth.uid() = id
    or exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'teacher'
    )
  );
