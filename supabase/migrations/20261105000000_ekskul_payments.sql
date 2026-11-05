-- Migration: 20261105000000_ekskul_payments.sql
-- Description: Iuran ekstrakurikuler mingguan (Rp3.000 / Kamis).
-- 1. Add is_ekskul_teacher to profiles
-- 2. Create ekskul_payments table with RLS
-- 3. Functions & RPCs: save_ekskul_payment, bulk_save_ekskul_payments, toggle_ekskul_teacher, update list_teachers, get_student_ekskul_history

-- 1. Add is_ekskul_teacher to profiles
alter table public.profiles
  add column if not exists is_ekskul_teacher boolean not null default false;

-- 2. Create ekskul_payments table
create table if not exists public.ekskul_payments (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete restrict,
  payment_date date not null,
  status text not null check (status in ('paid', 'unpaid', 'absent')),
  amount numeric not null default 3000 check (amount >= 0),
  note text,
  recorded_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ekskul_payments_student_date_uniq unique (student_id, payment_date)
);

create index if not exists ekskul_payments_date_idx on public.ekskul_payments(payment_date);
create index if not exists ekskul_payments_student_idx on public.ekskul_payments(student_id, payment_date desc);

-- Enable RLS
alter table public.ekskul_payments enable row level security;

-- Policy: master or teacher with is_ekskul_teacher = true
drop policy if exists "ekskul_payments_admin" on public.ekskul_payments;
create policy "ekskul_payments_admin"
  on public.ekskul_payments
  for all
  to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid())
        and (p.role = 'master' or p.is_ekskul_teacher = true)
    )
  )
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid())
        and (p.role = 'master' or p.is_ekskul_teacher = true)
    )
  );

-- 3. Update list_teachers() to include is_ekskul_teacher
drop function if exists public.list_teachers();
create or replace function public.list_teachers()
returns table (id uuid, full_name text, email text, class_names text[], is_ekskul_teacher boolean, created_at timestamptz)
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
    select p.id, p.full_name, u.email::text, p.class_names, coalesce(p.is_ekskul_teacher, false), p.created_at
      from public.profiles p
      join auth.users u on u.id = p.id
     where p.role = 'teacher'
     order by p.created_at;
end;
$$;
revoke all on function public.list_teachers() from public;
grant execute on function public.list_teachers() to authenticated;

