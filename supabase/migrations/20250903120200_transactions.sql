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

-- SELECT: teachers see all; parents see only transactions whose student has parent_id = auth.uid().
create policy "transactions_select_teacher_or_own_child"
  on public.transactions
  for select
  to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'teacher'
    )
    or exists (
      select 1 from public.students s
      where s.id = transactions.student_id and s.parent_id = auth.uid()
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
      where p.id = auth.uid() and p.role = 'teacher'
    )
    and created_by = auth.uid()
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
as $$
declare
  v_uid uuid := auth.uid();
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
