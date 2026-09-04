-- MVP: public parent access via public_code + 4-digit PIN, teacher-only login.
-- Idempotent: safe to re-run. Tables were rebuilt empty, so this doubles as
-- the canonical replay of the piecewise SQL applied via Dashboard/MCP.
--
-- Model:
-- - teachers: Supabase Auth + public.profiles (role='teacher')
-- - parents: anonymous, access only via SECURITY DEFINER RPCs below.
--   No table policy is granted to `anon`; PIN is bcrypt-hashed (pgcrypto),
--   never stored plaintext, never put in cookies/storage.

create extension if not exists pgcrypto with schema extensions;

-- pgcrypto must live in `extensions`: functions below pin `search_path = ''`,
-- so unqualified crypt()/gen_salt() would not resolve. Move it if a prior
-- install put it elsewhere.
do $$
begin
  if exists (select 1 from pg_extension
             where extname = 'pgcrypto'
               and extnamespace <> to_regnamespace('extensions')) then
    alter extension pgcrypto set schema extensions;
  end if;
end;
$$;

-- ---------- students ----------
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

-- Migrate legacy columns from the old schema when present.
alter table public.students add column if not exists nis text;
alter table public.students add column if not exists class_name text;
alter table public.students add column if not exists public_code text;
alter table public.students add column if not exists pin_hash text;
alter table public.students add column if not exists is_active boolean not null default true;
alter table public.students add column if not exists created_at timestamptz not null default now();
alter table public.students add column if not exists updated_at timestamptz not null default now();
alter table public.students alter column nis drop not null;
-- Backfill class_name from the legacy classes table before dropping the FK.
-- Guarded so re-runs (after class_id is gone) skip safely.
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'students'
               and column_name = 'class_id')
     and exists (select 1 from information_schema.tables
             where table_schema = 'public' and table_name = 'classes') then
    update public.students s
       set class_name = c.name
      from public.classes c
     where s.class_name is null and s.class_id = c.id;
  end if;
  update public.students
     set class_name = 'Tanpa Kelas'
   where class_name is null or btrim(class_name) = '';
end;
$$;
alter table public.students drop column if exists class_id;
alter table public.students drop column if exists parent_id;

-- Backfill for rows predating public_code/pin_hash (kept, not dropped).
do $$
declare
  r record;
  v_code text;
  v_pin text;
begin
  for r in select id, class_name from public.students
           where public_code is null or pin_hash is null loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr('abcdefghjkmnpqrstuvwxyz23456789',
        1 + floor(random() * 32)::int, 1);
    end loop;
    v_pin := coalesce(repeat(substring(r.class_name from '^[0-9]'), 4), '0000');
    update public.students
       set public_code = coalesce(public_code, v_code || substr(md5(id::text), 1, 2)),
           pin_hash = coalesce(pin_hash, extensions.crypt(v_pin, extensions.gen_salt('bf')))
     where id = r.id;
  end loop;
end;
$$;

alter table public.students alter column public_code set not null;
alter table public.students alter column pin_hash set not null;
alter table public.students alter column class_name set not null;

create unique index if not exists students_public_code_idx on public.students (public_code);
create index if not exists students_is_active_idx on public.students (is_active);
create unique index if not exists students_nis_idx on public.students (nis);

alter table public.students enable row level security;

drop policy if exists "students_select_teacher_or_own_parent" on public.students;
drop policy if exists "students_insert_teacher" on public.students;
drop policy if exists "students_update_teacher" on public.students;
drop policy if exists "students_delete_teacher" on public.students;
drop policy if exists "students_public_list" on public.students;
drop policy if exists "students_teacher_all" on public.students;

-- Teacher-only table access. Parents (anon) get data exclusively via the
-- RPCs below, so there is intentionally no policy for `anon`.
create policy "students_teacher_all"
  on public.students
  for all
  to authenticated
  using (
    exists (select 1 from public.profiles p
            where p.id = (select auth.uid()) and p.role = 'teacher')
  )
  with check (
    exists (select 1 from public.profiles p
            where p.id = (select auth.uid()) and p.role = 'teacher')
  );

revoke all on public.students from anon;
grant select, insert, update, delete on public.students to authenticated;

-- Tighten profiles role to teacher-only (MVP: parents are anonymous).
-- Guarded: only applies when no legacy parent rows remain.
do $$
begin
  if not exists (select 1 from public.profiles where role = 'parent') then
    alter table public.profiles drop constraint if exists profiles_role_check;
    alter table public.profiles
      add constraint profiles_role_check check (role in ('teacher'));
  end if;
end;
$$;

drop table if exists public.classes;

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

create index if not exists transactions_student_id_created_at_idx
  on public.transactions (student_id, created_at desc);
create index if not exists transactions_created_at_idx
  on public.transactions (created_at desc);

alter table public.transactions enable row level security;

drop policy if exists "transactions_select_teacher_or_own_child" on public.transactions;
drop policy if exists "transactions_insert_teacher" on public.transactions;
drop policy if exists "transactions_teacher_select" on public.transactions;
drop policy if exists "transactions_teacher_insert" on public.transactions;

create policy "transactions_teacher_select"
  on public.transactions
  for select
  to authenticated
  using (
    exists (select 1 from public.profiles p
            where p.id = (select auth.uid()) and p.role = 'teacher')
  );

create policy "transactions_teacher_insert"
  on public.transactions
  for insert
  to authenticated
  with check (
    created_by = (select auth.uid())
    and exists (select 1 from public.profiles p
                where p.id = (select auth.uid()) and p.role = 'teacher')
  );

