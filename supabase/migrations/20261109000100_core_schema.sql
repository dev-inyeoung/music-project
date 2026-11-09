create extension if not exists citext with schema extensions;

create type public.entry_visibility as enum ('private', 'friends', 'public');
create type public.entry_kind as enum ('post', 'save');
create type public.entry_status as enum ('active', 'hidden', 'deleted');
create type public.friendship_status as enum ('pending', 'accepted');

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  handle extensions.citext unique check (handle ~ '^[a-z0-9_.]{3,20}$'),
  display_name text check (char_length(display_name) between 1 and 30),
  star_color text not null check (star_color ~ '^#[0-9A-F]{6}$'),
  created_at timestamptz not null default now()
);

create table public.songs (
  id text primary key,
  isrc text,
  title text not null,
  artist text not null,
  artwork_url text,
  group_key text generated always as (coalesce(isrc, 'am:' || id)) stored
);
create index songs_group_key_idx on public.songs (group_key);

create table public.entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles (id) on delete set null,
  song_id text not null references public.songs (id),
  listened_at timestamptz,
  place_name text check (char_length(place_name) <= 60),
  place_lat float8,
  place_lng float8,
  comment text check (char_length(comment) <= 500),
  visibility public.entry_visibility not null,
  kind public.entry_kind not null,
  source_entry_id uuid references public.entries (id) on delete set null,
  status public.entry_status not null default 'active',
  report_count int not null default 0,
  posted_at timestamptz,
  created_at timestamptz not null default now(),
  constraint entries_place_pair check ((place_lat is null) = (place_lng is null)),
  constraint entries_save_private check (kind <> 'save' or (visibility = 'private' and source_entry_id is not null)),
  constraint entries_post_posted_at check ((kind = 'post') = (posted_at is not null) or status = 'deleted')
);
create unique index entries_save_unique on public.entries (user_id, source_entry_id)
  where kind = 'save' and status <> 'deleted';
create index entries_feed_idx on public.entries (posted_at desc, id desc)
  where kind = 'post' and status = 'active';
create index entries_source_idx on public.entries (source_entry_id);
create index entries_user_listened_idx on public.entries (user_id, listened_at);

create table public.friendships (
  user_low uuid not null references public.profiles (id) on delete cascade,
  user_high uuid not null references public.profiles (id) on delete cascade,
  status public.friendship_status not null,
  requested_by uuid not null,
  created_at timestamptz not null default now(),
  primary key (user_low, user_high),
  check (user_low < user_high)
);

create table public.blocks (
  blocker uuid not null references public.profiles (id) on delete cascade,
  blocked uuid not null references public.profiles (id) on delete cascade,
  primary key (blocker, blocked),
  check (blocker <> blocked)
);

create table public.reports (
  reporter uuid references public.profiles (id) on delete set null,
  entry_id uuid not null references public.entries (id),
  reason text check (char_length(reason) <= 200),
  created_at timestamptz not null default now(),
  unique (reporter, entry_id)
);

-- Profile creation on signup, with a random star color from the palette.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_palette text[] := array['#FFD166','#06D6A0','#EF476F','#118AB2','#A78BFA','#F78C6B',
                            '#4CC9F0','#F15BB5','#9BE564','#FF9F1C','#2EC4B6','#E0AAFF'];
begin
  insert into public.profiles (id, star_color)
  values (new.id, v_palette[1 + floor(random() * 12)::int]);
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create function public.set_profile(p_handle text, p_display_name text) returns public.profiles
language plpgsql security definer set search_path = '' as $$
declare
  v_row public.profiles;
begin
  update public.profiles
     set handle = lower(trim(p_handle)), display_name = p_display_name
   where id = auth.uid()
   returning * into v_row;
  return v_row;
exception when unique_violation then
  raise exception 'handle_taken';
end $$;

create function public.upsert_song(p_id text, p_isrc text, p_title text, p_artist text, p_artwork_url text)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_key text;
begin
  insert into public.songs (id, isrc, title, artist, artwork_url)
  values (p_id, p_isrc, p_title, p_artist, p_artwork_url)
  on conflict (id) do update
    set isrc = coalesce(public.songs.isrc, excluded.isrc),
        title = excluded.title,
        artist = excluded.artist,
        artwork_url = coalesce(excluded.artwork_url, public.songs.artwork_url)
  returning group_key into v_key;
  return v_key;
end $$;

revoke execute on function public.set_profile(text, text) from public, anon;
revoke execute on function public.upsert_song(text, text, text, text, text) from public, anon;
grant execute on function public.set_profile(text, text) to authenticated;
grant execute on function public.upsert_song(text, text, text, text, text) to authenticated;

alter table public.profiles enable row level security;
alter table public.songs enable row level security;
alter table public.entries enable row level security;
alter table public.friendships enable row level security;
alter table public.blocks enable row level security;
alter table public.reports enable row level security;

revoke insert, update, delete on all tables in schema public from anon, authenticated;

create policy profiles_select_authenticated on public.profiles
  for select to authenticated using (true);
create policy songs_select_authenticated on public.songs
  for select to authenticated using (true);
