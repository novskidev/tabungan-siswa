-- Sprint 1: local dev seed (run manually in Supabase SQL Editor, NOT in production).
-- Creates 1 teacher, 3 parents, 2 classes, 3 students for RLS testing.
-- DO NOT run this in production. DO NOT commit real auth.users to Git.

-- Teacher
insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at, created_at, updated_at, aud, role)
values
  ('00000000-0000-0000-0000-000000000001', 'teacher@example.com', '{}', now(), now(), now(), 'authenticated', 'authenticated')
on conflict (id) do nothing;

insert into public.profiles (id, full_name, role)
values ('00000000-0000-0000-0000-000000000001', 'Bu Guru Test', 'teacher')
on conflict (id) do nothing;

-- Parent A
insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at, created_at, updated_at, aud, role)
values
  ('00000000-0000-0000-0000-000000000002', 'parent.a@example.com', '{}', now(), now(), now(), 'authenticated', 'authenticated')
on conflict (id) do nothing;

insert into public.profiles (id, full_name, role)
values ('00000000-0000-0000-0000-000000000002', 'Bapak Ahmad', 'parent')
on conflict (id) do nothing;

-- Parent B
insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at, created_at, updated_at, aud, role)
values
  ('00000000-0000-0000-0000-000000000003', 'parent.b@example.com', '{}', now(), now(), now(), 'authenticated', 'authenticated')
on conflict (id) do nothing;

insert into public.profiles (id, full_name, role)
values ('00000000-0000-0000-0000-000000000003', 'Ibu Budi', 'parent')
on conflict (id) do nothing;

-- Parent C
insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at, created_at, updated_at, aud, role)
values
  ('00000000-0000-0000-0000-000000000004', 'parent.c@example.com', '{}', now(), now(), now(), 'authenticated', 'authenticated')
on conflict (id) do nothing;

insert into public.profiles (id, full_name, role)
values ('00000000-0000-0000-0000-000000000004', 'Bapak Citra', 'parent')
on conflict (id) do nothing;

-- Classes
insert into public.classes (id, name, academic_year)
values
  ('11111111-1111-1111-1111-111111111111', '1A', '2025/2026'),
  ('22222222-2222-2222-2222-222222222222', '2A', '2025/2026')
on conflict (id) do nothing;

-- Students (Parent A has 2, Parent B has 1, Parent C has none)
insert into public.students (nis, full_name, class_id, parent_id)
values
  ('2026001', 'Ahmad Fauzan', '11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000002'),
  ('2026002', 'Anisa Putri', '11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000002'),
  ('2026003', 'Budi Santoso', '11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000003')
on conflict (nis) do nothing;

-- Sprint 2: sample transactions for testing the transaction UI.
-- Uses fixed UUIDs for the transactions so the seed is idempotent.
insert into public.transactions (id, student_id, type, amount, note, created_by, created_at)
values
  ('aaaaaaaa-0000-0000-0000-000000000001',
   (select id from public.students where nis = '2026001'),
   'deposit', 50000, 'Tabungan harian',
   '00000000-0000-0000-0000-000000000001', now() - interval '2 days'),
  ('aaaaaaaa-0000-0000-0000-000000000002',
   (select id from public.students where nis = '2026001'),
   'deposit', 75000, null,
   '00000000-0000-0000-0000-000000000001', now() - interval '1 day'),
  ('aaaaaaaa-0000-0000-0000-000000000003',
   (select id from public.students where nis = '2026001'),
   'withdrawal', 20000, 'Beli alat tulis',
   '00000000-0000-0000-0000-000000000001', now() - interval '3 hours'),
  ('aaaaaaaa-0000-0000-0000-000000000004',
   (select id from public.students where nis = '2026002'),
   'deposit', 30000, null,
   '00000000-0000-0000-0000-000000000001', now() - interval '5 hours'),
  ('aaaaaaaa-0000-0000-0000-000000000005',
   (select id from public.students where nis = '2026003'),
   'deposit', 100000, 'Tabungan awal',
   '00000000-0000-0000-0000-000000000001', now() - interval '6 hours')
on conflict (id) do nothing;

-- Sprint 5: sample correction.
-- Original tx 0003 was a 20k withdrawal. Seed a correction of 10k that was
-- supposed to be the withdrawal amount instead.
insert into public.transactions (
  id, student_id, type, amount, note, created_by, created_at,
  correction_of, correction_reason, corrected_by, corrected_at
)
select
  'aaaaaaaa-0000-0000-0000-000000000006',
  (select student_id from public.transactions where id = 'aaaaaaaa-0000-0000-0000-000000000003'),
  'deposit', 10000,
  'Koreksi: nominal tarik seharusnya 10.000',
  '00000000-0000-0000-0000-000000000001',
  now(),
  'aaaaaaaa-0000-0000-0000-000000000003',
  'Nominal tarik seharusnya 10.000',
  '00000000-0000-0000-0000-000000000001',
  now()
where not exists (
  select 1 from public.transactions where correction_of = 'aaaaaaaa-0000-0000-0000-000000000003'
);