revoke all on public.transactions from anon;
grant select, insert on public.transactions to authenticated;

-- ---------- public RPCs (anon-safe) ----------
-- SECURITY DEFINER is required here: anon has zero table access, so the
-- function must bypass RLS. Each function authenticates via (public_code, PIN)
-- and exposes only non-sensitive columns. Revoked from PUBLIC, granted
-- explicitly to anon + authenticated.

create or replace function public.get_active_students()
returns table (id uuid, full_name text, class_name text, public_code text)
language sql
security definer
set search_path = ''
as $$
  select s.id, s.full_name, s.class_name, s.public_code
    from public.students s
   where s.is_active
   order by s.class_name, s.full_name;
$$;

create or replace function public.verify_student_pin(p_code text, p_pin text)
returns table (student_id uuid, full_name text, class_name text,
               balance numeric, total_deposit numeric, total_withdrawal numeric)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student public.students;
begin
  if p_code is null or p_pin is null or p_pin !~ '^\d{4}$' then
    return;
  end if;

  select * into v_student from public.students
   where public_code = p_code and is_active;

  if not found then
    return;
  end if;

  if v_student.pin_hash <> extensions.crypt(p_pin, v_student.pin_hash) then
    return;
  end if;

  return query
    select v_student.id, v_student.full_name, v_student.class_name,
           (select coalesce(sum(case when t.type = 'deposit' then t.amount else 0 end), 0)
              from public.transactions t where t.student_id = v_student.id)
         - (select coalesce(sum(case when t.type = 'withdrawal' then t.amount else 0 end), 0)
              from public.transactions t where t.student_id = v_student.id),
           (select coalesce(sum(case when t.type = 'deposit' then t.amount else 0 end), 0)
              from public.transactions t where t.student_id = v_student.id),
           (select coalesce(sum(case when t.type = 'withdrawal' then t.amount else 0 end), 0)
              from public.transactions t where t.student_id = v_student.id);
end;
$$;

create or replace function public.get_student_history(p_code text, p_pin text)
returns table (id uuid, type text, amount numeric, note text, created_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student public.students;
begin
  if p_code is null or p_pin is null or p_pin !~ '^\d{4}$' then
    return;
  end if;

  select * into v_student from public.students
   where public_code = p_code and is_active;

  if not found then
    return;
  end if;

  if v_student.pin_hash <> extensions.crypt(p_pin, v_student.pin_hash) then
    return;
  end if;

  return query
    select t.id, t.type, t.amount, t.note, t.created_at
      from public.transactions t
     where t.student_id = v_student.id
     order by t.created_at desc
     limit 200;
end;
$$;

-- ---------- teacher RPCs (authenticated, teacher role checked inside) ----------

create or replace function public.create_student(
  p_full_name text,
  p_class_name text,
  p_nis text default null
)
returns table (id uuid, full_name text, class_name text, public_code text, default_pin text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_pin text;
  v_code text;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  if not exists (select 1 from public.profiles p
                 where p.id = v_uid and p.role = 'teacher') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_full_name is null or btrim(p_full_name) = '' then
    raise exception 'nama wajib diisi' using errcode = '22023';
  end if;

  if p_class_name is null or btrim(p_class_name) = '' then
    raise exception 'kelas wajib diisi' using errcode = '22023';
  end if;

  v_pin := coalesce(repeat(substring(btrim(p_class_name) from '^[0-9]'), 4), '0000');

  loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr('abcdefghjkmnpqrstuvwxyz23456789',
        1 + floor(random() * 32)::int, 1);
    end loop;
    exit when not exists (select 1 from public.students where students.public_code = v_code);
  end loop;

  insert into public.students (nis, full_name, class_name, public_code, pin_hash)
  values (nullif(btrim(p_nis), ''), btrim(p_full_name), btrim(p_class_name),
          v_code, extensions.crypt(v_pin, extensions.gen_salt('bf')))
  returning students.id into v_id;

  return query
    select v_id, btrim(p_full_name), btrim(p_class_name), v_code, v_pin;
exception
  when unique_violation then
    raise exception 'NIS sudah dipakai siswa lain' using errcode = '23505';
end;
$$;

create or replace function public.reset_student_pin(p_student_id uuid)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_class text;
  v_pin text;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  if not exists (select 1 from public.profiles p
                 where p.id = v_uid and p.role = 'teacher') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select class_name into v_class from public.students where id = p_student_id;
  if not found then
    raise exception 'siswa tidak ditemukan' using errcode = 'P0002';
  end if;

  v_pin := coalesce(repeat(substring(v_class from '^[0-9]'), 4), '0000');

  update public.students
     set pin_hash = extensions.crypt(v_pin, extensions.gen_salt('bf')), updated_at = now()
   where id = p_student_id;

  return v_pin;
end;
$$;

revoke all on function public.get_active_students() from public;
revoke all on function public.verify_student_pin(text, text) from public;
revoke all on function public.get_student_history(text, text) from public;
revoke all on function public.create_student(text, text, text) from public;
revoke all on function public.reset_student_pin(uuid) from public;

grant execute on function public.get_active_students() to anon, authenticated;
grant execute on function public.verify_student_pin(text, text) to anon, authenticated;
grant execute on function public.get_student_history(text, text) to anon, authenticated;
grant execute on function public.create_student(text, text, text) to authenticated;
grant execute on function public.reset_student_pin(uuid) to authenticated;
