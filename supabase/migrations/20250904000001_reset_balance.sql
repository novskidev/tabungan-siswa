-- Testing helper: reset a student's balance by deleting their transactions.
-- Master widened 20250904000004: role check is teacher/master.
-- Requested for manual testing of deposit/withdraw flows. History for that
-- student is removed; use only on test data, never to hide real records.

create or replace function public.reset_student_balance(p_student_id uuid)
returns void
language plpgsql
security invoker
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
end;
$$;

revoke all on function public.reset_student_balance(uuid) from public;
grant execute on function public.reset_student_balance(uuid) to authenticated;
