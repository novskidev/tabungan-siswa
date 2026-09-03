-- Sprint 1: enable teacher CRUD on classes.

-- Drop placeholder if any
drop policy if exists "classes_select_teacher" on public.classes;

create policy "classes_select_authenticated"
  on public.classes
  for select
  to authenticated
  using (true);

create policy "classes_insert_teacher"
  on public.classes
  for insert
  to authenticated
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.role = 'teacher'
    )
  );

create policy "classes_update_teacher"
  on public.classes
  for update
  to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.role = 'teacher'
    )
  )
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.role = 'teacher'
    )
  );

create policy "classes_delete_teacher"
  on public.classes
  for delete
  to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.role = 'teacher'
    )
  );
