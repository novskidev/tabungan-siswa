-- Teacher multi-class: one teacher can hold several classes (1-6).
-- profiles.class_name (scalar) -> profiles.class_names text[].
-- Parents (public PIN pages) are unaffected.

-- 1. Drop the old policy first (it references profiles.class_name).
drop policy if exists "students_teacher_all" on public.students;

-- 2. Column swap with data migration.
alter table public.profiles
  add column if not exists class_names text[] not null default '{}';
update public.profiles
   set class_names = array[class_name]
 where class_name is not null
   and (class_names is null or class_names = '{}');
alter table public.profiles
  drop column if exists class_name;
alter table public.profiles
  drop constraint if exists profiles_class_name_check;
alter table public.profiles
  drop constraint if exists profiles_class_names_check;
alter table public.profiles
  add constraint profiles_class_names_check
  check (class_names <@ array['1','2','3','4','5','6']);

-- 3. Students RLS: teacher rows scoped to ANY of own classes.
create policy "students_teacher_all"
  on public.students
  for all
  to authenticated
  using (
    exists (select 1 from public.profiles p
            where p.id = (select auth.uid())
              and (p.role = 'master'
                   or (p.role = 'teacher' and students.class_name = any (p.class_names))))
  )
  with check (
    exists (select 1 from public.profiles p
            where p.id = (select auth.uid())
              and (p.role = 'master'
                   or (p.role = 'teacher' and students.class_name = any (p.class_names))))
  );

-- Transactions policies delegate to students RLS; unchanged.

-- 4. create_student: teacher guard checks membership in own classes.
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
  v_teacher_classes text[];
  v_pin text;
  v_code text;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  select p.role, p.class_names into v_role, v_teacher_classes
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
  if v_role = 'teacher' and not (btrim(p_class_name) = any (v_teacher_classes)) then
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

-- 5. delete_student: definer class guard checks membership.
create or replace function public.delete_student(p_student_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role text;
  v_teacher_classes text[];
  v_student_class text;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  select role, class_names into v_role, v_teacher_classes
    from public.profiles where id = v_uid;
  if v_role is null or v_role not in ('teacher', 'master') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select class_name into v_student_class from public.students where id = p_student_id;
  if not found then
    raise exception 'siswa tidak ditemukan' using errcode = 'P0002';
  end if;
  if v_role = 'teacher' and not (v_student_class = any (v_teacher_classes)) then
    raise exception 'bukan siswa kelas Anda' using errcode = '42501';
  end if;
  delete from public.transactions where student_id = p_student_id;
  delete from public.students where id = p_student_id;
end;
$$;

-- 6. Teacher management: array flows through; add/remove single classes.
drop function if exists public.create_teacher_profile(uuid, text, text);
create or replace function public.create_teacher_profile(
  p_user_id uuid,
  p_full_name text,
  p_class_names text[] default '{}'
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
  if not (p_class_names <@ array['1','2','3','4','5','6']) then
    raise exception 'kelas harus 1 sampai 6' using errcode = '22023';
  end if;
  if exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'profil sudah ada' using errcode = '23505';
  end if;
  insert into public.profiles (id, full_name, role, class_names)
  values (p_user_id, btrim(p_full_name), 'teacher', p_class_names);
end;
$$;
revoke all on function public.create_teacher_profile(uuid, text, text[]) from public;
grant execute on function public.create_teacher_profile(uuid, text, text[]) to authenticated;

drop function if exists public.set_teacher_class(uuid, text);

create or replace function public.add_teacher_class(
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
     set class_names = array_append(class_names, btrim(p_class_name))
   where id = p_teacher_id and role = 'teacher'
     and not (btrim(p_class_name) = any (class_names));
  if not found then
    if not exists (select 1 from public.profiles
                   where id = p_teacher_id and role = 'teacher') then
      raise exception 'guru tidak ditemukan' using errcode = 'P0002';
    end if;
    -- else: class already assigned — idempotent success.
  end if;
end;
$$;
revoke all on function public.add_teacher_class(uuid, text) from public;
grant execute on function public.add_teacher_class(uuid, text) to authenticated;

create or replace function public.remove_teacher_class(
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
  update public.profiles
     set class_names = array_remove(class_names, btrim(coalesce(p_class_name, '')))
   where id = p_teacher_id and role = 'teacher';
  if not found then
    raise exception 'guru tidak ditemukan' using errcode = 'P0002';
  end if;
end;
$$;
revoke all on function public.remove_teacher_class(uuid, text) from public;
grant execute on function public.remove_teacher_class(uuid, text) to authenticated;

drop function if exists public.list_teachers();
create or replace function public.list_teachers()
returns table (id uuid, full_name text, email text, class_names text[], created_at timestamptz)
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
    select p.id, p.full_name, u.email::text, p.class_names, p.created_at
      from public.profiles p
      join auth.users u on u.id = p.id
     where p.role = 'teacher'
     order by p.created_at;
end;
$$;
revoke all on function public.list_teachers() from public;
grant execute on function public.list_teachers() to authenticated;
