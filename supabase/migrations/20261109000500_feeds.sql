-- Friends feed and public feed. SECURITY INVOKER: entries/profiles RLS applies to the caller.

create type public.feed_item as (
  entry_id uuid,
  author_id uuid,
  author_handle extensions.citext,
  author_name text,
  author_color text,
  song_id text,
  song_title text,
  song_artist text,
  artwork_url text,
  group_key text,
  listened_at timestamptz,
  place_name text,
  place_lat float8,
  place_lng float8,
  comment text,
  visibility public.entry_visibility,
  posted_at timestamptz,
  source_entry_id uuid,
  source_author_name text
);

create function public.friends_feed(
  p_before_posted_at timestamptz default null,
  p_before_id uuid default null,
  p_limit int default 20
) returns setof public.feed_item
language plpgsql stable set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  return query
    select e.id, e.user_id, p.handle, p.display_name, p.star_color,
           s.id, s.title, s.artist, s.artwork_url, s.group_key,
           e.listened_at, e.place_name, e.place_lat, e.place_lng, e.comment,
           e.visibility, e.posted_at, e.source_entry_id, sp.display_name
      from public.entries e
      join public.profiles p on p.id = e.user_id
      join public.songs s on s.id = e.song_id
      left join public.entries se on se.id = e.source_entry_id
      left join public.profiles sp on sp.id = se.user_id
     where e.kind = 'post' and e.status = 'active'
       and e.visibility in ('friends', 'public')
       and (e.user_id = auth.uid() or public.are_friends(auth.uid(), e.user_id))
       and (p_before_posted_at is null or p_before_id is null
            or (e.posted_at, e.id) < (p_before_posted_at, p_before_id))
     order by e.posted_at desc, e.id desc
     limit greatest(1, least(coalesce(p_limit, 20), 50));
end $$;

create function public.public_feed(
  p_before_posted_at timestamptz default null,
  p_before_id uuid default null,
  p_limit int default 20
) returns setof public.feed_item
language plpgsql stable set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  return query
    select e.id, e.user_id, p.handle, p.display_name, p.star_color,
           s.id, s.title, s.artist, s.artwork_url, s.group_key,
           e.listened_at, e.place_name, e.place_lat, e.place_lng, e.comment,
           e.visibility, e.posted_at, e.source_entry_id, sp.display_name
      from public.entries e
      join public.profiles p on p.id = e.user_id
      join public.songs s on s.id = e.song_id
      left join public.entries se on se.id = e.source_entry_id
      left join public.profiles sp on sp.id = se.user_id
     where e.kind = 'post' and e.status = 'active'
       and e.visibility = 'public'
       and not public.is_blocked_between(auth.uid(), e.user_id)
       and (p_before_posted_at is null or p_before_id is null
            or (e.posted_at, e.id) < (p_before_posted_at, p_before_id))
     order by e.posted_at desc, e.id desc
     limit greatest(1, least(coalesce(p_limit, 20), 50));
end $$;

revoke execute on function public.friends_feed(timestamptz, uuid, int) from public, anon;
revoke execute on function public.public_feed(timestamptz, uuid, int) from public, anon;
grant execute on function public.friends_feed(timestamptz, uuid, int) to authenticated;
grant execute on function public.public_feed(timestamptz, uuid, int) to authenticated;
