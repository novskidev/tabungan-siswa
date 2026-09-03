-- Sprint 7: Balance reconciliation.
-- For each student: total deposit, total withdrawal, expected balance.
-- Compare with what the UI shows (teacher detail, parent detail).
-- Expected: Expected Balance = Teacher UI = Parent UI.

select
  s.id                                    as student_id,
  s.nis,
  s.full_name                             as student_name,
  c.name                                  as class_name,
  coalesce(d.total_deposit, 0)            as total_deposit,
  coalesce(w.total_withdrawal, 0)         as total_withdrawal,
  coalesce(d.total_deposit, 0) - coalesce(w.total_withdrawal, 0) as expected_balance,
  s.is_active
from public.students s
left join public.classes c on c.id = s.class_id
left join (
  select student_id, sum(amount) as total_deposit
  from public.transactions
  where type = 'deposit'
  group by student_id
) d on d.student_id = s.id
left join (
  select student_id, sum(amount) as total_withdrawal
  from public.transactions
  where type = 'withdrawal'
  group by student_id
) w on w.student_id = s.id
order by c.name, s.full_name;

-- Reconciliation summary: any student whose computed balance is negative
-- indicates a withdrawal that broke invariant (should be impossible given
-- the create_transaction RPC's balance check).
select 'negative_balance_count' as check, count(*) as value
from (
  select s.id,
         coalesce(d.total_deposit, 0) - coalesce(w.total_withdrawal, 0) as bal
  from public.students s
  left join (
    select student_id, sum(amount) as total_deposit
    from public.transactions where type = 'deposit' group by student_id
  ) d on d.student_id = s.id
  left join (
    select student_id, sum(amount) as total_withdrawal
    from public.transactions where type = 'withdrawal' group by student_id
  ) w on w.student_id = s.id
) x
where x.bal < 0;
