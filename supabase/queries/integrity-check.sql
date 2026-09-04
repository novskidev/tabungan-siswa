-- MVP: Database integrity check.
-- Run in Supabase SQL Editor. Expected output: zero rows for each query.
-- Do NOT delete rows just to make these clean — investigate root cause first.

-- 1) Students missing class_name, public_code, or pin_hash.
select id, nis, full_name
from public.students
where class_name is null or btrim(class_name) = ''
   or public_code is null or btrim(public_code) = ''
   or pin_hash is null or btrim(pin_hash) = '';

-- 2) Duplicate public_code (unique index blocks; should never be).
select public_code, count(*) as n
from public.students
group by public_code
having count(*) > 1;

-- 3) Transactions whose student doesn't exist (FK RESTRICT blocks; should never be).
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

-- 7) Corrections pointing to a non-existent original (FK RESTRICT blocks).
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

-- 10) Anon table access must stay zero (parents go through RPCs only).
select schemaname, tablename, policyname, roles
from pg_policies
where schemaname = 'public'
  and (tablename = 'students' or tablename = 'transactions')
  and 'anon' = any (roles);
