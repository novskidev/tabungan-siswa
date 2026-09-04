-- Master role: Novski can manage teachers, change own password, reset teacher passwords.
-- Hierarchy: master can do everything teacher can, plus teacher management.
-- Password changes go through Supabase Auth API (no service key in app):
--   own password  -> auth.updateUser (user's own token)
--   reset teacher -> auth.resetPasswordForEmail (reset link via email)

-- 1. Allow master in profiles.
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles
  add constraint profiles_role_check check (role in ('teacher', 'master'));

-- 2. Promote Novski (guarded: no-op when the account row is missing).
update public.profiles set role = 'master'
 where id = (select id from auth.users where email = 'novskidev@gmail.com');

-- 3. Block direct role changes via the table (teachers could self-promote once
-- 'master' is a legal value). Role assignment only via migration SQL or the
-- master-only create_teacher_profile RPC below (insert-only, unaffected).
create or replace function public.block_profile_role_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.role is distinct from old.role then
    raise exception 'role tidak bisa diubah langsung' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_block_role_change on public.profiles;
create trigger profiles_block_role_change
  before update on public.profiles
  for each row execute function public.block_profile_role_change();

-- 4. Widen table policies to teacher + master.
drop policy if exists "students_teacher_all" on public.students;
create policy "students_teacher_all"
  on public.students
  for all
  to authenticated
  using (
    exists (select 1 from public.profiles p
            where p.id = (select auth.uid()) and p.role in ('teacher', 'master'))
  )
  with check (
    exists (select 1 from public.profiles p
            where p.id = (select auth.uid()) and p.role in ('teacher', 'master'))
  );

drop policy if exists "transactions_teacher_select" on public.transactions;
create policy "transactions_teacher_select"
  on public.transactions
  for select
  to authenticated
  using (
    exists (select 1 from public.profiles p
            where p.id = (select auth.uid()) and p.role in ('teacher', 'master'))
  );

drop policy if exists "transactions_teacher_insert" on public.transactions;
create policy "transactions_teacher_insert"
  on public.transactions
  for insert
  to authenticated
  with check (
    created_by = (select auth.uid())
    and exists (select 1 from public.profiles p
                where p.id = (select auth.uid()) and p.role in ('teacher', 'master'))
  );

-- 5. Widen RPC role checks to teacher + master.
create or replace function public.create_transaction(
  p_student_id uuid,
  p_type text,
  p_amount numeric,
  p_note text default null
)
returns public.transactions
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role text;
  v_current_balance numeric(12, 0);
  v_row public.transactions;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  select role into v_role from public.profiles where id = v_uid;
  if v_role is null or v_role not in ('teacher', 'master') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_type not in ('deposit', 'withdrawal') then
    raise exception 'invalid type' using errcode = '22023';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive' using errcode = '22023';
  end if;

  perform 1 from public.students where id = p_student_id for update;
  if not found then
    raise exception 'student not found' using errcode = 'P0002';
  end if;

  select coalesce(sum(case when type = 'deposit' then amount else 0 end), 0)
       - coalesce(sum(case when type = 'withdrawal' then amount else 0 end), 0)
    into v_current_balance
  from public.transactions
  where student_id = p_student_id;

  if p_type = 'withdrawal' and p_amount > v_current_balance then
    raise exception 'insufficient balance' using errcode = 'P0001';
  end if;

  insert into public.transactions (student_id, type, amount, note, created_by)
  values (p_student_id, p_type, p_amount, p_note, v_uid)
  returning * into v_row;

  return v_row;
end;
$$;

create or replace function public.correct_transaction(
  p_original_id uuid,
  p_reason text
)
returns public.transactions
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role text;
  v_original public.transactions;
  v_existing uuid;
  v_current_balance numeric(12, 0);
  v_reverse_type text;
  v_row public.transactions;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  select role into v_role from public.profiles where id = v_uid;
  if v_role is null or v_role not in ('teacher', 'master') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'reason required' using errcode = '22023';
  end if;

  select * into v_original
  from public.transactions
  where id = p_original_id
  for update;

  if not found then
    raise exception 'transaction not found' using errcode = 'P0002';
  end if;

  select id into v_existing
  from public.transactions
  where correction_of = p_original_id
  limit 1;
  if v_existing is not null then
    raise exception 'transaction already corrected' using errcode = 'P0001';
  end if;

  perform 1 from public.students
  where id = v_original.student_id for update;

  select coalesce(sum(case when type = 'deposit' then amount else 0 end), 0)
       - coalesce(sum(case when type = 'withdrawal' then amount else 0 end), 0)
    into v_current_balance
  from public.transactions
  where student_id = v_original.student_id;

  if v_original.type = 'deposit' then
    v_reverse_type := 'withdrawal';
    if v_current_balance < v_original.amount then
      raise exception 'cannot reverse deposit: balance already lower' using errcode = 'P0001';
    end if;
  else
    v_reverse_type := 'deposit';
  end if;

  insert into public.transactions (
    student_id, type, amount, note, created_by,
    correction_of, correction_reason, corrected_by, corrected_at
  )
  values (
    v_original.student_id, v_reverse_type, v_original.amount,
    'Koreksi: ' || btrim(p_reason), v_uid,
    p_original_id, btrim(p_reason), v_uid, now()
  )
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    raise exception 'transaction already corrected' using errcode = 'P0001';
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
  v_pin text;
  v_code text;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  if not exists (select 1 from public.profiles p
                 where p.id = v_uid and p.role in ('teacher', 'master')) then
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

-- 6. Master-only teacher management RPCs (SECURITY DEFINER: teachers have no
-- SELECT on other profiles, so listing goes through a checked function).
-- Profiles SELECT stays self-only, so no recursive-policy login loop.

create or replace function public.list_teachers()
returns table (id uuid, full_name text, email text, created_at timestamptz)
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
    select p.id, p.full_name, u.email::text, p.created_at
      from public.profiles p
      join auth.users u on u.id = p.id
     where p.role = 'teacher'
     order by p.created_at;
end;
$$;

create or replace function public.create_teacher_profile(
  p_user_id uuid,
  p_full_name text
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

  if exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'profil sudah ada' using errcode = '23505';
  end if;

  insert into public.profiles (id, full_name, role)
  values (p_user_id, btrim(p_full_name), 'teacher');
end;
$$;

revoke all on function public.list_teachers() from public;
revoke all on function public.create_teacher_profile(uuid, text) from public;
revoke all on function public.block_profile_role_change() from public;
grant execute on function public.list_teachers() to authenticated;
grant execute on function public.create_teacher_profile(uuid, text) to authenticated;

-- Master-only email lookup for password-reset gating: returns the teacher id
-- for a registered teacher email, null otherwise. Prevents triggering a
-- reset email for arbitrary addresses (including the master account).
create or replace function public.lookup_teacher_email(p_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  if not exists (select 1 from public.profiles p
                 where p.id = v_uid and p.role = 'master') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select p.id into v_id
    from public.profiles p
    join auth.users u on u.id = p.id
   where p.role = 'teacher' and lower(u.email) = lower(btrim(p_email));
  return v_id;
end;
$$;

revoke all on function public.lookup_teacher_email(text) from public;
grant execute on function public.lookup_teacher_email(text) to authenticated;

-- Master auto-confirms teacher emails so new accounts work immediately
-- without clicking a verification link. All accounts are created by the
-- trusted master (no public signup page), so confirmation adds no security.
create or replace function public.confirm_teacher_email(p_user_id uuid)
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

  if p_user_id = v_uid then
    raise exception 'tidak bisa untuk akun sendiri' using errcode = '42501';
  end if;

  if exists (select 1 from public.profiles where id = p_user_id and role = 'master') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  update auth.users
     set email_confirmed_at = coalesce(email_confirmed_at, now()),
         confirmed_at = coalesce(confirmed_at, now()),
         updated_at = now()
   where id = p_user_id;
  if not found then
    raise exception 'akun tidak ditemukan' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.confirm_teacher_email(uuid) from public;
grant execute on function public.confirm_teacher_email(uuid) to authenticated;