-- 4. toggle_ekskul_teacher(p_teacher_id uuid, p_is_ekskul boolean)
create or replace function public.toggle_ekskul_teacher(
  p_teacher_id uuid,
  p_is_ekskul boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role text;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  select p.role into v_role from public.profiles p where p.id = v_uid;
  if v_role <> 'master' then
    raise exception 'forbidden: master only' using errcode = '42501';
  end if;

  update public.profiles
     set is_ekskul_teacher = coalesce(p_is_ekskul, false)
   where id = p_teacher_id;
end;
$$;
revoke all on function public.toggle_ekskul_teacher(uuid, boolean) from public;
grant execute on function public.toggle_ekskul_teacher(uuid, boolean) to authenticated;

-- 5. save_ekskul_payment
create or replace function public.save_ekskul_payment(
  p_student_id uuid,
  p_payment_date date,
  p_status text,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role text;
  v_is_ekskul boolean;
  v_amount numeric;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  select p.role, coalesce(p.is_ekskul_teacher, false)
    into v_role, v_is_ekskul
    from public.profiles p
   where p.id = v_uid;

  if v_role <> 'master' and not v_is_ekskul then
    raise exception 'forbidden: pembina ekskul only' using errcode = '42501';
  end if;

  if p_status not in ('paid', 'unpaid', 'absent') then
    raise exception 'status tidak valid' using errcode = '22023';
  end if;

  if p_status = 'absent' then
    v_amount := 0;
  else
    v_amount := 3000;
  end if;

  insert into public.ekskul_payments (student_id, payment_date, status, amount, note, recorded_by, created_at, updated_at)
  values (p_student_id, p_payment_date, p_status, v_amount, p_note, v_uid, now(), now())
  on conflict (student_id, payment_date)
  do update set
    status = excluded.status,
    amount = excluded.amount,
    note = coalesce(excluded.note, public.ekskul_payments.note),
    recorded_by = excluded.recorded_by,
    updated_at = now();
end;
$$;
revoke all on function public.save_ekskul_payment(uuid, date, text, text) from public;
grant execute on function public.save_ekskul_payment(uuid, date, text, text) to authenticated;

-- 6. bulk_save_ekskul_payments
create or replace function public.bulk_save_ekskul_payments(
  p_student_ids uuid[],
  p_payment_date date,
  p_status text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role text;
  v_is_ekskul boolean;
  v_amount numeric;
  v_sid uuid;
  v_count integer := 0;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  select p.role, coalesce(p.is_ekskul_teacher, false)
    into v_role, v_is_ekskul
    from public.profiles p
   where p.id = v_uid;

  if v_role <> 'master' and not v_is_ekskul then
    raise exception 'forbidden: pembina ekskul only' using errcode = '42501';
  end if;

  if p_status not in ('paid', 'unpaid', 'absent') then
    raise exception 'status tidak valid' using errcode = '22023';
  end if;

  if p_status = 'absent' then
    v_amount := 0;
  else
    v_amount := 3000;
  end if;

  foreach v_sid in array p_student_ids
  loop
    insert into public.ekskul_payments (student_id, payment_date, status, amount, note, recorded_by, created_at, updated_at)
    values (v_sid, p_payment_date, p_status, v_amount, null, v_uid, now(), now())
    on conflict (student_id, payment_date)
    do update set
      status = excluded.status,
      amount = excluded.amount,
      recorded_by = excluded.recorded_by,
      updated_at = now();
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;
revoke all on function public.bulk_save_ekskul_payments(uuid[], date, text) from public;
grant execute on function public.bulk_save_ekskul_payments(uuid[], date, text) to authenticated;

-- 7. get_student_ekskul_history(p_code text, p_pin text)
create or replace function public.get_student_ekskul_history(p_code text, p_pin text)
returns table (
  id uuid,
  payment_date date,
  status text,
  amount numeric,
  note text,
  created_at timestamptz
)
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
   where public_code = p_code;

  if not found then
    return;
  end if;

  if v_student.pin_hash <> extensions.crypt(p_pin, v_student.pin_hash) then
    return;
  end if;

  return query
    select ep.id, ep.payment_date, ep.status, ep.amount, ep.note, ep.created_at
      from public.ekskul_payments ep
     where ep.student_id = v_student.id
     order by ep.payment_date desc
     limit 24;
end;
$$;
revoke all on function public.get_student_ekskul_history(text, text) from public;
grant execute on function public.get_student_ekskul_history(text, text) to anon, authenticated;

-- 8. pay_all_ekskul_arrears(p_student_id uuid)
create or replace function public.pay_all_ekskul_arrears(p_student_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role text;
  v_is_ekskul boolean;
  v_count integer;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  select p.role, coalesce(p.is_ekskul_teacher, false)
    into v_role, v_is_ekskul
    from public.profiles p
   where p.id = v_uid;

  if v_role <> 'master' and not v_is_ekskul then
    raise exception 'forbidden: pembina ekskul only' using errcode = '42501';
  end if;

  with updated as (
    update public.ekskul_payments
       set status = 'paid',
           amount = 3000,
           recorded_by = v_uid,
           updated_at = now()
     where student_id = p_student_id
       and status = 'unpaid'
    returning id
  )
  select count(*) into v_count from updated;

  return v_count;
end;
$$;
revoke all on function public.pay_all_ekskul_arrears(uuid) from public;
grant execute on function public.pay_all_ekskul_arrears(uuid) to authenticated;
