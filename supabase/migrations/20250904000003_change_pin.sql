-- Self-service PIN change for parents (wali murid).
-- Verifies the old PIN, then replaces the bcrypt hash. Anonymous access is
-- safe: SECURITY DEFINER with no table grants, PIN never stored plaintext.

create or replace function public.change_student_pin(
  p_code text,
  p_old_pin text,
  p_new_pin text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student public.students;
begin
  if p_code is null or p_old_pin is null or p_new_pin is null
     or p_old_pin !~ '^\d{4}$' or p_new_pin !~ '^\d{4}$' then
    raise exception 'pin tidak valid' using errcode = '22023';
  end if;

  select * into v_student from public.students
   where public_code = p_code and is_active;
  if not found then
    raise exception 'siswa tidak ditemukan' using errcode = 'P0002';
  end if;

  if v_student.pin_hash <> extensions.crypt(p_old_pin, v_student.pin_hash) then
    raise exception 'pin lama salah' using errcode = '42501';
  end if;

  update public.students
     set pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf')),
         updated_at = now()
   where id = v_student.id;
end;
$$;

revoke all on function public.change_student_pin(text, text, text) from public;
grant execute on function public.change_student_pin(text, text, text) to anon, authenticated;
