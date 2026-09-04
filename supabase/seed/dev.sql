-- MVP local dev seed (run manually in Supabase SQL Editor, NOT in production).
-- Teacher-only auth; parents are anonymous via public_code + PIN.
-- DO NOT run this in production. DO NOT commit real auth.users to Git.

-- Teacher
insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at, created_at, updated_at, aud, role)
values
  ('00000000-0000-0000-0000-000000000001', 'teacher@example.com', '{}', now(), now(), now(), 'authenticated', 'authenticated')
on conflict (id) do nothing;

insert into public.profiles (id, full_name, role)
values ('00000000-0000-0000-0000-000000000001', 'Bu Guru Test', 'teacher')
on conflict (id) do nothing;

-- Students with public access codes. Default PIN = first digit of class x4.
-- Ahmad (kelas 1A) PIN 1111, Budi (kelas 2A) PIN 2222.
insert into public.students (id, nis, full_name, class_name, public_code, pin_hash)
values
  ('11111111-1111-1111-1111-111111111111', '2026001', 'Ahmad Fauzan', '1A', 'ahmad1',
   extensions.crypt('1111', extensions.gen_salt('bf'))),
  ('22222222-2222-2222-2222-222222222222', '2026002', 'Budi Santoso', '2A', 'budi22',
   extensions.crypt('2222', extensions.gen_salt('bf')))
on conflict (id) do update set
  nis = excluded.nis,
  full_name = excluded.full_name,
  class_name = excluded.class_name,
  public_code = excluded.public_code,
  pin_hash = excluded.pin_hash;

-- Sample transactions: Ahmad deposit 10K + 20K, withdraw 5K → saldo 25K.
insert into public.transactions (id, student_id, type, amount, note, created_by, created_at)
values
  ('aaaaaaaa-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111',
   'deposit', 10000, 'Tabungan harian',
   '00000000-0000-0000-0000-000000000001', now() - interval '2 days'),
  ('aaaaaaaa-0000-0000-0000-000000000002',
   '11111111-1111-1111-1111-111111111111',
   'deposit', 20000, null,
   '00000000-0000-0000-0000-000000000001', now() - interval '1 day'),
  ('aaaaaaaa-0000-0000-0000-000000000003',
   '11111111-1111-1111-1111-111111111111',
   'withdrawal', 5000, 'Beli alat tulis',
   '00000000-0000-0000-0000-000000000001', now() - interval '3 hours'),
  ('aaaaaaaa-0000-0000-0000-000000000004',
   '22222222-2222-2222-2222-222222222222',
   'deposit', 30000, null,
   '00000000-0000-0000-0000-000000000001', now() - interval '5 hours')
on conflict (id) do nothing;
