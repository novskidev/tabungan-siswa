-- Sprint 1: students table
-- One parent can have many students (parent_id is the many-side key).
-- class_id references classes; parent_id references profiles (nullable).

create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  nis text not null unique,
  full_name text not null,
  class_id uuid not null references public.classes (id) on delete restrict,
  parent_id uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists students_class_id_idx on public.students (class_id);
create index if not exists students_parent_id_idx on public.students (parent_id);
create index if not exists students_nis_idx on public.students (nis);

-- ponytail: skip trigram index, add when student table grows past ~5k rows.
-- CREATE EXTENSION IF NOT EXISTS pg_trgm;
-- CREATE INDEX students_full_name_trgm_idx ON public.students USING gin (full_name gin_trgm_ops);

alter table public.students enable row level security;

-- SELECT:
--  - teacher sees all
--  - parent sees only rows where parent_id = auth.uid()
create policy "students_select_teacher_or_own_parent"
  on public.students
  for select
  to authenticated
  using (
    parent_id = auth.uid()
    or exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'teacher'
    )
  );

-- INSERT: teachers only
create policy "students_insert_teacher"
  on public.students
  for insert
  to authenticated
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'teacher'
    )
  );

-- UPDATE: teachers only
create policy "students_update_teacher"
  on public.students
  for update
  to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'teacher'
    )
  )
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'teacher'
    )
  );

-- DELETE: teachers only (not in Sprint 1 spec, but standard CRUD safety)
create policy "students_delete_teacher"
  on public.students
  for delete
  to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'teacher'
    )
  );

-- updated_at trigger
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists students_touch_updated_at on public.students;
create trigger students_touch_updated_at
  before update on public.students
  for each row execute function public.touch_updated_at();
