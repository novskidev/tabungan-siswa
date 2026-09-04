-- Teacher/master student deletion (testing cleanup). Master widened 20250904000004.
-- Deletes the student's transactions first, then the student, in one call.
-- SECURITY DEFINER is required: teachers have no DELETE grant on
-- transactions, so the function bypasses RLS after checking teacher role.

create or replace function public.delete_student(p_student_id uuid)
returns void
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
                 where p.id = v_uid and p.role in ('teacher', 'master')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  delete from public.transactions where student_id = p_student_id;
  delete from public.students where id = p_student_id;
  if not found then
    raise exception 'siswa tidak ditemukan' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.delete_student(uuid) from public;
grant execute on function public.delete_student(uuid) to authenticated;
