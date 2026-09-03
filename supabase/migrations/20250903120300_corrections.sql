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
as $$
declare
  v_uid uuid := auth.uid();
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
