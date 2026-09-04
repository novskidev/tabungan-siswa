-- Teacher class scope: each teacher is assigned exactly one class (1-6).
-- Teachers see/manage only students of their own class; master sees all.
-- Parents (public PIN pages) are unaffected.

-- 1. profiles.class_name (nullable until master assigns a class).
alter table public.profiles
  add column if not exists class_name text;
alter table public.profiles
  drop constraint if exists profiles_class_name_check;
alter table public.profiles
  add constraint profiles_class_name_check
  check (class_name is null or class_name ~ '^[1-6]$');

-- Backfill: Bu Yana pegang kelas 5.
update public.profiles
   set class_name = '5'
 where id = (select id from auth.users where email = 'yanasusanti@gmail.com');

-- 2. Students: teacher rows scoped to own class, master unrestricted.
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

-- 3. Transactions visible/insertable only for own-class students (the inner
-- students subquery is already RLS-scoped for teachers; master passes via
-- the master branch).
drop policy if exists "transactions_teacher_select" on public.transactions;
create policy "transactions_teacher_select"
  on public.transactions
  for select
  to authenticated
  using (
    exists (select 1 from public.profiles p
            where p.id = (select auth.uid()) and p.role = 'master')
    or exists (select 1 from public.students s where s.id = student_id)
  );

drop policy if exists "transactions_teacher_insert" on public.transactions;
create policy "transactions_teacher_insert"
  on public.transactions
  for insert
  to authenticated
  with check (
    created_by = (select auth.uid())
    and exists (select 1 from public.students s where s.id = student_id)
  );

-- 4. SECURITY DEFINER RPCs: add explicit class guards (definer bypasses RLS).
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
                 where p.id = v_uid and p.role in ('teacher', 'master')) then
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

create or replace function public.reset_student_balance(p_student_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles p
                 where p.id = v_uid and p.role in ('teacher', 'master')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  delete from public.transactions where student_id = p_student_id;
end;
$$;

create or replace function public.delete_student(p_student_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role text;
  v_teacher_class text;
  v_student_class text;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  select role, class_name into v_role, v_teacher_class
    from public.profiles where id = v_uid;
  if v_role is null or v_role not in ('teacher', 'master') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select class_name into v_student_class from public.students where id = p_student_id;
  if not found then
    raise exception 'siswa tidak ditemukan' using errcode = 'P0002';
  end if;
  if v_role = 'teacher' and v_student_class is distinct from v_teacher_class then
    raise exception 'bukan siswa kelas Anda' using errcode = '42501';
  end if;
  delete from public.transactions where student_id = p_student_id;
  delete from public.students where id = p_student_id;
end;
$$;

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
  v_role text;
  v_teacher_class text;
  v_pin text;
  v_code text;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  select p.role, p.class_name into v_role, v_teacher_class
    from public.profiles p where p.id = v_uid;
  if v_role is null or v_role not in ('teacher', 'master') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_full_name is null or btrim(p_full_name) = '' then
    raise exception 'nama wajib diisi' using errcode = '22023';
  end if;
  if p_class_name is null or btrim(p_class_name) !~ '^[1-6]$' then
    raise exception 'kelas harus 1 sampai 6' using errcode = '22023';
  end if;
  if v_role = 'teacher' and btrim(p_class_name) is distinct from v_teacher_class then
    raise exception 'bukan kelas Anda' using errcode = '42501';
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

-- 5. Teacher management: class_name flows through.
create or replace function public.create_teacher_profile(
  p_user_id uuid,
  p_full_name text,
  p_class_name text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles p
                 where p.id = v_uid and p.role = 'master') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_full_name is null or btrim(p_full_name) = '' then
    raise exception 'nama wajib diisi' using errcode = '22023';
  end if;
  if p_class_name is null or btrim(p_class_name) !~ '^[1-6]$' then
    raise exception 'kelas harus 1 sampai 6' using errcode = '22023';
  end if;
  if exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'profil sudah ada' using errcode = '23505';
  end if;
  insert into public.profiles (id, full_name, role, class_name)
  values (p_user_id, btrim(p_full_name), 'teacher', btrim(p_class_name));
end;
$$;

create or replace function public.set_teacher_class(
  p_teacher_id uuid,
  p_class_name text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles p
                 where p.id = v_uid and p.role = 'master') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_class_name is null or btrim(p_class_name) !~ '^[1-6]$' then
    raise exception 'kelas harus 1 sampai 6' using errcode = '22023';
  end if;
  update public.profiles
     set class_name = btrim(p_class_name)
   where id = p_teacher_id and role = 'teacher';
  if not found then
    raise exception 'guru tidak ditemukan' using errcode = 'P0002';
  end if;
end;
$$;

drop function if exists public.list_teachers();
create or replace function public.list_teachers()
returns table (id uuid, full_name text, email text, class_name text, created_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles p
                 where p.id = v_uid and p.role = 'master') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
    select p.id, p.full_name, u.email::text, p.class_name, p.created_at
      from public.profiles p
      join auth.users u on u.id = p.id
     where p.role = 'teacher'
     order by p.created_at;
end;
$$;
revoke all on function public.list_teachers() from public;
grant execute on function public.list_teachers() to authenticated;

-- 6. Master-only teacher removal. Profile row only: transactions.created_by
-- FK (RESTRICT) keeps money history — a teacher with transactions cannot be
-- deleted until handled explicitly.
create or replace function public.delete_teacher(p_teacher_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles p
                 where p.id = v_uid and p.role = 'master') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  delete from public.profiles where id = p_teacher_id and role = 'teacher';
  if not found then
    raise exception 'guru tidak ditemukan' using errcode = 'P0002';
  end if;
end;
$$;
revoke all on function public.delete_teacher(uuid) from public;
grant execute on function public.delete_teacher(uuid) to authenticated;
