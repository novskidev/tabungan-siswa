-- Sprint 7: Database integrity check.
-- Run in Supabase SQL Editor. Expected output: zero rows for each query.
-- Do NOT delete rows just to make these clean — investigate root cause first.

-- 1) Students without a class (class_id must exist).
select s.id, s.nis, s.full_name
from public.students s
left join public.classes c on c.id = s.class_id
where c.id is null;

-- 2) Students whose parent_id doesn't resolve to a profile.
select s.id, s.nis, s.full_name, s.parent_id
from public.students s
left join public.profiles p on p.id = s.parent_id
where s.parent_id is not null and p.id is null;

-- 3) Transactions whose student doesn't exist (FK CASCADE blocks; should never be).
select t.id, t.student_id
from public.transactions t
left join public.students s on s.id = t.student_id
where s.id is null;

-- 4) Transactions whose created_by doesn't resolve to a profile.
select t.id, t.created_by
from public.transactions t
left join public.profiles p on p.id = t.created_by
where p.id is null;

-- 5) Transactions with non-positive or null amount.
select id, student_id, amount
from public.transactions
where amount is null or amount <= 0;

-- 6) Transactions with invalid type.
select id, student_id, type
from public.transactions
where type not in ('deposit', 'withdrawal');

-- 7) Corrections pointing to a non-existent original (FK CASCADE blocks).
select t.id, t.correction_of
from public.transactions t
left join public.transactions o on o.id = t.correction_of
where t.correction_of is not null and o.id is null;

-- 8) Duplicate corrections on the same original (unique index blocks).
select correction_of, count(*) as n
from public.transactions
where correction_of is not null
group by correction_of
having count(*) > 1;

-- 9) Profile without an auth.users row (orphaned profile).
select p.id, p.full_name, p.role
from public.profiles p
left join auth.users u on u.id = p.id
where u.id is null;
