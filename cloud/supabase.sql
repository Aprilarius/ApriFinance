-- Run once in the SQL editor of your own Supabase project.
-- No administrative key belongs in the application.
begin;
create table if not exists public.finance_snapshots (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  revision integer not null check (revision > 0),
  payload text not null check (octet_length(payload) <= 50331648),
  updated_at timestamptz not null default now()
);
alter table public.finance_snapshots enable row level security;
revoke all on public.finance_snapshots from public, anon, authenticated;
grant select on public.finance_snapshots to authenticated;
drop policy if exists read_own_snapshot on public.finance_snapshots;
create policy read_own_snapshot on public.finance_snapshots for select
  to authenticated using ((select auth.uid()) = owner_id);

-- Only this function can write. The owner comes from the verified JWT,
-- never from a client parameter. The lock also serializes initial inserts.
create or replace function public.put_finance_snapshot_v2(expected_revision integer, encrypted_payload text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  caller uuid := auth.uid();
  current_revision integer;
  envelope jsonb;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if expected_revision is null or expected_revision < 0 or expected_revision >= 2147483647
     or encrypted_payload is null or octet_length(encrypted_payload) > 50331648 then
    raise exception 'INVALID_SNAPSHOT';
  end if;
  envelope := encrypted_payload::jsonb;
  if envelope->>'format' is distinct from 'my-finances-encrypted'
     or envelope->>'version' is distinct from '1'
     or envelope->>'kdf' is distinct from 'pbkdf2-sha256'
     or envelope->>'iterations' is distinct from '600000'
     or envelope->>'cipher' is distinct from 'aes-256-gcm'
     or jsonb_typeof(envelope->'data') is distinct from 'string' then
    raise exception 'INVALID_SNAPSHOT';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(caller::text, 0));
  select s.revision into current_revision from public.finance_snapshots s where s.owner_id = caller;
  if coalesce(current_revision, 0) <> expected_revision then raise exception 'SYNC_CONFLICT'; end if;
  insert into public.finance_snapshots(owner_id, revision, payload, updated_at)
    values(caller, expected_revision + 1, encrypted_payload, now())
    on conflict(owner_id) do update set revision = excluded.revision,
      payload = excluded.payload, updated_at = excluded.updated_at;
  return expected_revision + 1;
end;
$$;
revoke all on function public.put_finance_snapshot_v2(integer,text) from public, anon;
grant execute on function public.put_finance_snapshot_v2(integer,text) to authenticated;
-- Older clients omit goals and analysis data. Reject their writes rather than
-- letting them replace a complete new snapshot with a reduced legacy snapshot.
create or replace function public.put_finance_snapshot(expected_revision integer, encrypted_payload text)
returns integer language plpgsql security definer set search_path = '' as $$
begin
  raise exception 'CLIENT_UPGRADE_REQUIRED';
end;
$$;
revoke all on function public.put_finance_snapshot(integer,text) from public, anon;
grant execute on function public.put_finance_snapshot(integer,text) to authenticated;
commit;
