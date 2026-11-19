-- ECAM Reset Assist · STEP 2: shared reset-procedure changes (run once in Supabase → SQL Editor → New query → Run)
create table if not exists public.era_state(
  store text not null check (store in ('pbs','links','hide','conds','drafts','pnotes')),
  akey  text not null check (length(akey) between 1 and 120),
  value jsonb not null check (pg_column_size(value) < 20000),
  updated_by text,
  updated_at timestamptz not null default now(),
  primary key (store, akey)
);
create table if not exists public.era_state_log(
  id bigserial primary key,
  store text, akey text, old_value jsonb, new_value jsonb,
  changed_by text, changed_at timestamptz not null default now()
);
alter table public.era_state enable row level security;
alter table public.era_state_log enable row level security;
alter table public.era_state replica identity full;
revoke all on public.era_state, public.era_state_log from anon, authenticated;
grant select on public.era_state to anon, authenticated;
drop policy if exists "read state" on public.era_state;
create policy "read state" on public.era_state for select using (true);

create or replace function public.era_put_state(p_store text, p_key text, p_value jsonb, p_name text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_old jsonb;
begin
  if coalesce(trim(p_name),'') = '' then raise exception 'Name required'; end if;
  if (select count(*) from era_state_log where changed_at > now() - interval '1 minute') > 120 then
    raise exception 'Too many changes, try again in a minute';
  end if;
  select value into v_old from era_state where store = p_store and akey = p_key;
  if p_value is null or p_value = 'null'::jsonb then
    delete from era_state where store = p_store and akey = p_key;
  else
    insert into era_state(store, akey, value, updated_by, updated_at)
    values (p_store, p_key, p_value, left(trim(p_name),40), now())
    on conflict (store, akey) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  end if;
  insert into era_state_log(store, akey, old_value, new_value, changed_by) values (p_store, p_key, v_old, p_value, left(trim(p_name),40));
  return true;
end $$;
revoke all on function public.era_put_state(text,text,jsonb,text) from public;
grant execute on function public.era_put_state(text,text,jsonb,text) to anon, authenticated;

do $$ begin
  begin alter publication supabase_realtime add table public.era_state; exception when others then null; end;
end $$;
