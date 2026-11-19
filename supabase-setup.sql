-- ECAM Reset Assist · shared comments & likes (run once in Supabase → SQL Editor → New query → Run)
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.era_comments(
  id uuid primary key default gen_random_uuid(),
  akey text not null check (length(akey) between 1 and 100),
  name text not null check (length(name) between 1 and 40),
  text text not null check (length(text) between 1 and 2000),
  eng  text check (length(eng) < 40),
  edit text check (length(edit) < 300),
  created_at timestamptz not null default now()
);
create table if not exists public.era_comment_owners(
  id uuid primary key references public.era_comments(id) on delete cascade,
  dev_hash text not null
);
create table if not exists public.era_likes(
  akey text not null check (length(akey) between 1 and 100),
  name_lc text not null check (length(name_lc) between 1 and 40),
  name text not null,
  created_at timestamptz not null default now(),
  primary key (akey, name_lc)
);

alter table public.era_comments enable row level security;
alter table public.era_likes enable row level security;
alter table public.era_comment_owners enable row level security;
alter table public.era_comments replica identity full;
alter table public.era_likes replica identity full;

-- everybody can read; nobody writes directly (only through the functions below)
revoke all on public.era_comments, public.era_likes, public.era_comment_owners from anon, authenticated;
grant select on public.era_comments to anon, authenticated;
grant select on public.era_likes to anon, authenticated;
drop policy if exists "read comments" on public.era_comments;
create policy "read comments" on public.era_comments for select using (true);
drop policy if exists "read likes" on public.era_likes;
create policy "read likes" on public.era_likes for select using (true);

create or replace function public.era_add_comment(p_akey text, p_name text, p_text text, p_eng text, p_edit text, p_token text)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid;
begin
  if (select count(*) from era_comments where created_at > now() - interval '1 minute') > 30 then
    raise exception 'Too many comments, try again in a minute';
  end if;
  insert into era_comments(akey, name, text, eng, edit)
  values (trim(p_akey), trim(p_name), trim(p_text), p_eng, nullif(p_edit, ''))
  returning id into v_id;
  insert into era_comment_owners(id, dev_hash) values (v_id, encode(digest(coalesce(p_token,''), 'sha256'), 'hex'));
  return v_id;
end $$;

create or replace function public.era_delete_comment(p_id uuid, p_token text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from era_comments c using era_comment_owners o
   where c.id = p_id and o.id = c.id and o.dev_hash = encode(digest(coalesce(p_token,''), 'sha256'), 'hex');
  return found;
end $$;

create or replace function public.era_toggle_like(p_akey text, p_name text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_lc text := lower(trim(p_name));
begin
  if v_lc = '' then raise exception 'Name required'; end if;
  delete from era_likes where akey = p_akey and name_lc = v_lc;
  if found then return false; end if;
  insert into era_likes(akey, name_lc, name) values (trim(p_akey), v_lc, trim(p_name));
  return true;
end $$;

revoke all on function public.era_add_comment(text,text,text,text,text,text), public.era_delete_comment(uuid,text), public.era_toggle_like(text,text) from public;
grant execute on function public.era_add_comment(text,text,text,text,text,text), public.era_delete_comment(uuid,text), public.era_toggle_like(text,text) to anon, authenticated;

-- live updates
do $$ begin
  begin alter publication supabase_realtime add table public.era_comments; exception when others then null; end;
  begin alter publication supabase_realtime add table public.era_likes; exception when others then null; end;
end $$;
