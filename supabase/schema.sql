-- Canonical schema snapshot (MVP: teacher-only login, anonymous parents via PIN).
-- Source of truth for day-to-day work is supabase/migrations/*.sql.
-- This file mirrors them so a fresh project can be replayed in file order,
-- except the guarded backfill pieces that only make sense on live data.
-- Last synced: teacher class scope 20250904000005_teacher_class_scope.sql.

create extension if not exists pgcrypto with schema extensions;

-- ---------- profiles (teacher + master) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  role text not null check (role in ('teacher', 'master')),
  created_at timestamptz not null default now()
);

-- One class per teacher ('1'-'6'); null until master assigns. Master sees all.
alter table public.profiles
  add column if not exists class_name text;
alter table public.profiles
  drop constraint if exists profiles_class_name_check;
alter table public.profiles
  add constraint profiles_class_name_check
  check (class_name is null or class_name ~ '^[1-6]$');

alter table public.profiles enable row level security;

drop policy if exists "profiles_select_own" on public.profiles;

create policy "profiles_select_self_or_teacher"
  on public.profiles
  for select
  to authenticated
  using ((select auth.uid()) = id);

create policy "profiles_update_own"
  on public.profiles
  for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- ---------- students (public_code + PIN, no classes/parent tables) ----------
create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  nis text unique,
  full_name text not null,
  class_name text not null,
  public_code text unique not null,
  pin_hash text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists students_public_code_idx on public.students (public_code);
create index if not exists students_is_active_idx on public.students (is_active);
create unique index if not exists students_nis_idx on public.students (nis);

alter table public.students enable row level security;

drop policy if exists "students_teacher_all" on public.students;

create policy "students_teacher_all"
  on public.students
  for all
  to authenticated
  using (
    exists (select 1 from public.profiles p
            where p.id = (select auth.uid())
              and (p.role = 'master'
                   or (p.role = 'teacher' and p.class_name = students.class_name)))
  )
  with check (
    exists (select 1 from public.profiles p
            where p.id = (select auth.uid())
              and (p.role = 'master'
                   or (p.role = 'teacher' and p.class_name = students.class_name)))
  );

revoke all on public.students from anon;
grant select, insert, update, delete on public.students to authenticated;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
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

-- ---------- transactions ----------
create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students (id) on delete restrict,
  type text not null check (type in ('deposit', 'withdrawal')),
  amount numeric(12, 0) not null check (amount > 0),
  note text,
  created_by uuid not null references public.profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  correction_of uuid references public.transactions (id) on delete restrict,
  correction_reason text,
  corrected_by uuid references public.profiles (id) on delete restrict,
  corrected_at timestamptz
);

create unique index if not exists transactions_correction_of_unique
  on public.transactions (correction_of)
  where correction_of is not null;

create index if not exists transactions_correction_of_idx
  on public.transactions (correction_of);

create index if not exists transactions_student_id_created_at_idx
  on public.transactions (student_id, created_at desc);

create index if not exists transactions_created_at_idx
  on public.transactions (created_at desc);

create index if not exists transactions_created_by_idx
  on public.transactions (created_by);

alter table public.transactions enable row level security;

drop policy if exists "transactions_teacher_select" on public.transactions;
drop policy if exists "transactions_teacher_insert" on public.transactions;

create policy "transactions_teacher_select"
  on public.transactions
  for select
  to authenticated
  using (
    exists (select 1 from public.profiles p
            where p.id = (select auth.uid()) and p.role = 'master')
    or exists (select 1 from public.students s where s.id = student_id)
  );

create policy "transactions_teacher_insert"
  on public.transactions
  for insert
  to authenticated
  with check (
    created_by = (select auth.uid())
    and exists (select 1 from public.students s where s.id = student_id)
  );

revoke all on public.transactions from anon;
grant select, insert on public.transactions to authenticated;

-- ---------- teacher RPCs ----------
-- (Full bodies live in their migration files; signatures repeated here.)

-- create_transaction(uuid, text, numeric, text): teacher-only atomic insert
-- with balance check. See 20250903120200_transactions.sql.
grant execute on function public.create_transaction(uuid, text, numeric, text)
  to authenticated;

-- correct_transaction(uuid, text): teacher-only compensating reversal.
-- See 20250903120300_corrections.sql.
grant execute on function public.correct_transaction(uuid, text)
  to authenticated;

-- create_student(text, text, text): teacher-only, generates public_code +
-- bcrypt PIN; teacher locked to own class. See 20250904000005.
grant execute on function public.create_student(text, text, text)
  to authenticated;

-- reset_student_pin(uuid): teacher/master PIN reset to class default.
-- See 20250904000000_mvp_public_pin.sql.
grant execute on function public.reset_student_pin(uuid)
  to authenticated;

-- delete_student(uuid): teacher/master student+history delete (testing).
-- See 20250904000002_delete_student.sql.
revoke all on function public.delete_student(uuid) from public;
grant execute on function public.delete_student(uuid) to authenticated;

-- reset_student_balance(uuid): teacher/master testing reset.
-- See 20250904000001_reset_balance.sql.
revoke all on function public.reset_student_balance(uuid) from public;
grant execute on function public.reset_student_balance(uuid) to authenticated;

-- ---------- master RPCs ----------
-- list_teachers(): master-only teacher list (SECURITY DEFINER, incl class).
-- create_teacher_profile(uuid, text, text): master-only teacher insert.
-- set_teacher_class(uuid, text): master-only class assignment.
-- delete_teacher(uuid): master-only profile removal (FK keeps transactions).
-- lookup_teacher_email(text): master-only teacher email check for reset gating.
-- confirm_teacher_email(uuid): master-only auto-activate teacher account (no
-- verification click needed).
-- Full bodies in 20250904000004_master_role.sql.
revoke all on function public.list_teachers() from public;
revoke all on function public.create_teacher_profile(uuid, text, text) from public;
revoke all on function public.set_teacher_class(uuid, text) from public;
revoke all on function public.delete_teacher(uuid) from public;
revoke all on function public.lookup_teacher_email(text) from public;
revoke all on function public.confirm_teacher_email(uuid) from public;
grant execute on function public.list_teachers() to authenticated;
grant execute on function public.create_teacher_profile(uuid, text, text) to authenticated;
grant execute on function public.set_teacher_class(uuid, text) to authenticated;
grant execute on function public.delete_teacher(uuid) to authenticated;
grant execute on function public.lookup_teacher_email(text) to authenticated;
grant execute on function public.confirm_teacher_email(uuid) to authenticated;

-- ---------- public RPCs (anon-safe, SECURITY DEFINER) ----------
-- get_active_students(): public student list for `/`.
-- verify_student_pin(text, text): PIN-gated saldo for `/siswa/[code]`.
-- get_student_history(text, text): PIN-gated history (limit 200).
-- Full bodies in 20250904000000_mvp_public_pin.sql.

revoke all on function public.get_active_students() from public;
revoke all on function public.verify_student_pin(text, text) from public;
revoke all on function public.get_student_history(text, text) from public;

grant execute on function public.get_active_students() to anon, authenticated;
grant execute on function public.verify_student_pin(text, text) to anon, authenticated;
grant execute on function public.get_student_history(text, text) to anon, authenticated;
