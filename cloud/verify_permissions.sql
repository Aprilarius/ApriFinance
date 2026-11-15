-- Transactional checks on fictional accounts; every fixture is rolled back.
-- Run in the Supabase SQL Editor after supabase.sql.
begin;
insert into auth.users(id) values
  ('00000000-0000-4000-8000-000000000001'),
  ('00000000-0000-4000-8000-000000000002');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
do $$
declare
  envelope text := '{"format":"my-finances-encrypted","version":1,"kdf":"pbkdf2-sha256","iterations":600000,"cipher":"aes-256-gcm","data":"fictional-test-only"}';
begin
  if public.put_finance_snapshot_v2(0, envelope) <> 1 then
    raise exception 'FAIL_INITIAL_WRITE';
  end if;
  if (select count(*) from public.finance_snapshots) <> 1 then
    raise exception 'FAIL_OWNER_READ';
  end if;
  begin
    perform public.put_finance_snapshot_v2(0, envelope);
    raise exception 'FAIL_STALE_WRITE_ALLOWED';
  exception when raise_exception then
    if sqlerrm <> 'SYNC_CONFLICT' then raise; end if;
  end;
  begin
    insert into public.finance_snapshots(owner_id,revision,payload)
      values ('00000000-0000-4000-8000-000000000002',1,envelope);
    raise exception 'FAIL_DIRECT_WRITE_ALLOWED';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.put_finance_snapshot(1,envelope);
    raise exception 'FAIL_LEGACY_WRITE_ALLOWED';
  exception when raise_exception then
    if sqlerrm <> 'CLIENT_UPGRADE_REQUIRED' then raise; end if;
  end;
end $$;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
do $$
begin
  if exists(select 1 from public.finance_snapshots) then
    raise exception 'FAIL_OTHER_OWNER_READ';
  end if;
end $$;
select set_config('request.jwt.claims', '{}', true);
do $$
begin
  begin
    perform public.put_finance_snapshot_v2(0,'{}');
    raise exception 'FAIL_UNAUTHENTICATED_WRITE_ALLOWED';
  exception when raise_exception then
    if sqlerrm <> 'AUTH_REQUIRED' then raise; end if;
  end;
end $$;
reset role;
do $$
begin
  if has_table_privilege('anon','public.finance_snapshots','SELECT')
    or has_function_privilege('anon','public.put_finance_snapshot_v2(integer,text)','EXECUTE') then
    raise exception 'FAIL_ANONYMOUS_PRIVILEGES';
  end if;
end $$;
rollback;
select 'PASS: owner isolation, denied direct/anonymous/legacy writes, revision conflict; fixtures rolled back' as result;
