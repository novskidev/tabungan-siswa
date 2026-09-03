-- Sprint 0: profiles table
-- Each profile is linked 1:1 to an auth.users row.

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  role text not null check (role in ('teacher', 'parent')),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Read: a logged-in user can only read their own profile.
create policy "profiles_select_own"
  on public.profiles
  for select
  to authenticated
  using ((select auth.uid()) = id);

-- Update: a logged-in user can only update their own profile.
create policy "profiles_update_own"
  on public.profiles
  for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- Insert is intentionally restricted to the service role / trigger flows.
-- No insert policy for the `authenticated` role keeps user self-signup locked down
-- until a teacher-driven flow is built (Sprint 1+).

-- ==============================================
-- Sprint 0: classes table
-- Sprint 0 ships the table + RLS scaffolding only.
-- CRUD UI is intentionally deferred to Sprint 1.

create table if not exists public.classes (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  academic_year text not null,
  created_at timestamptz not null default now()
);

alter table public.classes enable row level security;

-- No policies yet. Sprint 0 keeps access service-role only;
-- teacher-facing CRUD lands in Sprint 1.

-- ==============================================
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

-- ==============================================
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

-- ==============================================
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
--  - parent sees only rows where parent_id = (select auth.uid())
create policy "students_select_teacher_or_own_parent"
  on public.students
  for select
  to authenticated
  using (
    parent_id = (select auth.uid())
    or exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.role = 'teacher'
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
      where p.id = (select auth.uid()) and p.role = 'teacher'
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
      where p.id = (select auth.uid()) and p.role = 'teacher'
    )
  )
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.role = 'teacher'
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
      where p.id = (select auth.uid()) and p.role = 'teacher'
    )
  );

-- updated_at trigger
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

-- ==============================================
-- Sprint 2: transactions table + atomic create_transaction RPC + RLS.
-- Money values are stored as numeric(12,0) — enough for Rp 999.999.999.999,99
-- without the float drift that real money must never have.

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students (id) on delete restrict,
  type text not null check (type in ('deposit', 'withdrawal')),
  amount numeric(12, 0) not null check (amount > 0),
  note text,
  created_by uuid not null references public.profiles (id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists transactions_student_id_created_at_idx
  on public.transactions (student_id, created_at desc);

create index if not exists transactions_created_at_idx
  on public.transactions (created_at desc);

create index if not exists transactions_created_by_idx
  on public.transactions (created_by);

alter table public.transactions enable row level security;

-- SELECT: teachers see all; parents see only transactions whose student has parent_id = (select auth.uid()).
create policy "transactions_select_teacher_or_own_child"
  on public.transactions
  for select
  to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.role = 'teacher'
    )
    or exists (
      select 1 from public.students s
      where s.id = transactions.student_id and s.parent_id = (select auth.uid())
    )
  );

-- INSERT: teachers only.
create policy "transactions_insert_teacher"
  on public.transactions
  for insert
  to authenticated
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.role = 'teacher'
    )
    and created_by = (select auth.uid())
  );

-- No UPDATE / DELETE policies for authenticated role.
-- Corrections in a future sprint will go through a compensating transaction RPC,
-- not direct row mutation. Historical financial records must stay intact.

-- Atomic create_transaction RPC.
-- Wraps balance check + insert in a single statement at default READ COMMITTED
-- with row-level lock on the student row, so two concurrent withdrawals can't
-- both pass the balance check.
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
  if v_role is null or v_role <> 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_type not in ('deposit', 'withdrawal') then
    raise exception 'invalid type' using errcode = '22023';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive' using errcode = '22023';
  end if;

  -- Lock the student row to serialize concurrent transactions on the same student.
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

grant execute on function public.create_transaction(uuid, text, numeric, text)
  to authenticated;

-- ==============================================
-- Sprint 5: corrections + inactive students + audit fields.
-- Corrections are modeled as reversing transactions: a row with `correction_of`
-- set is a financial record of opposite sign that cancels an earlier record.
-- Balance = SUM(deposit) - SUM(withdrawal) is unchanged; corrections flow
-- through the same formula.

alter table public.transactions
  add column if not exists correction_of uuid
  references public.transactions (id) on delete restrict;

alter table public.transactions
  add column if not exists correction_reason text;

alter table public.transactions
  add column if not exists corrected_by uuid
  references public.profiles (id) on delete restrict;

alter table public.transactions
  add column if not exists corrected_at timestamptz;

create unique index if not exists transactions_correction_of_unique
  on public.transactions (correction_of)
  where correction_of is not null;

create index if not exists transactions_correction_of_idx
  on public.transactions (correction_of);

-- Inactive students: hidden from operational workflow, transactions preserved.
alter table public.students
  add column if not exists is_active boolean not null default true;

create index if not exists students_is_active_idx
  on public.students (is_active);

-- Atomic correct_transaction RPC.
-- Locks the original transaction row; rejects if already corrected.
-- Balance check: reversing a withdrawal that already helped reduce balance
-- below current saldo is allowed (adds money back). Reversing a deposit that
-- has since been withdrawn would over-draw — reject.
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
  if v_role is null or v_role <> 'teacher' then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'reason required' using errcode = '22023';
  end if;

  -- Lock the original transaction row.
  select * into v_original
  from public.transactions
  where id = p_original_id
  for update;

  if not found then
    raise exception 'transaction not found' using errcode = 'P0002';
  end if;

  -- Reject if already corrected.
  select id into v_existing
  from public.transactions
  where correction_of = p_original_id
  limit 1;
  if v_existing is not null then
    raise exception 'transaction already corrected' using errcode = 'P0001';
  end if;

  -- Lock the student row to serialize concurrent corrections.
  perform 1 from public.students
  where id = v_original.student_id for update;

  -- Compute current balance.
  select coalesce(sum(case when type = 'deposit' then amount else 0 end), 0)
       - coalesce(sum(case when type = 'withdrawal' then amount else 0 end), 0)
    into v_current_balance
  from public.transactions
  where student_id = v_original.student_id;

  -- Determine reverse type and validate balance impact.
  if v_original.type = 'deposit' then
    v_reverse_type := 'withdrawal';
    -- Reversing a deposit subtracts money. If current balance < original amount,
    -- the user has already spent that money; we can't withdraw it again.
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

grant execute on function public.correct_transaction(uuid, text)
  to authenticated;

-- ==============================================
